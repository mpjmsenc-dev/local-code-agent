#!/usr/bin/env bash
# scripts/agent-project.sh — project mode: one spec in, a built project out.
#
#   lca agent project SPEC --dir DIR [--autonomy ask|self|answerer]
#
# The agent plans the project into PLAN.md, a numbered checklist where every
# step names the command that proves it. Then each step runs as its own fresh
# conversation (through scripts/agent-task.sh, with the directory named), is
# verified by running that command, and is committed only when it passes. A
# step that fails is retried with the failure in hand, AGENT_PROJECT_RETRIES
# times, and then the run STOPS rather than building on a broken base.
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
Usage: lca agent project SPEC --dir DIR [--autonomy ask|self|answerer] [--foreground]
       lca agent project --dir DIR --status | --stop | --resume [--answer "text"]

Builds a project from one spec file with no input from you: the agent writes
PLAN.md (small steps, each with a command that proves it), then each step runs
as its own conversation, is verified, and is committed when it passes. A step
that fails ${AGENT_PROJECT_RETRIES} retries stops the run instead of building on it.

  --dir DIR         the project directory; must be under AGENT_PROJECTS_DIR
                    (now: ${AGENT_PROJECTS_DIR:-unset — project mode is off})
  --autonomy MODE   when the agent stops to ask (default: ${AGENT_PROJECT_AUTONOMY}):
                    - ask       stop and report the question
                    - self      it decides, and records why in DECISIONS.md
                    - answerer  $(project_answerer_model) answers as project lead,
                                and the answer is logged in DECISIONS.md
                    In every mode it stops for credentials, anything outside
                    DIR, and deleting data.
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
  # The runner's own state is not the project's history.
  grep -qxF '.lca-project/' "${DIR}/.git/info/exclude" 2>/dev/null \
    || printf '.lca-project/\n' >> "${DIR}/.git/info/exclude"
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
  local sid
  sid="$(conversation_field "$1" sandbox_id || true)"
  [[ -n "${sid}" ]] || return 0
  if curl -fsS --max-time 120 -X DELETE "$(api)/api/v1/sandboxes/${sid}" >/dev/null 2>&1; then
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
  payload="$(curl -fsS --max-time 30 "$(api)/api/v1/conversation/$1/events/search?limit=10000" 2>/dev/null || true)"
  project_final_text "${payload}" 2>/dev/null || true
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

summary_text()   { cat "${STATE_DIR}/spec-summary.md" 2>/dev/null || head -c 1500 "${STATE_DIR}/spec.md"; }
plan_text()      { cat "${DIR}/PLAN.md" 2>/dev/null || true; }
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
  state_set STATUS "$1" REASON "$2"
  say "STOPPED ($1): $2"
  write_summary
  exit 0
}

# handle_turn CID WHAT — run the conversation to an end, answering questions
# the way the autonomy mode says. Returns 0 with the agent's last word in
# LAST_TEXT, or 1 with the reason in TURN_FAIL for a stopped/broken run.
handle_turn() {
  local cid="$1" what="$2" how kind hs reply asked=0 ans
  while :; do
    how="$(wait_turn "${cid}")"
    case "${how}" in
      finished) ;;
      timeout)    TURN_FAIL="the step ran past AGENT_TIMEOUT_MINUTES (${AGENT_TIMEOUT_MINUTES}) and was stopped"; return 1 ;;
      iterations) TURN_FAIL="the step reached AGENT_MAX_ITERATIONS (${AGENT_MAX_ITERATIONS}) and was stopped"; return 1 ;;
      gone)       TURN_FAIL="the step's sandbox went away before it finished"; return 1 ;;
      *)          TURN_FAIL="the conversation ended in state '${how}'"; return 1 ;;
    esac
    LAST_TEXT="$(final_text "${cid}")"
    kind="$(project_turn_kind "${LAST_TEXT}")"
    say "${what}: the agent's turn ended (${kind})"
    [[ "${kind}" == "question" ]] || return 0
    asked=$(( asked + 1 ))
    if hs="$(project_hard_stop "${LAST_TEXT}")"; then
      delete_sandbox "${cid}"
      stop_for_human waiting "${what}: the agent asked something only you may decide (${hs}): $(project_clip "${LAST_TEXT}" 600)"
    fi
    (( asked <= PROJECT_MAX_QUESTIONS )) \
      || { TURN_FAIL="the agent asked ${asked} questions in one attempt without finishing"; return 1; }
    case "${AUTONOMY}" in
      "ask")
        delete_sandbox "${cid}"
        state_set QUESTION "$(project_clip "${LAST_TEXT}" 2000)"
        stop_for_human waiting "${what}: the agent asked: $(project_clip "${LAST_TEXT}" 600)  — answer with: lca agent project --dir ${DIR} --resume --answer \"...\""
        ;;
      "self")
        reply="${PROJECT_SELF_REPLY}"
        say "${what}: answered in self mode: ${reply}"
        ;;
      "answerer")
        say "${what}: asking $(project_answerer_model) as project lead"
        if ! ans="$(ask_answerer "${LAST_TEXT}")"; then
          delete_sandbox "${cid}"
          stop_for_human waiting "${what}: the answerer $(project_answerer_model) did not answer. The question: $(project_clip "${LAST_TEXT}" 600)"
        fi
        if grep -q 'ESCALATE' <<<"${ans}" || hs="$(project_hard_stop "${ans}")"; then
          delete_sandbox "${cid}"
          stop_for_human waiting "${what}: the answerer escalated (${hs:-ESCALATE}). The question: $(project_clip "${LAST_TEXT}" 600)"
        fi
        record_decision "${what}: answered by $(project_answerer_model) as project lead" \
          "$(project_clip "${LAST_TEXT}" 1500)" "${ans}"
        say "${what}: answer recorded in DECISIONS.md"
        reply="Project lead's answer: ${ans}

