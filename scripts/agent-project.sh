#!/usr/bin/env bash
# scripts/agent-project.sh — project mode: one spec in, a built project out.
#
#   lca agent project SPEC --dir DIR [--autonomy ask|self|answerer]
#
# The agent plans the project into PLAN.md, a numbered checklist where every
# step names the command that proves it, after deciding whether a mature
# open-source project should be the base (DECISIONS.md, with its license).
# Then, for each step, as fresh conversations of their own: its tests are
# written first and committed; the step is implemented and verified by that
# command, and committed only when it passes; and the accepted change is
# reviewed for bugs and security. A step whose tests fail is retried with
# their output, AGENT_PROJECT_RETRIES times, and then the run STOPS rather
# than building on a broken base.
#
# Two engines do the work (AGENT_PROJECT_ENGINE, or --engine): openhands, a
# conversation in the app (through scripts/agent-task.sh, with the directory
# named), and opencode, 'opencode run' in a throwaway container. Everything
# around them (the plan, verification, commits, questions, the stops) is the
# same code for both, so the two can be compared on the same spec.
#
# Unattended, and the pieces that make that safe are deliberate:
#
#   it runs under systemd   not under your SSH session; enabled, so a reboot
#                           resumes it (local-code-agent-project@.service)
#   state is in DIR         .lca-project/state, PLAN.md's ticks and git — so a
#                           restart picks up at the step it was on
#   verification is not     the step's command runs in a throwaway container
#   the agent's word        from the agent's own image, with the network off
#   three hard stops        credentials, anything outside DIR, deleting data:
#                           never decided by any autonomy mode (lib.sh,
#                           project_hard_stop and the checks after each step)
#
# The decisions are pure functions in scripts/lib.sh (the project-mode
# section), driven by the suite; this file is the loop that feeds them.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_env

# The sandbox runs as this group (uid and gid 10001 in the agent-server image,
# measured with 'docker run --rm IMAGE id'). Files are kept group-owned by it and
# group-writable, so the sandbox can edit what the runner committed and the
# runner can commit what the sandbox wrote.
PROJECT_SANDBOX_GID=10001
# How long one verification may run before it counts as a failure.
PROJECT_VERIFY_SECONDS=900
# Questions one attempt may ask before the attempt is abandoned: a model that
# keeps asking is not converging, whoever is answering.
PROJECT_MAX_QUESTIONS=3

usage() {
  cat <<EOF
Usage: lca agent project SPEC --dir DIR [--autonomy ask|self|answerer]
                                [--engine openhands|opencode] [--foreground]
       lca agent project --dir DIR --status | --stop | --resume [--answer "text"]

Builds a project from one spec file with no input from you: the agent writes
PLAN.md (small steps, each with a command that proves it), choosing a mature
open-source base project when one fits. Then, for each step: its tests are
written first, the step is implemented and verified and committed when it
passes, and the change is reviewed for bugs and security. A step that fails
${AGENT_PROJECT_RETRIES} retries stops the run instead of building on it.

  --dir DIR         the project directory; must be under AGENT_PROJECTS_DIR
                    (now: ${AGENT_PROJECTS_DIR:-unset — project mode is off})
  --autonomy MODE   when the agent stops to ask (default: ${AGENT_PROJECT_AUTONOMY}):
                    - ask       stop and report the question
                    - self      it decides, and records why in DECISIONS.md
                    - answerer  $(project_answerer_model) answers as project lead,
                                and the answer is logged in DECISIONS.md
                    In every mode it stops for credentials, anything outside
                    DIR, and deleting data.
  --engine ENGINE   who does the work (default: ${AGENT_PROJECT_ENGINE}):
                    - openhands  the agent app, a sandbox per conversation
                    - opencode   OpenCode ${AGENT_OPENCODE_VERSION}, a container per turn
                                 (needs a model whose native tool calls work)
  --foreground      run here instead of under systemd
  --status          where it is: the plan, the state, the last log lines
  --stop            stop it and stop it resuming at boot
  --resume          carry on from where it stopped; --answer adds your
                    answer to the open question to DECISIONS.md first

Follow it: lca agent watch --live      Full notes: docs/AGENT.md
EOF
}

