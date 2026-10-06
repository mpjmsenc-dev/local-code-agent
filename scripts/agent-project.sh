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
# reviewed for bugs and security. A step whose checks fail is retried with
# their output, AGENT_PROJECT_RETRIES times; then it is split into smaller
# steps (two levels at most), and a part that still fails is re-planned once.
# When every step is done, the acceptance rounds run the project's full checks,
# every step's check again and the spec's Definition of Done, and add fix
# steps for whatever fails (AGENT_PROJECT_ACCEPT_ROUNDS).
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
#   few stops               credentials, anything outside DIR, rewriting what
#                           is not the project's: never decided by any autonomy
#                           mode (project_hard_stop, after_step_checks); and no
#                           progress for AGENT_PROJECT_STALL_HOURS, or a run of
#                           AGENT_PROJECT_MAX_DAYS in all
#   local git only          remotes are removed and pushing refused on every
#                           turn (enforce_local_git), not configured once
#   one at a time           projects queue for one lock (queue_wait)
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
       lca agent project --dir DIR --status | --json | --stop | --resume [--answer "text"]

Builds a project from one spec file with no input from you: the agent writes
PLAN.md (small steps, each with a command that proves it), choosing a mature
open-source base project when one fits. Then, for each step: its tests are
written first, the step is implemented and verified and committed when it
passes, and the change is reviewed for bugs and security. A step that fails
${AGENT_PROJECT_RETRIES} retries is split into smaller steps; at the end, the full checks and
the spec's Definition of Done are run, with up to ${AGENT_PROJECT_ACCEPT_ROUNDS} rounds of fixes.
One project runs at a time; the others queue.

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
  --json            the same, as one JSON object (what the dashboard reads)
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
  enforce_local_git
}

# local_only_hook — the pre-push hook every project carries.
local_only_hook() {
  printf '%s\n' '#!/bin/sh' \
    '# Installed by local-code-agent project mode: this project is local only.' \
    'echo "This project is local only: git is its history and its rollback, never a way off this machine. Push refused." >&2' \
    'exit 1'
}

# enforce_local_git — git is the project's history and its way back, never a
# way off this machine. Enforced after every turn, not configured once: the
# agent can run git in its sandbox, and a base project cloned in brings its
# origin with it. Every remote is removed, pushing is refused by a hook that is
# put back if changed, a hooks path pointing elsewhere is unset, and a nested
# repository's .git is moved aside (its files stay in the project). The runner
# itself never pushes, and no sandbox holds a credential to push with.
enforce_local_git() {
  local r g rel to hook="${DIR}/.git/hooks/pre-push"
  [[ -d "${DIR}/.git" ]] || return 0
  while IFS= read -r r; do
    [[ -n "${r}" ]] || continue
    git_here remote remove "${r}" >/dev/null 2>&1 || git_here config --remove-section "remote.${r}" >/dev/null 2>&1 || true
    say "git: removed the remote '${r}': projects are local only"
  done < <(git_here remote 2>/dev/null || true)
  git_here config --unset-all core.hooksPath >/dev/null 2>&1 || true
  mkdir -p "${DIR}/.git/hooks"
  if ! cmp -s <(local_only_hook) "${hook}" 2>/dev/null; then
    local_only_hook > "${hook}" && chmod 755 "${hook}"
  fi
  while IFS= read -r -d '' g; do
    rel="${g#"${DIR}"/}"
    to="${STATE_DIR}/nested-git/${rel}.$(date +%s)"
    mkdir -p "$(dirname "${to}")"
    mv -f "${g}" "${to}" \
      && say "git: moved the nested repository ${rel} aside to ${to#"${DIR}"/} (its files stay in the project; its history and remotes do not)"
  done < <(find "${DIR}" -mindepth 2 \( -path "${STATE_DIR}" -o -path "${DIR}/.git" -o -name node_modules \) -prune \
             -o -name .git -print0 2>/dev/null)
  return 0
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
# STATUS waiting: a person has to answer or decide (credentials, something
# outside the project). failed: re-planning made no progress. stalled: nothing
# passed for AGENT_PROJECT_STALL_HOURS. limit: AGENT_PROJECT_MAX_DAYS used up.
# incomplete: the acceptance rounds ran out with checks still failing. All exit
# 0, so systemd does not restart into the same wall; the next queued project
# then gets its turn.
stop_for_human() {   # STATUS REASON
  # A turn that is stopped mid-conversation leaves its sandbox or container
  # behind unless whoever started it said how to take it down.
  if [[ -n "${TURN_CLEANUP:-}" ]]; then ${TURN_CLEANUP} || true; TURN_CLEANUP=""; fi
  state_set STATUS "$1" REASON "$2"
  say "STOPPED ($1): $2"
  retire_unit
  write_summary
  local why
  case "$1" in
    failed)     why="re-planning made no progress" ;;
    stalled)    why="no progress for ${AGENT_PROJECT_STALL_HOURS} hours" ;;
    limit)      why="its ${AGENT_PROJECT_MAX_DAYS}-day limit is used up" ;;
    incomplete) why="acceptance checks still fail after ${AGENT_PROJECT_ACCEPT_ROUNDS} rounds" ;;
    *)          why="it needs you"
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
    # Unattended, a question about credentials, the world outside the project
    # or deleting data gets the one safe answer (project_question_reply), and
    # only an agent that asks for credentials AGAIN, having been told there
    # are none, stops the run: then the project really needs them.
    if [[ "${AUTONOMY}" == "ask" ]] || [[ "${hs}" == "credentials" && "${CRED_ASKED:-0}" -ge 1 ]]; then
      stop_for_human waiting "${what}: the agent asked something only you may decide (${hs}): $(project_clip "${LAST_TEXT}" 600)"
    fi
    [[ "${hs}" != "credentials" ]] || CRED_ASKED=$(( ${CRED_ASKED:-0} + 1 ))
    (( asked <= PROJECT_MAX_QUESTIONS )) \
      || { TURN_FAIL="the agent asked ${asked} questions in one attempt without finishing"; return 1; }
    REPLY="$(project_question_reply "${hs}")"
    record_decision "${what}: a question about ${hs}, answered by the runner's rule" \
      "$(project_clip "${LAST_TEXT}" 1500)" "${REPLY}"
    say "${what}: a question about ${hs}, answered with the safe rule (DECISIONS.md)"
    REPLY+=" End your final message with STEP DONE (TESTS DONE when writing tests, PLAN DONE when planning)."
    return 0
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
      # Nobody is there to ask instead: a lead that does not answer, or
      # refuses, leaves the agent to decide, and that is recorded too.
      if ! ans="$(ask_answerer "${LAST_TEXT}")" || project_answer_escalates "${ans}"; then
        say "${what}: the project lead did not answer (or escalated); the agent decides"
        ans="${PROJECT_SELF_REPLY}"
      fi
      say "${what}: the project lead replied: $(project_clip "${ans}" 600)"
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
  local cid="$1" what="$2" how kind asked=0 CRED_ASKED=0
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
                                  "$(agent_model_context)" "$(agent_max_output_tokens)" "${steps}" \
                                  "$(( $(agent_request_timeout) * 1000 ))")" \
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
  local msg="$1" what="$2" session="" out rc kind asked=0 name t0 events finish cut=0 CRED_ASKED=0
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
    finish="$(opencode_last_finish < "${out}")"
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
    # A reply cut at the cap ends the run with the work half-written: a CRM
    # step's tests were typed out as text up to exactly 4,096 tokens, no file
    # was written, and the step went on without tests (2026-10-06). It is
    # asked to carry on, in smaller pieces, twice at most.
    if [[ "${finish}" == "length" && -n "${session}" ]] && (( cut < 2 )); then
      cut=$(( cut + 1 ))
      say "${what}: the reply was cut at the cap on one reply ($(agent_max_output_tokens) tokens); asking it to continue in smaller pieces (${cut} of 2)"
      msg="Your last reply was cut off at the length limit before you finished. Continue from where you stopped. Write every file with the write or edit tool, never as text in your reply, and keep each file or edit under 250 lines: split bigger ones."
      continue
    fi
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
# runs on: 0 with LAST_TEXT, or 1 with TURN_FAIL. Around it: the limits are
# checked first, and afterwards whatever the agent did to git is undone (the
# runner is the only one that commits) and the project made local again.
run_turn() {
  local rc=0 head ref
  progress_guard
  head="$(git_here rev-parse -q --verify HEAD 2>/dev/null || true)"
  ref="$(git_here symbolic-ref -q HEAD 2>/dev/null || true)"
  case "${ENGINE}" in
    opencode) oc_turn "$1" "$2" || rc=$? ;;
    *)        oh_turn "$1" "$2" || rc=$? ;;
  esac
  guard_history "${head}" "${ref}"
  enforce_local_git
  return "${rc}"
}

