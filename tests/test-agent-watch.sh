#!/usr/bin/env bash
# tests/test-agent-watch.sh — make the supervisor actually stop something.
#
# 'lca agent watch' is the least-exercised code in this repo and the one with
# the most at stake: it is what stops a runaway run while nobody is watching.
# Its DECISIONS have unit tests (agent_run_verdict, agent_failure_signature) and
# its event-API readers have been checked against a live container. The LOOP
# around them had never been run to the point of stopping anything.
#
# So this drives the real scripts/agent-watch.sh against a real container, over
# a real 'docker logs -f' stream, and asserts on what it did — not on what it
# would have decided. Each of the three limits is provoked by making the world
# genuinely look the way that limit is about:
#
#   wall clock   a container that runs and says NOTHING. Silence is the shape of
#                a wedged run, and a loop that only judged on output would never
#                notice — which is a bug this file has had.
#   stuck        a container repeating one failure with a new id every time, so
#                the signature collapser is what has to see through it.
#   step ceiling an event API that really answers, over HTTP, with a rising
#                count. The watcher polls it exactly as it would poll OpenHands.
#
# WHAT IS A FIXTURE AND WHY. The event endpoint here is a small HTTP server, not
# OpenHands. That is honest about one thing and dishonest about nothing: the
# watcher's own code — agent_conversation_ref, agent_event_steps, the polling
# tick, the verdict, the stop — is the real code on a real socket. What it does
# NOT prove is that OpenHands' counts rise the way this fixture's do. Closing
# that needs a real agent, and docs/AGENT.md says how in one command.
#
# Usage: tests/test-agent-watch.sh [--keep]
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${TESTS_DIR}/.." && pwd)"
BOX="lca-watch-test"
FIXTURE_PORT="${LCA_WATCH_FIXTURE_PORT:-13457}"
KEEP=false
[[ "${1:-}" == "--keep" ]] && KEEP=true

FAILED=0
t_ok()   { printf 'ok   - %s\n' "$*"; }
t_fail() { printf 'FAIL - %s\n' "$*"; FAILED=$((FAILED+1)); }

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "skip - no reachable docker daemon, so the supervisor has nothing to supervise"
  exit 0
fi

WORK="$(mktemp -d)"
# shellcheck disable=SC2317  # a trap handler; shellcheck cannot see the call
cleanup() {
  if [[ "${KEEP}" == "true" ]]; then
    echo "kept: ${WORK}, container ${BOX}"
    return
  fi
  docker rm -f "${BOX}" >/dev/null 2>&1
  [[ -z "${FIXTURE_PID:-}" ]] || kill "${FIXTURE_PID}" 2>/dev/null
  rm -rf "${WORK}"
}
trap cleanup EXIT

# A base image that is certainly present: the one this project already ships.
# Pulling something new would make a supervisor test depend on a registry.
BASE="$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -vi '<none>' | head -1)"
if [[ -z "${BASE}" ]]; then
  echo "skip - no local image to build a container from"
  exit 0
fi

# start_box SHELL_SNIPPET — a container that produces the world we want.
start_box() {
  docker rm -f "${BOX}" >/dev/null 2>&1
  docker run -d --name "${BOX}" --entrypoint sh "${BASE}" -c "$1" >/dev/null 2>&1
}

box_running() { [[ "$(docker container inspect -f '{{.State.Running}}' "${BOX}" 2>/dev/null)" == "true" ]]; }

# followers_alive — how many 'docker logs -f' processes for our box are still
# running. The watcher backgrounds one per container it follows, and the
# question this answers is whether it took them with it.
#
# Filtered on the comm field out of ps, never 'ps | grep' or 'pkill -f': those
# match the calling shell's own command line, which in this project has twice
# meant a test killing itself. comm is the executable name, so this shell —
# whose args merely mention docker — cannot match.
followers_alive() {
  ps -eo pid=,comm=,args= 2>/dev/null \
    | awk -v box="${BOX}" '$2 == "docker" && /logs/ && index($0, box) { n++ } END { print n+0 }'
}

# The watcher reads .env through load_env, which overwrites exported values, so
# the settings under test are written to a real .env in a throwaway copy of the
# repo rather than exported and silently lost. That overwrite is a documented
# trap in this project and it would make every case here pass for the wrong
# reason.
SANDBOX_REPO="${WORK}/repo"
mkdir -p "${SANDBOX_REPO}/scripts" "${SANDBOX_REPO}/config"
cp "${REPO}/scripts/lib.sh" "${REPO}/scripts/agent-watch.sh" "${SANDBOX_REPO}/scripts/"
cp "${REPO}/config/CONVENTIONS.md" "${REPO}/config/prompt-suggestions.json" "${SANDBOX_REPO}/config/" 2>/dev/null
cp "${REPO}/.env.example" "${SANDBOX_REPO}/"

