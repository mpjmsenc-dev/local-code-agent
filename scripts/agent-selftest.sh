#!/usr/bin/env bash
# scripts/agent-selftest.sh — prove the agent tier can actually do work, here,
# on this box, and say how long it took.
#
# Everything this checks was learned the hard way across three sessions of
# debugging, and none of it was knowledge the repo held. A tier that "starts"
# tells you almost nothing: it started every time while it was silently
# incapable of executing a single tool call, and the run it produced was marked
# 'finished' with an empty workspace and no error anywhere to find.
#
# So this runs one small REAL task end to end and asserts a file appeared. Each
# link is checked in the order it breaks, and each failure names the remedy —
# because "the agent does not work" is the least useful sentence in this repo's
# history and every one of these links produced it at least once:
#
#   relay      the container cannot reach Ollama at all; tasks fail silently
#   model      the derived model is missing, so the window is the chat app's
#   container  not running, or running on a different port than .env says
#   settings   never seeded, so the first task dies inside the app on an assert
#   channel    native tool calling on, and this model never uses it
#   task       everything above fine and still no file on disk
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_env

TASK_TEXT='Create a file /workspace/project/lca_selftest.py containing a function selftest() that returns the string "ok". Then stop.'
TASK_FILE='lca_selftest.py'

usage() {
  cat <<EOF
Usage: lca agent selftest [--keep]

Runs one small real task through the agent and asserts a file appeared.
Reports the wall clock and this machine's measured speed, so the answer to
"is this tier usable here?" is a number rather than an opinion.

  --keep   leave the conversation and its sandbox behind for inspection

Every link is named on failure, with what to run. Why each one exists and what
it cost to find: docs/AGENT.md
EOF
}

fail() { err "$*"; exit 1; }

# link_relay — can anything in a container reach the model at all?
link_relay() {
  step "1/6  The relay"
  if [[ "${ENABLE_OLLAMA_RELAY}" != "true" ]]; then
    fail "ENABLE_OLLAMA_RELAY is false, so the agent cannot reach Ollama on ${OLLAMA_HOST} — a container's loopback is the container, and every task would fail without producing a token. Set it true in ${ENV_FILE}, then: sudo ${REPO_ROOT}/bin/lca relay install"
  fi
  ollama_relay_healthy \
    || fail "Nothing answers through the relay at $(ollama_relay_address). Install or repair it: sudo ${REPO_ROOT}/bin/lca relay install   (then: lca relay status)"
  ok "Ollama answers through $(ollama_relay_address)."
}

# link_model — the derived model, and the window Ollama really loads it at.
link_model() {
  local want got model
  step "2/6  The model"
  model="$(agent_model_name "${MODEL_NAME}")"
  want="$(agent_model_context)"
  case "$(agent_model_drift 2>/dev/null || printf ok)" in
    absent)
      fail "'${model}' does not exist, so the agent would run at the server-wide context (${OLLAMA_CONTEXT_LENGTH}) — its first prompt on a real run was 13,796 tokens, and at the server-wide context it would not fit. Build it: sudo ${SCRIPT_DIR}/tune.sh" ;;
    context)
      got="$(agent_model_loaded_context "${model}" 2>/dev/null || printf unknown)"
      fail "'${model}' exists but Ollama loads it at ${got}, not ${want}, so the agent would silently truncate mid-task. Rebuild it: sudo ${SCRIPT_DIR}/tune.sh" ;;
  esac
  ok "${model} loads at ${want} tokens."
}

# link_container — running, and on the port .env names.
link_container() {
  local live
  step "3/6  The container"
  agent_container_running \
    || fail "The agent container is not running. Start it: ${REPO_ROOT}/bin/lca agent start"
  live="$(agent_live_port 2>/dev/null || printf '%s' "${AGENT_PORT}")"
  [[ "${live}" == "${AGENT_PORT}" ]] \
    || fail "The agent is published on port ${live}, not .env's ${AGENT_PORT} — its port is fixed when the container is created, so everything below would ask the wrong socket. Re-create it: ${REPO_ROOT}/bin/lca agent restart"
  ok "Container running on ${AGENT_PORT}."
}

