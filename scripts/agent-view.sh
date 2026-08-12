#!/usr/bin/env bash
# scripts/agent-view.sh — watch an agent run the way you would watch a person
# work: what it is thinking, what it just ran, what came back, and how long it
# has been on the current step.
#
# WHY THIS IS A SEPARATE FILE FROM agent-watch.sh.
#
# 'lca agent watch' is a supervisor: it enforces the limits in .env and it can
# stop the run. This is a viewer, and the one property a viewer must have is
# that it cannot disturb what it is looking at. Keeping them in one file would
# have made "read-only" a promise in a comment. Keeping them apart makes it a
# property of the file: there is no stop path in here to reach by accident, no
# POST, no docker exec, no kill — only GETs against the agent's own API and the
# read-only container inspects lib.sh already does. A gate in tests/test-lib.sh
# holds it that way.
#
# WHAT IT READS, AND HOW WELL THAT IS KNOWN.
#
# The conversation event stream, which already carries thoughts, tool calls,
# observations and timestamps — the same stream 'lca agent watch' counts for
# its step ceiling. It is OpenHands' format, not ours, and not a documented
# interface. Every field is read through the accessors in lib.sh, which try the
# spellings that have been seen and then FALL BACK TO PRINTING THE EVENT RAW.
# That fallback is the whole design: a view that silently rendered nothing
# would be indistinguishable from an agent that is quietly working, which is
# the exact confusion this replaces.
#
# WHY WALL CLOCK IS ON EVERY LINE.
#
# A step on this hardware takes ten to twenty-five minutes. A display that has
# not moved for four minutes is normal; the same display frozen for forty is a
# run that died. Nothing else on screen can tell those apart, so the elapsed
# time on the current step ticks every second, live, and it is the number the
# status line leads with.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_env

# How long without a single new event before the view stops calling it
# "thinking" and starts calling it stalled. See agent_view_state: 901 s is the
# longest single model reply measured on this box, so this is comfortably
# above ordinary and comfortably below a lost night.
AGENT_VIEW_STALL_SECONDS="${AGENT_VIEW_STALL_SECONDS:-1500}"
# Lines of tool output shown per observation before it is folded away. --full
# turns it off.
AGENT_VIEW_BODY_LINES="${AGENT_VIEW_BODY_LINES:-8}"

usage() {
  cat <<EOF
Usage: lca agent watch --live [options]

Tails the running conversation and prints each turn as it lands: what the agent
is thinking, which tool it called with what arguments, what came back, and how
long the step took. Read-only — it cannot stop, pause or alter the run.

  --once          print everything recorded so far and exit
  --from FILE     render a saved events payload instead of the live one
                  ('-' reads stdin) — for looking at a run after the fact
  --dump          print the raw event JSON and exit (what you would otherwise
                  be cat-ing out of the container by hand)
  --full          do not fold long tool output
  --interval N    seconds between polls (default 3)

The status line answers one question — is it working or stuck:

  running    a tool is running
  thinking   waiting for the model (normal here for 10-25 minutes)
  stalled    nothing has arrived for ${AGENT_VIEW_STALL_SECONDS}s — worth looking at
  finished   the agent says it is done
  error      the last event was a failure, and it stays on screen

What it cannot see, and why: docs/AGENT.md
EOF
}

# --- the pieces that talk to the outside world, all of them GETs -------------

# fetch_events ID — the events payload, or nothing. Two spellings of the search
# path are in circulation; both are tried, for the same reason agent_event_steps
# tries three.
fetch_events() {
  local id="${1:-}" base path payload
  [[ "${id}" =~ ^[A-Za-z0-9_-]{1,128}$ ]] || return 1
  have curl || return 1
  base="$(agent_api_base)"
  for path in "/api/v1/conversation/${id}/events/search?limit=10000" \
              "/api/v1/conversations/${id}/events/search?limit=10000" \
              "/api/v1/conversation/${id}/events"; do
    payload="$(curl -fsS --max-time 10 "${base}${path}" 2>/dev/null || true)"
    [[ -n "${payload}" ]] || continue
    if agent_event_lines "${payload}" >/dev/null 2>&1; then
      printf '%s' "${payload}"
      return 0
    fi
  done
  return 1
}

# --- drawing ------------------------------------------------------------------