# watch_with [--dry-run] KEY=VALUE... — run the REAL watcher with these
# settings, and return what it printed. Whether the container actually stopped
# is asked separately: "it said it stopped it" and "it stopped it" are two
# claims, and telling them apart is why this file exists.
watch_with() {
  local kv flags=()
  while [[ "${1:-}" == --* ]]; do flags+=("$1"); shift; done
  cp "${REPO}/.env.example" "${SANDBOX_REPO}/.env"
  {
    printf '\nAGENT_CONTAINER=%s\n' "${BOX}"
    printf 'AGENT_PORT=%s\n' "${FIXTURE_PORT}"
    for kv in "$@"; do printf '%s\n' "${kv}"; done
  } >> "${SANDBOX_REPO}/.env"
  local out rc
  out="$( cd "${SANDBOX_REPO}" && AGENT_WATCH_TICK=2 NO_PROXY='*' no_proxy='*' \
      timeout 120 ./scripts/agent-watch.sh "${flags[@]+"${flags[@]}"}" 2>&1 )"
  rc=$?
  # 124 is timeout's own. Said out loud rather than left to look like a limit
  # that simply did not fire: a supervisor that never returns is its own bug,
  # and a harness that waits quietly for it is how a two-minute suite becomes a
  # ten-minute one nobody runs.
  (( rc != 124 )) || out="${out}
WATCHER-TIMED-OUT after 120s without reaching a verdict"
  printf '%s' "${out}"
}

# no_watcher_timeout OUTPUT — the marker above is a failure wherever it appears.
assert_reached_a_verdict() {
  if grep -q 'WATCHER-TIMED-OUT' <<<"$1"; then
    t_fail "the watcher never reached a verdict: $1"
    return 1
  fi
  return 0
}

echo "# the supervisor, against a real container, stopping real things"

# ---------------------------------------------------------------- wall clock
# A container that says nothing at all. This is the case the loop got wrong
# once: judging only when a log line arrived meant a silent run was never
# judged, and silence is exactly the shape of the hang the timeout exists for.
start_box 'sleep 600' || { echo "skip - could not start a container"; exit 0; }
OUT="$(watch_with 'AGENT_TIMEOUT_MINUTES=1' 'AGENT_MAX_ITERATIONS=0' 'AGENT_STUCK_STRIKES=0' 'AGENT_STEP_SOURCE=log')"
assert_reached_a_verdict "${OUT}"
if grep -q 'wall-clock limit' <<<"${OUT}"; then
  t_ok "the wall clock fires on a container that never says a word"
else
  t_fail "the wall clock did not fire on a silent container: ${OUT}"
fi
if box_running; then
  t_fail "the watcher said it stopped the agent and the container is still running"
else
  t_ok "...and the container was really stopped, not just reported"
fi

# ---------------------------------------------------------------- dry run
# The same world, and nothing may be touched.
start_box 'sleep 600'
OUT="$(watch_with --dry-run 'AGENT_TIMEOUT_MINUTES=1' 'AGENT_MAX_ITERATIONS=0' 'AGENT_STUCK_STRIKES=0' 'AGENT_STEP_SOURCE=log')"
if box_running; then
  t_ok "--dry-run reaches a verdict and leaves the container running"
else
  t_fail "--dry-run stopped the container it promised not to touch"
fi
if grep -q 'dry-run' <<<"${OUT}"; then
  t_ok "...and says so rather than going quiet"
else
  t_fail "--dry-run stopped nothing and also said nothing: ${OUT}"
fi

# ------------------------------------------------- the followers came with it
# This case, and only this case, is the condition the leak needed: the watcher
# returns while the CONTAINER IS STILL UP, so nothing ever closes a follower's
# input and it has no reason to die on its own.
#
# Measured against the version before the process-group fix, in this exact
# harness: one 'docker logs -f' survived, reparented to init, invisible to every
# pid the watcher had recorded. So this number is not a formality — it was 1.
sleep 1
LEFTOVERS="$(followers_alive)"
if (( LEFTOVERS == 0 )); then
  t_ok "...and left no 'docker logs -f' behind, on the run where the container outlives it"
else
  t_fail "${LEFTOVERS} 'docker logs -f' process(es) survived the watcher — the follower leak is back"
fi
# WHICH path took them down. The watcher falls back to a pid-by-pid sweep if the
# followers did not get their own process group, and that sweep is exactly what
# used to leak; a green count above with this warning present would mean the
# real fix is dead and the count is luck.
if grep -q 'did not get a process group of their own' <<<"${OUT}"; then
  t_fail "the watcher fell back to the pid-by-pid sweep, so the process group never formed: ${OUT}"
