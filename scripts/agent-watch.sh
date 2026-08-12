#!/usr/bin/env bash
# scripts/agent-watch.sh — supervise a long, unattended agent run.
#
# The agent is meant to be handed a real task and left alone. Three things go
# wrong when nobody is watching, and none of them announce themselves:
#
#   it keeps going for ever          -> AGENT_TIMEOUT_MINUTES (wall clock)
#   it takes thousands of tiny steps -> AGENT_MAX_ITERATIONS  (step ceiling)
#   it retries one broken idea       -> AGENT_STUCK_STRIKES   (same failure,
#                                       N rounds running, nothing new tried)
#
# The limits are enforced HERE, from outside the container, deliberately.
# OpenHands' V1 documentation publishes no environment variable for an
# iteration ceiling or for confirmation mode, and shipping one that might
# quietly do nothing is the shape this project keeps removing from its own
# messages. What is enforced here can be shown to work.
#
# The decisions live in lib.sh (agent_run_verdict, agent_failure_signature) so
# they are testable without pulling a multi-gigabyte image; this file is the
# loop that feeds them.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_env

usage() {
  cat <<EOF
Usage: lca agent watch [--dry-run]

Follows the running agent and stops it when one of the limits in .env is hit:

  AGENT_MAX_ITERATIONS=${AGENT_MAX_ITERATIONS}   steps before it is stopped (0 = no limit)
  AGENT_TIMEOUT_MINUTES=${AGENT_TIMEOUT_MINUTES}   wall-clock minutes (0 = no limit)
  AGENT_STUCK_STRIKES=${AGENT_STUCK_STRIKES}     identical failures in a row before the
                             approach is abandoned (0 = never)

  AGENT_STEP_SOURCE=${AGENT_STEP_SOURCE}    where steps are counted from:
                             auto (event API, log as fallback) | events | log

  --dry-run   report what it would stop on, and stop nothing

Why it says what it says, and what it cannot see: docs/AGENT.md
EOF
}

# What counts as a step, and what counts as a failure, in the agent's log.
#
# Overridable because they are the one part of this that is a guess about
# somebody else's output format: OpenHands' log lines are not a documented
# interface, and a pattern that silently matches nothing would turn every limit
# off while looking like it was on. 'watch' says which patterns it is using and
# how many lines each has matched, so a mismatch is visible in the first
# minute rather than after a wasted night.
# Both defaults were rewritten after watching a real run, and both were wrong
# in the same way: they described the wrong process's output.
#
# The app container (AGENT_CONTAINER) starts conversations and hands the actual
# work to a SANDBOX container it creates per conversation, named
# oh-agent-server-<random>. Measured: the app container's log contains no step
# line at all, while the sandbox is where openhands.sdk and openhands.tools
# report what the agent is doing. A watcher following only the app container
# can never see a step, which is precisely the "limit that cannot fire" this
# file exists to refuse.
#
# The sandbox also logs JSON, one object per line —
#   {"asctime": "...", "levelname": "INFO", "name": "openhands.tools.terminal.impl", ...}
# — so a pattern written for plain text matches the field names rather than the
# events. These match the logger 'name', which is the stable part.
AGENT_STEP_PATTERN="${AGENT_STEP_PATTERN:-openhands\.(sdk|tools|agent_server)\.[a-z_.]*(agent|terminal|tool|action|impl)}"
AGENT_FAIL_PATTERN="${AGENT_FAIL_PATTERN:-(\"levelname\": \"ERROR\"|Traceback|CommandFailed|non-zero exit)}"

# Where the STEP COUNT comes from, which is a different question from where the
# failures come from.
#
# The pattern above was rewritten twice against real logs and it is still not
# enough, and that is a measurement, not a suspicion: across a 27-minute
# reasoning turn that ran to 'finished', the sandbox log grew by one line, and
# that line was a cost-calculation warning. Everything the pattern matches is
# tool initialisation from sandbox startup. So on this build the log can tell
# you a run is failing — the failure pattern and the stuck detector both work
# on it — but it cannot tell you a run is *stepping*.
#
# The app's event API can, so that is tried first and the log is the fallback.
#
#   auto    use the event API when it answers, the log when it does not
#   events  event API only; if it never answers, the ceiling is reported dead
#           rather than silently replaced
#   log     the old behaviour, for a build whose log does carry steps
#
# 'auto' is the default because the fallback loses nothing: the log arm is
# exactly what shipped before, warning included.
AGENT_STEP_SOURCE="${AGENT_STEP_SOURCE:-auto}"