VIEW_TTY=false
[[ -t 1 ]] && VIEW_TTY=true
VIEW_COLS=100
if [[ "${VIEW_TTY}" == "true" ]] && have tput; then
  VIEW_COLS="$(tput cols 2>/dev/null || echo 100)"
fi
[[ "${VIEW_COLS}" =~ ^[0-9]+$ ]] && (( VIEW_COLS > 40 )) || VIEW_COLS=100

# clear_status — take the live status line off the screen before printing a
# real line over it. A no-op when stdout is not a terminal, where the status
# line is never drawn in the first place: piping this into a file must produce
# a readable log, not a screenful of carriage returns.
clear_status() {
  [[ "${VIEW_TTY}" == "true" ]] || return 0
  printf '\r%*s\r' "$(( VIEW_COLS - 1 ))" ''
}

wrap() {   # INDENT TEXT
  local indent="$1"; shift
  local width=$(( VIEW_COLS - ${#indent} - 1 ))
  (( width > 20 )) || width=60
  printf '%s\n' "$*" | fold -s -w "${width}" | sed "s/^/${indent}/"
}

# print_event JSON SEQ — one rendered turn.
print_event() {
  local json="$1"
  local class clock tool thought body at
  class="$(agent_event_class "${json}")"
  tool="$(agent_event_tool "${json}" 2>/dev/null || true)"
  thought="$(agent_event_thought "${json}" 2>/dev/null || true)"
  body="$(agent_event_body "${json}" 2>/dev/null || true)"
  at="$(agent_event_at "${json}" 2>/dev/null || true)"
  clock='--:--:--'
  [[ -n "${at}" ]] && clock="$(date -d "@${at}" +%H:%M:%S 2>/dev/null || echo '--:--:--')"

  local marker colour
  case "${class}" in
    action)      marker='>'; colour="${C_BLUE}" ;;
    observation) marker='<'; colour="${C_GREEN}" ;;
    message)     marker='*'; colour="" ;;
    error)       marker='!'; colour="${C_RED}" ;;
    *)           marker='?'; colour="${C_YELLOW}" ;;
  esac

  printf '%b%s  %s %s%b\n' "${colour}" "${clock}" "${marker}" \
    "$(agent_event_headline "${json}")" "${C_RESET}"

  # The thought goes above the call it produced, which is the order it happened
  # in and the order that reads.
  if [[ -n "${thought}" ]]; then
    wrap '            ' "${thought}"
  fi
  # The body is skipped when the headline already carries it. Without this,
  # 'edit · create /workspace/project/wordcount.py' was followed by a lone line
  # reading 'create' — the same field, twice, the second time with the half
  # that made it meaningful removed.
  local arg
  arg="$(agent_event_arg "${json}" 2>/dev/null || true)"
  if [[ -n "${body}" && -n "${arg}" && "${arg}" == "${body}"* ]]; then
    body=""
  fi
  if [[ -n "${body}" ]]; then
    # mapfile, not 'printf | head'. This project has hit the same SIGPIPE three
    # times now: a variable written into a reader that exits early kills the
    # writer at >64 KiB, which under 'set -o pipefail' takes the whole script
    # with it — and a tool observation is exactly the thing that can be a
    # megabyte. The suite's own gate caught this one before it shipped.
    local -a body_lines=()
    local total
    mapfile -t body_lines <<<"${body}"
    total="${#body_lines[@]}"
    if [[ "${VIEW_FULL}" == "true" ]] || (( total <= AGENT_VIEW_BODY_LINES )); then
      printf '            %s\n' "${body_lines[@]}"
    else
      printf '            %s\n' "${body_lines[@]:0:${AGENT_VIEW_BODY_LINES}}"
      printf '            %b(%s more line(s) — --full shows them)%b\n' \
        "${C_YELLOW}" "$(( total - AGENT_VIEW_BODY_LINES ))" "${C_RESET}"
    fi
  fi
  # An event none of the accessors could read is printed whole. This is the
  # line that keeps a silent screen from ever meaning "nothing happened".
  if [[ "${class}" == "unknown" && -z "${thought}" && -z "${body}" ]]; then
    wrap '            ' "${json}"
  fi
  # Time between this event and the one before it: the number that says which
  # step was expensive, available only once there are two of them.
  # What the gap between two events MEANS depends on which way round they are,
  # and saying "took" for both was wrong in one of the two cases: an action
  # arriving after a result is the model thinking, and a result arriving after
  # an action is the tool running. On a box where one of those is twenty
  # minutes and the other is a second, the label is the information.
  if [[ -n "${at}" && -n "${VIEW_LAST_AT}" ]] && (( at >= VIEW_LAST_AT )); then
    local gap word
    gap=$(( at - VIEW_LAST_AT ))
    case "${class}" in
      action|finished) word="thought for" ;;
      observation)     word="ran for" ;;
      error)           word="failed after" ;;
      *)               word="+" ;;
    esac
    printf '            %b%s %s%b\n' "${C_BOLD}" "${word}" \
      "$(human_duration "${gap}")" "${C_RESET}"
  fi
  [[ -n "${at}" ]] && VIEW_LAST_AT="${at}"
  VIEW_LAST_CLASS="${class}"
}