else
  t_ok "...via the process group, not the fallback sweep that used to leak"
fi

# ------------------------------------------------------- returns when piped
# The regression guard for the bug this harness found. The watcher backgrounds
# 'docker logs -f' followers, and they used to outlive it holding its stdout
# open — so the script returned but the PIPE never closed, and
#
#   lca agent watch --dry-run | tee run.log
#
# ran for ever on a run that had already reached its verdict. Measured before
# the fix: indefinite. After: 60s, the length of the wall clock it was given.
start_box 'sleep 600'
PIPE_START="$(date +%s)"
OUT="$(watch_with --dry-run 'AGENT_TIMEOUT_MINUTES=1' 'AGENT_MAX_ITERATIONS=0' 'AGENT_STUCK_STRIKES=0' 'AGENT_STEP_SOURCE=log')"
PIPE_ELAPSED=$(( $(date +%s) - PIPE_START ))
if (( PIPE_ELAPSED < 100 )); then
  t_ok "the watcher's output can be read to the end (${PIPE_ELAPSED}s, container still up)"
else
  t_fail "reading the watcher's output took ${PIPE_ELAPSED}s — its log followers are holding the pipe open again"
fi

# ---------------------------------------------------------------- stuck
# One failure, over and over, with a new pid and a new temp path every round —
# the shape that made a raw line comparison see a novel error each time and
# never fire.
# shellcheck disable=SC2016  # the expansions belong to the container's shell, not to ours
start_box 'i=0; while :; do i=$((i+1)); echo "ERROR build failed in /tmp/x${i}a${i} after ${i} retries"; sleep 1; done'
OUT="$(watch_with 'AGENT_TIMEOUT_MINUTES=0' 'AGENT_MAX_ITERATIONS=0' 'AGENT_STUCK_STRIKES=3' 'AGENT_STEP_SOURCE=log' \
        'AGENT_FAIL_PATTERN=ERROR')"
assert_reached_a_verdict "${OUT}"
if grep -q 'same failure repeated' <<<"${OUT}"; then
  t_ok "the stuck detector fires on one failure wearing a new id each round"
else
  t_fail "the stuck detector never fired on three identical failures: ${OUT}"
fi
if box_running; then
  t_fail "the stuck detector reported a stop that did not happen"
else
  t_ok "...and stopped the container"
fi

# ---------------------------------------------------------------- step ceiling
# A real HTTP endpoint the watcher polls exactly as it polls OpenHands. The
# count rises on each read, so the ceiling is reached by the watcher's own
# arithmetic rather than by anything this file asserts.
cat > "${WORK}/events.py" <<'FIX'
import http.server, sys
n = [0]
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_GET(self):
        if "app-conversations/search" in self.path:
            body = b'{"items":[{"id":"watchtest"}],"next_page_id":null}'
        elif "/events/count" in self.path:
            n[0] += 1
            body = str(n[0]).encode()
        else:
            body = b'{}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
FIX
python3 "${WORK}/events.py" "${FIXTURE_PORT}" >/dev/null 2>&1 &
FIXTURE_PID=$!
sleep 2
if ! curl -fsS --noproxy '*' --max-time 3 "http://127.0.0.1:${FIXTURE_PORT}/api/v1/conversation/x/events/count" >/dev/null 2>&1; then
  t_fail "the event fixture never came up, so the ceiling was not exercised"
else
  start_box 'sleep 600'
  OUT="$(watch_with 'AGENT_TIMEOUT_MINUTES=0' 'AGENT_MAX_ITERATIONS=3' 'AGENT_STUCK_STRIKES=0' 'AGENT_STEP_SOURCE=events')"
assert_reached_a_verdict "${OUT}"
  if grep -q 'step ceiling' <<<"${OUT}"; then
    t_ok "the step ceiling fires on a rising count from a real event endpoint"
  else
    t_fail "the step ceiling never fired while the event count climbed: ${OUT}"
  fi
  if grep -q 'events on the agent API' <<<"${OUT}"; then
    t_ok "...and says it counted events, not log lines"
  else
    t_fail "the stop message does not name the source it counted: ${OUT}"
  fi
  if box_running; then
    t_fail "the step ceiling reported a stop that did not happen"
  else
    t_ok "...and stopped the container"
  fi
fi

echo
if (( FAILED == 0 )); then
  echo "RESULT: all three limits fired against a real container and really stopped it"
else
  echo "RESULT: ${FAILED} supervisor assertion(s) FAILED"
fi
exit $(( FAILED > 0 ? 1 : 0 ))