This decision is recorded in DECISIONS.md. Continue, and end your final message with STEP DONE (or PLAN DONE when planning)."
        ;;
    esac
    local before_steps waited=0
    before_steps="$(agent_event_steps "${cid}" 2>/dev/null || printf 0)"
    send_reply "${cid}" "${reply}" \
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

# --- the two phases -------------------------------------------------------------
plan_phase() {
  local attempt problem failure=""
  [[ -f "${DIR}/PLAN.md" ]] && ! problem="$(project_plan_problem "${DIR}/PLAN.md")" && return 0
  for (( attempt = 1; attempt <= AGENT_PROJECT_RETRIES + 1; attempt++ )); do
    state_set STATUS planning STEP 0 ATTEMPT "${attempt}"
    say "planning, attempt ${attempt}"
    normalize_perms || true
    local task
    task="$(project_planning_task "${SBX}")"
    [[ -z "${failure}" ]] || task+=$'\n\n'"The previous plan could not be used: ${failure}. Rewrite PLAN.md in exactly the form above."
    submit "${task}" || { say "the agent would not take the planning task (see run.log); retrying later"; exit 75; }
    if ! handle_turn "${CID}" "planning"; then
      failure="${TURN_FAIL}"; delete_sandbox "${CID}"; continue
    fi
    delete_sandbox "${CID}"
    normalize_perms || true
    if problem="$(project_plan_problem "${DIR}/PLAN.md")"; then
      failure="${problem}"
      say "the plan is not usable: ${problem}"
      continue
    fi
    [[ -f "${DIR}/DECISIONS.md" ]] || printf '# Decisions\n' > "${DIR}/DECISIONS.md"
    commit_all "Plan: $(project_plan_steps "${DIR}/PLAN.md" | wc -l | tr -d ' ') steps"
    return 0
  done
  stop_for_human failed "planning failed $(( AGENT_PROJECT_RETRIES + 1 )) times; last: ${failure}"
}

step_phase() {   # N TOTAL TITLE VERIFY
  local n="$1" total="$2" title="$3" check="$4" attempt failure="" task
  for (( attempt = 1; attempt <= AGENT_PROJECT_RETRIES + 1; attempt++ )); do
    state_set STATUS running STEP "${n}" ATTEMPT "${attempt}" TITLE "${title}"
    say "step ${n}/${total}: ${title} (attempt ${attempt})"
    normalize_perms || true
    touch "${STATE_DIR}/step-start"
    task="$(project_step_task "${SBX}" "${n}" "${total}" "${title}" "${check}" \
            "$(summary_text)" "$(plan_text)" "$(decisions_text)" "${failure}")"
    submit "${task}" || { say "the agent would not take step ${n} (see run.log); retrying later"; exit 75; }
    if ! handle_turn "${CID}" "step ${n}"; then
      failure="${TURN_FAIL}"
      say "step ${n}, attempt ${attempt}: ${failure}"
      delete_sandbox "${CID}"
      continue
    fi
    delete_sandbox "${CID}"
    normalize_perms || true
    if ! after_step_checks; then
      stop_for_human waiting "step ${n}: ${CHECK_FAIL} — nothing was committed; look at the working tree before resuming"
    fi
    if verify "${check}"; then
      printf '%s\n' "${VERIFY_OUT}" > "${STATE_DIR}/step-${n}-attempt-${attempt}.log"
      project_plan_mark_done "${DIR}/PLAN.md" "${n}" || say "could not tick step ${n} in PLAN.md"
      commit_all "Step ${n}: ${title}"
      say "step ${n} PASSED: ${check}"
      return 0
    fi
    printf '%s\n' "${VERIFY_OUT}" > "${STATE_DIR}/step-${n}-attempt-${attempt}.log"
    failure="${VERIFY_OUT}"
    say "step ${n}, attempt ${attempt}: verification FAILED (${check}); output in .lca-project/step-${n}-attempt-${attempt}.log"
  done
  stop_for_human failed "step ${n} (${title}) failed verification $(( AGENT_PROJECT_RETRIES + 1 )) times; last output in .lca-project/step-${n}-attempt-$(( attempt - 1 )).log"
}