SPIN='-\|/'
# status_line SECONDS_ON_STEP TOTAL_SECONDS STEPS — the live line at the bottom.
status_line() {
  local on_step="$1" total="$2" steps="$3"
  local state frame colour
  state="$(agent_view_state "${VIEW_LAST_CLASS}" "${on_step}" "${AGENT_VIEW_STALL_SECONDS}")"
  case "${state}" in
    error)    colour="${C_RED}" ;;
    stalled)  colour="${C_YELLOW}" ;;
    finished) colour="${C_GREEN}" ;;
    *)        colour="" ;;
  esac
  frame="${SPIN:$(( VIEW_TICKS % 4 )):1}"
  # A spinner ONLY while something is genuinely expected to move. A spinning
  # cursor over a dead run is the thing this whole view was written against.
  case "${state}" in
    stalled|finished|error) frame='.' ;;
  esac
  if [[ "${VIEW_TTY}" == "true" ]]; then
    printf '\r%b%s %s%b · %s · step %s · %s on this step · %s total%b' \
      "${colour}" "${frame}" "${state}" "${C_RESET}" \
      "$(agent_view_state_words "${state}")" "${steps}" \
      "$(human_duration "${on_step}")" "$(human_duration "${total}")" "${C_RESET}"
  elif [[ "${state}" != "${VIEW_LAST_STATE}" ]]; then
    printf '%s — %s (step %s, %s on this step)\n' \
      "${state}" "$(agent_view_state_words "${state}")" "${steps}" \
      "$(human_duration "${on_step}")"
  fi
  VIEW_LAST_STATE="${state}"
}

# --- main ---------------------------------------------------------------------

VIEW_FULL=false
VIEW_LAST_AT=""
VIEW_LAST_CLASS=""
VIEW_LAST_STATE=""
VIEW_TICKS=0

# render_payload PAYLOAD FROM_INDEX — prints every event after FROM_INDEX and
# leaves the total in VIEW_RENDERED.
#
# The count comes back in a variable rather than on stdout, because stdout is
# where the rendering goes. The first draft returned it by printing it, and the
# caller that wanted only the number redirected stdout to /dev/null — which
# silently threw away the entire view. Caught by running it.
VIEW_RENDERED=0
render_payload() {
  local payload="$1" from="$2" i=0 line
  while IFS= read -r line; do
    i=$((i+1))
    (( i > from )) || continue
    clear_status
    print_event "${line}"
    printf '\n'
  done < <(agent_event_lines "${payload}" 2>/dev/null || true)
  VIEW_RENDERED="${i}"
}