# --- state: one KEY=VALUE file in the project ---------------------------------
state_get() {   # KEY -> value, or nothing
  [[ -r "${STATE_FILE}" ]] || return 0
  sed -n "s/^$1=//p" "${STATE_FILE}" | tail -1
}
state_set() {   # KEY VALUE... — replaces each KEY, keeps the rest, stamps UPDATED
  local tmp keys=UPDATED i
  local -a kv=("$@")
  for (( i = 0; i + 1 < ${#kv[@]}; i += 2 )); do keys+="|${kv[i]}"; done
  tmp="$(mktemp "${STATE_DIR}/.state.XXXXXX")"
  {
    if [[ -r "${STATE_FILE}" ]]; then grep -vE "^(${keys})=" "${STATE_FILE}" || true; fi
    for (( i = 0; i + 1 < ${#kv[@]}; i += 2 )); do
      printf '%s=%s\n' "${kv[i]}" "${kv[i+1]//$'\n'/ }"
    done
    printf 'UPDATED=%s\n' "$(date -u +%FT%TZ)"
  } > "${tmp}"
  mv -f "${tmp}" "${STATE_FILE}"
}

say() {   # MESSAGE — to the project log and to stdout (the journal, under systemd)
  local line
  line="$(date -u '+%F %T') $*"
  printf '%s\n' "${line}" >> "${STATE_DIR}/run.log" 2>/dev/null || true
  printf '%s\n' "${line}"
}

# --- the host side: ownership, git, the sandbox image ---------------------------
runtime_image() { printf '%s:%s' "${AGENT_RUNTIME_IMAGE}" "${AGENT_RUNTIME_TAG}"; }
# The person the project belongs to, and their uid — invoking_user, so a run
# started under sudo still hands the files to the person and not to root.
owner_uid() { id -u "$(invoking_user)"; }

# The project is owned by the person running this and group-owned by the
# sandbox's group, group-writable, with setgid directories. Done before and
# after every step: the sandbox writes as uid 10001, which the runner could
# otherwise read but never edit, and git could never commit over.
normalize_perms() {
  docker run --rm --network none --user 0 --entrypoint sh \
    -v "${DIR}:/p" "$(runtime_image)" -c \
    "chown -R $(owner_uid):${PROJECT_SANDBOX_GID} /p && chmod -R g+rwX /p && find /p -type d -exec chmod g+s {} +" \
    >/dev/null 2>&1
}

git_here() { git -C "${DIR}" "$@"; }

ensure_repo() {
  if [[ ! -d "${DIR}/.git" ]]; then
    git_here init -q
    say "git: initialised ${DIR}"
  fi
  # The runner's own state is not the project's history, and neither are the
  # dependencies a step installs into the project, nor what running it leaves.
  local x
  for x in .lca-project/ .venv/ venv/ node_modules/ __pycache__/ '*.pyc' .pytest_cache/; do
    grep -qxF -- "${x}" "${DIR}/.git/info/exclude" 2>/dev/null \
      || printf '%s\n' "${x}" >> "${DIR}/.git/info/exclude"
  done
  git_here config user.name >/dev/null 2>&1 || git_here config user.name "lca project mode"
  git_here config user.email >/dev/null 2>&1 || git_here config user.email "lca-project@localhost"
}

commit_all() {   # MESSAGE
  git_here add -A
  if git_here diff --cached --quiet; then
    say "git: nothing to commit for: $1"
    return 0
  fi
  git_here commit -q -m "$1"
  say "git: committed $(git_here rev-parse --short HEAD) $1"
}

# --- the agent side: conversations, through the app's API -----------------------
api() { agent_api_base; }

# conversation_json CID — the app's record of one conversation, or nothing.
conversation_json() {
  curl -fsS --max-time 15 "$(api)/api/v1/app-conversations?ids=$1" 2>/dev/null \
    | jq -c --arg id "$1" '[.. | objects | select(.id? == $id)] | .[0] // empty' 2>/dev/null
}

conversation_field() {   # CID FIELD
  conversation_json "$1" | jq -r --arg f "$2" '.[$f] // empty' 2>/dev/null
}

delete_sandbox() {   # CID — the step is over; its work is on the host already
  local sid tries=0
  # A conversation seconds old may not have its sandbox recorded yet: the
  # stop that came 90 s into a step found no id, returned without a word, and
  # left the sandbox running. Asked again for up to 30 s, and said if never.
  while :; do
    sid="$(conversation_field "$1" sandbox_id || true)"
    [[ -z "${sid}" && "${tries}" -lt 6 ]] || break
    tries=$(( tries + 1 )); sleep 5
  done
  [[ -n "${sid}" ]] || { say "could not find the sandbox of conversation $1 to remove it (lca agent gc collects it)"; return 0; }
  if curl -fsS --max-time 120 -X DELETE "$(agent_sandbox_delete_url "${sid}")" >/dev/null 2>&1; then
    say "sandbox ${sid} removed"
  else
    say "could not remove sandbox ${sid} (it is collected later by: lca agent gc)"
  fi
}

# submit TASK — a fresh conversation for TASK, through agent-task.sh so it gets
# every precondition and prompt rule that command has. Sets CID.
submit() {
  local before out rc=0
  before="$(head -1 "${AGENT_CONVERSATION_FILE}" 2>/dev/null || true)"
  out="$("${SCRIPT_DIR}/agent-task.sh" --dir "${SBX}" "$1" 2>&1)" || rc=$?
  printf '%s\n' "${out}" >> "${STATE_DIR}/run.log"
  CID="$(head -1 "${AGENT_CONVERSATION_FILE}" 2>/dev/null || true)"
  if (( rc != 0 )) || [[ -z "${CID}" || "${CID}" == "${before}" ]]; then
    CID=""
    return 1
  fi
  state_set CONVERSATION "${CID}"
  say "conversation ${CID} started"
}

# wait_turn CID — until the agent stops. Prints how it stopped:
# finished | error | stuck | timeout | iterations | gone
wait_turn() {
  local cid="$1" started now st sb steps idle_polls=0 seen_running=false
  started="$(date +%s)"
  while :; do
    st="$(conversation_field "${cid}" execution_status || true)"
    sb="$(conversation_field "${cid}" sandbox_status || true)"
    case "${st}" in
      finished|error|stuck) printf '%s' "${st}"; return 0 ;;
      running) seen_running=true; idle_polls=0 ;;
      idle)
        # Idle before the first token is a sandbox still starting; idle after
        # running is a turn that ended without a finish.
        if [[ "${seen_running}" == "true" ]]; then
          idle_polls=$(( idle_polls + 1 ))
          (( idle_polls < 3 )) || { printf 'finished'; return 0; }
        fi ;;
    esac
    case "${sb}" in
      MISSING|ERROR|PAUSED) printf 'gone'; return 0 ;;
    esac
    now="$(date +%s)"
    if (( AGENT_TIMEOUT_MINUTES > 0 )) && (( now - started >= AGENT_TIMEOUT_MINUTES * 60 )); then
      printf 'timeout'; return 0
    fi
    steps="$(agent_event_steps "${cid}" 2>/dev/null || true)"
    if [[ "${steps}" =~ ^[0-9]+$ ]] && (( AGENT_MAX_ITERATIONS > 0 )) && (( steps >= AGENT_MAX_ITERATIONS )); then
      printf 'iterations'; return 0
    fi
    sleep 15
  done
}

final_text() {   # CID — the agent's last word in this conversation
  local payload
  payload="$(agent_events_payload "$1" 2>/dev/null || true)"
  project_final_text "${payload}" 2>/dev/null || true
}

# settled_final_text CID — the agent's last word, once the app has it.
#
# The sandbox posts its events to the app on its own schedule, so the
# conversation can say "finished" before the event that finished it has
# arrived. Measured on the first full run: the reply that ended step 2 came
# back from Ollama at 03:59:06, the runner read the events at 03:59:21 and
# found the last one a terminal observation from 03:56:32, and then removed
# the sandbox, so that final event never arrived at all. Every turn read
# as "unclear", and a question would have been missed the same way.
#
# So: until a final word is there, or the event count has not moved for 40 s
# (the agent really did end without one), at most two minutes.
settled_final_text() {
  local text n prev=-1 still=0 waited=0
  while :; do
    text="$(final_text "$1")"
    [[ -z "${text//[[:space:]]/}" ]] || { printf '%s' "${text}"; return 0; }
    n="$(agent_event_steps "$1" 2>/dev/null || printf '?')"
    if [[ "${n}" == "${prev}" ]]; then still=$(( still + 1 )); else still=0; prev="${n}"; fi
    if (( still >= 4 || waited >= 120 )); then break; fi
    sleep 10; waited=$(( waited + 10 ))
  done
  printf '%s' "${text}"
}

send_reply() {   # CID TEXT
  curl -fsS --max-time 60 -X POST "$(api)/api/v1/app-conversations/$1/send-message" \
    -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg t "$2" '{role:"user", content:[{type:"text", text:$t}], run:true}')" \
    >/dev/null 2>&1
}

ask_answerer() {   # QUESTION — the answerer model's reply, or rc 1
  local model reply
  model="$(project_answerer_model)"
  reply="$(curl -fsS --max-time 1800 "$(ollama_url)/api/chat" -H 'Content-Type: application/json' \
            -d "$(project_answerer_payload "${model}" "$(summary_text)" "$(plan_text)" "$(decisions_text)" "$1")" 2>/dev/null \
           | jq -r '.message.content // empty' 2>/dev/null)" || return 1
  [[ -n "${reply//[[:space:]]/}" ]] || return 1
  printf '%s' "${reply}"
}

# The spec itself when it is short enough to carry, its summary when not. The
# second live run's summary turned "prints a usage line to stderr" into
# "printing ... a usage line", and the CLI it built printed usage to stdout;
# it also softened "ask the project lead" into "decided by the project lead".
# A short spec is cheaper to send whole than to lose a requirement from.
PROJECT_SPEC_VERBATIM_CHARS=3000
summary_text() {
  if [[ -s "${STATE_DIR}/spec.md" ]] \
     && (( $(wc -c < "${STATE_DIR}/spec.md") <= PROJECT_SPEC_VERBATIM_CHARS )); then
    cat "${STATE_DIR}/spec.md"
  elif [[ -s "${STATE_DIR}/spec-summary.md" ]]; then
    project_strip_tool_markup < "${STATE_DIR}/spec-summary.md"
  else
    head -c 1500 "${STATE_DIR}/spec.md"
  fi
}
plan_text()      { project_strip_tool_markup < "${DIR}/PLAN.md" 2>/dev/null || true; }
decisions_text() { cat "${DIR}/DECISIONS.md" 2>/dev/null || true; }

record_decision() {   # HEADING QUESTION ANSWER
  normalize_perms || true
  [[ -f "${DIR}/DECISIONS.md" ]] || printf '# Decisions\n' > "${DIR}/DECISIONS.md"
  printf '\n## %s\n\n**Question:** %s\n\n**Answer:** %s\n' "$1" "$2" "$3" >> "${DIR}/DECISIONS.md"
  # Made group-writable again at once: the agent is mid-conversation and may
  # be told to record a decision in this very file.
  normalize_perms || true
}

# --- stopping, which is a result and not a failure of the runner ----------------
# STATUS waiting: a person has to answer or decide. failed: a step could not be
# made to pass. Both exit 0, so systemd does not restart into the same wall.
stop_for_human() {   # STATUS REASON
  # A turn that is stopped mid-conversation leaves its sandbox or container
  # behind unless whoever started it said how to take it down.
  if [[ -n "${TURN_CLEANUP:-}" ]]; then ${TURN_CLEANUP} || true; TURN_CLEANUP=""; fi
  state_set STATUS "$1" REASON "$2"
  say "STOPPED ($1): $2"
  write_summary
  local why
  case "$1" in
    failed) why="a step could not be made to pass" ;;
    *)      why="it needs you"
            if [[ "$2" =~ \((credentials|outside|delete)\) ]]; then why+=" (${BASH_REMATCH[1]})"; fi ;;
  esac
  tg_progress "Stopped (${1}): ${why}"
  tg_event "⏸ stopped at step $(state_get STEP): ${why}. $(tg_summary). See: lca agent project --dir ${DIR} --status"
  exit 0
}

# answer_question WHAT ASKED — the agent's last word (LAST_TEXT) is a
# question, the ASKED-th of this attempt: answer it the way the autonomy mode
# says. Sets REPLY; rc 1 with TURN_FAIL when the attempt should be abandoned;
# exits through stop_for_human when a person has to answer.
answer_question() {
  local what="$1" asked="$2" hs ans
  if hs="$(project_hard_stop "${LAST_TEXT}")"; then
    stop_for_human waiting "${what}: the agent asked something only you may decide (${hs}): $(project_clip "${LAST_TEXT}" 600)"
  fi
  (( asked <= PROJECT_MAX_QUESTIONS )) \
    || { TURN_FAIL="the agent asked ${asked} questions in one attempt without finishing"; return 1; }
  case "${AUTONOMY}" in
    "ask")
      state_set QUESTION "$(project_clip "${LAST_TEXT}" 2000)"
      stop_for_human waiting "${what}: the agent asked: $(project_clip "${LAST_TEXT}" 600)  — answer with: lca agent project --dir ${DIR} --resume --answer \"...\""
      ;;
    "self")
      REPLY="${PROJECT_SELF_REPLY}"
      say "${what}: answered in self mode: ${REPLY}"
      ;;
    "answerer")
      say "${what}: asking $(project_answerer_model) as project lead"
      if ! ans="$(ask_answerer "${LAST_TEXT}")"; then
        stop_for_human waiting "${what}: the answerer $(project_answerer_model) did not answer. The question: $(project_clip "${LAST_TEXT}" 600)"
      fi
      say "${what}: the project lead replied: $(project_clip "${ans}" 600)"
      if project_answer_escalates "${ans}" || hs="$(project_hard_stop "${ans}")"; then
        stop_for_human waiting "${what}: the answerer escalated (${hs:-ESCALATE}). The question: $(project_clip "${LAST_TEXT}" 600)"
      fi
      record_decision "${what}: answered by $(project_answerer_model) as project lead" \
        "$(project_clip "${LAST_TEXT}" 1500)" "${ans}"
      say "${what}: answer recorded in DECISIONS.md"
      tg_event "💬 ${what}: the project lead answered a question (recorded in DECISIONS.md)"
      REPLY="Project lead's answer: ${ans}