write_summary() {
  local steps total done_ status decisions failed_line
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
    printf -- '- Autonomy: %s%s\n\n' "$(state_get AUTONOMY)" "$( [[ "$(state_get AUTONOMY)" == answerer ]] && printf ' (answerer: %s)' "$(project_answerer_model)")"
    printf '## What to review\n\n'
    printf -- '- DECISIONS.md: every decision taken without you:\n'
    grep '^## ' "${DIR}/DECISIONS.md" 2>/dev/null | sed 's/^## /  - /' || true
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
  # A run that was interrupted (a reboot, a crash) left its attempt's sandbox
  # behind. The attempt is started again from the top, so that one goes.
  local stale
  stale="$(state_get CONVERSATION)"
  if ! agent_container_running || ! curl -fsS --max-time 10 -o /dev/null "$(api)/" 2>/dev/null; then
    say "the agent is not answering yet; systemd will try again"
    exit 75
  fi
  if [[ -n "${stale}" ]]; then
    delete_sandbox "${stale}"
    state_set CONVERSATION ""
  fi
  ensure_repo
  plan_phase
  steps="$(project_plan_steps "${DIR}/PLAN.md")"
  total="$(grep -c . <<<"${steps}")"
  while IFS=$'\t' read -r n done_ title check; do
    [[ "${done_}" == "1" ]] && continue
    step_phase "${n}" "${total}" "${title}" "${check}" </dev/null
  done <<<"${steps}"
  state_set STATUS "done" STEP "${total}" REASON ""
  say "all ${total} steps done"
  write_summary
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
  agent_container_running || die "The agent container is not running. Start it: lca agent start"
  # The mount is fixed when the app container starts, so a value set since then
  # has not reached any sandbox yet.
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${AGENT_CONTAINER}" 2>/dev/null \
      | grep -qxF "OH_SANDBOX_MOUNTS_0_HOST_PATH=${AGENT_PROJECTS_DIR%/}" \
    || die "The running agent does not mount ${AGENT_PROJECTS_DIR} into its sandboxes yet. Restart it so it does: lca agent restart"
  have git || die "git is needed to commit each step. Install it: sudo apt-get install -y git"
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
  state_set STATUS planning AUTONOMY "${AUTONOMY}" STEP 0 ATTEMPT 0 STARTED "$(date -u +%FT%TZ)" SPEC "$(realpath "${SPEC}")"
  ensure_repo
  normalize_perms || die "Could not set up ${DIR} for the sandbox (docker run of $(runtime_image) failed). Is the agent's image pulled? lca agent start"
  say "project started from ${SPEC}, autonomy ${AUTONOMY}"
  start_runner
}

cmd_resume() {
  preflight
  [[ -r "${STATE_FILE}" ]] || die "No project at ${DIR} to resume."
  [[ "$(state_get STATUS)" != "done" ]] || die "The project at ${DIR} is done. See ${STATE_DIR}/SUMMARY.md."
  if [[ -n "${ANSWER}" ]]; then
    record_decision "step $(state_get STEP): answered by you" "$(state_get QUESTION)" "${ANSWER}"
    say "your answer is recorded in DECISIONS.md"
  fi
  [[ -z "${AUTONOMY_FLAG}" ]] || state_set AUTONOMY "${AUTONOMY_FLAG}"
  # Back to the step it was on; a failed step gets a fresh set of attempts.
  if [[ "$(state_get STEP)" == "0" ]]; then state_set STATUS planning REASON "" QUESTION ""
  else state_set STATUS running REASON "" QUESTION ""; fi
  say "resumed by $(invoking_user)"
  start_runner
}

cmd_status() {
  [[ -r "${STATE_FILE}" ]] || die "No project at ${DIR}."
  local steps
  printf 'Project:  %s\nStatus:   %s%s\nStep:     %s (attempt %s)  %s\nAutonomy: %s\n' \
    "${DIR}" "$(state_get STATUS)" "$( [[ -n "$(state_get REASON)" ]] && printf ' — %s' "$(state_get REASON)")" \
    "$(state_get STEP)" "$(state_get ATTEMPT)" "$(state_get TITLE)" "$(state_get AUTONOMY)"
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
  [[ "$(state_get STATUS)" == "done" ]] || state_set STATUS stopped REASON "stopped by $(invoking_user)"
  ok "Stopped. Carry on later with: lca agent project --dir ${DIR} --resume"
}

main() {
  SPEC="" DIR="" AUTONOMY_FLAG="" ANSWER="" ACTION=start FOREGROUND=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir)        DIR="${2:-}"; shift 2 || die "--dir needs a path" ;;
      --autonomy)   AUTONOMY_FLAG="${2:-}"; shift 2 || die "--autonomy needs ask, self or answerer" ;;
      --answer)     ANSWER="${2:-}"; shift 2 || die "--answer needs the text" ;;
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
