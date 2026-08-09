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
AGENT_STEP_PATTERN="${AGENT_STEP_PATTERN:-(^|[^A-Za-z])(STEP|ACTION|AgentController)}"
AGENT_FAIL_PATTERN="${AGENT_FAIL_PATTERN:-(ERROR|Traceback|CommandFailed|non-zero exit)}"

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
  started="$(date +%s)"

  # Read the log as it arrives. 'docker logs -f' is the producer and this loop
  # is the consumer, so nothing here exits early on it — the SIGPIPE trap this
  # project has hit repeatedly is the other way round, a consumer that leaves
  # while the producer still writes.
  while IFS= read -r line; do
    if [[ "${line}" =~ ${AGENT_STEP_PATTERN} ]]; then
      iters=$(( iters + 1 )); matched_steps=$(( matched_steps + 1 ))
    fi
    if [[ "${line}" =~ ${AGENT_FAIL_PATTERN} ]]; then
      matched_fails=$(( matched_fails + 1 ))
      sig="$(agent_failure_signature "${line}")"
      if [[ -n "${sig}" && "${sig}" == "${last_sig}" ]]; then
        strikes=$(( strikes + 1 ))
      else
        strikes=1
        last_sig="${sig}"
      fi
    fi

    now="$(date +%s)"; elapsed=$(( now - started ))
    verdict="$(agent_run_verdict "${iters}" "${AGENT_MAX_ITERATIONS}" \
                 "${elapsed}" "${AGENT_TIMEOUT_MINUTES}" \
                 "${strikes}" "${AGENT_STUCK_STRIKES}")"
    [[ "${verdict}" == "ok" ]] && continue

    warn "Stopping the agent: $(agent_stop_reason "${verdict}")"
    info "Steps seen: ${iters} · failures seen: ${matched_fails} · run time: $(human_duration "${elapsed}")"
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
  done < <(as_root docker logs -f --tail 0 "${AGENT_CONTAINER}" 2>&1)

  # The stream ended, which means the container did.
  elapsed=$(( $(date +%s) - started ))
  if (( matched_steps == 0 )); then
    # Said out loud rather than reported as a clean run. Zero matches over a
    # whole run means the step pattern does not fit this agent build, and the
    # ceiling was therefore never able to fire — a limit that cannot trigger is
    # worse than no limit, because it was believed.
    warn "The agent stopped on its own after $(human_duration "${elapsed}"), and NO log line matched the step pattern, so the step ceiling was never able to fire. Check the pattern against a real log: lca agent logs   (override with AGENT_STEP_PATTERN)"
    return 1
  fi
  ok "The agent stopped on its own after $(human_duration "${elapsed}") and ${iters} step(s)."
}

main "$@"