This decision is recorded in DECISIONS.md. Continue, and end your final message with STEP DONE (TESTS DONE when writing tests, PLAN DONE when planning)."
      ;;
  esac
}

# handle_turn CID WHAT — run an OpenHands conversation to an end, answering
# questions the way the autonomy mode says. Returns 0 with the agent's last
# word in LAST_TEXT, or 1 with the reason in TURN_FAIL for a stopped/broken run.
handle_turn() {
  local cid="$1" what="$2" how kind asked=0
  while :; do
    how="$(wait_turn "${cid}")"
    case "${how}" in
      finished) ;;
      timeout)    TURN_FAIL="the step ran past AGENT_TIMEOUT_MINUTES (${AGENT_TIMEOUT_MINUTES}) and was stopped"; return 1 ;;
      iterations) TURN_FAIL="the step reached AGENT_MAX_ITERATIONS (${AGENT_MAX_ITERATIONS}) and was stopped"; return 1 ;;
      gone)       TURN_FAIL="the step's sandbox went away before it finished"; return 1 ;;
      *)          TURN_FAIL="the conversation ended in state '${how}'"; return 1 ;;
    esac
    LAST_TEXT="$(settled_final_text "${cid}")"
    kind="$(project_turn_kind "${LAST_TEXT}")"
    say "${what}: the agent's turn ended (${kind})"
    [[ "${kind}" == "question" ]] || return 0
    asked=$(( asked + 1 ))
    answer_question "${what}" "${asked}" || return 1
    local before_steps waited=0
    before_steps="$(agent_event_steps "${cid}" 2>/dev/null || printf 0)"
    send_reply "${cid}" "${REPLY}" \
      || { TURN_FAIL="could not deliver the answer to the conversation"; return 1; }
    # The status still says "finished" for a moment after the reply lands, and
    # waiting on it then would read the SAME question back and answer it again.
    # So: until the agent is visibly working on the answer.
    while (( waited < 300 )); do
      [[ "$(conversation_field "${cid}" execution_status || true)" == "running" ]] && break
      (( $(agent_event_steps "${cid}" 2>/dev/null || printf 0) > before_steps + 1 )) && break
      sleep 5; waited=$(( waited + 5 ))
    done
  done
}

# oh_turn TASK WHAT — one OpenHands conversation, start to end, sandbox removed.
oh_turn() {
  submit "$1" || { say "the agent would not take ${2} (see run.log); retrying later"; exit 75; }
  TURN_CLEANUP="delete_sandbox ${CID}"
  if handle_turn "${CID}" "$2"; then
    delete_sandbox "${CID}"; TURN_CLEANUP=""; return 0
  fi
  delete_sandbox "${CID}"; TURN_CLEANUP=""
  return 1
}

# --- the OpenCode engine: 'opencode run' in a container of its own ---------------
# The image is built here, as whoever runs this (docker, no sudo), the first
# time it is needed: the agent's runtime image plus the pinned binary.
ensure_opencode_image() {
  docker image inspect "$(opencode_image)" >/dev/null 2>&1 && return 0
  say "building $(opencode_image) (OpenCode ${AGENT_OPENCODE_VERSION} over $(runtime_image))"
  opencode_dockerfile "$(runtime_image)" | docker build -q -t "$(opencode_image)" - >/dev/null
}

# oc_run NAME SESSION TITLE MESSAGE — one 'opencode run' to its end; its JSON
# events on stdout. The project is mounted at the path the agent sees under
# OpenHands, and OpenCode's own state (its sessions) lives in .lca-project,
# so a question can be answered in the same session by the next run. The
# container carries the project's label, so whatever outlives this runner
# (a SIGKILL takes the docker client and not the container) is found and
# removed by the next one (remove_opencode_containers).
oc_run() {
  local kv secs="$(( AGENT_TIMEOUT_MINUTES * 60 ))" steps="${AGENT_MAX_ITERATIONS}"
  local -a envs=() args=(run --format json --title "$3")
  (( steps > 0 )) || steps=1000
  while IFS= read -r kv; do envs+=(-e "${kv}"); done < <(opencode_env)
  [[ -z "$2" ]] || args+=(--session "$2")
  timeout --kill-after=30 "${secs}" docker run --rm --init --name "$1" --label "lca-project=${DIR}" \
    --user "$(owner_uid):${PROJECT_SANDBOX_GID}" --add-host host.docker.internal:host-gateway \
    -e HOME="${SBX}/.lca-project/opencode-home" "${envs[@]}" \
    -e OPENCODE_CONFIG_CONTENT="$(opencode_config_json "$(agent_model_name)" "$(agent_llm_base_url)" \
                                  "$(agent_model_context)" "${AGENT_MAX_OUTPUT_TOKENS}" "${steps}")" \
    -v "${DIR}:${SBX}" -w "${SBX}" "$(opencode_image)" opencode "${args[@]}" "$4"
}

remove_opencode_containers() {
  local ids
  ids="$(docker ps -aq --filter "label=lca-project=${DIR}" 2>/dev/null || true)"
  # shellcheck disable=SC2086  # container ids: hex, one per word
  [[ -z "${ids}" ]] || { docker rm -f ${ids} >/dev/null 2>&1 || true; say "removed a leftover OpenCode container"; }
}

# oc_turn TASK WHAT — the same contract as oh_turn, with OpenCode.
oc_turn() {
  local msg="$1" what="$2" session="" out rc kind asked=0 name t0 events
  mkdir -p "${STATE_DIR}/opencode-home"
  while :; do
    out="$(mktemp "${STATE_DIR}/.opencode.XXXXXX")"
    name="lca-opencode-$$-${RANDOM}"
    rc=0; t0="$(date +%s)"
    oc_run "${name}" "${session}" "${what}" "${msg}" > "${out}" 2>> "${STATE_DIR}/opencode.err" || rc=$?
    cat "${out}" >> "${STATE_DIR}/opencode-events.jsonl"
    events="$(grep -c '"type"' "${out}" || true)"
    [[ -n "${session}" ]] || session="$(opencode_session_id < "${out}")"
    LAST_TEXT="$(opencode_final_text < "${out}")"
    say "${what}: opencode exited ${rc}; requests, first prompt, prompt and output tokens: $(opencode_usage < "${out}")"
    rm -f "${out}"
    if (( rc != 0 && events == 0 )) && [[ -z "${session}" ]]; then
      # Not one event: docker, the image, the relay or the model never got
      # going. That is the machine, not the step; like a submit the app would
      # not take, it is for systemd to try again, not a retry to burn.
      remove_opencode_containers
      say "${what}: opencode produced nothing (exit ${rc}; see .lca-project/opencode.err); retrying later"
      exit 75
    fi
    case "${rc}" in
      0) ;;
      124|137)
        docker rm -f "${name}" >/dev/null 2>&1 || true
        if (( $(date +%s) - t0 >= AGENT_TIMEOUT_MINUTES * 60 && AGENT_TIMEOUT_MINUTES > 0 )); then
          TURN_FAIL="the step ran past AGENT_TIMEOUT_MINUTES (${AGENT_TIMEOUT_MINUTES}) and was stopped"
        else
          TURN_FAIL="opencode was killed (exit ${rc}) before the time limit"
        fi
        return 1 ;;
      *)
        [[ -n "${LAST_TEXT}" ]] \
          || { TURN_FAIL="opencode exited ${rc} without a word (see .lca-project/opencode.err)"; return 1; } ;;
    esac
    kind="$(project_turn_kind "${LAST_TEXT}")"
    say "${what}: the agent's turn ended (${kind})"
    [[ "${kind}" == "question" ]] || return 0
    asked=$(( asked + 1 ))
    answer_question "${what}" "${asked}" || return 1
    [[ -n "${session}" ]] || { TURN_FAIL="opencode asked a question but named no session to answer it in"; return 1; }
    msg="${REPLY}"
  done
}

# run_turn TASK WHAT — one fresh conversation with the engine this project
# runs on: 0 with LAST_TEXT, or 1 with TURN_FAIL.
run_turn() {
  case "${ENGINE}" in
    opencode) oc_turn "$1" "$2" ;;
    *)        oh_turn "$1" "$2" ;;
  esac
}