# Where the log followers record themselves, so they can be taken down again,
# and the pipe they write into.
#
# A FIFO rather than the '< <(agent_follow_logs)' this used to read from: a
# process substitution offers no way to ask for a new process group, and a
# group is what finally closes the follower leak (see stop_followers).
AGENT_FOLLOWERS="$(mktemp)"
AGENT_FOLLOWER_FIFO="${AGENT_FOLLOWERS}.fifo"
# The follower loop's pid, which is also its process-group id because the loop
# is started under 'set -m'. Empty until then, and empty means "nothing was
# ever spawned, so there is nothing to stop" — which is the whole of the work
# on the paths that exit before the loop.
AGENT_FOLLOWER_PGID=""

# step_source_label SOURCE — what the number next to "Steps seen" actually
# counted. Named rather than left bare, because the two sources do not count
# the same thing: an event is finer-grained than a reasoning turn (the one
# measured turn here produced five), so the same ceiling means different
# amounts of work depending on which arm is live, and a reader deserves to know
# which they are looking at.
step_source_label() {
  case "${1:-log}" in
    events) printf 'events on the agent API' ;;
    *)      printf 'log lines matching the step pattern' ;;
  esac
}

# agent_log_sources — every container whose log this run should be read from.
#
# The app container plus any sandbox it has spawned. Sandbox names are assigned
# at conversation start, so they are discovered rather than configured; when
# there is no sandbox yet the app container alone is the honest answer.
agent_log_sources() {
  printf '%s\n' "${AGENT_CONTAINER}"
  as_root docker ps --format '{{.Names}}' 2>/dev/null \
    | grep -E '^oh-agent-server-' || true
}

# agent_follow_logs — one merged stream from the app container and every
# sandbox it has spawned.
#
# Sandboxes appear after the run starts, so this re-checks for new ones rather
# than resolving the list once: a watcher that fixed the list at launch would
# follow the app container for the whole run and see none of the work.
#
# Each follower is backgrounded and writes into this function's stdout, which
# the caller reads.
#
# Their PIDs are recorded because they do NOT die on their own, and the comment
# that used to sit here said they did. Measured: after a --dry-run run returned,
# two 'docker logs -f' processes were still alive — the container was still up,
# so nothing ever closed their input. The consequences are worse than a stray
# process: they hold this script's stdout open, so
#
#   lca agent watch --dry-run | tee run.log
#
# never returns, and neither does anything else that reads the output. That is
# also why a test harness around this looked like it was hanging.
agent_follow_logs() {
  local seen="" name
  printf '%s\n' "${BASHPID}" >> "${AGENT_FOLLOWERS}"
  while true; do
    while read -r name; do
      [[ -n "${name}" ]] || continue
      case " ${seen} " in *" ${name} "*) continue ;; esac
      seen="${seen} ${name}"
      as_root docker logs -f --tail 0 "${name}" 2>&1 &
      printf '%s\n' "$!" >> "${AGENT_FOLLOWERS}"
    done < <(agent_log_sources)
    # Cheap: a sandbox takes tens of seconds to appear, so polling for one is
    # not a hot loop, and the read -t in the caller keeps the clock honest
    # regardless of how quiet these streams are.
    sleep 5
    agent_container_running || break
  done
}