# link_settings — seeded, pointed at the relay, and in the right tool mode.
#
# Read back rather than assumed. That endpoint declares additionalProperties
# true, so it answers 200 to a body it stores none of — this project shipped a
# "settings seeded" message about exactly that once.
link_settings() {
  local url got_model got_native want_model
  step "4/6  The settings"
  url="$(agent_api_base)/api/v1/settings"
  want_model="$(agent_llm_model "$(agent_model_name "${MODEL_NAME}")")"
  got_model="$(curl -fsS --max-time 10 "${url}" 2>/dev/null | jq -r '.agent_settings.llm.model // ""' 2>/dev/null || true)"
  [[ -n "${got_model}" ]] \
    || fail "The agent's settings API answered nothing at ${url}. Without settings the first task dies inside the app on an assertion, not with a message. Re-create it: ${REPO_ROOT}/bin/lca agent restart"
  [[ "${got_model}" == "${want_model}" ]] \
    || fail "The agent holds model '${got_model}', not '${want_model}' — it would run against the wrong model or none. Re-seed by re-creating it: ${REPO_ROOT}/bin/lca agent restart"
  got_native="$(agent_stored_native_tool_calling "$(curl -fsS --max-time 10 "${url}" 2>/dev/null || true)")"
  [[ "${got_native}" == "${AGENT_NATIVE_TOOL_CALLING}" ]] \
    || fail "The agent holds native_tool_calling='${got_native}', not '${AGENT_NATIVE_TOOL_CALLING}'. With qwen2.5-coder that is the difference between a run that works and one that ends instantly with an empty workspace. Re-create it: ${REPO_ROOT}/bin/lca agent restart"
  ok "Settings hold ${got_model}, native tool calling ${got_native}."
}

# link_channel — will this model's tool calls survive the channel it is on?
#
# Asked of the MODEL, directly, before a task is submitted: this is the failure
# that costs half an hour to discover from the other end, because the run
# succeeds, reports 'finished', and produces nothing.
link_channel() {
  local resp calls body
  step "5/6  The tool-call channel"
  body="$(jq -nc --arg m "$(agent_model_name "${MODEL_NAME}")" \
    '{model:$m, temperature:0, max_tokens:64,
      messages:[{role:"user",content:"Create /tmp/x.py containing print(1). Use the tool."}],
      tools:[{type:"function",function:{name:"file_editor",description:"Create or edit a file.",
              parameters:{type:"object",properties:{path:{type:"string"},file_text:{type:"string"}},
                          required:["path","file_text"]}}}]}')"
  resp="$(curl -fsS --max-time 900 -X POST "$(ollama_url)/v1/chat/completions" \
          -H 'Content-Type: application/json' -d "${body}" 2>/dev/null || true)"
  [[ -n "${resp}" ]] \
    || fail "The model did not answer a tool-calling probe at all. Is it loaded? ${REPO_ROOT}/bin/lca speed"
  calls="$(jq -r '.choices[0].message.tool_calls | if . then length else 0 end' <<<"${resp}" 2>/dev/null || printf 0)"
  if [[ "${AGENT_NATIVE_TOOL_CALLING}" == "true" ]] && [[ "${calls}" == "0" ]]; then
    fail "AGENT_NATIVE_TOOL_CALLING is true and this model returned ZERO native tool calls — it writes them into the message body instead, and the agent will read that as 'the assistant has finished' and stop with an empty workspace. Measured on qwen2.5-coder at 3b AND 7b, so a bigger model is not the fix. Set AGENT_NATIVE_TOOL_CALLING=false in ${ENV_FILE}, then: ${REPO_ROOT}/bin/lca agent restart"
  fi
  if [[ "${AGENT_NATIVE_TOOL_CALLING}" == "true" ]]; then
    ok "The model returns native tool calls (${calls})."
  else
    ok "Prompt-parsed tool calls (native returned ${calls}, which is why this mode is the default)."
  fi
}

# sandbox_has_file NAME — did a file really land in the agent's workspace?
#
# Asked of the sandbox container, because that is where /workspace lives: the
# app container starts conversations and hands the work to a sandbox it names
# at runtime.
sandbox_has_file() {
  local name="$1" sb
  sb="$(as_root docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^oh-agent-server-' | head -1 || true)"
  [[ -n "${sb}" ]] || return 1
  as_root docker exec "${sb}" sh -c "ls /workspace/project/${name}" >/dev/null 2>&1
}