# --- what each phase cost: .lca-project/metrics.tsv --------------------------------
# Seconds from the wall clock; tokens from Ollama's own journal for the same
# window (ollama_journal_usage), so both engines are counted by one meter.
PHASE_T0=0
phase_begin() { PHASE_T0="$(date +%s)"; }
phase_end() {   # PHASE STEP ATTEMPT OUTCOME
  local t1 usage="0 0 0 0 0" f="${STATE_DIR}/metrics.tsv" log
  # The server logs a request's timings just after its reply has gone: a
  # review that ends with its one request read as 0 tokens without this.
  sleep 2
  t1="$(date +%s)"
  # Wherever this host keeps Ollama's log; only a journal can be read by time.
  log="$(ollama_log_hint)"
  if [[ "${log}" == journalctl* ]]; then
    usage="$(${log} --since "@${PHASE_T0}" --until "@${t1}" --no-pager -o cat 2>/dev/null | ollama_journal_usage)"
  fi
  [[ -s "${f}" ]] || printf 'when\tengine\tphase\tstep\tattempt\toutcome\tseconds\trequests\tfirst_prompt\tprompt_tokens\tprompt_read\tgenerated\n' > "${f}"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "${ENGINE}" "$1" "$2" "$3" "$4" \
    "$(( t1 - PHASE_T0 ))" "${usage// /$'\t'}" >> "${f}"
}

# --- the checks after a step, before anything is committed --------------------
after_step_checks() {   # -> rc 1 and a reason in CHECK_FAIL when the step may not be kept
  local outside deleted
  outside="$(find "${AGENT_PROJECTS_DIR%/}" -mindepth 1 -path "${DIR}" -prune -o \
              -newer "${STATE_DIR}/step-start" -print 2>/dev/null | head -5 || true)"
  if [[ -n "${outside}" ]]; then
    CHECK_FAIL="outside: files outside the project changed during the step: $(tr '\n' ' ' <<<"${outside}")"
    return 1
  fi
  git_here add -A
  deleted="$(git_here diff --cached --name-status | awk '$1 == "D" { print $2 }' | head -10)"
  if [[ -n "${deleted}" ]]; then
    git_here reset -q
    CHECK_FAIL="delete: the step deleted tracked files: $(tr '\n' ' ' <<<"${deleted}")"
    return 1
  fi
  if project_diff_has_secret "$(git_here diff --cached)"; then
    git_here reset -q
    CHECK_FAIL="credentials: the step's changes contain what looks like a credential"
    return 1
  fi
  git_here reset -q
}

# verify CMD — run the step's own check in a throwaway container from the
# agent's image, at the same path the agent saw (a .venv's shebangs name it),
# network off. Sets VERIFY_OUT; rc is the command's.
verify() {
  local name="lca-verify-$$-${RANDOM}" rc=0
  VERIFY_OUT="$(timeout "${PROJECT_VERIFY_SECONDS}" docker run --rm --name "${name}" \
      --network none --user "$(owner_uid):${PROJECT_SANDBOX_GID}" -e HOME=/tmp \
      -v "${DIR}:${SBX}" -w "${SBX}" --entrypoint bash "$(runtime_image)" -lc "$1" 2>&1)" || rc=$?
  if (( rc == 124 )); then
    docker rm -f "${name}" >/dev/null 2>&1 || true
    VERIFY_OUT+=$'\n'"(verification stopped after ${PROJECT_VERIFY_SECONDS}s)"
  fi
  return "${rc}"
}

