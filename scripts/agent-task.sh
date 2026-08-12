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
#   the directory   stated in the prompt AND in the system message suffix
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
# Belt and braces, deliberately. The directory goes in the PROMPT TEXT because
# that is the part the model demonstrably reads — the selftest's task names a
# path and the file lands there — and into the system message suffix below
# because that is the documented place for standing instructions. Neither alone
# is trusted: the model ignored the working directory it was actually given.
PROMPT="$(agent_task_prompt "${DIR}" "${TASK}")"

# The two rules from config/CONVENTIONS.md, on the channel OpenHands documents
# for standing instructions.
#
# HONEST STATUS: unverified on this build. agent_settings.tools round-trips
# through the settings API and is then ignored — 22 tools still load — so a
# field being accepted here proves nothing about it being used. That is exactly
# why the same two rules are in the prompt text, where they are known to be
# read. If the suffix works it is better placed; if it does not, nothing is lost.
SUFFIX="$(agent_task_suffix)"

# --- submit ------------------------------------------------------------------
# The conversations that exist BEFORE we submit, so ours can be identified by
# difference rather than by being newest. The POST's own id is not usable: it
# answers with a start-task id the events API knows nothing about (measured).
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
# Polled rather than assumed: the conversation appears in the listing a moment
# after the POST returns.
CID=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  AFTER="$(agent_conversation_ids "$(agent_conversations_payload || true)" 2>/dev/null || true)"
  if [[ -n "${AFTER}" ]]; then
    # The ids that were not there before. comm needs both sides sorted, and an
    # empty BEFORE is the normal case on a fresh container.
    CID="$(comm -13 <(printf '%s\n' "${BEFORE}" | sort -u) \
                    <(printf '%s\n' "${AFTER}" | sort -u) 2>/dev/null \
           | grep -E '^[A-Za-z0-9_-]+$' | head -1 || true)"
    [[ -n "${CID}" ]] && break
  fi
  sleep 2
done

if [[ -n "${CID}" ]]; then
  agent_conversation_record "${CID}" \
    || warn "Could not record the conversation id at ${AGENT_CONVERSATION_FILE}; 'lca agent watch' will fall back to picking the newest sandbox."
  ok "Conversation ${CID}"
else
  # Said plainly rather than left as a silent degradation: the task IS running,
  # and only the identification failed.
  warn "The task was submitted but its conversation id could not be identified, so 'lca agent watch' will fall back to picking the newest sandbox. If more than one run is alive, it may attach to the wrong one."
fi

info "Follow it: lca agent watch      ·      see what it did: lca agent logs"
if [[ "${WATCH}" == "true" ]]; then
  exec "${SCRIPT_DIR}/agent-watch.sh"
fi
