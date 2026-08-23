#!/usr/bin/env bash
# scripts/agent-task.sh — this project's own way to give the agent a task.
#
# WHY IT EXISTS, and it is one measurement. Two droplet runs at the 3b rung
# wrote their deliverable to /workspace — the sandbox root — while working in a
# repo at /workspace/project/<name>, so the work landed nowhere useful. The
# selftest, whose task text names the absolute path, puts its file in the right
# place every single run. Naming the directory is what works, and nothing
# submitted through the OpenHands web UI gets it named.
#
# This is the path where it can be. Everything that made those runs fail is
# handled here rather than hoped for:
#
#   the directory   stated in the prompt (the suffix is sent too and does not
#                   arrive — the app overwrites it; see the note at SUFFIX)
#   verification    the "run what you built" rule travels with the task
#   the id          returned, so watching is a lookup and not a guess
#   preconditions   checked BEFORE submitting, so a task never goes into a
#                   stack that cannot run it
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_env

# The sandbox path the agent's repo is mounted under. Not a guess: it is where
# the selftest's file lands and where the failing runs SHOULD have written.
AGENT_TASK_DIR_DEFAULT="${AGENT_TASK_DIR_DEFAULT:-/workspace/project}"

usage() {
  cat <<EOF
Usage: lca agent task [--dir PATH] [--watch] "what to do"

Submits a task the way this project has evidence works: with the working
directory named explicitly, in the prompt and in the agent's system message.

  --dir PATH   absolute path inside the sandbox to work in
               (default: ${AGENT_TASK_DIR_DEFAULT})
  --watch      supervise the run afterwards, attached to THIS conversation

It prints the conversation id. 'lca agent watch' picks it up automatically —
it no longer has to guess which run you meant.

Why the directory has to be said out loud, with the runs that proved it:
docs/AGENT.md
EOF
}

TASK=""
DIR="${AGENT_TASK_DIR_DEFAULT}"
WATCH=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)     DIR="${2:-}"; shift 2 || die "--dir needs a path" ;;
    --watch)   WATCH=true; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)        ARG="$1"; usage >&2; die "Unknown option: ${ARG}" ;;
    *)         TASK="$1"; shift ;;
  esac
done