main() {
  local once=false dump=false from="" interval=3 arg
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --live)     shift ;;   # accepted here too, so the two entry points agree
      --once)     once=true; shift ;;
      --dump)     dump=true; shift ;;
      --full)     VIEW_FULL=true; shift ;;
      --from)     from="${2:-}"; [[ -n "${from}" ]] || die "--from needs a file (or - for stdin)"; shift 2 ;;
      --interval) interval="${2:-}"
                  if [[ ! "${interval}" =~ ^[0-9]+$ ]] || (( interval < 1 )); then
                    die "--interval needs a whole number of seconds, at least 1."
                  fi
                  shift 2 ;;
      -h|--help)  usage; exit 0 ;;
      *)          arg="$1"; usage >&2; die "Unknown option: ${arg}" ;;
    esac
  done

  have jq || die "This view needs jq to read the event stream, and jq is not installed. Install it (sudo apt-get install -y jq) — everything else in the stack keeps working without it."

  # --- a saved payload, which is also how this is tested -----------------------
  if [[ -n "${from}" ]]; then
    local payload
    if [[ "${from}" == "-" ]]; then payload="$(cat)"
    else
      [[ -r "${from}" ]] || die "Cannot read ${from}."
      payload="$(cat "${from}")"
    fi
    if [[ "${dump}" == "true" ]]; then printf '%s\n' "${payload}"; exit 0; fi
    agent_event_lines "${payload}" >/dev/null 2>&1 \
      || die "There are no events in ${from}. It parsed, but nothing in it looks like an event list — this reads {\"items\":[...]}, {\"events\":[...]}, {\"results\":[...]}, {\"data\":[...]} or a bare array."
    render_payload "${payload}" 0
    exit 0
  fi

  require_cmd docker
  agent_container_running \
    || die "The agent is not running, so there is no conversation to watch. Start it: lca agent start"

  step "Watching the agent"

  # The conversation, named out loud. 'Waiting for sandbox' with no id is
  # exactly the screen this replaces: if there is nothing to watch yet, say
  # what is missing and keep saying how long it has been missing.
  local conv_id="" waited=0
  while :; do
    conv_id="$(agent_conversation_ref 2>/dev/null || true)"
    [[ -n "${conv_id}" ]] && break
    clear_status
    if (( waited == 0 )); then
      info "No conversation exists yet. The agent container is up; a conversation appears when a task is submitted (lca agent task --dir PATH \"...\")."
    fi
    if [[ "${VIEW_TTY}" == "true" ]]; then
      printf '\r. waiting for a conversation to exist · %s' "$(human_duration "${waited}")"
    fi
    sleep 2; waited=$((waited+2))
    if [[ "${once}" == "true" ]]; then
      clear_status
      die "No conversation exists yet, and --once does not wait. Submit a task first: lca agent task --dir PATH \"...\""
    fi
  done
  clear_status
  info "Conversation ${conv_id} — this is read-only; nothing here can stop or change the run."
  local ambiguity
  if ambiguity="$(agent_conversation_warning 2>/dev/null)"; then
    warn "More than one run is alive here — ${ambiguity}. This is showing ${conv_id}."
  fi

  local payload
  payload="$(fetch_events "${conv_id}" 2>/dev/null || true)"
  if [[ -z "${payload}" ]]; then
    die "The agent's event API did not answer for conversation ${conv_id}, so there is nothing to render. It is reachable at $(agent_api_base) when the container is healthy — check with: lca agent status"
  fi

  if [[ "${dump}" == "true" ]]; then printf '%s\n' "${payload}"; exit 0; fi

  local seen started last_event_at now on_step total
  started="$(date +%s)"
  render_payload "${payload}" 0
  seen="${VIEW_RENDERED}"
  last_event_at="$(date +%s)"
  [[ -n "${VIEW_LAST_AT}" ]] && last_event_at="${VIEW_LAST_AT}"

  if [[ "${once}" == "true" ]]; then
    clear_status
    info "${seen} event(s) so far. Re-run without --once to follow it live."
    exit 0
  fi

  # The loop ticks once a second so the elapsed time on the current step is
  # live, and polls every --interval seconds. Those are different rates on
  # purpose: the clock is the thing a person is reading, and a clock that only
  # moves when the network answers is a clock that stops exactly when it
  # matters most.
  trap 'clear_status; printf "\n"; exit 0' INT TERM
  local since_poll=0 fresh
  while :; do
    VIEW_TICKS=$((VIEW_TICKS+1))
    if (( since_poll >= interval )); then
      since_poll=0
      payload="$(fetch_events "${conv_id}" 2>/dev/null || true)"
      if [[ -n "${payload}" ]]; then
        render_payload "${payload}" "${seen}"
        fresh="${VIEW_RENDERED}"
        if [[ "${fresh}" =~ ^[0-9]+$ ]] && (( fresh > seen )); then
          seen="${fresh}"
          last_event_at="$(date +%s)"
        fi
      fi
    fi
    now="$(date +%s)"
    on_step=$(( now - last_event_at ))
    total=$(( now - started ))
    status_line "${on_step}" "${total}" "${seen}"
    sleep 1
    since_poll=$((since_poll+1))
  done
}

# Sourceable, so the renderer can be driven by the suite without a container —
# the same arrangement uninstall.sh and restore.sh use.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