# --- Telegram: progress text only (lib.sh, the Telegram section) --------------------
# One progress message per project, edited in place, and a message per event.
# Everything is composed from the runner's own state; nothing the agent wrote
# is sent. A failure to reach Telegram never touches the run.
tg_elapsed() {
  local s
  s="$(date -d "$(state_get STARTED)" +%s 2>/dev/null)" || { printf 0; return; }
  printf '%s' "$(( $(date +%s) - s ))"
}
tg_progress() {   # NOW
  telegram_ready 2>/dev/null || return 0
  local f="${STATE_DIR}/telegram" steps total done_ text id
  steps="$(project_plan_steps "${DIR}/PLAN.md" 2>/dev/null || true)"
  total="$(grep -c . <<<"${steps}" || true)"
  done_="$(awk -F'\t' '$2 == 1' <<<"${steps}" | grep -c . || true)"
  text="$(telegram_progress_text "$(basename "${DIR}")" "${done_:-0}" "${total:-0}" "$1" "$(tg_elapsed)")"
  # No file yet on the first call: that must not end the runner under set -e.
  id="$(sed -n 's/^PROGRESS=//p' "${f}" 2>/dev/null | tail -1 || true)"
  if [[ "${id}" =~ ^[0-9]+$ ]] && telegram_edit "${id}" "${text}"; then return 0; fi
  id="$(telegram_send "${text}")" && printf 'PROGRESS=%s\n' "${id}" > "${f}"
  return 0
}
tg_event() {   # TEXT
  telegram_ready 2>/dev/null || return 0
  telegram_send "$(basename "${DIR}"): $1" >/dev/null || say "telegram: could not send a notification"
  return 0
}
# tg_summary — the end of a run in one message: counts and the clock only.
tg_summary() {
  local steps total done_ dec base f
  steps="$(project_plan_steps "${DIR}/PLAN.md" 2>/dev/null || true)"
  total="$(grep -c . <<<"${steps}" || true)"
  done_="$(awk -F'\t' '$2 == 1' <<<"${steps}" | grep -c . || true)"
  dec="$(grep -c '^## ' "${DIR}/DECISIONS.md" 2>/dev/null || true)"
  printf 'Steps %s/%s · %s · %s decisions recorded' "${done_:-0}" "${total:-0}" "$(telegram_elapsed "$(tg_elapsed)")" "${dec:-0}"
  f="${DIR}/REVIEW.md"
  [[ ! -f "${f}" ]] || printf ' · review: %s findings, %s fixed, %s open' "$(grep -cE '^\| (high|medium|low) ' "${f}" || true)" \
    "$(grep -cE '\| fixed \|$' "${f}" || true)" "$(grep -cE '\| open \|$' "${f}" || true)"
  base="$(project_base_decision "${DIR}/DECISIONS.md" 2>/dev/null || true)"
  [[ -z "${base}" ]] || printf ' · base project: %s (%s)' "$(telegram_safe "${base%%$'\t'*}" 60)" "$(telegram_safe "${base#*$'\t'}" 30)"
}

# --- the phases ---------------------------------------------------------------------
# plan_accepted — a plan was accepted earlier in this project. Then it stands
# as it is: a project started before the base-project rule, or whose
# DECISIONS.md lost that section since, is not planned again over its own work.
plan_accepted() {
  [[ "$(state_get PLAN_ACCEPTED)" == "1" ]] && return 0
  [[ -n "$(git_here log -1 --format=%H -F --grep='Plan: ' 2>/dev/null || true)" ]]
}

plan_phase() {
  local attempt problem failure=""
  if [[ -f "${DIR}/PLAN.md" ]] && ! project_plan_problem "${DIR}/PLAN.md" "${STATE_DIR}/spec.md" >/dev/null; then
    if plan_accepted || ! project_base_problem "${DIR}/DECISIONS.md" >/dev/null; then
      return 0
    fi
  fi
  for (( attempt = 1; attempt <= AGENT_PROJECT_RETRIES + 1; attempt++ )); do
    state_set STATUS planning STEP 0 ATTEMPT "${attempt}"
    say "planning, attempt ${attempt}"
    tg_progress "Planning (attempt ${attempt})"
    normalize_perms || true
    local task
    task="$(project_planning_task "${SBX}")"
    [[ -z "${failure}" ]] || task+=$'\n\n'"The previous plan could not be used: ${failure}. Rewrite the files in exactly the form above."
    phase_begin
    # Like a step: a turn that ends on a limit is not a failure by itself; the
    # plan it left is checked like any other. Measured on task D: two planning
    # turns of qwen3-coder-next under OpenHands spent 100 events each revising a
    # PLAN.md that was already in the right form, and both were thrown away.
    local how="done"
    run_turn "${task}" "planning" || { how="turn: ${TURN_FAIL}"; say "planning: ${TURN_FAIL}; checking the plan it left"; }
    normalize_perms || true
    keep_plan_only
    if problem="$(project_plan_problem "${DIR}/PLAN.md" "${STATE_DIR}/spec.md")" \
       || problem="$(project_base_problem "${DIR}/DECISIONS.md")"; then
      phase_end plan 0 "${attempt}" "refused (${how})"
      failure="${problem}"
      [[ "${how}" == "done" ]] || failure="${TURN_FAIL}; and the plan it left: ${problem}"
      say "the plan is not usable: ${problem}"
      continue
    fi
    phase_end plan 0 "${attempt}" "accepted (${how})"
    note_base_project
    commit_all "Plan: $(project_plan_steps "${DIR}/PLAN.md" | wc -l | tr -d ' ') steps"
    state_set PLAN_ACCEPTED 1
    tg_event "📋 plan accepted: $(project_plan_steps "${DIR}/PLAN.md" | wc -l | tr -d ' ') steps"
    return 0
  done
  stop_for_human failed "planning failed $(( AGENT_PROJECT_RETRIES + 1 )) times; last: ${failure}"
}

# note_base_project — the planner's choice of base project, logged, with the
# condition its license puts on using it written under it in DECISIONS.md.
note_base_project() {
  local d choice license class note
  d="$(project_base_decision "${DIR}/DECISIONS.md")" || return 0
  choice="${d%%$'\t'*}" license="${d#*$'\t'}"
  if project_base_is_none "${choice}"; then class=none; else class="$(project_license_class "${license}")"; fi
  note="$(project_license_note "${class}")" || return 0
  say "base project: ${choice} (license: ${license:-n/a}, ${class})"
  grep -qF -- "- Note: ${note}" "${DIR}/DECISIONS.md" 2>/dev/null && return 0
  awk -v note="- Note: ${note}" '
    { print; k = tolower($0); gsub(/\*\*/, "", k) }
    k ~ /^##[[:space:]]+base project/ { inside = 1; next }
    inside && k ~ /^[[:space:]]*([-*][[:space:]]*)?license[[:space:]]*:/ { print note; inside = 0 }
  ' "${DIR}/DECISIONS.md" > "${STATE_DIR}/.decisions" && cat "${STATE_DIR}/.decisions" > "${DIR}/DECISIONS.md"
  rm -f "${STATE_DIR}/.decisions"
}

# keep_plan_only — planning may write PLAN.md and DECISIONS.md and nothing
# else of the project's. Anything else it changed is put back as it was, and
# what it created is moved aside to .lca-project/planning-discarded/, kept
# rather than deleted. Measured: an OpenHands planning turn on task D wrote
# the models, the schedule and both test files, and all of it was committed
# with the plan, ahead of the tests-first step that should have written them.
keep_plan_only() {
  local line st path moved=""
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    st="${line:0:2}" path="${line:3}"
    case "${path}" in PLAN.md|DECISIONS.md|.lca-project/*) continue ;; esac
    if [[ "${st}" == "??" ]]; then
      mkdir -p "${STATE_DIR}/planning-discarded/$(dirname "${path}")"
      mv -f "${DIR}/${path}" "${STATE_DIR}/planning-discarded/${path}"
    else
      git_here checkout -q HEAD -- "${path}" 2>/dev/null || true
    fi
    moved+=" ${path}"
  done < <(git_here status --porcelain -z --untracked-files=all 2>/dev/null | tr '\0' '\n' || true)
  [[ -z "${moved}" ]] || say "planning changed files it may not; put back or moved to .lca-project/planning-discarded/:${moved}"
}

# head_or_empty — HEAD, or git's empty tree when there is no commit yet: a
# diff base that always exists.
head_or_empty() {
  git_here rev-parse -q --verify HEAD 2>/dev/null || git_here hash-object -t tree /dev/null
}

# tests_phase N TOTAL TITLE VERIFY — a step's tests, written and committed
# before the step itself, by a conversation of their own. Sets TESTS_COMMIT
# and TEST_FILES (the test files that commit holds, one a line) and TEST_LIST
# (the same on one line, for the prompt); all empty when the step's check
# runs no test suite. The commit is remembered in the
# state, so a resumed run does not write them again.
tests_phase() {
  local n="$1" total="$2" title="$3" check="$4" c="" before
  TEST_FILES="" TEST_LIST="" TESTS_COMMIT=""
  if ! project_verify_runs_tests "${check}"; then
    say "step ${n}: its check runs no test suite, so no tests are written first"
    return 0
  fi
  if [[ "$(state_get TESTS_STEP)" == "${n}" ]]; then
    c="$(state_get TESTS_COMMIT)"
    git_here cat-file -e "${c}^{commit}" 2>/dev/null || c=""
  fi
  if [[ -z "${c}" ]]; then
    state_set STATUS running STEP "${n}" ATTEMPT 0 TITLE "${title}"
    say "step ${n}/${total}: writing its tests first"
    tg_progress "Step ${n}/${total}, writing its tests: ${title}"
    normalize_perms || true
    touch "${STATE_DIR}/step-start"
    phase_begin
    run_turn "$(project_tests_task "${SBX}" "${n}" "${total}" "${title}" "${check}" \
                "$(summary_text)" "$(plan_text)" "$(decisions_text)")" "step ${n} tests" \
      || say "step ${n} tests: ${TURN_FAIL}; keeping what was written"
    normalize_perms || true
    if ! after_step_checks; then
      phase_end tests "${n}" 1 "stopped"
      stop_for_human waiting "step ${n} tests: ${CHECK_FAIL} — nothing was committed; look at the working tree before resuming"
    fi
    if verify "${check}"; then
      phase_end tests "${n}" 1 "already-pass"
      say "step ${n}: its tests already pass before the step is written, so they may not test it (the review sees this)"
    else
      phase_end tests "${n}" 1 "red"
      say "step ${n}: the new tests fail before the step is written, as they should"
    fi
    printf '%s\n' "${VERIFY_OUT}" > "${STATE_DIR}/step-${n}-tests.log"
    before="$(head_or_empty)"
    commit_all "Step ${n} tests: ${title}"
    c="$(git_here rev-parse -q --verify HEAD 2>/dev/null || true)"
    [[ "${c}" != "${before}" ]] || c=""
    state_set TESTS_STEP "${n}" TESTS_COMMIT "${c}"
  fi
  [[ -n "${c}" ]] || { say "step ${n}: no tests were written"; return 0; }
  TESTS_COMMIT="${c}"
  TEST_FILES="$(git_here -c core.quotePath=false diff-tree --no-commit-id --name-only --diff-filter=AM -r "${c}" \
                | grep -E '(^|/)(tests?/|spec/|test_[^/]*$|tests\.py$|[^/]*_(test|spec)\.[[:alnum:]]+$|[^/]*\.(test|spec)\.[[:alnum:]]+$)' || true)"
  TEST_LIST="$(tr '\n' ' ' <<<"${TEST_FILES}" | sed 's/ *$//')"
}

# restore_tests — the step may not change the tests written for it: put back
# any it changed or deleted, as HEAD has them, and say so. HEAD, not the tests
# commit: a test a person corrected and committed before resuming stays
# corrected. Not on the last attempt (see project_step_task).
restore_tests() {
  local f changed=""
  [[ -n "${TESTS_COMMIT}" && -n "${TEST_FILES}" ]] || return 0
  while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    git_here cat-file -e "HEAD:${f}" 2>/dev/null || continue
    git_here diff --quiet HEAD -- "${f}" 2>/dev/null && [[ -e "${DIR}/${f}" ]] && continue
    changed+=" ${f}"
    git_here checkout HEAD -- "${f}"
  done <<<"${TEST_FILES}"
  [[ -z "${changed}" ]] || say "the step changed its tests, which were put back:${changed}"
}

step_phase() {   # N TOTAL TITLE VERIFY
  local n="$1" total="$2" title="$3" check="$4" attempt failure="" task base last
  # Where the step began, kept across a restart, so its review sees all of it.
  if [[ "$(state_get BASE_STEP)" == "${n}" ]] && base="$(state_get BASE)" \
     && git_here cat-file -e "${base}" 2>/dev/null; then :; else
    base="$(head_or_empty)"
    state_set BASE_STEP "${n}" BASE "${base}"
  fi
  tests_phase "${n}" "${total}" "${title}" "${check}"
  for (( attempt = 1; attempt <= AGENT_PROJECT_RETRIES + 1; attempt++ )); do
    # The last attempt may correct a test; with no retries at all there is no
    # "last" to speak of, and the tests stay protected.
    last=false; (( AGENT_PROJECT_RETRIES == 0 || attempt <= AGENT_PROJECT_RETRIES )) || last=true
    state_set STATUS running STEP "${n}" ATTEMPT "${attempt}" TITLE "${title}"
    say "step ${n}/${total}: ${title} (attempt ${attempt})"
    tg_progress "Step ${n}/${total}: ${title} (attempt ${attempt})"
    normalize_perms || true
    touch "${STATE_DIR}/step-start"
    task="$(project_step_task "${SBX}" "${n}" "${total}" "${title}" "${check}" \
            "$(summary_text)" "$(plan_text)" "$(decisions_text)" "${failure}" "${TEST_LIST}" "${last}")"
    phase_begin
    # A turn that ends badly (a timeout, a step limit) is not a retry by
    # itself: the tests decide, and they run on whatever it left.
    run_turn "${task}" "step ${n}" || say "step ${n}, attempt ${attempt}: ${TURN_FAIL}; verifying what it left"
    normalize_perms || true
    if [[ "${last}" == "true" ]]; then
      local -a tf=()
      [[ -z "${TEST_FILES}" ]] || mapfile -t tf <<<"${TEST_FILES}"
      (( ${#tf[@]} == 0 )) || git_here diff --quiet HEAD -- "${tf[@]}" \
        || say "step ${n}: the last attempt changed its tests (allowed once; the review sees it)"
    else
      # Before the checks: a test the step deleted is put back, not a stop.
      restore_tests
    fi
    if ! after_step_checks; then
      phase_end step "${n}" "${attempt}" "stopped"
      stop_for_human waiting "step ${n}: ${CHECK_FAIL} — nothing was committed; look at the working tree before resuming"
    fi
    if verify "${check}"; then
      phase_end step "${n}" "${attempt}" "passed"
      printf '%s\n' "${VERIFY_OUT}" > "${STATE_DIR}/step-${n}-attempt-${attempt}.log"
      commit_all "Step ${n}: ${title}"
      say "step ${n} PASSED: ${check}"
      tg_event "✅ step ${n}/${total} passed: $(telegram_safe "${title}") (attempt ${attempt})"
      review_phase "${n}" "${title}" "${check}" "${base}"
      return 0
    fi
    phase_end step "${n}" "${attempt}" "failed"
    printf '%s\n' "${VERIFY_OUT}" > "${STATE_DIR}/step-${n}-attempt-${attempt}.log"
    failure="${VERIFY_OUT}"
    say "step ${n}, attempt ${attempt}: verification FAILED (${check}); output in .lca-project/step-${n}-attempt-${attempt}.log"
    if (( attempt <= AGENT_PROJECT_RETRIES )); then
      tg_event "🔁 step ${n}/${total} failed its tests (attempt ${attempt} of $(( AGENT_PROJECT_RETRIES + 1 ))); retrying with the failure in hand"
    else
      tg_event "❌ step ${n}/${total} failed its tests on its last attempt (${attempt})"
    fi
  done
  stop_for_human failed "step ${n} (${title}) failed verification $(( AGENT_PROJECT_RETRIES + 1 )) times; last output in .lca-project/step-${n}-attempt-$(( attempt - 1 )).log"
}

# finish_step N TITLE — tick the step in PLAN.md and commit that, the last
# thing a step does, after its review: a step is only "done" once reviewed.
finish_step() {
  project_plan_mark_done "${DIR}/PLAN.md" "$1" || say "could not tick step $1 in PLAN.md"
  commit_all "Step $1 done: $2"
  state_set REVIEW_PENDING "" ACCEPTED ""
  tg_progress "Step $1 done: $2"
}

# --- the review of every accepted step ----------------------------------------------
ask_reviewer() {   # TITLE DIFF — the reviewer's reply, or rc 1
  local reply
  reply="$(curl -fsS --max-time "${AGENT_REQUEST_TIMEOUT:-3600}" "$(ollama_url)/api/chat" -H 'Content-Type: application/json' \
            -d "$(project_review_payload "$(project_reviewer_model)" "$(summary_text)" "$1" "$2")" 2>/dev/null \
           | jq -r '.message.content // empty' 2>/dev/null)" || return 1
  [[ -n "${reply//[[:space:]]/}" ]] || return 1
  printf '%s' "${reply}"
}

# REVIEW_EXCLUDE — what the review does not read: the runner's own files,
# lockfiles, minified and generated assets, translations' compiled forms.
REVIEW_EXCLUDE=(':(exclude)PLAN.md' ':(exclude)DECISIONS.md' ':(exclude)REVIEW.md'
  ':(exclude,glob)**/*.lock' ':(exclude,glob)**/package-lock.json' ':(exclude,glob)**/*.min.*'
  ':(exclude,glob)**/*.mo' ':(exclude,glob)**/*.svg' ':(exclude,glob)**/*.map')

# review_diff BASE — the step's diff for the reviewer: every file gets at most
# PER_FILE characters, our files first, so a big install does not crowd out
# the code that was written; the files that did not fit are named.
review_diff() {
  local base="$1" f d out="" left=() per=3500 max=14000
  while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    d="$(git_here -c core.quotePath=false diff "${base}" HEAD -- "${f}" 2>/dev/null || true)"
    if (( ${#out} + 200 >= max )); then left+=("${f}"); continue; fi
    out+="$(project_clip_head "${d}" "${per}")"$'\n'
  done < <(git_here -c core.quotePath=false diff --name-only "${base}" HEAD -- . "${REVIEW_EXCLUDE[@]}" 2>/dev/null \
           | awk '{ print (($0 ~ /(^|\/)(tests?|spec)\// || $0 ~ /(^|\/)test_/) ? 1 : 0) "\t" $0 }' \
           | sort -s -k1,1n | cut -f2-)
  (( ${#left[@]} == 0 )) || out+="[not shown, over the budget: ${left[*]}]"$'\n'
  printf '%s' "${out}"
}

# review_phase N TITLE VERIFY BASE — review everything the step changed since
# BASE (its tests included) for bugs and security. Every finding goes into
# REVIEW.md. The ones that must be fixed (project_review_must_fix) get ONE
# fresh conversation; its fix is kept only if the step's check still passes,
# and otherwise discarded and the finding left open. The step is ticked done
# only after this, and a restart in the middle reviews it again from the
# accepted commit (resume_review).
review_phase() {
  local n="$1" title="$2" check="$3" base="$4" diff reply findings must status accepted
  accepted="$(git_here rev-parse HEAD)"
  state_set REVIEW_PENDING "${n}" ACCEPTED "${accepted}" REVIEW_TITLE "${title}" REVIEW_CHECK "${check}"
  diff="$(review_diff "${base}")"
  if [[ -z "${diff}" ]]; then finish_step "${n}" "${title}"; return 0; fi
  state_set STATUS running STEP "${n}" ATTEMPT review TITLE "${title}"
  say "step ${n}: reviewing the change for bugs and security ($(git_here diff --shortstat "${base}" HEAD | sed 's/^ *//'))"
  tg_progress "Step ${n}: review for bugs and security"
  phase_begin
  if ! reply="$(ask_reviewer "${title}" "${diff}")"; then
    phase_end review "${n}" 1 "no-answer"
    say "step ${n}: the reviewer $(project_reviewer_model) did not answer; the step stays accepted, unreviewed"
    review_record "${n}" "${title}" "" "not reviewed: the reviewer did not answer"
    finish_step "${n}" "${title}"
    return 0
  fi
  findings="$(project_review_findings <<<"${reply}")"
  must="$(project_review_must_fix <<<"${findings}")"
  phase_end review "${n}" 1 "$(grep -c . <<<"${findings}" || true) findings, $(grep -c . <<<"${must}" || true) to fix"
  printf '%s\n' "${reply}" > "${STATE_DIR}/step-${n}-review.txt"
  say "step ${n}: review: $(grep -c . <<<"${findings}" || true) findings, $(grep -c . <<<"${must}" || true) to fix"
  status=""
  if [[ -n "${must}" ]]; then
    state_set STATUS running STEP "${n}" ATTEMPT fix TITLE "${title}"
    normalize_perms || true
    touch "${STATE_DIR}/step-start"
    phase_begin
    run_turn "$(project_fix_task "${SBX}" "${n}" "${title}" "${check}" "${must}")" "step ${n} review fixes" \
      || say "step ${n} review fixes: ${TURN_FAIL}; verifying what it left"
    normalize_perms || true
    CHECK_FAIL=""
    if ! after_step_checks && [[ "${CHECK_FAIL}" == outside* ]]; then
      phase_end fix "${n}" 1 "stopped"
      stop_for_human waiting "step ${n} review fixes: ${CHECK_FAIL} — look before resuming"
    fi
    if [[ -z "${CHECK_FAIL}" ]] && verify "${check}"; then
      phase_end fix "${n}" 1 "kept"
      commit_all "Step ${n}: review fixes"
      status=fixed
      say "step ${n}: the review fixes pass the step's check and are kept"
    else
      phase_end fix "${n}" 1 "discarded"
      discard_to "${accepted}"
      status=open
      say "step ${n}: the review fixes broke the step's check (${CHECK_FAIL:-verification}) and were discarded; the findings stay open in REVIEW.md"
    fi
  fi
  review_record "${n}" "${title}" "${findings}" "${status}"
  finish_step "${n}" "${title}"
}

# discard_to COMMIT — back to COMMIT, dropping only what came after it: the
# accepted step is committed and the runner's files and the dependencies are
# ignored, so clean leaves them. DECISIONS.md keeps what was decided in the
# meantime (an answer the lead gave the discarded fix is still the answer).
discard_to() {
  local keep="${STATE_DIR}/.decisions-keep"
  cp -p "${DIR}/DECISIONS.md" "${keep}" 2>/dev/null || keep=""
  git_here reset -q --hard "$1"
  git_here clean -fdq
  if [[ -n "${keep}" ]]; then cat "${keep}" > "${DIR}/DECISIONS.md"; rm -f "${keep}"; fi
}

# resume_review — a run that stopped between accepting a step and finishing
# its review: back to the accepted commit, and review it again.
resume_review() {
  local n accepted base
  n="$(state_get REVIEW_PENDING)"
  [[ -n "${n}" ]] || return 0
  accepted="$(state_get ACCEPTED)"
  git_here cat-file -e "${accepted}^{commit}" 2>/dev/null || { state_set REVIEW_PENDING "" ACCEPTED ""; return 0; }
  say "step ${n} was accepted and its review did not finish; reviewing it again"
  discard_to "${accepted}"
  base="$(state_get BASE)"
  if [[ "$(state_get BASE_STEP)" != "${n}" ]] || ! git_here cat-file -e "${base}" 2>/dev/null; then
    base="${accepted}~1"
  fi
  review_phase "${n}" "$(state_get REVIEW_TITLE)" "$(state_get REVIEW_CHECK)" "${base}"
}

# review_record N TITLE FINDINGS FIX_STATUS — the step's findings, appended to
# REVIEW.md: must-fix ones marked fixed or open, the rest noted.
review_record() {
  local n="$1" title="$2" findings="$3" fixst="$4" f="${DIR}/REVIEW.md"
  [[ -f "${f}" ]] || printf '# Review\n\nEvery accepted step, reviewed for bugs and security by %s.\n' "$(project_reviewer_model)" > "${f}"
  {
    printf '\n## Step %s: %s\n\n' "${n}" "${title}"
    if [[ "${fixst}" == "not reviewed"* ]]; then
      printf '%s\n' "${fixst}"
    elif [[ -z "${findings}" ]]; then
      printf 'No findings.\n'
    else
      printf '| Severity | Kind | Where | Finding | Status |\n|---|---|---|---|---|\n'
      while IFS=$'\t' read -r sev kind where text; do
        local st=noted
        if project_review_must_fix <<<"${sev}"$'\t'"${kind}"$'\t'"${where}"$'\t'"${text}" | grep -q .; then st="${fixst:-open}"; fi
        printf '| %s | %s | %s | %s | %s |\n' "${sev}" "${kind}" "${where//|/\\|}" "${text//|/\\|}" "${st}"
      done <<<"${findings}"
    fi
  } >> "${f}"
}

write_summary() {
  local steps total done_ status decisions failed_line base
  steps="$(project_plan_steps "${DIR}/PLAN.md" 2>/dev/null || true)"
  total="$(grep -c . <<<"${steps}" || true)"
  done_="$(awk -F'\t' '$2 == 1' <<<"${steps}" | grep -c . || true)"
  status="$(state_get STATUS)"
  decisions="$(grep -c '^## ' "${DIR}/DECISIONS.md" 2>/dev/null || true)"
  failed_line=""
  [[ "${status}" == "failed" ]] && failed_line="- Failed: step $(state_get STEP) ($(state_get TITLE)), after $(state_get ATTEMPT) attempts"
  {
    printf '# Project summary\n\n'
    printf -- '- Directory: %s\n- Status: %s%s\n' "${DIR}" "${status}" "$( [[ -n "$(state_get REASON)" ]] && printf ' (%s)' "$(state_get REASON)")"
    printf -- '- Steps done: %s of %s\n' "${done_:-0}" "${total:-0}"
    [[ -z "${failed_line}" ]] || printf '%s\n' "${failed_line}"
    printf -- '- Decisions recorded in DECISIONS.md: %s\n' "${decisions:-0}"
    printf -- '- Autonomy: %s%s\n' "$(state_get AUTONOMY)" "$( [[ "$(state_get AUTONOMY)" == answerer ]] && printf ' (answerer: %s)' "$(project_answerer_model)")"
    printf -- '- Engine: %s, model %s\n' "$(state_get ENGINE | grep . || echo openhands)" "$(agent_model_name)"
    base="$(project_base_decision "${DIR}/DECISIONS.md" 2>/dev/null || true)"
    [[ -z "${base}" ]] || printf -- '- Base project: %s (license: %s)\n' "${base%%$'\t'*}" "${base#*$'\t'}"
    if [[ -s "${STATE_DIR}/metrics.tsv" ]]; then
      awk -F'\t' 'NR > 1 { s += $7; r += $8; p += $10; g += $12 }
        END { printf "- Model time: %.1f h over %d requests; %d prompt tokens, %d generated\n", s / 3600, r, p, g }' \
        "${STATE_DIR}/metrics.tsv"
    fi
    if [[ -f "${DIR}/REVIEW.md" ]]; then
      printf -- '- Review findings: %s (fixed %s, open %s)\n' "$(grep -cE '^\| (high|medium|low) ' "${DIR}/REVIEW.md" || true)" \
        "$(grep -cE '\| fixed \|$' "${DIR}/REVIEW.md" || true)" "$(grep -cE '\| open \|$' "${DIR}/REVIEW.md" || true)"
    fi
    printf '\n## What to review\n\n'
    printf -- '- DECISIONS.md: every decision taken without you:\n'
    grep '^## ' "${DIR}/DECISIONS.md" 2>/dev/null | sed 's/^## /  - /' || true
    printf -- '- REVIEW.md: what the review of each step found, and what was fixed\n'
    printf -- '- What each phase cost: %s/metrics.tsv\n' "${STATE_DIR}"
    printf -- '- The commits: git -C %s log --oneline\n' "${DIR}"
    printf -- '- Each step'"'"'s verification output: %s/step-*-attempt-*.log\n' "${STATE_DIR}"
    [[ -z "$(state_get QUESTION)" || "${status}" != waiting ]] || printf -- '- The open question: %s\n' "$(state_get QUESTION)"
  } > "${STATE_DIR}/SUMMARY.md"
  say "summary: ${STATE_DIR}/SUMMARY.md"
  cat "${STATE_DIR}/SUMMARY.md"
}

# --- commands ---------------------------------------------------------------------
cmd_run() {
  local status steps total n done_ title check
  [[ -r "${STATE_FILE}" ]] || die "No project at ${DIR} (no ${STATE_FILE}). Start one: lca agent project SPEC --dir ${DIR}"
  printf '%s\n' "${DIR}" > "${PROJECT_POINTER_FILE}" 2>/dev/null || true
  status="$(state_get STATUS)"
  case "${status}" in
    done|failed|waiting|stopped) say "nothing to do: the project is ${status}"; exit 0 ;;
  esac
  AUTONOMY="$(state_get AUTONOMY)"
  ENGINE="$(state_get ENGINE)"; ENGINE="${ENGINE:-openhands}"
  if [[ "${ENGINE}" == "opencode" ]] && ! ensure_opencode_image; then
    say "could not build $(opencode_image); systemd will try again"
    exit 75
  fi
  # A run that was interrupted (a reboot, a crash) left its attempt's sandbox
  # or container behind. The attempt is started again from the top, so that
  # one goes. The app is only waited for when this project runs on it, or has
  # a sandbox there to remove (it switched engines).
  local stale app_up=false
  stale="$(state_get CONVERSATION)"
  if agent_container_running && curl -fsS --max-time 10 -o /dev/null "$(api)/" 2>/dev/null; then app_up=true; fi
  if [[ "${ENGINE}" == "openhands" && "${app_up}" != "true" ]]; then
    say "the agent is not answering yet; systemd will try again"
    exit 75
  fi
  if [[ -n "${stale}" && "${app_up}" == "true" ]]; then
    delete_sandbox "${stale}"
    state_set CONVERSATION ""
  fi
  remove_opencode_containers
  # Stopped by systemd or a person mid-turn: an OpenCode container outlives
  # its docker client, so it goes with the runner.
  trap 'remove_opencode_containers; exit 143' TERM INT
  ensure_repo
  plan_phase
  resume_review
  steps="$(project_plan_steps "${DIR}/PLAN.md")"
  total="$(grep -c . <<<"${steps}")"
  while IFS=$'\t' read -r n done_ title check; do
    [[ "${done_}" == "1" ]] && continue
    step_phase "${n}" "${total}" "${title}" "${check}" </dev/null
  done <<<"${steps}"
  state_set STATUS "done" STEP "${total}" REASON ""
  say "all ${total} steps done"
  write_summary
  tg_progress "Finished"
  tg_event "🏁 finished. $(tg_summary)"
}

unit_instance() { printf 'local-code-agent-project@%s.service' "$(systemd-escape --path "${DIR}")"; }

install_unit() {
  local user home
  user="$(invoking_user)"
  [[ "${user}" != "root" ]] || die "Run this as the person who owns ${DIR}, not as root: the runner commits as that user."
  home="$(getent passwd "${user}" | cut -d: -f6)"
  as_root mkdir -p "$(dirname "${PROJECT_SERVICE}")" || die "Could not create $(dirname "${PROJECT_SERVICE}")."
  write_root_file "${PROJECT_SERVICE}" <<EOF || die "Could not write ${PROJECT_SERVICE}."
# Managed by local-code-agent (scripts/agent-project.sh). One instance per
# project directory; it resumes at boot until the project is done or stopped.
[Unit]
Description=local-code-agent project mode in %f
After=network-online.target docker.service ollama.service
Wants=network-online.target

[Service]
Type=simple
User=${user}
Environment=HOME=${home}
ExecStart=${SCRIPT_DIR}/agent-project.sh --run --dir %f
Restart=on-failure
RestartSec=60

[Install]
WantedBy=multi-user.target
EOF
  as_root systemctl daemon-reload || die "systemctl daemon-reload failed."
}

start_runner() {
  if [[ "${FOREGROUND}" == "true" ]]; then
    cmd_run
    return
  fi
  systemd_available || die "systemd is not running here, so the project cannot run unattended. Run it in this terminal instead: lca agent project --dir ${DIR} --resume --foreground"
  announce_possible_prompt "Installing the project runner as a systemd service"
  install_unit
  as_root systemctl enable --now "$(unit_instance)" >/dev/null 2>&1 \
    || die "Could not start $(unit_instance). Look at: journalctl -u '$(unit_instance)'"
  ok "Running under systemd as $(unit_instance) — it does not need this session, and it resumes after a reboot."
  info "Follow it: lca agent watch --live      ·      where it is: lca agent project --dir ${DIR} --status"
}

preflight() {
  [[ -n "${AGENT_PROJECTS_DIR}" ]] \
    || die "Project mode is off: AGENT_PROJECTS_DIR is empty. Set it in ${ENV_FILE} to a directory of yours (e.g. AGENT_PROJECTS_DIR=${HOME}/projects), then: lca agent restart"
  SBX="$(project_sandbox_dir "${DIR}")" \
    || die "${DIR} is not inside AGENT_PROJECTS_DIR (${AGENT_PROJECTS_DIR}), which is the only host directory the agent's sandboxes can see. Put the project under it."
  [[ "${ENABLE_AGENT}" == "true" ]] || die "The agent tier is off. Bring it up: lca agent setup"
  have git || die "git is needed to commit each step. Install it: sudo apt-get install -y git"
  # OpenCode needs the agent's model and the relay, and none of the app.
  [[ "${ENGINE}" != "opencode" ]] || return 0
  agent_container_running || die "The agent container is not running. Start it: lca agent start"
  # The mount is fixed when the app container starts, so a value set since then
  # has not reached any sandbox yet.
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${AGENT_CONTAINER}" 2>/dev/null \
      | grep -qxF "OH_SANDBOX_MOUNTS_0_HOST_PATH=${AGENT_PROJECTS_DIR%/}" \
    || die "The running agent does not mount ${AGENT_PROJECTS_DIR} into its sandboxes yet. Restart it so it does: lca agent restart"
}

cmd_start() {
  preflight
  if [[ -r "${STATE_FILE}" && -z "${SPEC}" ]]; then
    die "${DIR} already holds a project ($(state_get STATUS)). Carry on with: lca agent project --dir ${DIR} --resume"
  fi
  if [[ -r "${STATE_FILE}" ]]; then
    case "$(state_get STATUS)" in
      done|stopped) ;;
      *) die "${DIR} already holds a project that is $(state_get STATUS). Carry on with --resume, or use a new directory." ;;
    esac
  fi
  [[ -r "${SPEC}" ]] || die "Cannot read the spec ${SPEC}."
  mkdir -p "${STATE_DIR}"
  cp "${SPEC}" "${STATE_DIR}/spec.md"
  : > "${STATE_DIR}/run.log"
  rm -f "${STATE_FILE}"
  state_set STATUS planning AUTONOMY "${AUTONOMY}" ENGINE "${ENGINE}" STEP 0 ATTEMPT 0 STARTED "$(date -u +%FT%TZ)" SPEC "$(realpath "${SPEC}")"
  ensure_repo
  normalize_perms || die "Could not set up ${DIR} for the sandbox (docker run of $(runtime_image) failed). Is the agent's image pulled? lca agent start"
  if [[ "${ENGINE}" == "opencode" ]]; then
    ensure_opencode_image || die "Could not build $(opencode_image): docker build of OpenCode ${AGENT_OPENCODE_VERSION} over $(runtime_image) failed."
  fi
  say "project started from ${SPEC}, autonomy ${AUTONOMY}, engine ${ENGINE}"
  start_runner
}

cmd_resume() {
  ENGINE="${ENGINE_FLAG:-$(state_get ENGINE)}"; ENGINE="${ENGINE:-openhands}"
  preflight
  [[ -r "${STATE_FILE}" ]] || die "No project at ${DIR} to resume."
  [[ "$(state_get STATUS)" != "done" ]] || die "The project at ${DIR} is done. See ${STATE_DIR}/SUMMARY.md."
  if [[ -n "${ANSWER}" ]]; then
    record_decision "step $(state_get STEP): answered by you" "$(state_get QUESTION)" "${ANSWER}"
    say "your answer is recorded in DECISIONS.md"
  fi
  [[ -z "${AUTONOMY_FLAG}" ]] || state_set AUTONOMY "${AUTONOMY_FLAG}"
  [[ -z "${ENGINE_FLAG}" ]] || state_set ENGINE "${ENGINE_FLAG}"
  # Back to the step it was on; a failed step gets a fresh set of attempts.
  if [[ "$(state_get STEP)" == "0" ]]; then state_set STATUS planning REASON "" QUESTION ""
  else state_set STATUS running REASON "" QUESTION ""; fi
  say "resumed by $(invoking_user)"
  start_runner
}

cmd_status() {
  [[ -r "${STATE_FILE}" ]] || die "No project at ${DIR}."
  local steps
  printf 'Project:  %s\nStatus:   %s%s\nStep:     %s (attempt %s)  %s\nAutonomy: %s\nEngine:   %s\n' \
    "${DIR}" "$(state_get STATUS)" "$( [[ -n "$(state_get REASON)" ]] && printf ' — %s' "$(state_get REASON)")" \
    "$(state_get STEP)" "$(state_get ATTEMPT)" "$(state_get TITLE)" "$(state_get AUTONOMY)" "$(state_get ENGINE)"
  if systemd_available; then
    printf 'Service:  %s (%s)\n' "$(unit_instance)" "$(systemctl is-active "$(unit_instance)" 2>/dev/null || true)"
  fi
  steps="$(project_plan_steps "${DIR}/PLAN.md" 2>/dev/null || true)"
  if [[ -n "${steps}" ]]; then
    printf '\nPlan:\n'
    awk -F'\t' '{ printf "  [%s] %s. %s\n", ($2 == 1 ? "x" : " "), $1, $3 }' <<<"${steps}"
  fi
  printf '\nLast log lines (%s/run.log):\n' "${STATE_DIR}"
  tail -n 8 "${STATE_DIR}/run.log" 2>/dev/null | sed 's/^/  /' || true
}

cmd_stop() {
  [[ -r "${STATE_FILE}" ]] || die "No project at ${DIR}."
  if systemd_available; then
    announce_possible_prompt "Stopping the project runner"
    as_root systemctl disable --now "$(unit_instance)" >/dev/null 2>&1 || true
  fi
  local cid
  cid="$(state_get CONVERSATION)"
  [[ -z "${cid}" ]] || delete_sandbox "${cid}"
  remove_opencode_containers
  [[ "$(state_get STATUS)" == "done" ]] || state_set STATUS stopped REASON "stopped by $(invoking_user)"
  ok "Stopped. Carry on later with: lca agent project --dir ${DIR} --resume"
}

main() {
  SPEC="" DIR="" AUTONOMY_FLAG="" ENGINE_FLAG="" ANSWER="" ACTION=start FOREGROUND=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir)        DIR="${2:-}"; shift 2 || die "--dir needs a path" ;;
      --autonomy)   AUTONOMY_FLAG="${2:-}"; shift 2 || die "--autonomy needs ask, self or answerer" ;;
      --answer)     ANSWER="${2:-}"; shift 2 || die "--answer needs the text" ;;
      --engine)     ENGINE_FLAG="${2:-}"; shift 2 || die "--engine needs openhands or opencode" ;;
      --status)     ACTION=status; shift ;;
      --stop)       ACTION=stop; shift ;;
      --resume)     ACTION=resume; shift ;;
      --run)        ACTION=run; shift ;;
      --foreground) FOREGROUND=true; shift ;;
      -h|--help)    usage; exit 0 ;;
      -*)           usage >&2; die "Unknown option: $1" ;;
      *)            SPEC="$1"; shift ;;
    esac
  done
  [[ -n "${DIR}" ]] || { usage >&2; die "No project directory. Name it: --dir ${AGENT_PROJECTS_DIR:-PATH}/myapp"; }
  DIR="$(realpath -m -- "${DIR}")"
  STATE_DIR="${DIR}/.lca-project"
  STATE_FILE="${STATE_DIR}/state"
  AUTONOMY="${AUTONOMY_FLAG:-${AGENT_PROJECT_AUTONOMY}}"
  project_autonomy_valid "${AUTONOMY}" || die "--autonomy must be ask, self or answerer (got '${AUTONOMY}')."
  # The .env default only matters to a new project; a running one has its
  # engine in its state, and a bad .env value must not stop it.
  ENGINE="${ENGINE_FLAG:-${AGENT_PROJECT_ENGINE}}"
  if [[ -n "${ENGINE_FLAG}" || "${ACTION}" == "start" ]]; then
    project_engine_valid "${ENGINE}" || die "--engine must be openhands or opencode (got '${ENGINE}')."
  fi
  [[ "${AGENT_PROJECT_RETRIES}" =~ ^[0-9]+$ ]] || die "AGENT_PROJECT_RETRIES must be a number (got '${AGENT_PROJECT_RETRIES}')."
  require_cmd curl jq docker
  # start, resume and stop ACT (they install or stop a systemd unit), so they
  # may ask for a password; --run is the unit itself and --status is a report,
  # and neither may stop for one. See LCA_MAY_PROMPT in lib.sh.
  case "${ACTION}" in
    start|resume|stop) LCA_MAY_PROMPT=true ;;
  esac
  case "${ACTION}" in
    start)  [[ -n "${SPEC}" ]] || { usage >&2; die "No spec file given."; }; cmd_start ;;
    resume) cmd_resume ;;
    status) cmd_status ;;
    stop)   cmd_stop ;;
    run)
      SBX="$(project_sandbox_dir "${DIR}")" || die "${DIR} is not inside AGENT_PROJECTS_DIR (${AGENT_PROJECTS_DIR:-unset})."
      cmd_run ;;
  esac
}

# Sourceable, so the suite can drive the pieces without a model.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