[[ -n "${TASK}" ]] || { usage >&2; die "No task given. Put it in quotes: lca agent task \"add a --json flag to the CLI\""; }
# Absolute, because a relative path is the whole bug. '/workspace' relative to
# nothing is exactly where the failing runs put their files.
[[ "${DIR}" == /* ]] || die "--dir must be an absolute path inside the sandbox (got '${DIR}'). The repo is normally under ${AGENT_TASK_DIR_DEFAULT}."

# --- preconditions, before anything is submitted -----------------------------
# A task posted into a broken stack is the worst outcome available: it looks
# accepted, it runs for half an hour, and it produces nothing. Each of these
# names its own remedy and none of them guesses.
require_cmd curl
have jq || die "jq is needed to submit a task and read the reply. Install it: sudo apt-get install -y jq"
[[ "${ENABLE_AGENT}" == "true" ]] \
  || die "The agent tier is off (ENABLE_AGENT=false). Bring it up: lca agent setup"
agent_container_running \
  || die "The agent container is not running. Bring it up: lca agent setup"

BASE="$(agent_api_base)"
curl -fsS --max-time 10 -o /dev/null "${BASE}/" 2>/dev/null \
  || die "The agent is not answering at ${BASE}. It may still be unpacking — watch it: lca agent logs"

# The settings must hold the model this task will actually be run with. A
# container whose settings hold the BASE model runs at the server-wide context
# instead of the agent's window, which is stop 5 of the six in docs/AGENT.md.
WANT_MODEL="$(agent_llm_model "$(agent_model_for_run)")"
GOT_MODEL="$(curl -fsS --max-time 10 "${BASE}/api/v1/settings" 2>/dev/null \
             | jq -r '.agent_settings.llm.model // empty' 2>/dev/null || true)"
[[ "${GOT_MODEL}" == "${WANT_MODEL}" ]] \
  || die "The agent holds model '${GOT_MODEL:-none}', not '${WANT_MODEL}', so this task would run against the wrong model or none at all. Fix it: lca agent restart"

# ...and the setting this project calls more decisive than the model.
#
# The selftest has checked this for months and this path never did, which is the
# wrong way round: the selftest costs a quarter of an hour and you run it on
# purpose, while THIS is where a real twenty-minute task goes in. With
# native_tool_calling stored as true, qwen2.5-coder writes its tool call into
# the message body, ollama reports zero tool calls, and OpenHands reads that as
# "the assistant has finished" — the run ends at once with an empty workspace
# and no error anywhere. Measured at 3b and 7b, so a bigger model is not the fix.
#
# Same shape as everything else fixed this week: a precondition list that
# checked the cheap half. Refusing to submit costs a second; not refusing costs
# the task and tells you nothing about why.
GOT_NATIVE="$(agent_stored_native_tool_calling \
              "$(curl -fsS --max-time 10 "${BASE}/api/v1/settings" 2>/dev/null || true)")"
[[ "${GOT_NATIVE}" == "${AGENT_NATIVE_TOOL_CALLING}" ]] \
  || die "The agent holds native_tool_calling='${GOT_NATIVE:-unset}', not '${AGENT_NATIVE_TOOL_CALLING}'. With qwen2.5-coder that is the difference between a run that works and one that ends instantly with an empty workspace and no error at all — this task would be accepted and produce nothing. Fix it: ${REPO_ROOT}/bin/lca agent restart"

# --- the prompt --------------------------------------------------------------
# One channel, not two, and this is it. The directory goes in the PROMPT TEXT
# because that is the part the model demonstrably reads — the selftest's task
# names a path and the file lands there, and on the first live run through this
# command the file landed under the named directory with nothing written above
# it. The suffix below was meant to be the second statement of the same rule and
# never arrives at all (see the note at SUFFIX), so this text is carrying it
# alone.
PROMPT="$(agent_task_prompt "${DIR}" "${TASK}")"

# The two rules from config/CONVENTIONS.md, on the channel OpenHands documents
# for standing instructions.
#
# SETTLED, and the answer is no: this build does not use it. Measured on the
# first live run, by reading what the agent actually ran with rather than what
# the API accepted:
#
#   SystemPromptEvent      14,640 chars, neither rule present
#   base_state.json        "system_message_suffix":
#                            "<HOST>\nhttp://host.docker.internal:3001</HOST>"
#
# The app does not merely ignore the field — it OVERWRITES it with its own
# value, which it needs for the sandbox's host address. So a caller cannot use
# system_message_suffix on this build at all, and the earlier "unverified"
# note was too generous: it is not unverified now, it is unavailable.
#
# It is still sent. It costs one JSON field, it is correct on any build that
# does honour it, and the alternative — dropping it — would leave nothing to
# re-test when OpenHands is upgraded. What has been dropped is the CLAIM: the
# two rules have exactly one home that works, the prompt text, and everything
# in this repo that implied two has been corrected to say so.
SUFFIX="$(agent_task_suffix)"

# --- submit ------------------------------------------------------------------
# The conversations that exist BEFORE we submit, so ours can be identified by
# difference rather than by being newest. The POST's own id is not usable: it
# answers with a start-task id the events API knows nothing about (measured).
# NOT serialised, deliberately, and it was for one commit. An flock around this
# section would let two runs of this command take turns instead of both seeing
# the other's conversation as new — but holding a lock across the submit needs a
# command-less 'exec 9>FILE', and this suite forbids that for a good reason: a
# command-less exec with a redirection applies to the SHELL, so the obvious
# spelling also sends every later warning to /dev/null. The subshell idiom that
# avoids exec cannot work here either, because the id has to outlive the lock.
#
# Nothing is lost in correctness. Two conversations appearing at once is already
# refused rather than guessed at (agent_new_conversation, rc 2), so the worst
# outcome of a collision is that neither run records an id and both say so. What
# a lock would have added is convenience — the second run waiting a moment and
# then succeeding — and that is not worth either weakening a gate or silencing
# this script's own error output.
BEFORE="$(agent_conversation_ids "$(agent_conversations_payload || true)" 2>/dev/null || true)"

step "Submitting the task"
info "Working directory: ${DIR}"
BODY="$(jq -nc --arg t "${PROMPT}" --arg s "${SUFFIX}" \
        '{initial_message:{role:"user",content:[{type:"text",text:$t}]},
          agent:{system_message_suffix:$s}}')"
# The reply is READ, not discarded. This POST does not return a conversation --
# it returns a START-TASK, and the conversation is created afterwards, in the
# background, by a path that can and does fail. Throwing the reply away with
# >/dev/null is what made a failed submit indistinguishable from a slow one.
RESPONSE="$(curl -fsS --max-time 120 -X POST "${BASE}/api/v1/app-conversations" \
     -H 'Content-Type: application/json' -d "${BODY}" 2>/dev/null)" \
  || die "The agent refused the task at ${BASE}/api/v1/app-conversations. Its own log will say why: lca agent logs"

TASK_ID="$(agent_start_task_id "${RESPONSE}" 2>/dev/null || true)"

# --- identify it -------------------------------------------------------------
# Two ways, and the first one is not a guess. The app publishes the outcome of
# every submission at /api/v1/app-conversations/start-tasks, keyed by the id the
# POST just returned: READY with the conversation it made, or ERROR with the
# reason there is none. Asking it directly replaces both the set difference and
# the three minutes of waiting that the set difference needed.
#
# WHY THIS EXISTS. Measured on this box, against the app's own record: 5 of 23
# submissions ended ERROR -- 21.7%, on 08-12 (three), 08-17 and 08-22 -- every
# one of them a sandbox whose agent-server answered a second or two after the
# app stopped waiting. All five were reported to the user as a task that WAS
# submitted whose conversation "could not be identified", with exit status 0,
# and all five left their sandbox container running. A submission that produces
# nothing must not look like a submission that worked.
CID=""
AMBIGUOUS=false
FAILED=""

if [[ -n "${TASK_ID}" ]]; then
  for attempt in $(seq 1 90); do
    STATE="$(agent_start_task_state "${TASK_ID}" 2>/dev/null || true)"
    STATUS="$(printf '%s' "${STATE}" | cut -f1)"
    case "${STATUS}" in
      READY)
        CID="$(printf '%s' "${STATE}" | cut -f2)"
        [[ -n "${CID}" ]] && break
        ;;
      ERROR)
        FAILED="$(printf '%s' "${STATE}" | cut -f3)"
        break
        ;;
    esac
    (( attempt == 5 )) && info "Waiting for the app to build a sandbox for this task..."
    sleep 2
  done
else
  # Fallback, for a reply this cannot parse -- jq missing, or an OpenHands that
  # answers some other shape. The old set difference, unchanged, including its
  # rc 2 "two appeared at once" refusal.
  for attempt in $(seq 1 90); do
    AFTER="$(agent_conversation_ids "$(agent_conversations_payload || true)" 2>/dev/null || true)"
    RC=0
    CID="$(agent_new_conversation "${BEFORE}" "${AFTER}")" || RC=$?
    if (( RC == 0 )) && [[ -n "${CID}" ]]; then
      break
    fi
    CID=""
    if (( RC == 2 )); then
      AMBIGUOUS=true
      break
    fi
    (( attempt == 5 )) && info "Waiting for the app to register the conversation (it is creating a sandbox first)..."
    sleep 2
  done
fi

# The loud failure. This is the branch that used to be a warning and an exit 0.
if [[ -n "${FAILED}" ]]; then
  SANDBOX="$(printf '%s' "${FAILED}" | grep -oE 'oh-agent-server-[A-Za-z0-9]+' || true)"
  if [[ -n "${SANDBOX}" ]]; then
    warn "The sandbox it gave up on is still running: ${SANDBOX}. Stop it: docker stop ${SANDBOX}"
  fi
  die "Your task was NOT submitted. The app failed to start a conversation for it, and said why:

  ${FAILED}

Nothing is running it and nothing will. This is almost always the sandbox
answering later than the app was willing to wait -- OpenHands allows 15 seconds
by default and this box has needed 17. Raise the margin and try again:

  AGENT_SANDBOX_GRACE_SECONDS=120   in ${ENV_FILE}
  ${REPO_ROOT}/bin/lca agent restart"
fi


if [[ -n "${CID}" ]]; then
  agent_conversation_record "${CID}" \
    || warn "Could not record the conversation id at ${AGENT_CONVERSATION_FILE}; 'lca agent watch' will fall back to picking the newest sandbox."
  ok "Conversation ${CID}"
elif [[ "${AMBIGUOUS}" == "true" ]]; then
  # The one case where guessing would be worse than admitting it. Two
  # conversations appeared between the snapshot and the poll, so one of them is
  # this task and the other is not, and nothing in the listing says which.
  warn "Your task was submitted and is running — but another conversation started at the same moment, so this cannot tell which of them is yours. Nothing was recorded, deliberately: picking one would be a coin toss, and a watcher on the wrong run reports somebody else's progress as yours. Stop the other run, or read this one directly: lca agent logs"
else
  # Said plainly rather than left as a silent degradation: the task IS running,
  # and only the identification failed.
  warn "The task was submitted but its conversation id could not be identified, so 'lca agent watch' will fall back to picking the newest sandbox. If more than one run is alive, it may attach to the wrong one."
fi

info "Follow it: lca agent watch      ·      see what it did: lca agent logs"
if [[ "${WATCH}" == "true" ]]; then
  exec "${SCRIPT_DIR}/agent-watch.sh"
fi