# stop_followers — take the log followers down with us.
#
# One signal to their process group, because that is the only handle that still
# points at the follower this file kept losing. Measured, on a run where the
# container outlives the watcher ('watch --dry-run'): a pid-by-pid sweep left
# exactly one 'docker logs -f' alive every time. The reason is a race it cannot
# win — killing a follower's parent first reparents its child to init, so the
# child vanishes from every pid we hold — and the fix is that a reparented
# process KEEPS its process group. Both halves were reproduced outside docker
# before either was relied on.
#
# THE GUARD IS NOT DECORATION, and it is the only branch here. If 'set -m' ever
# failed to split the group, this pgid would be the WATCHER's own and the group
# kill would take the watcher down mid-report — a far worse bug than the leak it
# closes. So in that case it kills nothing and says what is left behind.
#
# There used to be a pid-by-pid fallback here for that case. It is gone, and
# deliberately: it was unreachable on the bash this project targets (5.2 splits
# the group — measured), it was therefore never executed by any test, it was
# measured to leak one follower every time it ran, and its last resort was a
# sweep by command line that could kill a 'docker logs -f' this run never
# started. Untested code whose only measured behaviour is "leaks, and sometimes
# kills something else" is not a safety net. Leaving the followers and naming
# them is worse in one way and better in every other.
stop_followers() {
  local mine
  if [[ -n "${AGENT_FOLLOWER_PGID}" ]]; then
    mine="$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ' || true)"
    if [[ -n "${mine}" && "${AGENT_FOLLOWER_PGID}" == "${mine}" ]]; then
      # Never 'pkill -f docker logs' as the remedy: that pattern matches the
      # user's own command line and this project has watched it kill the
      # calling shell four separate times. List, then kill by pid.
      warn "The log followers ended up in this script's own process group, so nothing was killed — signalling that group would have killed this watcher in the middle of its report. A few 'docker logs -f' processes are still running and will not stop on their own. List them with: ps -eo pid,comm,args | awk '\$2 == \"docker\" && /logs -f/'   then kill the pids it prints."
    else
      kill -- -"${AGENT_FOLLOWER_PGID}" 2>/dev/null
      sleep 0.3
      kill -9 -- -"${AGENT_FOLLOWER_PGID}" 2>/dev/null
    fi
  fi
  rm -f "${AGENT_FOLLOWERS}" "${AGENT_FOLLOWER_FIFO}"
  return 0
}