# link_task — the whole point. One small task, and a file on disk.
link_task() {
  local base cid started now elapsed events last_events=-1 quiet=0
  step "6/6  A real task"
  base="$(agent_api_base)"
  started="$(date +%s)"
  curl -fsS --max-time 120 -X POST "${base}/api/v1/app-conversations" \
    -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg t "${TASK_TEXT}" \
          '{initial_message:{role:"user",content:[{type:"text",text:$t}]}}')" \
    >/dev/null 2>&1 \
    || fail "The agent refused the task at ${base}/api/v1/app-conversations. Check its log: ${REPO_ROOT}/bin/lca agent logs"
  info "Task submitted. On a CPU box the first step alone has been measured at 10 minutes; the limit here is AGENT_TIMEOUT_MINUTES=${AGENT_TIMEOUT_MINUTES}."

  # The conversation id is discovered from the listing, NOT taken from the POST
  # above: that call answers with its own start-task id, and the events API
  # returns nothing for it.
  while :; do
    now="$(date +%s)"; elapsed=$(( now - started ))
    if [[ "${AGENT_TIMEOUT_MINUTES}" =~ ^[0-9]+$ ]] && (( AGENT_TIMEOUT_MINUTES > 0 )) \
       && (( elapsed >= AGENT_TIMEOUT_MINUTES * 60 )); then
      fail "No file after $(human_duration "${elapsed}") (AGENT_TIMEOUT_MINUTES). The chain above is fine, so this is the model being too slow or too small for this task on this box — see the timing table in docs/AGENT.md."
    fi
    if sandbox_has_file "${TASK_FILE}"; then
      ok "The agent wrote /workspace/project/${TASK_FILE} after $(human_duration "${elapsed}")."
      SELFTEST_SECONDS="${elapsed}"
      return 0
    fi
    [[ -n "${cid:-}" ]] || cid="$(agent_conversation_ref 2>/dev/null || true)"
    if [[ -n "${cid:-}" ]]; then
      events="$(agent_event_steps "${cid}" 2>/dev/null || printf '?')"
      if [[ "${events}" == "${last_events}" ]]; then
        quiet=$(( quiet + 1 ))
      else
        quiet=0; last_events="${events}"
        info "  ${events} event(s), $(human_duration "${elapsed}") elapsed"
      fi
    fi
    sleep 15
  done
}

# report_speed — this machine's numbers, so "usable here?" gets an answer.
#
# From Ollama's own counters rather than a stopwatch: they exclude model load
# and connection overhead, which on a CPU box are most of a short request.
report_speed() {
  local resp p_c p_ns e_c e_ns
  step "This machine"
  resp="$(curl -fsS --max-time 1800 -X POST "$(ollama_url)/api/generate" \
          -d "$(jq -nc --arg m "$(agent_model_name "${MODEL_NAME}")" --arg p "$(read_probe_prompt)" \
                '{model:$m, prompt:$p, stream:false, options:{num_predict:40}}')" 2>/dev/null || true)"
  if [[ -z "${resp}" ]]; then
    warn "Could not measure this machine's speed; the task result above stands."
    return 0
  fi
  p_c="$(jq -r '.prompt_eval_count // 0' <<<"${resp}")"
  p_ns="$(jq -r '.prompt_eval_duration // 0' <<<"${resp}")"
  e_c="$(jq -r '.eval_count // 0' <<<"${resp}")"
  e_ns="$(jq -r '.eval_duration // 0' <<<"${resp}")"
  info "Reading: $(tokens_per_second "${p_c}" "${p_ns}" || printf '?') tok/s   Writing: $(tokens_per_second "${e_c}" "${e_ns}" || printf '?') tok/s"
  info "One agent task here: $(human_duration "${SELFTEST_SECONDS:-0}")."
}

main() {
  local keep=false arg
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --keep) keep=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) arg="$1"; usage >&2; die "Unknown option: ${arg}" ;;
    esac
  done
  require_cmd docker; require_cmd curl; require_cmd jq
  [[ "${ENABLE_AGENT}" == "true" ]] \
    || die "ENABLE_AGENT is false in ${ENV_FILE}, so there is no agent tier to test."
  link_relay
  link_model
  link_container
  link_settings
  link_channel
  link_task
  report_speed
  if [[ "${keep}" == "false" ]]; then
    # The workspace is the user's, so only this test's own file is taken back.
    local sb
    sb="$(as_root docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^oh-agent-server-' | head -1 || true)"
    [[ -z "${sb}" ]] \
      || as_root docker exec "${sb}" sh -c "rm -f /workspace/project/${TASK_FILE}" >/dev/null 2>&1 || true
  fi
  ok "The agent tier works on this machine, end to end."
}

main "$@"