# guard_history HEAD REF — the agent is told not to run git, and the tree is
# what is verified, so a commit, reset or branch switch it made is undone
# without touching its files: back on REF, at HEAD, with the work uncommitted.
# A .git that is gone is a stop: the project's history is the one thing an
# unattended run must never lose.
guard_history() {
  local was="$1" ref="$2" now
  [[ -d "${DIR}/.git" ]] || stop_for_human waiting "the step removed the project's .git (delete): its history is gone; look before resuming"
  [[ -z "${ref}" ]] || [[ "$(git_here symbolic-ref -q HEAD 2>/dev/null || true)" == "${ref}" ]] \
    || { git_here symbolic-ref HEAD "${ref}" && say "git: the agent switched branches; back on ${ref#refs/heads/}"; }
  now="$(git_here rev-parse -q --verify HEAD 2>/dev/null || true)"
  [[ "${now}" != "${was}" ]] || return 0
  if [[ -z "${was}" ]]; then
    git_here update-ref -d HEAD 2>/dev/null || true
  else
    git_here reset -q --soft "${was}" 2>/dev/null || git_here update-ref HEAD "${was}"
  fi
  git_here reset -q 2>/dev/null || true
  say "git: the agent moved HEAD itself (${now:0:12}); put back to ${was:0:12}, its changes kept uncommitted for the checks"
}

