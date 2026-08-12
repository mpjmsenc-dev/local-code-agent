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
# SERIALISED, because the set difference is only sound while nothing else is
# creating conversations. Two 'lca agent task' runs overlapping — two terminals,
# or a script — would each see the other's conversation as "new", and each could
# record the other's id. The lock makes that case impossible for this command
# against itself, which is the case a user can actually hit twice by accident.
#
# It does NOT cover a conversation started from the web UI at the same moment;
# nothing here can, because the app offers no way to ask "which conversation did
# MY post create" — the POST answers with a start-task id the events API does
# not know. That residual case is handled below by refusing to guess.
#
# Released before the exec into agent-watch.sh, or a --watch run would hold it
# for hours.
LOCK_FILE="${TMPDIR:-/tmp}/lca-agent-task.lock"
if exec 9>"${LOCK_FILE}" 2>/dev/null && have flock; then
  flock 9 2>/dev/null || true
fi

BEFORE="$(agent_conversation_ids "$(agent_conversations_payload || true)" 2>/dev/null || true)"

step "Submitting the task"
info "Working directory: ${DIR}"
BODY="$(jq -nc --arg t "${PROMPT}" --arg s "${SUFFIX}" \
        '{initial_message:{role:"user",content:[{type:"text",text:$t}]},
          agent:{system_message_suffix:$s}}')"
curl -fsS --max-time 120 -X POST "${BASE}/api/v1/app-conversations" \
     -H 'Content-Type: application/json' -d "${BODY}" >/dev/null 2>&1 \
  || die "The agent refused the task at ${BASE}/api/v1/app-conversations. Its own log will say why: lca agent logs"

# --- identify it -------------------------------------------------------------
# Polled rather than assumed: the conversation appears in the listing some time
# after the POST returns — and "a moment" was wrong by a factor of two.
#
# MEASURED, twice, on this box. The POST answers as soon as the task is
# accepted; the app then provisions a sandbox container before the conversation
# is visible in the listing at all:
#
#   run 1  submitted 18:30:22   conversation created 18:31:19   lag 57s
#   run 2  submitted 19:01:35   conversation created 19:02:18   lag 43s
#
# The loop below was ten tries of two seconds — a window of about 25 seconds,
# which is not half the shortest lag observed. So it never once succeeded: both
# live runs printed "its conversation id could not be identified" and fell back
# to the newest-sandbox guess, which is the exact inference this whole
# mechanism exists to avoid. Replaying the same set-difference by hand against
# the same API a minute later identifies the conversation correctly every time;
# nothing was wrong with the method, only with how long it was given.
#
# Three minutes, because the lag is sandbox creation and that is bounded by an
# image pull on a cold box, not by anything this script controls. It costs
# nothing when identification succeeds on the first pass, which is the common
# case once a sandbox image is local.
CID=""
AMBIGUOUS=false
# 90 tries of two seconds, not ten. The count is the whole difference between a
# mechanism that works and one that has never once succeeded: the conversation
# does not reach the listing until the app has built a sandbox for it, which was
# 57s and 43s on the two live runs measured here, against a window of about 25.
# Both runs therefore fell back to the newest-sandbox guess this exists to
# replace, and neither failure was the set difference's fault — replayed by hand
# a minute later it names the right conversation every time.
for attempt in $(seq 1 90); do
  AFTER="$(agent_conversation_ids "$(agent_conversations_payload || true)" 2>/dev/null || true)"
  RC=0
  CID="$(agent_new_conversation "${BEFORE}" "${AFTER}")" || RC=$?
  if (( RC == 0 )) && [[ -n "${CID}" ]]; then
    break
  fi
  CID=""
  # rc 2 is "more than one appeared", and polling again cannot unmake that —
  # both are real conversations now. Stop and say so rather than waiting out
  # nine more rounds to give the same non-answer.
  if (( RC == 2 )); then
    AMBIGUOUS=true
    break
  fi
  # Said once, when the wait stops looking instant. The lag is sandbox
  # creation — up to a minute here, longer on a box pulling the image.
  (( attempt == 5 )) && info "Waiting for the app to register the conversation (it is creating a sandbox first)..."
  sleep 2
done

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
# Before any exec below, so a --watch run does not hold the submit lock for the
# length of the run.
exec 9>&- 2>/dev/null || true

info "Follow it: lca agent watch      ·      see what it did: lca agent logs"
if [[ "${WATCH}" == "true" ]]; then
  exec "${SCRIPT_DIR}/agent-watch.sh"
fi