main() {
  local dry_run=false arg
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --dry-run) dry_run=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) arg="$1"; usage >&2; die "Unknown option: ${arg}" ;;
    esac
  done

  require_cmd docker
  agent_container_running \
    || die "The agent is not running, so there is nothing to watch. Start it: lca agent start"

  step "Supervising the agent"
  info "Step ceiling: ${AGENT_MAX_ITERATIONS}   wall clock: ${AGENT_TIMEOUT_MINUTES} min   stuck after: ${AGENT_STUCK_STRIKES} identical failures"
  [[ "${dry_run}" == "true" ]] && info "--dry-run: nothing will be stopped."

  local started iters=0 strikes=0 last_sig="" line sig verdict elapsed now
  local matched_steps=0 matched_fails=0
  local step_source="log" conv_id="" events_base=0 events_now="" ticks=0 ambiguity
  started="$(date +%s)"

  # Which stream the ceiling counts, asked now and said out loud.
  #
  # The answer decides whether AGENT_MAX_ITERATIONS means anything on this
  # build, and somebody who is about to walk away for a night should learn that
  # in the first second rather than in the morning. 'log' is not an error here —
  # it is what shipped before, and it is right for a build whose log does carry
  # steps. It is only called a dead ceiling at the end, once a whole run has
  # gone by with nothing matched.
  if [[ "${AGENT_STEP_SOURCE}" != "log" ]]; then
    conv_id="$(agent_conversation_ref 2>/dev/null || true)"
    [[ -n "${conv_id}" ]] && events_now="$(agent_event_steps "${conv_id}" 2>/dev/null || true)"
    if [[ "${events_now}" =~ ^[0-9]+$ ]]; then
      step_source="events"
      events_base="${events_now}"
      info "Steps come from the agent's event API (conversation ${conv_id}; ${events_now} event(s) already recorded, and the ceiling counts what happens from here)."
      # Said BEFORE the run rather than deduced from it afterwards. On a real
      # droplet an earlier 'selftest --keep' left a second sandbox alive, the
      # watcher attached to that older conversation, and the count never moved
      # — for as long as it was left running, with nothing anywhere saying why.
      # The conversation is now chosen by the newest running sandbox, which is
      # deterministic; this says when there was a choice to get wrong at all.
      if ambiguity="$(agent_conversation_warning 2>/dev/null)"; then
        warn "More than one run is alive here — ${ambiguity}. This is watching the one belonging to the NEWEST sandbox (${conv_id}). If that is not the run you meant, stop the others first: lca agent stop, then remove any leftover oh-agent-server-* containers."
      fi
    elif [[ "${AGENT_STEP_SOURCE}" == "events" ]]; then
      warn "The agent's event API has not answered yet, so the step ceiling is not armed. It arms as soon as a conversation exists; the wall clock and the stuck detector are already on."
    else
      info "The agent's event API has no conversation to count yet — counting log lines until it does."
    fi
  fi

  # Read the log as it arrives. 'docker logs -f' is the producer and this loop
  # is the consumer, so nothing here exits early on it — the SIGPIPE trap this
  # project has hit repeatedly is the other way round, a consumer that leaves
  # while the producer still writes.
  # 'read -t', not a bare read, and this is the difference between a wall clock
  # that works and one that only looks like it does.
  #
  # The first version evaluated the limits once per log line, which means a
  # silent agent was never checked at all — and silence is exactly the shape of
  # the runaway this timeout exists to catch: a process wedged on a network
  # call or a prompt writes nothing, so the loop blocks in read for ever and
  # the clock is never consulted. Found by watching a real container's log
  # rather than by reasoning about the loop.
  #
  # rc > 128 is the timeout (nothing to read yet, keep going and re-judge);
  # anything else non-zero is end of stream, which means the container is gone.
  #
  # The followers are started HERE, into a FIFO, in a process group of their
  # own. 'set -m' is the whole of that: a backgrounded job in a script normally
  # stays in the watcher's own group, which would make the group kill in
  # stop_followers suicide. Measured on this bash, both halves —
  #
  #   without set -m   loop, subshells, docker AND the watcher: one pgid
  #   with set -m      the loop leads its own group, children inherit it, and
  #                    'kill -- -PGID' takes all of them and leaves us alive
  #
  # The two opens rendezvous, so the writer must be backgrounded before the
  # loop's redirection opens the read end — which is the order below.
  mkfifo "${AGENT_FOLLOWER_FIFO}" \
    || die "Could not create a pipe for the log followers at ${AGENT_FOLLOWER_FIFO}. Is TMPDIR writable?"
  set -m
  agent_follow_logs > "${AGENT_FOLLOWER_FIFO}" &
  AGENT_FOLLOWER_PGID=$!
  set +m

  local rc
  while true; do
    line=""
    # No '!' on the read. '! cmd' INVERTS the status, so inside that branch $?
    # is the negation's 0 and not read's own 128+timeout code — measured: the
    # loop broke on the first tick and announced "the agent stopped on its own"
    # about a container that was still serving.
    if IFS= read -r -t "${AGENT_WATCH_TICK:-20}" line; then
      : # a line arrived; fall through and judge it
    else
      rc=$?
      (( rc > 128 )) || break
    fi
    if [[ -n "${line}" ]] && [[ "${line}" =~ ${AGENT_STEP_PATTERN} ]]; then
      matched_steps=$(( matched_steps + 1 ))
      # Only the log arm feeds the ceiling. Counted either way, because a run
      # where nothing ever matched is worth saying at the end even when the
      # ceiling was armed from somewhere better.
      if [[ "${step_source}" == "log" ]]; then iters=$(( iters + 1 )); fi
    fi
    if [[ -n "${line}" ]] && [[ "${line}" =~ ${AGENT_FAIL_PATTERN} ]]; then
      matched_fails=$(( matched_fails + 1 ))
      sig="$(agent_failure_signature "${line}")"
      if [[ -n "${sig}" && "${sig}" == "${last_sig}" ]]; then
        strikes=$(( strikes + 1 ))
      else
        strikes=1
        last_sig="${sig}"
      fi
    fi

    # Re-read the count from the event API on a TICK, not on a log line. A step
    # that writes nothing to the log is the entire reason this source exists,
    # so a counter that only advanced when a line arrived would be the same bug
    # in a new hat.
    ticks=$(( ticks + 1 ))
    if [[ "${AGENT_STEP_SOURCE}" != "log" ]]; then
      if [[ "${step_source}" == "events" ]]; then
        events_now="$(agent_event_steps "${conv_id}" 2>/dev/null || true)"
        if [[ "${events_now}" =~ ^[0-9]+$ ]]; then
          iters=$(( events_now - events_base ))
          (( iters >= 0 )) || iters=0
        fi
      # The upgrade probe every third tick, not every one: each of its calls
      # burns its own timeout when the API is not there, and five of those
      # would stretch a 20 s tick into something that is no longer a tick. The
      # armed path above polls every time, where the calls are cheap because
      # they answer.
      elif (( ticks % 3 == 1 )); then
        [[ -n "${conv_id}" ]] || conv_id="$(agent_conversation_ref 2>/dev/null || true)"
        [[ -n "${conv_id}" ]] && events_now="$(agent_event_steps "${conv_id}" 2>/dev/null || true)"
        if [[ "${events_now}" =~ ^[0-9]+$ ]]; then
          step_source="events"; events_base="${events_now}"; iters=0
          info "The agent's event API is answering now (conversation ${conv_id}) — the step ceiling counts events from here."
        fi
      fi
    fi

    now="$(date +%s)"; elapsed=$(( now - started ))
    verdict="$(agent_run_verdict "${iters}" "${AGENT_MAX_ITERATIONS}" \
                 "${elapsed}" "${AGENT_TIMEOUT_MINUTES}" \
                 "${strikes}" "${AGENT_STUCK_STRIKES}")"
    [[ "${verdict}" == "ok" ]] && continue

    warn "Stopping the agent: $(agent_stop_reason "${verdict}")"
    info "Steps seen: ${iters} ($(step_source_label "${step_source}")) · failures seen: ${matched_fails} · run time: $(human_duration "${elapsed}")"
    [[ "${verdict}" == "stuck" ]] && info "The failure it kept repeating: ${last_sig}"
    if [[ "${dry_run}" == "true" ]]; then
      info "--dry-run: the agent is still running."
    else
      if as_root docker stop "${AGENT_CONTAINER}" >/dev/null 2>&1; then
        ok "Agent stopped. Its workspace is intact in ${HOME}/.openhands — read it, then start again."
      else
        warn "Could not stop the container; do it by hand: lca agent stop"
      fi
    fi
    return 0
  done < "${AGENT_FOLLOWER_FIFO}"

  # The stream ended, which means the container did.
  elapsed=$(( $(date +%s) - started ))
  if [[ "${step_source}" == "events" ]]; then
    ok "The agent stopped on its own after $(human_duration "${elapsed}") and ${iters} event(s) on its own API."
    return 0
  fi
  # Everything below is the log arm, and the two ways it can end badly are
  # different questions: whether the ceiling was armed at all, and whether the
  # pattern fits.
  if [[ "${AGENT_STEP_SOURCE}" == "events" ]]; then
    warn "The agent stopped on its own after $(human_duration "${elapsed}"), and its event API never answered, so with AGENT_STEP_SOURCE=events the step ceiling never armed. The wall clock and the stuck detector were the only limits in force. Set AGENT_STEP_SOURCE=auto to fall back to the log."
    return 1
  fi
  if (( matched_steps == 0 )); then
    # Said out loud rather than reported as a clean run. Zero matches over a
    # whole run means the step pattern does not fit this agent build, and the
    # ceiling was therefore never able to fire — a limit that cannot trigger is
    # worse than no limit, because it was believed.
    warn "The agent stopped on its own after $(human_duration "${elapsed}"), its event API never answered, and NO log line matched the step pattern, so the step ceiling was never able to fire. Check the pattern against a real log: lca agent logs   (override with AGENT_STEP_PATTERN)"
    return 1
  fi
  ok "The agent stopped on its own after $(human_duration "${elapsed}") and ${iters} step(s)."
}

trap stop_followers EXIT
main "$@"