# --- the limits: no progress for hours, or too many days in all ---------------------
# Progress is a plan accepted, a step that passed, a milestone planned or an
# acceptance round passed: note_progress. Days are counted while the runner
# runs (ACTIVE_SECONDS, plus this run since RUN_T0), so time spent queued or
# stopped by a person does not count.
RUN_T0="$(date +%s)"
note_progress() { state_set LAST_PROGRESS "$(date +%s)"; }
active_seconds() {
  local total
  total="$(state_get ACTIVE_SECONDS)"; [[ "${total}" =~ ^[0-9]+$ ]] || total=0
  printf '%s' "$(( total + $(date +%s) - RUN_T0 ))"
}
account_active() {
  [[ -r "${STATE_FILE:-}" && "${RUN_ACCOUNTED:-}" != "true" ]] || return 0
  RUN_ACCOUNTED=true
  state_set ACTIVE_SECONDS "$(active_seconds)"
}
progress_guard() {
  local now last
  now="$(date +%s)"
  last="$(state_get LAST_PROGRESS)"
  [[ "${last}" =~ ^[0-9]+$ ]] || { last="${now}"; state_set LAST_PROGRESS "${now}"; }
  if [[ "${AGENT_PROJECT_STALL_HOURS}" =~ ^[0-9]+$ ]] && (( AGENT_PROJECT_STALL_HOURS > 0 )) \
     && (( now - last >= AGENT_PROJECT_STALL_HOURS * 3600 )); then
    stop_for_human stalled "no progress for ${AGENT_PROJECT_STALL_HOURS} hours: nothing passed since $(date -u -d "@${last}" '+%F %H:%M') UTC"
  fi
  if [[ "${AGENT_PROJECT_MAX_DAYS}" =~ ^[0-9]+$ ]] && (( AGENT_PROJECT_MAX_DAYS > 0 )) \
     && (( $(active_seconds) >= AGENT_PROJECT_MAX_DAYS * 86400 )); then
    stop_for_human limit "the project has run for ${AGENT_PROJECT_MAX_DAYS} days, its limit"
  fi
  return 0
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
# rc 0: keep it. rc 1, reason in CHECK_FAIL: stop, a person must look (files
# outside the project changed; a real credential in the tree). rc 2, reason in
# CHECK_FAIL: the attempt does not count and the step goes on (a hard-coded
# secret, to be read from the environment instead). Deleting a tracked file is
# allowed, because git still has it, and recorded in DECISIONS.md.
after_step_checks() {
  local outside deleted kind
  outside="$(find "${AGENT_PROJECTS_DIR%/}" -mindepth 1 -path "${DIR}" -prune -o \
              -newer "${STATE_DIR}/step-start" -print 2>/dev/null | head -5 || true)"
  if [[ -n "${outside}" ]]; then
    CHECK_FAIL="outside: files outside the project changed during the step: $(tr '\n' ' ' <<<"${outside}")"
    return 1
  fi
  restore_runner_files
  git_here add -A
  kind="$(project_diff_secret_kind "$(git_here diff --cached)" || true)"
  deleted="$(git_here diff --cached --name-status | awk '$1 == "D" { print $2 }' | head -20)"
  git_here reset -q
  if [[ "${kind}" == "key" ]]; then
    CHECK_FAIL="credentials: the step's changes contain what looks like a real credential (a private key or an access token)"
    return 1
  fi
  if [[ "${kind}" == "literal" ]]; then
    CHECK_FAIL="the change hard-codes a password or secret in the code. Read it from an environment variable (with a clearly fake default only for tests), document the variable in README.md, and never commit a real value."
    return 2
  fi
  if [[ -n "${deleted}" ]]; then
    record_decision "$(state_get TITLE): files removed by the agent" "Which tracked files did the step delete?" \
      "$(tr '\n' ' ' <<<"${deleted}")— kept in git's history at $(git_here rev-parse --short HEAD 2>/dev/null || echo 'the last commit'); restore one with: git checkout <commit> -- <file>"
    say "the step deleted tracked files (recorded in DECISIONS.md; git still has them): $(tr '\n' ' ' <<<"${deleted}")"
  fi
  return 0
}

# restore_runner_files — PLAN.md and ACCEPTANCE.md are the runner's: a step
# that ticks its own step, or rewrites the checks it is held to, is not done by
# saying so. Put back as committed, and said.
restore_runner_files() {
  local f
  for f in PLAN.md ACCEPTANCE.md; do
    git_here cat-file -e "HEAD:${f}" 2>/dev/null || continue
    if ! git_here diff --quiet HEAD -- "${f}" 2>/dev/null || [[ ! -e "${DIR}/${f}" ]]; then
      git_here checkout -q HEAD -- "${f}" && say "the step changed ${f}, which is the runner's; put back"
    fi
  done
}

# verify CMD — run the step's own check in a throwaway container from the
# agent's image, at the same path the agent saw (a .venv's shebangs name it),
# network off. Sets VERIFY_OUT; rc is the command's.
verify() {
  local name="lca-verify-$$-${RANDOM}" rc=0
  VERIFY_OUT="$(timeout "${PROJECT_VERIFY_SECONDS}" docker run --rm --name "${name}" \
      --network none --user "$(owner_uid):${PROJECT_SANDBOX_GID}" -e HOME=/tmp \
      -v "${DIR}:${SBX}" -w "${SBX}" --entrypoint bash "$(runtime_image)" -lc "$1" 2>&1 </dev/null)" || rc=$?
  if (( rc == 124 )); then
    docker rm -f "${name}" >/dev/null 2>&1 || true
    VERIFY_OUT+=$'\n'"(verification stopped after ${PROJECT_VERIFY_SECONDS}s)"
  fi
  return "${rc}"
}

# verify_step CMD — a step is done when its own check passes AND every project
# check (PLAN.md's "## Checks": install, build, typecheck, lint, the whole test
# suite) that has passed once still passes. A check that has never passed is
# not on yet (the code it checks may not exist); it switches on, for good, the
# first time it passes (CHECKS_ON). The acceptance rounds run all of them.
# Sets VERIFY_OUT; rc 0 only when everything that is on passed.
verify_step() {
  local out name cmd on
  verify "$1" || return 1
  out="${VERIFY_OUT}"
  on=" $(state_get CHECKS_ON) "
  while IFS=$'\t' read -r name cmd; do
    [[ -n "${name}" && -n "${cmd}" ]] || continue
    if verify "${cmd}"; then
      if [[ "${on}" != *" ${name} "* ]]; then
        on+="${name} "
        say "the project check ${name} passes for the first time; every step from now on must keep it passing"
      fi
    elif [[ "${on}" == *" ${name} "* ]]; then
      VERIFY_OUT="${out}"$'\n\n'"The step's own check passed, but the project check ${name} (${cmd}) fails now:"$'\n'"$(project_clip "${VERIFY_OUT}" 2500)"
      state_set CHECKS_ON "$(xargs <<<"${on}")"
      return 1
    fi
  done < <(project_plan_checks "${DIR}/PLAN.md" 2>/dev/null || true)
  state_set CHECKS_ON "$(xargs <<<"${on}")"
  VERIFY_OUT="${out}"
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
  local attempt problem failure="" large=""
  # An accepted plan stands as the runner has since changed it (split steps,
  # milestones, acceptance fixes); it is not checked against the spec again.
  if plan_accepted && project_plan_steps "${DIR}/PLAN.md" 2>/dev/null | grep -q .; then
    return 0
  fi
  if [[ -f "${DIR}/PLAN.md" ]] && ! project_plan_problem "${DIR}/PLAN.md" "${STATE_DIR}/spec.md" >/dev/null; then
    if ! project_base_problem "${DIR}/DECISIONS.md" >/dev/null; then
      return 0
    fi
  fi
  ! project_spec_is_large "${STATE_DIR}/spec.md" || large=large
  # Not a fixed number of tries: planning goes on, told what was wrong each
  # time, until the run's limits stop it (progress_guard, in run_turn).
  for (( attempt = 1; ; attempt++ )); do
    state_set STATUS planning STEP 0 ATTEMPT "${attempt}"
    say "planning, attempt ${attempt}"
    tg_progress "Planning (attempt ${attempt})"
    normalize_perms || true
    local task
    task="$(project_planning_task "${SBX}" "${large}")"
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
    note_progress
    tg_event "📋 plan accepted: $(project_plan_steps "${DIR}/PLAN.md" | wc -l | tr -d ' ') steps"
    return 0
  done
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
keep_plan_only() {   # [FILE...] — what it may write instead of PLAN.md and DECISIONS.md
  local line st path moved="" f ok
  local -a may=("$@")
  (( ${#may[@]} > 0 )) || may=(PLAN.md DECISIONS.md)
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    st="${line:0:2}" path="${line:3}"
    case "${path}" in .lca-project/*) continue ;; esac
    ok=false
    for f in "${may[@]}"; do [[ "${path}" != "${f}" ]] || ok=true; done
    [[ "${ok}" == "false" ]] || continue
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
                "$(summary_text)" "$(plan_ctx "${n}")" "$(decisions_text)")" "step ${n} tests" \
      || say "step ${n} tests: ${TURN_FAIL}; keeping what was written"
    normalize_perms || true
    local ck=0
    after_step_checks || ck=$?
    if (( ck == 1 )); then
      phase_end tests "${n}" 1 "stopped"
      stop_for_human waiting "step ${n} tests: ${CHECK_FAIL} — nothing was committed; look at the working tree before resuming"
    fi
    if [[ -z "$(git_here status --porcelain 2>/dev/null)" ]]; then
      phase_end tests "${n}" 1 "none-written"
      say "step ${n}: no tests were written; the step goes on without tests first"
      return 0
    fi
    if verify "${check}"; then
      phase_end tests "${n}" 1 "already-pass"
      say "step ${n}: its tests already pass before the step is written, so they may not test it (the review sees this)"
    else
      phase_end tests "${n}" 1 "red"
      say "step ${n}: the new tests fail before the step is written, as they should"
      check_tests "${n}" "${total}" "${title}" "${check}"
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

# check_tests N TOTAL TITLE VERIFY — red tests, but red for the right reason?
# One request asks (project_tests_check_payload). Broken tests get ONE more
# tests conversation, told what is wrong; whatever it leaves is what is
# committed. Leaves VERIFY_OUT as the last red run's.
ask_tests_check() {   # TITLE TESTS OUTPUT — the verdict line
  local reply
  reply="$(curl -fsS --max-time "$(agent_request_timeout)" "$(ollama_url)/api/chat" -H 'Content-Type: application/json' \
            -d "$(project_tests_check_payload "$(project_reviewer_model)" "$(summary_text)" "$1" "$2" "$3")" 2>/dev/null \
           | jq -r '.message.content // empty' 2>/dev/null)" || { printf 'unclear'; return 0; }
  project_tests_verdict <<<"${reply}"
}
check_tests() {
  local n="$1" total="$2" title="$3" check="$4" tests verdict reason f
  # What the tests conversation wrote: changes to tracked files, and new files whole.
  tests="$(git_here diff HEAD 2>/dev/null || true)"
  while IFS= read -r -d '' f; do
    tests+=$'\n'"=== ${f} ==="$'\n'"$(cat "${DIR}/${f}" 2>/dev/null || true)"
  done < <(git_here ls-files --others --exclude-standard -z 2>/dev/null || true)
  phase_begin
  verdict="$(ask_tests_check "${title}" "${tests}" "${VERIFY_OUT}")"
  phase_end tests-check "${n}" 1 "${verdict%%$'\t'*}"
  [[ "${verdict}" == broken* ]] || return 0
  reason="${verdict#*$'\t'}"
  say "step ${n}: the check says its tests are broken, not just red: $(project_clip "${reason}" 300); one more go at the tests"
  phase_begin
  run_turn "$(project_tests_task "${SBX}" "${n}" "${total}" "${title}" "${check}" \
              "$(summary_text)" "$(plan_text)" "$(decisions_text)")"$'\n\n'"The tests you wrote are broken, not just failing for the missing feature: ${reason} Fix the tests themselves; still do not implement the step." \
           "step ${n} tests, again" \
    || say "step ${n} tests, again: ${TURN_FAIL}; keeping what was written"
  normalize_perms || true
  local ck=0
  after_step_checks || ck=$?
  if (( ck == 1 )); then
    phase_end tests "${n}" 2 "stopped"
    stop_for_human waiting "step ${n} tests: ${CHECK_FAIL} — nothing was committed; look at the working tree before resuming"
  fi
  if verify "${check}"; then phase_end tests "${n}" 2 "already-pass"; else phase_end tests "${n}" 2 "red"; fi
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
            "$(summary_text)" "$(plan_ctx "${n}")" "$(decisions_text)" "${failure}" "${TEST_LIST}" "${last}")"
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
    local ck=0
    after_step_checks || ck=$?
    if (( ck == 1 )); then
      phase_end step "${n}" "${attempt}" "stopped"
      stop_for_human waiting "step ${n}: ${CHECK_FAIL} — nothing was committed; look at the working tree before resuming"
    fi
    if (( ck == 2 )); then
      VERIFY_OUT="Not accepted: ${CHECK_FAIL}"
    elif verify_step "${check}"; then
      phase_end step "${n}" "${attempt}" "passed"
      printf '%s\n' "${VERIFY_OUT}" > "${STATE_DIR}/step-${n}-attempt-${attempt}.log"
      commit_all "Step ${n}: ${title}"
      note_progress
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
  # Not the end: the step is made smaller (split_step), or re-planned when it
  # is already as small as it gets. The loop in cmd_run reads the plan again.
  split_step "${n}" "${title}" "${check}" "${failure}" "${base}"
}

# plan_ctx N — PLAN.md as a step's prompt carries it (project_plan_context).
plan_ctx() { project_plan_context "${DIR}/PLAN.md" "$1" 2500; }

# set_aside_attempts N — the failed attempts at step N, kept: the working tree
# committed onto refs/lca/failed/step-N (HEAD does not move), then dropped.
set_aside_attempts() {
  local n="$1" base="$2" tree c parent
  git_here add -A
  parent="$(git_here rev-parse -q --verify HEAD 2>/dev/null || true)"
  tree="$(git_here write-tree)"
  if [[ -n "${parent}" ]]; then
    c="$(git_here commit-tree "${tree}" -p "${parent}" -m "Step ${n}: the failed attempts, set aside" 2>/dev/null || true)"
  else
    c="$(git_here commit-tree "${tree}" -m "Step ${n}: the failed attempts, set aside" 2>/dev/null || true)"
  fi
  git_here reset -q
  [[ -z "${c}" ]] || git_here update-ref "refs/lca/failed/step-${n}" "${c}"
  # Back to where step N began, before its tests: the parts write their own.
  if git_here cat-file -e "${base}^{commit}" 2>/dev/null; then
    discard_to "${base}"
  else
    discard_to HEAD
  fi
  say "step ${n}: its failed attempts are kept at refs/lca/failed/step-${n}; back to where the step began"
}

# ask_lead PAYLOAD — one request to the reviewer model; its reply, or rc 1.
ask_lead() {
  local reply
  reply="$(curl -fsS --max-time "$(agent_request_timeout)" "$(ollama_url)/api/chat" -H 'Content-Type: application/json' \
            -d "$1" 2>/dev/null | jq -r '.message.content // empty' 2>/dev/null)" || return 1
  [[ -n "${reply//[[:space:]]/}" ]] || return 1
  printf '%s' "${reply}"
}

# split_step N TITLE VERIFY FAILURE BASE — step N failed every attempt. Under
# two levels deep, it becomes 2 to 4 smaller steps (project_plan_split), the
# last one still held to N's check. Two levels deep, it is re-planned once in
# place: a new approach, and a new check when the old one was wrong. A step
# that fails again after that: re-planning made no progress, and the run stops.
split_step() {
  local n="$1" title="$2" check="$3" failure="$4" base="$5" depth try reply parts problem
  depth="$(project_step_depth "${n}")"
  set_aside_attempts "${n}" "${base}"
  state_set TESTS_STEP "" TESTS_COMMIT "" BASE_STEP "" BASE ""
  if (( depth >= 2 )); then
    replan_step "${n}" "${title}" "${check}" "${failure}"
    return 0
  fi
  parts="${STATE_DIR}/split-${n}.md"
  for (( try = 1; try <= 3; try++ )); do
    state_set STATUS running STEP "${n}" ATTEMPT split TITLE "${title}"
    say "step ${n} failed every attempt; asking for it as smaller steps (try ${try})"
    progress_guard
    phase_begin
    if ! reply="$(ask_lead "$(project_split_payload "$(project_reviewer_model)" "$(summary_text)" "$(plan_ctx "${n}")" \
                    "${n}" "${title}" "${check}" "${failure}")")"; then
      phase_end split "${n}" "${try}" "no-answer"
      continue
    fi
    project_strip_tool_markup <<<"${reply}" | sed -E '/^[[:space:]]*```/d' > "${parts}"
    cp -p "${DIR}/PLAN.md" "${STATE_DIR}/.plan-before-split"
    if project_plan_split "${DIR}/PLAN.md" "${n}" "${parts}" "${check}" \
       && ! problem="$(project_plan_problem "${DIR}/PLAN.md")"; then
      phase_end split "${n}" "${try}" "split"
      record_decision "step ${n} split into smaller steps" "Step ${n} (${title}) failed every attempt. How is it done instead?" \
        "As these steps, the last one still held to the step's own check:"$'\n\n'"$(project_plan_steps "${DIR}/PLAN.md" | awk -F'\t' -v n="${n}." 'index($1, n) == 1 { printf "- %s %s (Verify: %s)\n", $1, $3, $4 }')"
      commit_all "Step ${n} split into smaller steps"
      say "step ${n} is split into $(project_plan_steps "${parts}" | grep -c .) smaller steps"
      tg_event "✂️ step ${n} split into smaller steps"
      return 0
    fi
    cat "${STATE_DIR}/.plan-before-split" > "${DIR}/PLAN.md"
    phase_end split "${n}" "${try}" "unusable"
    say "step ${n}: the split was not usable (${problem:-not 2 to 6 steps with a check each}); asking again"
  done
  # No usable split: the step is re-planned in place instead, once.
  replan_step "${n}" "${title}" "${check}" "${failure}"
}

# replan_step N TITLE VERIFY FAILURE — one step, written again with a new
# approach (and a corrected check if the old one was wrong), once per step.
replan_step() {
  local n="$1" title="$2" check="$3" failure="$4" key reply one new problem
  one="${STATE_DIR}/replan-${n}.md"
  key="REPLANNED_${n//./_}"
  if [[ "$(state_get "${key}")" == "1" ]]; then
    stop_for_human failed "step ${n} (${title}) failed again after it was split and re-planned: re-planning made no progress. The last output is in .lca-project/; the attempts are kept at refs/lca/failed/step-${n}"
  fi
  state_set "${key}" 1 STATUS running STEP "${n}" ATTEMPT replan TITLE "${title}"
  say "step ${n} cannot be split further; re-planning it"
  progress_guard
  reply="$(ask_lead "$(project_split_payload "$(project_reviewer_model)" "$(summary_text)" "$(plan_ctx "${n}")" \
             "${n}" "${title}" "${check}" "${failure}" \
           | jq -c '.messages[0].content = "You are the project lead. A step of the plan failed every attempt, and it is already as small as steps get. Write it again as ONE step with a different approach, in exactly this form and nothing else:\n- [ ] 1. Short title\n  Verify: `one shell command, run from the project directory with no network, that exits 0 only when the step works`\nWhy: one sentence\nKeep the same check unless the failure output shows the check itself is wrong (a typo, a wrong path, a test that contradicts the spec); then write the corrected check and say so after Why:. Never `true`, `echo` or a check that passes whatever the code does."')" || true)"
  project_strip_tool_markup <<<"${reply}" | sed -E '/^[[:space:]]*```/d' > "${one}"
  new="$(project_plan_steps "${one}" 2>/dev/null | head -1)"
  if [[ -n "${new}" ]] && [[ -n "$(cut -f4 <<<"${new}")" ]] && ! project_verify_trivial "$(cut -f4 <<<"${new}")"; then
    cp -p "${DIR}/PLAN.md" "${STATE_DIR}/.plan-before-replan"
    awk -v n="${n}" -v t="$(cut -f3 <<<"${new}")" -v v="$(cut -f4 <<<"${new}")" '
      !hit && match($0, /^[[:space:]]*[-*] \[ \] [0-9]+(\.[0-9]+)*\./) {
        s = $0; sub(/^[[:space:]]*[-*] \[ \] /, "", s); match(s, /^[0-9]+(\.[0-9]+)*/)
        if (substr(s, 1, RLENGTH) == n) {
          match($0, /^[[:space:]]*/); ind = substr($0, 1, RLENGTH)
          printf "%s- [ ] %s. %s (re-planned)\n%s  Verify: `%s`\n", ind, n, t, ind, v; hit = 1; skip = 1; next
        }
      }
      skip && /^[[:space:]]*(-[[:space:]]*)?[Vv]erify:/ { skip = 0; next }
      { skip = 0; print }
    ' "${STATE_DIR}/.plan-before-replan" > "${DIR}/PLAN.md"
    if problem="$(project_plan_problem "${DIR}/PLAN.md")"; then
      cat "${STATE_DIR}/.plan-before-replan" > "${DIR}/PLAN.md"
      say "step ${n}: the re-plan was not usable (${problem}); it is tried as it was, once more"
    else
      record_decision "step ${n} re-planned" "Step ${n} (${title}) failed every attempt even split. What now?" \
        "$(cut -f3 <<<"${new}") (Verify: $(cut -f4 <<<"${new}")). $(grep -m1 -i '^why:' "${one}" || true)"
      commit_all "Step ${n} re-planned"
      say "step ${n} re-planned: $(cut -f3 <<<"${new}")"
    fi
  else
    say "step ${n}: no usable re-plan came back; it is tried as it was, once more"
  fi
}

# next_open_step — the first step not done: N<TAB>DONE<TAB>TITLE<TAB>VERIFY.
next_open_step() {
  project_plan_steps "${DIR}/PLAN.md" 2>/dev/null | awk -F'\t' '$2 != "1" { print; found = 1; exit } END { exit !found }'
}

# plan_step_total — how many steps the plan has now (split parts counted, not
# the step they replaced).
plan_step_total() { project_plan_steps "${DIR}/PLAN.md" 2>/dev/null | grep -c . || true; }

# plan_next_number — the number after the plan's last top-level step.
plan_next_number() {
  local last
  last="$(project_plan_steps "${DIR}/PLAN.md" 2>/dev/null | cut -f1 | cut -d. -f1 | sort -n | tail -1)"
  printf '%s' "$(( ${last:-0} + 1 ))"
}

# --- milestones: a large spec is planned one milestone at a time ----------------------
# milestone_phase — when every planned step is done and PLAN.md still has a
# milestone with no steps, a planning turn writes its steps. rc 1 when there is
# no such milestone. The steps before it must come back exactly as they were.
milestone_phase() {
  local ms next before after problem failure="" attempt task
  ms="$(project_plan_pending_milestone "${DIR}/PLAN.md")" || return 1
  next="$(plan_next_number)"
  before="$(project_plan_steps "${DIR}/PLAN.md")"
  for (( attempt = 1; ; attempt++ )); do
    state_set STATUS planning STEP 0 ATTEMPT "${attempt}" TITLE "${ms}"
    say "planning the next milestone: ${ms} (attempt ${attempt})"
    normalize_perms || true
    cp -p "${DIR}/PLAN.md" "${STATE_DIR}/.plan-before-milestone"
    task="$(project_milestone_task "${SBX}" "${ms}" "${next}")"
    [[ -z "${failure}" ]] || task+=$'\n\n'"The previous attempt could not be used: ${failure}"
    phase_begin
    run_turn "${task}" "planning ${ms}" || say "planning ${ms}: ${TURN_FAIL}; checking what it left"
    normalize_perms || true
    keep_plan_only PLAN.md DECISIONS.md
    after="$(project_plan_steps "${DIR}/PLAN.md" 2>/dev/null || true)"
    problem=""
    if [[ "${after:0:${#before}}" != "${before}" ]]; then
      problem="the steps that existed were changed; only add the new milestone's steps"
    elif (( $(grep -c . <<<"${after}") <= $(grep -c . <<<"${before}") )); then
      problem="no steps were added under the milestone"
    elif [[ "$(project_plan_pending_milestone "${DIR}/PLAN.md" || true)" == "${ms}" ]]; then
      problem="the new steps are not under the heading of ${ms}"
    else
      problem="$(project_plan_problem "${DIR}/PLAN.md" || true)"
    fi
    if [[ -z "${problem}" ]]; then
      phase_end milestone 0 "${attempt}" "accepted"
      commit_all "Plan: ${ms}"
      note_progress
      record_decision "milestone planned: ${ms}" "What does this milestone build, step by step?" \
        "$(( $(grep -c . <<<"${after}") - $(grep -c . <<<"${before}") )) steps, from ${next}; see PLAN.md."
      return 0
    fi
    phase_end milestone 0 "${attempt}" "refused"
    cat "${STATE_DIR}/.plan-before-milestone" > "${DIR}/PLAN.md"
    failure="${problem}"
    say "the milestone plan is not usable: ${problem}"
  done
}

# --- the acceptance rounds: done means the whole project passes ---------------------
# acceptance_items — ACCEPTANCE.md, written from the spec's Definition of Done
# by an agent turn (once, and again only if it is not usable). rc 1 when the
# spec has no Definition of Done.
acceptance_items() {
  local items problem n got attempt
  items="$(project_spec_dod_items "${STATE_DIR}/spec.md")" || return 1
  n="$(grep -c . <<<"${items}")"
  for (( attempt = 1; attempt <= 3; attempt++ )); do
    got="$(project_plan_steps "${DIR}/ACCEPTANCE.md" 2>/dev/null | grep -c . || true)"
    if [[ "${got}" == "${n}" ]] && ! problem="$(project_plan_problem "${DIR}/ACCEPTANCE.md")"; then
      git_here add ACCEPTANCE.md && commit_all "Acceptance checks from the spec's Definition of Done"
      return 0
    fi
    [[ ! -e "${DIR}/ACCEPTANCE.md" ]] || say "ACCEPTANCE.md is not usable (${problem:-${got} items for ${n}}); writing it again"
    rm -f "${DIR}/ACCEPTANCE.md"
    say "writing the acceptance checks for the ${n} items of the spec's Definition of Done (attempt ${attempt})"
    normalize_perms || true
    phase_begin
    run_turn "$(project_acceptance_task "${SBX}" "${items}")" "acceptance checks" || say "acceptance checks: ${TURN_FAIL}"
    normalize_perms || true
    keep_plan_only ACCEPTANCE.md DECISIONS.md
    phase_end acceptance-checks 0 "${attempt}" "written"
  done
  say "the Definition of Done could not be turned into checks after 3 attempts"
  return 2
}

# acceptance_phase — every project check, every done step's check again, and
# every item of ACCEPTANCE.md, all run by the runner. All pass: rc 0. Some
# fail: they become fix steps at the end of PLAN.md and rc 1, and the loop
# builds them; after AGENT_PROJECT_ACCEPT_ROUNDS rounds the run ends as
# incomplete, with what still fails in the summary.
# shellcheck disable=SC2016  # the backticks are Markdown, written literally
acceptance_phase() {
  local round name cmd n done_ title check fails="" k=0 next items_rc=0 report
  round=$(( $(state_get ACCEPT_ROUND | grep -E '^[0-9]+$' || echo 0) + 1 ))
  state_set STATUS accepting STEP 0 ATTEMPT "${round}" TITLE "acceptance round ${round}"
  say "acceptance round ${round} of ${AGENT_PROJECT_ACCEPT_ROUNDS}: the full checks, every step's check, the Definition of Done"
  tg_progress "Acceptance round ${round}"
  progress_guard
  acceptance_items || items_rc=$?
  report="${STATE_DIR}/acceptance-round-${round}.md"
  printf '# Acceptance round %s\n\n' "${round}" > "${report}"
  phase_begin
  while IFS=$'\t' read -r name cmd; do
    [[ -n "${name}" ]] || continue
    if verify "${cmd}"; then printf -- '- [x] check %s: `%s`\n' "${name}" "${cmd}" >> "${report}"
    else
      printf -- '- [ ] check %s: `%s`\n```\n%s\n```\n' "${name}" "${cmd}" "$(project_clip "${VERIFY_OUT}" 2000)" >> "${report}"
      fails+="Make the project's ${name} check pass"$'\t'"${cmd}"$'\n'
    fi
  done < <(project_plan_checks "${DIR}/PLAN.md" 2>/dev/null || true)
  while IFS=$'\t' read -r n done_ title check; do
    [[ -n "${n}" && "${done_}" == "1" ]] || continue
    if verify "${check}"; then printf -- '- [x] step %s: %s\n' "${n}" "${title}" >> "${report}"
    else
      printf -- '- [ ] step %s: %s\n```\n%s\n```\n' "${n}" "${title}" "$(project_clip "${VERIFY_OUT}" 2000)" >> "${report}"
      fails+="Fix a regression: step ${n} (${title}) no longer passes its check"$'\t'"${check}"$'\n'
    fi
  done < <(project_plan_steps "${DIR}/PLAN.md" 2>/dev/null || true)
  if (( items_rc == 2 )); then
    printf -- '- [ ] the Definition of Done could not be turned into checks\n' >> "${report}"
  elif (( items_rc == 0 )); then
    sed 's/\[[xX]\]/[ ]/' "${DIR}/ACCEPTANCE.md" > "${STATE_DIR}/.acceptance"
    while IFS=$'\t' read -r n done_ title check; do
      [[ -n "${n}" ]] || continue
      if verify "${check}"; then
        printf -- '- [x] done when: %s\n' "${title}" >> "${report}"
        project_plan_mark_done "${STATE_DIR}/.acceptance" "${n}" >/dev/null 2>&1 || true
      else
        printf -- '- [ ] done when: %s\n```\n%s\n```\n' "${title}" "$(project_clip "${VERIFY_OUT}" 2000)" >> "${report}"
        fails+="Meet the Definition of Done: ${title}"$'\t'"${check}"$'\n'
      fi
    done < <(sed 's/\[[xX]\]/[ ]/' "${DIR}/ACCEPTANCE.md" | project_plan_steps /dev/stdin 2>/dev/null || true)
    cat "${STATE_DIR}/.acceptance" > "${DIR}/ACCEPTANCE.md"
  fi
  phase_end acceptance 0 "${round}" "$(grep -c . <<<"${fails}" || true) failing"
  state_set ACCEPT_ROUND "${round}"
  if [[ -z "${fails}" && "${items_rc}" != "2" ]]; then
    commit_all "Acceptance round ${round}: everything passes"
    note_progress
    say "acceptance round ${round}: every check passes"
    return 0
  fi
  [[ -n "${fails}" ]] || fails="Write ACCEPTANCE.md: one check for each item of the spec's Definition of Done"$'\t'"test -s ACCEPTANCE.md"$'\n'
  if (( round >= AGENT_PROJECT_ACCEPT_ROUNDS )); then
    commit_all "Acceptance round ${round}: still failing" || true
    state_set UNMET "$(cut -f1 <<<"${fails}" | head -20 | paste -sd ';' -)"
    stop_for_human incomplete "after ${round} acceptance rounds, $(grep -c . <<<"${fails}") checks still fail (see .lca-project/acceptance-round-${round}.md)"
  fi
  # The failures become steps, at most ten a round; the next round sees the rest.
  next="$(plan_next_number)"
  {
    printf '\n## Acceptance round %s: fixes\n\n' "${round}"
    while IFS=$'\t' read -r title check; do
      [[ -n "${title}" ]] || continue
      (( k < 10 )) || break
      printf -- '- [ ] %s. %s\n  Verify: `%s`\n' "$(( next + k ))" "${title}" "${check}"
      k=$(( k + 1 ))
    done <<<"${fails}"
  } >> "${DIR}/PLAN.md"
  commit_all "Acceptance round ${round}: ${k} fix steps"
  record_decision "acceptance round ${round}" "What still fails when the whole project is checked?" \
    "$(grep . <<<"${fails}" | cut -f1 | head -10 | sed 's/^/- /')"$'\n\n'"Added as steps ${next} to $(( next + k - 1 )) of PLAN.md."
  say "acceptance round ${round}: ${k} fix steps added to the plan"
  tg_event "🔎 acceptance round ${round}: ${k} things to fix"
  return 1
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
    local ck=0
    after_step_checks || ck=$?
    if (( ck == 1 )); then
      phase_end fix "${n}" 1 "stopped"
      stop_for_human waiting "step ${n} review fixes: ${CHECK_FAIL} — look before resuming"
    fi
    if (( ck == 0 )) && verify_step "${check}"; then
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
  [[ "${status}" == "failed" ]] && failed_line="- Failed: step $(state_get STEP) ($(state_get TITLE)): re-planning made no progress"
  {
    printf '# Project summary\n\n'
    printf -- '- Directory: %s\n- Status: %s%s\n' "${DIR}" "${status}" "$( [[ -n "$(state_get REASON)" ]] && printf ' (%s)' "$(state_get REASON)")"
    printf -- '- Steps done: %s of %s\n' "${done_:-0}" "${total:-0}"
    [[ -z "${failed_line}" ]] || printf '%s\n' "${failed_line}"
    printf -- '- Decisions recorded in DECISIONS.md: %s\n' "${decisions:-0}"
    printf -- '- Running time: %s h (limit %s days); acceptance rounds: %s of %s\n' \
      "$(awk -v s="$(active_seconds)" 'BEGIN { printf "%.1f", s / 3600 }')" "${AGENT_PROJECT_MAX_DAYS}" \
      "$(state_get ACCEPT_ROUND | grep . || echo 0)" "${AGENT_PROJECT_ACCEPT_ROUNDS}"
    [[ -z "$(state_get CHECKS_ON)" ]] || printf -- '- Project checks on: %s\n' "$(state_get CHECKS_ON)"
    [[ "${status}" != "incomplete" ]] || printf -- '- Still failing: %s\n' "$(state_get UNMET)"
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
    [[ ! -f "${DIR}/ACCEPTANCE.md" ]] || printf -- '- ACCEPTANCE.md: the Definition of Done, each item with the check that proves it\n'
    ls "${STATE_DIR}"/acceptance-round-*.md >/dev/null 2>&1 \
      && printf -- '- Each acceptance round: %s/acceptance-round-*.md\n' "${STATE_DIR}"
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
  local status line n title check
  [[ -r "${STATE_FILE}" ]] || die "No project at ${DIR} (no ${STATE_FILE}). Start one: lca agent project SPEC --dir ${DIR}"
  status="$(state_get STATUS)"
  case "${status}" in
    done|failed|waiting|stopped|stalled|limit|incomplete) queue_remove "${DIR}"; say "nothing to do: the project is ${status}"; exit 0 ;;
  esac
  # Time the machine was off or the runner down (the log was not written) is
  # not time without progress: the stall clock is moved on by that much.
  local alive gap last
  alive="$(stat -c %Y "${STATE_DIR}/run.log" 2>/dev/null || date +%s)"
  gap=$(( $(date +%s) - alive ))
  last="$(state_get LAST_PROGRESS)"
  if (( gap > 600 )) && [[ "${last}" =~ ^[0-9]+$ ]]; then state_set LAST_PROGRESS "$(( last + gap ))"; fi
  queue_wait
  printf '%s\n' "${DIR}" > "${PROJECT_POINTER_FILE}" 2>/dev/null || true
  RUN_T0="$(date +%s)"
  trap 'account_active' EXIT
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
  progress_guard
  plan_phase
  resume_review
  # The plan is read again after every step: a step that failed may have
  # been split, a milestone planned, an acceptance round added fixes.
  while :; do
    if line="$(next_open_step)"; then
      IFS=$'\t' read -r n _ title check <<<"${line}"
      step_phase "${n}" "$(plan_step_total)" "${title}" "${check}" </dev/null
      continue
    fi
    milestone_phase </dev/null && continue
    acceptance_phase </dev/null && break
  done
  state_set STATUS "done" STEP "$(plan_step_total)" REASON ""
  say "all $(plan_step_total) steps done, and the acceptance checks pass"
  retire_unit
  write_summary
  tg_progress "Finished"
  tg_event "🏁 finished. $(tg_summary)"
}

# --- one project at a time: a queue, and one lock --------------------------------------
# Every runner takes its place in the queue file and waits until it is first
# among the projects still waiting AND holds the lock; then it is the one
# running. The lock is a file descriptor, so a runner that dies (a reboot, a
# kill) releases it with nothing to clean up, and a project whose runner is
# gone, or that ended, drops out of the queue when the next one looks.
PROJECT_QUEUE_DIR="${HOME}/.lca-projects"
queue_edit() {   # AWK_PROGRAM [VAR=VALUE...] — rewrite the queue file under its own lock
  local prog="$1" q="${PROJECT_QUEUE_DIR}/queue"
  shift
  mkdir -p "${PROJECT_QUEUE_DIR}"
  (
    flock 8
    touch "${q}"
    awk "$@" "${prog}" "${q}" > "${q}.tmp" && mv -f "${q}.tmp" "${q}"
  ) 8>"${PROJECT_QUEUE_DIR}/queue.lock"
}
# shellcheck disable=SC2016  # awk programs: $0 is awk's
queue_add()    { queue_edit '$0 == d { seen = 1 } { print } END { if (!seen) print d }' -v d="$1"; }
# shellcheck disable=SC2016  # awk programs: $0 is awk's
queue_remove() { queue_edit '$0 != d' -v d="$1" 2>/dev/null || true; }
# queue_head — the first project in the queue that is still waiting to run.
queue_head() {
  local d st
  while IFS= read -r d; do
    [[ -n "${d}" ]] || continue
    st="$(sed -n 's/^STATUS=//p' "${d}/.lca-project/state" 2>/dev/null | tail -1)"
    case "${st}" in queued|planning|running|accepting) printf '%s' "${d}"; return 0 ;; esac
  done < "${PROJECT_QUEUE_DIR}/queue" 2>/dev/null
  return 1
}
# queue_running — the project that holds the lock now, or nothing when none
# does (a lock nobody holds can be taken; the probe lets it go at once).
queue_running() {
  local f="${PROJECT_QUEUE_DIR}/run.lock"
  [[ -e "${f}" ]] || return 0
  flock -n "${f}" true 2>/dev/null && return 0
  head -1 "${PROJECT_QUEUE_DIR}/running" 2>/dev/null || true
}
# queue_position DIR — 1 for the first waiting project; nothing when not queued.
queue_position() {
  awk -v d="$1" '$0 == d { print NR; exit }' "${PROJECT_QUEUE_DIR}/queue" 2>/dev/null
}
queue_wait() {
  local before head said=false
  queue_add "${DIR}"
  mkdir -p "${PROJECT_QUEUE_DIR}"
  exec {RUN_LOCK_FD}>"${PROJECT_QUEUE_DIR}/run.lock"
  before="$(state_get STATUS)"
  while :; do
    head="$(queue_head || true)"
    if [[ -z "${head}" || "${head}" == "${DIR}" ]] && flock -n "${RUN_LOCK_FD}"; then break; fi
    # The queue's head may be a project whose runner is not running at all
    # (stopped from outside, its unit gone): it holds no lock, so it is
    # skipped when the lock is free and it has not taken it for a minute.
    if [[ -n "${head}" && "${head}" != "${DIR}" ]] && flock -n "${RUN_LOCK_FD}"; then
      sleep 60
      if [[ "$(queue_head || true)" == "${head}" ]]; then
        say "the queue's first project (${head}) is not running; going ahead of it"
        break
      fi
      flock -u "${RUN_LOCK_FD}"
      continue
    fi
    if [[ "${said}" != "true" ]]; then
      state_set STATUS queued
      say "queued: another project is running ($(queue_running | grep . || echo unknown)); waiting for it"
      said=true
    fi
    sleep 30
  done
  queue_remove "${DIR}"
  printf '%s\n' "${DIR}" > "${PROJECT_QUEUE_DIR}/running"
  if [[ "${said}" == "true" ]]; then
    # Waiting is not standing still: the stall clock starts when the work does.
    state_set STATUS "${before/queued/running}"
    note_progress
    say "our turn: starting"
  fi
}

unit_instance() { printf 'local-code-agent-project@%s.service' "$(systemd-escape --path "${DIR}")"; }

# user_units — the runner is a systemd USER unit of the project's owner: no
# root to start, stop or resume a project, and it still starts at boot, since
# lingering is on (loginctl enable-linger, done once by setup). Without
# lingering it is a system unit, as before, installed with sudo.
user_units() {
  [[ "$(id -u)" != "0" ]] || return 1
  [[ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" == "yes" ]] || return 1
  systemctl --user show-environment >/dev/null 2>&1
}
# retire_unit — a run that has ended (done, or stopped for any reason) no
# longer starts at boot: its user unit is disabled from inside, which needs no
# root ('--resume' enables it again). A system unit stays as it is: disabling
# that needs root, and it only exits at boot with "nothing to do".
retire_unit() {
  user_units 2>/dev/null || return 0
  uctl disable "$(unit_instance)" >/dev/null 2>&1 || true
}
user_unit_file() { printf '%s/systemd/user/local-code-agent-project@.service' "${XDG_CONFIG_HOME:-${HOME}/.config}"; }
uctl() { systemctl --user "$@"; }

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

install_user_unit() {
  local f
  f="$(user_unit_file)"
  mkdir -p "$(dirname "${f}")"
  cat > "${f}.tmp" <<EOF
# Managed by local-code-agent (scripts/agent-project.sh). One instance per
# project directory, run as you; it resumes at boot (lingering is on) until the
# project is done or stopped. One project runs at a time; the others queue.
[Unit]
Description=local-code-agent project mode in %f

[Service]
Type=simple
ExecStart=${SCRIPT_DIR}/agent-project.sh --run --dir %f
Restart=on-failure
RestartSec=60

[Install]
WantedBy=default.target
EOF
  mv -f "${f}.tmp" "${f}"
  uctl daemon-reload || die "systemctl --user daemon-reload failed."
}

start_runner() {
  if [[ "${FOREGROUND}" == "true" ]]; then
    cmd_run
    return
  fi
  if user_units; then
    install_user_unit
    uctl enable "$(unit_instance)" >/dev/null 2>&1 || die "Could not enable $(unit_instance)."
    uctl restart "$(unit_instance)" >/dev/null 2>&1 \
      || die "Could not start $(unit_instance). Look at: journalctl --user -u '$(unit_instance)'"
    ok "Running as your own systemd service $(unit_instance): it does not need this session, and it resumes after a reboot."
    local other
    other="$(queue_running)"
    [[ -z "${other}" || "${other}" == "${DIR}" ]] || info "Another project is running (${other}): this one queues behind it."
    info "Where it is: lca agent project --dir ${DIR} --status"
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
  state_set STATUS planning AUTONOMY "${AUTONOMY}" ENGINE "${ENGINE}" STEP 0 ATTEMPT 0 STARTED "$(date -u +%FT%TZ)" SPEC "$(realpath "${SPEC}")" \
    LAST_PROGRESS "$(date +%s)" ACTIVE_SECONDS 0
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
  # Back to the step it was on; a failed step gets a fresh set of attempts,
  # the stall clock starts again, and a project stopped at its day limit gets
  # a new one: resuming is the owner's decision to go on.
  [[ "$(state_get STATUS)" != "limit" ]] || state_set ACTIVE_SECONDS 0
  if [[ "$(state_get STATUS)" == "incomplete" ]]; then state_set ACCEPT_ROUND 0; fi
  state_set LAST_PROGRESS "$(date +%s)"
  if [[ "$(state_get STEP)" == "0" && "$(state_get PLAN_ACCEPTED)" != "1" ]]; then state_set STATUS planning REASON "" QUESTION ""
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
    printf 'Service:  %s (%s)\n' "$(unit_instance)" "$(runner_state)"
  fi
  [[ -z "$(queue_position "${DIR}")" ]] || printf 'Queue:    number %s; running now: %s\n' "$(queue_position "${DIR}")" "$(queue_running | grep . || echo nothing)"
  steps="$(project_plan_steps "${DIR}/PLAN.md" 2>/dev/null || true)"
  if [[ -n "${steps}" ]]; then
    printf '\nPlan:\n'
    awk -F'\t' '{ printf "  [%s] %s. %s\n", ($2 == 1 ? "x" : " "), $1, $3 }' <<<"${steps}"
  fi
  printf '\nLast log lines (%s/run.log):\n' "${STATE_DIR}"
  tail -n 8 "${STATE_DIR}/run.log" 2>/dev/null | sed 's/^/  /' || true
}

# runner_state — active, activating, inactive, failed: the user unit's state
# when there is one, else the system unit's.
runner_state() {
  local st
  st="$(uctl is-active "$(unit_instance)" 2>/dev/null || true)"
  if [[ -z "${st}" || "${st}" == "inactive" ]] && systemctl cat "$(unit_instance)" >/dev/null 2>&1; then
    st="$(systemctl is-active "$(unit_instance)" 2>/dev/null || true)"
  fi
  printf '%s' "${st:-inactive}"
}

# cmd_json — the state, the plan's progress, the queue and which files exist,
# as one JSON object: what the dashboard shows. Read-only; the plan is read by
# project_plan_steps, the same parser the runner uses.
cmd_json() {
  [[ -r "${STATE_FILE}" ]] || die "No project at ${DIR}."
  local steps f files=() started elapsed=0
  steps="$(project_plan_steps "${DIR}/PLAN.md" 2>/dev/null || true)"
  for f in SUMMARY:"${STATE_DIR}/SUMMARY.md" DECISIONS:"${DIR}/DECISIONS.md" \
           REVIEW:"${DIR}/REVIEW.md" PLAN:"${DIR}/PLAN.md" ACCEPTANCE:"${DIR}/ACCEPTANCE.md"; do
    [[ -s "${f#*:}" ]] && files+=("${f%%:*}")
  done
  started="$(date -d "$(state_get STARTED)" +%s 2>/dev/null || true)"
  [[ -z "${started}" ]] || elapsed=$(( $(date +%s) - started ))
  jq -n --arg dir "${DIR}" --arg status "$(state_get STATUS)" --arg reason "$(state_get REASON)" \
    --arg question "$(state_get QUESTION)" --arg step "$(state_get STEP)" --arg attempt "$(state_get ATTEMPT)" \
    --arg title "$(state_get TITLE)" --arg autonomy "$(state_get AUTONOMY)" --arg engine "$(state_get ENGINE)" \
    --arg started "$(state_get STARTED)" --arg updated "$(state_get UPDATED)" --arg elapsed "${elapsed}" \
    --arg active "$(state_get ACTIVE_SECONDS)" --arg round "$(state_get ACCEPT_ROUND)" --arg checks "$(state_get CHECKS_ON)" \
    --arg queue "$(queue_position "${DIR}")" --arg runner "$(runner_state)" \
    --arg last "$(tail -n 1 "${STATE_DIR}/run.log" 2>/dev/null || true)" \
    --arg steps "${steps}" --arg files "${files[*]+${files[*]}}" '
    ($steps | split("\n") | map(select(length > 0) | split("\t")
      | {n: .[0], done: (.[1] == "1"), title: .[2]})) as $plan
    | {dir: $dir, name: ($dir | split("/") | last), status: $status, reason: $reason, question: $question,
       step: $step, attempt: $attempt, title: $title, autonomy: $autonomy, engine: $engine,
       started: $started, updated: $updated, elapsed_seconds: ($elapsed | tonumber? // 0),
       active_seconds: ($active | tonumber? // 0), acceptance_round: ($round | tonumber? // 0),
       checks_on: ($checks | split(" ") | map(select(length > 0))), queue_position: ($queue | tonumber? // null),
       runner: $runner, last_log: $last,
       done: ($plan | map(select(.done)) | length), total: ($plan | length),
       steps: $plan, files: ($files | split(" ") | map(select(length > 0) | ascii_downcase))}'
}

cmd_stop() {
  [[ -r "${STATE_FILE}" ]] || die "No project at ${DIR}."
  if user_units && uctl cat "$(unit_instance)" >/dev/null 2>&1; then
    uctl disable --now "$(unit_instance)" >/dev/null 2>&1 || true
  fi
  if systemd_available && systemctl cat "$(unit_instance)" >/dev/null 2>&1 \
     && { systemctl is-enabled --quiet "$(unit_instance)" 2>/dev/null || systemctl is-active --quiet "$(unit_instance)" 2>/dev/null; }; then
    announce_possible_prompt "Stopping the project runner"
    as_root systemctl disable --now "$(unit_instance)" >/dev/null 2>&1 || true
  fi
  queue_remove "${DIR}"
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
      --json)       ACTION=json; shift ;;
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
    json)   cmd_json ;;
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
