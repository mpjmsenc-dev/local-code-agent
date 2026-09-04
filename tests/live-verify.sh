#!/usr/bin/env bash
# tests/live-verify.sh — drive the agent-tier gates against a REAL machine.
#
# WHY THIS EXISTS. tests/test-lib.sh is pure-logic by charter: "no root, no
# network, no services touched, so they run anywhere". That charter is right,
# and it has a cost nobody had paid. Every gate covering the agent tier reaches
# its verdict through a stub — `docker` shadowed by a shell function, `curl`
# replaced by a canned payload, `ollama` faked to return zero. Five of those
# shims are installed suite-wide (test-lib.sh:138-160) precisely so a gate that
# forgets to stub gets a fixed "no" rather than an answer from the box it is
# running on.
#
# So the suite proves the LOGIC around docker, and has never once proved the
# logic MATCHES docker. A stub encodes what somebody believed the API returns.
# When the belief is wrong the gate still passes, for ever, in CI. That is not
# hypothetical here: docs record settings POSTs answered 200 while storing
# nothing, an events API that knows nothing of the id the POST returns, and a
# conversation that is invisible for 43-57 seconds after it is created. Each was
# found by hand on a live box, never by the suite.
#
# This file is the other half. Same subjects, same production functions, no
# stubs at all: it asks the real docker, the real OpenHands API, the real
# Ollama, and reports where the machine and the fixtures disagree.
#
# Deliberately NOT part of 'make test' or CI, for the same reason
# scripts/prompt-bench.sh is not: it needs a running agent tier, a pulled model
# and a live relay, and CI has none of them. It is read-only — it starts,
# stops and removes nothing — so it is safe to run against a working box while
# a task is in flight.
#
# Three verdicts:
#
#   ok      the real machine agrees with what the stubbed gate asserts
#   FAIL    the real machine disagrees — the stub was wrong, or the code is
#   skip    the precondition is absent, so nothing was measured
#
# A fourth, WRONG ("the gate passes, but it is not asserting what it claims
# to"), was declared here, counted, printed in the summary and included in the
# exit condition — and no line in this file could ever produce it. A column
# that always reads zero looks like a check being made. Removed rather than
# left saying so; it can come back the day something actually reports it.
#
# Usage: tests/live-verify.sh [--slow]
#   --slow  also run the checks that cost a model load (minutes on a CPU box,
#           and they queue behind any task the agent is running)
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${TESTS_DIR}/.." && pwd)"

# shellcheck source=../scripts/lib.sh
source "${REPO}/scripts/lib.sh"
load_env

SLOW=false
[[ "${1:-}" == "--slow" ]] && SLOW=true

FAILED=0
SKIPPED=0
PASSED=0
t_ok()    { printf 'ok    - %s\n' "$*"; PASSED=$((PASSED+1)); }
t_fail()  { printf 'FAIL  - %s\n' "$*"; FAILED=$((FAILED+1)); }
t_skip()  { printf 'skip  - %s\n' "$*"; SKIPPED=$((SKIPPED+1)); }
sect()    { printf '\n=== %s\n' "$*"; }
# note — evidence under a verdict. Indented so a reader can tell at a glance
# which lines are claims and which are the numbers behind them.
note()    { printf '        %s\n' "$*"; }

# --- preconditions ------------------------------------------------------------
# Refused rather than skipped one gate at a time: a run of this file against a
# box with no agent tier would print forty 'skip' lines and look like coverage.
have docker || { printf 'docker is not installed; nothing here can be driven.\n' >&2; exit 2; }
docker_daemon_reachable || { printf 'The docker daemon is not reachable as %s; nothing here can be driven.\n' "$(whoami)" >&2; exit 2; }
have curl || { printf 'curl is not installed.\n' >&2; exit 2; }
have jq || { printf 'jq is not installed; the API checks all need it.\n' >&2; exit 2; }

printf 'Driving the agent tier on THIS machine: %s\n' "$(hostname)"
printf 'Container %s, port %s, model %s\n' \
  "${AGENT_CONTAINER}" "${AGENT_PORT}" "$(agent_llm_model "$(agent_model_for_run)")"

# =============================================================================
sect "1. container state — the five suite-wide shims, unshimmed"
# test-lib.sh:157-160 shadows agent_container_running and agent_live_port to
# return 1 for the whole suite. Nothing has ever seen them answer.
# =============================================================================

if agent_container_running; then
  t_ok "agent_container_running says yes about a container that is up"
  note "docker: $(docker container inspect -f '{{.State.Running}}' "${AGENT_CONTAINER}" 2>/dev/null)"
else
  t_skip "the agent container is not running — sections 1-7 need it up (lca agent setup)"
fi

if agent_container_exists; then
  t_ok "agent_container_exists — named by NO test in any suite; it answers correctly here"
else
  t_fail "agent_container_exists says no about a container docker can see"
fi

LIVE_PORT="$(agent_live_port 2>/dev/null || true)"
MAPPED="$(docker container port "${AGENT_CONTAINER}" 3000 2>/dev/null | head -1 || true)"
if [[ -n "${LIVE_PORT}" ]]; then
  t_ok "agent_live_port reads the port docker really published: ${LIVE_PORT}"
  note "docker container port ${AGENT_CONTAINER} 3000 -> ${MAPPED}"
  [[ "${LIVE_PORT}" == "${AGENT_PORT}" ]] \
    || note "NOTE: live port ${LIVE_PORT} differs from .env AGENT_PORT=${AGENT_PORT}"
else
  t_fail "agent_live_port could not read the mapping (docker says: ${MAPPED:-nothing})"
fi

# test-lib.sh:2696 asserts the API base prefers the live port over .env, with
# agent_live_port stubbed to a port nothing listens on.
BASE="$(agent_api_base)"
if curl -fsS --max-time 10 -o /dev/null "${BASE}/" 2>/dev/null; then
  t_ok "agent_api_base points somewhere that answers: ${BASE}"
else
  t_fail "agent_api_base returned ${BASE}, which does not answer"
fi

# =============================================================================
sect "2. publication — three addresses, asserted by grepping agent.sh"
# test-lib.sh:3678-3751 proves the -p flags are PRESENT IN THE SOURCE. Whether
# the container ended up with them is a different question and this is it.
# =============================================================================

BINDINGS="$(docker inspect "${AGENT_CONTAINER}" -f '{{json .HostConfig.PortBindings}}' 2>/dev/null || true)"
BOUND_ADDRS="$(jq -r '.["3000/tcp"][]?.HostIp' <<<"${BINDINGS}" 2>/dev/null | sort -u | tr '\n' ' ')"
note "published on: ${BOUND_ADDRS:-nothing}"

if grep -q '127.0.0.1' <<<"${BOUND_ADDRS}"; then
  t_ok "published on loopback (you, and 'lca agent status')"
else
  t_fail "not published on loopback"
fi

GW="$(docker_bridge_gateway 2>/dev/null || true)"
if [[ -n "${GW}" ]] && grep -qF "${GW}" <<<"${BOUND_ADDRS}"; then
  t_ok "published on the docker bridge gateway ${GW} (its own sandboxes)"
else
  t_fail "not published on the bridge gateway ${GW:-unknown} — sandboxes cannot call back"
fi

TSIP="$(tailscale_ip4 2>/dev/null || true)"
if [[ -z "${TSIP}" ]]; then
  t_skip "no Tailscale address on this machine, so the phone path cannot be checked"
elif grep -qF "${TSIP}" <<<"${BOUND_ADDRS}"; then
  t_ok "published on the Tailscale address ${TSIP} — the address 'lca agent url' prints"
  # The listeners are the THIRD argument and there is no fallback: called with
  # two, port_open_at reads an empty list and answers "closed" for everything.
  # Both production callers pass "$(host_listeners)" (check-system.sh:652,
  # agent-setup.sh:211); the first draft of this file did not, and duly
  # reported a bound, answering port as unreachable.
  if port_open_at "${TSIP}" "${LIVE_PORT:-${AGENT_PORT}}" "$(host_listeners || true)" 2>/dev/null; then
    t_ok "port_open_at agrees the phone address is really listening"
  else
    t_fail "published, but port_open_at says ${TSIP}:${LIVE_PORT:-${AGENT_PORT}} is not open"
  fi
else
  t_fail "'lca agent url' advertises ${TSIP} but nothing is published there — the documented phone path is dead"
fi

# 0.0.0.0 is the thing the design argument in agent.sh forbids.
if grep -qE '(^| )0\.0\.0\.0( |$)' <<<"${BOUND_ADDRS}"; then
  t_fail "the agent is published on 0.0.0.0 — the most dangerous port here is on every interface"
else
  t_ok "not published on 0.0.0.0 — three named private addresses, as designed"
fi

EXTRA_HOSTS="$(docker inspect "${AGENT_CONTAINER}" -f '{{json .HostConfig.ExtraHosts}}' 2>/dev/null || true)"
if grep -q 'host.docker.internal:host-gateway' <<<"${EXTRA_HOSTS}"; then
  t_ok "--add-host host.docker.internal:host-gateway is on the running container"
else
  t_fail "no host-gateway add-host — every LLM call fails to connect, silently, behind 5 retries"
fi

# The three OH_* variables, each of which is a silent no-op when missing.
CENV="$(docker inspect "${AGENT_CONTAINER}" -f '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null || true)"
for want in "OH_SANDBOX_KIND" "OH_SANDBOX_HOST_PORT" "OH_WEB_URL"; do
  if grep -qE "^${want}=." <<<"${CENV}"; then
    t_ok "container env carries $(grep -E "^${want}=" <<<"${CENV}" | head -1)"
  else
    t_fail "container env is missing ${want} — the sandbox dials the wrong port and dies in init"
  fi
done
# The value, not just the key: OH_SANDBOX_HOST_PORT defaulting to 3000 is what
# sent the sandbox to Open WebUI, which accepts the connection and never speaks
# MCP, so the agent died in init on a 30s tool-listing timeout.
ENV_HOST_PORT="$(grep -E '^OH_SANDBOX_HOST_PORT=' <<<"${CENV}" | head -1 | cut -d= -f2)"
if [[ "${ENV_HOST_PORT}" == "${AGENT_PORT}" ]]; then
  t_ok "OH_SANDBOX_HOST_PORT is ${ENV_HOST_PORT}, matching the published port"
else
  t_fail "OH_SANDBOX_HOST_PORT is '${ENV_HOST_PORT}', not ${AGENT_PORT} — sandboxes call back to the wrong port"
fi

# =============================================================================
sect "3. relay reachability — ollama_relay_healthy is driven by NO test at all"
# =============================================================================

RELAY_ADDR="$(ollama_relay_address 2>/dev/null || true)"
if [[ -n "${RELAY_ADDR}" ]]; then
  t_ok "ollama_relay_address resolves to ${RELAY_ADDR}"
  [[ "${RELAY_ADDR}" == 0.0.0.0* ]] \
    && t_fail "the relay would bind 0.0.0.0 — that is the thing it exists to avoid"
else
  t_skip "no relay address (ENABLE_OLLAMA_RELAY=${ENABLE_OLLAMA_RELAY})"
fi

if [[ "${ENABLE_OLLAMA_RELAY}" == "true" ]]; then
  if ollama_relay_healthy 2>/dev/null; then
    t_ok "ollama_relay_healthy — UNTESTED BY THE SUITE — says the relay is answering"
    note "$(curl -fsS --max-time 5 "$(ollama_relay_url)/api/version" 2>/dev/null || echo '(no version)')"
  else
    t_fail "ollama_relay_healthy says the relay is NOT answering at $(ollama_relay_url 2>/dev/null)"
  fi

  if ollama_relay_drift 2>/dev/null; then
    t_fail "ollama_relay_drift: the unit's address no longer matches the live bridge"
    note "unit: $(ollama_relay_unit_address 2>/dev/null || echo unknown)   bridge: ${GW}"
  else
    t_ok "ollama_relay_drift reports no drift between the unit and the live bridge"
  fi
else
  t_skip "the relay is off in .env"
fi

# The one that matters: can the AGENT reach the model? Asked from inside its own
# network namespace, which is the only place the answer is real.
LLM_BASE="$(agent_llm_base_url)"
if agent_container_running; then
  if docker exec "${AGENT_CONTAINER}" curl -fsS -m 10 -o /dev/null "${LLM_BASE}/models" 2>/dev/null; then
    t_ok "the agent container can reach the model at ${LLM_BASE}"
  else
    t_fail "the agent CANNOT reach ${LLM_BASE} — every task fails without producing a token"
  fi
fi

# =============================================================================
sect "4. the derived model — stubs return canned num_ctx strings"
# test-lib.sh:3132 stubs ollama() to print 'num_ctx 16384'. This asks ollama.
# =============================================================================

AMODEL="$(agent_model_name "${MODEL_NAME}")"
if model_present "${AMODEL}" 2>/dev/null; then
  t_ok "the derived model ${AMODEL} exists"
  DECL="$(agent_model_declared_context "${AMODEL}" 2>/dev/null || true)"
  WANT="$(agent_model_context)"
  if [[ "${DECL}" == "${WANT}" ]]; then
    t_ok "agent_model_declared_context reads ${DECL} from the real model, as wanted"
  else
    t_fail "the model declares num_ctx '${DECL:-none}', not ${WANT}"
  fi
else
  t_skip "the derived model ${AMODEL} is not built (lca tune)"
fi

# What Ollama has ACTUALLY loaded it at, if it happens to be resident. Free when
# it is; skipped rather than forced, because forcing costs a model load.
PS_CTX="$(curl -fsS --max-time 5 "$(ollama_url)/api/ps" 2>/dev/null \
          | jq -r --arg m "${AMODEL}" '.models[]? | select(.name == $m) | .context_length' 2>/dev/null | head -1 || true)"
if [[ -n "${PS_CTX}" ]]; then
  if [[ "${PS_CTX}" == "$(agent_model_context)" ]]; then
    t_ok "Ollama has it RESIDENT at context_length ${PS_CTX} — the Modelfile really took"
  else
    t_fail "resident at ${PS_CTX}, not $(agent_model_context) — it silently truncates mid-task"
  fi
elif [[ "${SLOW}" == "true" ]]; then
  LOADED="$(agent_model_loaded_context "${AMODEL}" 2>/dev/null || true)"
  if [[ "${LOADED}" == "$(agent_model_context)" ]]; then
    t_ok "agent_model_loaded_context: loads at ${LOADED}"
  else
    t_fail "agent_model_loaded_context: loads at '${LOADED:-unreadable}', wanted $(agent_model_context)"
  fi
else
  t_skip "the model is not resident; --slow would load it to read the real window"
fi

if agent_model_drift >/dev/null 2>&1; then
  t_fail "agent_model_drift: $(agent_model_drift 2>/dev/null)"
else
  t_ok "agent_model_drift finds nothing wrong with the derived model"
fi

# =============================================================================
sect "5. settings — every gate here greps agent.sh; none has ever POSTed"
# test-lib.sh:3521-4171 assert the PAYLOAD IS BUILT with --argjson. Whether the
# server stored what was sent is the question they cannot ask.
# =============================================================================

SETTINGS="$(curl -fsS --max-time 10 "${BASE}/api/v1/settings" 2>/dev/null || true)"
if [[ -z "${SETTINGS}" ]]; then
  t_skip "the settings API did not answer at ${BASE}/api/v1/settings"
else
  GOT_MODEL="$(jq -r '.agent_settings.llm.model // ""' <<<"${SETTINGS}")"
  WANT_MODEL="$(agent_llm_model "$(agent_model_for_run)")"
  if [[ "${GOT_MODEL}" == "${WANT_MODEL}" ]]; then
    t_ok "the agent really holds model ${GOT_MODEL}"
  else
    t_fail "the agent holds '${GOT_MODEL:-none}', not '${WANT_MODEL}'"
  fi

  # The three that are stored as the WRONG TYPE if --arg is used instead of
  # --argjson. The suite checks the flag; this checks the stored type.
  NTC_TYPE="$(jq -r '.agent_settings.llm.native_tool_calling | type' <<<"${SETTINGS}" 2>/dev/null || true)"
  if [[ "${NTC_TYPE}" == "boolean" ]]; then
    t_ok "native_tool_calling is stored as a real boolean, not the string \"false\""
  else
    t_fail "native_tool_calling is stored as ${NTC_TYPE} — a quoted false looks stored and is not"
  fi
  NTC="$(agent_stored_native_tool_calling "${SETTINGS}")"
  if [[ "${NTC}" == "${AGENT_NATIVE_TOOL_CALLING}" ]]; then
    t_ok "agent_stored_native_tool_calling reads back '${NTC}' from a LIVE payload (jq's // bug stays fixed)"
  else
    t_fail "stored native_tool_calling is '${NTC}', wanted '${AGENT_NATIVE_TOOL_CALLING}'"
  fi

  OUT_TYPE="$(jq -r '.agent_settings.llm.max_output_tokens | type' <<<"${SETTINGS}" 2>/dev/null || true)"
  OUT_VAL="$(jq -r '.agent_settings.llm.max_output_tokens // "null"' <<<"${SETTINGS}")"
  if [[ "${OUT_TYPE}" == "number" && "${OUT_VAL}" == "$(agent_max_output_tokens)" ]]; then
    t_ok "max_output_tokens stored as the number ${OUT_VAL} — the truncation fix is live"
  else
    t_fail "max_output_tokens is ${OUT_TYPE} '${OUT_VAL}', wanted number $(agent_max_output_tokens)"
  fi

  TMO_TYPE="$(jq -r '.agent_settings.llm.timeout | type' <<<"${SETTINGS}" 2>/dev/null || true)"
  TMO_VAL="$(jq -r '.agent_settings.llm.timeout // "null"' <<<"${SETTINGS}")"
  if [[ "${TMO_TYPE}" == "number" && "${TMO_VAL}" == "$(agent_request_timeout)" ]]; then
    t_ok "timeout stored as the number ${TMO_VAL}s — outlasts the 901s generation measured here"
  else
    t_fail "timeout is ${TMO_TYPE} '${TMO_VAL}', wanted number $(agent_request_timeout)"
  fi

  STORED_BASE="$(jq -r '.agent_settings.llm.base_url // ""' <<<"${SETTINGS}")"
  if [[ "${STORED_BASE}" == "${LLM_BASE}" ]]; then
    t_ok "the stored base_url is the one this repo would set: ${STORED_BASE}"
  else
    t_fail "stored base_url '${STORED_BASE}' is not '${LLM_BASE}'"
  fi
fi

# =============================================================================
sect "6. the conversation API — nine curl() stubs and ~25 canned payloads"
# =============================================================================

PAYLOAD="$(agent_conversations_payload 2>/dev/null || true)"
if [[ -z "${PAYLOAD}" ]]; then
  t_skip "the conversations listing did not answer"
else
  t_ok "agent_conversations_payload got a real listing ($(printf '%s' "${PAYLOAD}" | wc -c) bytes)"
  IDS="$(agent_conversation_ids "${PAYLOAD}" 2>/dev/null || true)"
  N_IDS="$(grep -c . <<<"${IDS}" || true)"
  if [[ -n "${IDS}" ]]; then
    t_ok "agent_conversation_ids parsed ${N_IDS} id(s) out of the real 1.8 envelope"
  else
    t_fail "agent_conversation_ids parsed NOTHING from a real listing — the fixture shape is wrong"
  fi

  ONE="$(agent_conversation_id "${PAYLOAD}" 2>/dev/null || true)"
  if [[ -n "${ONE}" ]]; then
    t_ok "agent_conversation_id picked ${ONE} from the live payload"
  else
    t_fail "agent_conversation_id found no id in a real listing"
  fi

  # The set difference, against the real thing rather than CONV_BEFORE/AFTER.
  if [[ -n "${IDS}" ]]; then
    FIRST="$(head -1 <<<"${IDS}")"
    REST="$(tail -n +2 <<<"${IDS}")"
    NEW="$(agent_new_conversation "${REST}" "${IDS}" 2>/dev/null || true)"
    if [[ "${NEW}" == "${FIRST}" ]]; then
      t_ok "agent_new_conversation names the added id against a real listing"
    else
      t_fail "agent_new_conversation returned '${NEW}', wanted '${FIRST}'"
    fi
  fi
fi

REC="$(agent_recorded_conversation 2>/dev/null || true)"
if [[ -n "${REC}" ]]; then
  t_ok "agent_recorded_conversation — named by NO test — returns ${REC}"
else
  t_skip "no conversation recorded at ${AGENT_CONVERSATION_FILE}"
fi

REF="$(agent_conversation_ref 2>/dev/null || true)"
if [[ -n "${REF}" ]]; then
  t_ok "agent_conversation_ref resolved ${REF} against the live API"
  STEPS="$(agent_event_steps "${REF}" 2>/dev/null || true)"
  if [[ "${STEPS}" =~ ^[0-9]+$ ]]; then
    t_ok "agent_event_steps got ${STEPS} from a real events route (3 routes tried)"
  else
    t_fail "agent_event_steps could not count events for a REAL conversation id"
  fi
else
  t_skip "no conversation to reference"
fi

# A rejected id must never reach the network. test-lib.sh:2644 proves this with
# a curl spy; here the proof is that a bad id is refused before any route.
if agent_event_steps '../../etc/passwd' >/dev/null 2>&1; then
  t_fail "agent_event_steps accepted a path-traversal id"
else
  t_ok "agent_event_steps refuses a path-traversal id (unchanged against a live API)"
fi

# =============================================================================
sect "7. sandboxes — agent_orphan_sandboxes is named by NO test"
# =============================================================================

SBX="$(agent_live_sandboxes 2>/dev/null || true)"
N_SBX="$(grep -c . <<<"${SBX}" || true)"
note "live sandboxes: ${N_SBX}"
[[ -n "${SBX}" ]] && note "$(tr '\n' ' ' <<<"${SBX}")"

# The restraint is the assertion: while the app is UP, nothing is an orphan.
ORPH="$(agent_orphan_sandboxes 2>/dev/null || true)"
if agent_container_running; then
  if [[ -z "${ORPH}" ]]; then
    t_ok "agent_orphan_sandboxes offers nothing while the app is up — the restraint holds live"
  else
    t_fail "it called $(grep -c . <<<"${ORPH}") sandbox(es) orphaned while the app is RUNNING"
  fi
else
  t_skip "the app is down; every sandbox is an orphan by definition"
fi

RECL="$(agent_reclaimable_sandboxes 2>/dev/null || true)"
if [[ -z "${RECL}" ]]; then
  t_ok "agent_reclaimable_sandboxes offers nothing — no finished conversation is holding a sandbox"
else
  t_ok "agent_reclaimable_sandboxes named $(grep -c . <<<"${RECL}") collectable sandbox(es)"
  while IFS=$'\t' read -r nm why; do
    [[ -n "${nm}" ]] && note "${nm} — ${why}"
  done <<<"${RECL}"
  # Every name it offers must be a container that really exists, or 'lca agent
  # gc' would try to remove something that is not there.
  while IFS=$'\t' read -r nm _; do
    [[ -n "${nm}" ]] || continue
    if docker container inspect "${nm}" >/dev/null 2>&1; then
      t_ok "  ${nm} is a real container"
    else
      t_fail "  ${nm} is offered for collection but docker has no such container"
    fi
  done <<<"${RECL}"
fi

# =============================================================================
sect "8. the inbound guard — four docker seams stubbed to 1 in every gate"
# =============================================================================

GUARDED="$(guarded_ports 2>/dev/null || true)"
note "guarded_ports says: $(tr '\n' '|' <<<"${GUARDED}")"
if [[ "${ENABLE_AGENT}" == "true" ]]; then
  if grep -qE "(^|[^0-9])${AGENT_PORT}([^0-9]|$)" <<<"${GUARDED}"; then
    t_ok "the agent's port ${AGENT_PORT} is in the guard list, computed from real container state"
  else
    t_fail "the agent is on but port ${AGENT_PORT} is not in the guard list"
  fi
fi
if grep -qE '(^|[^0-9])22([^0-9]|$)' <<<"${GUARDED}"; then
  t_fail "port 22 reached the guard list — SSH would be dropped"
else
  t_ok "port 22 never reaches the guard list"
fi

# Both arguments are load-bearing and neither has a fallback. Called with no
# address it returns 1, which reads as "no gaps" through a '|| true'; called
# with no listener list it reports EVERY promised port as a gap. The first
# draft of this file did both, and reported a bound, answering, HTTP-200 port
# as unreachable — a false FAIL rather than a false pass, but the same lesson:
# the contract lives in the argument list and nothing enforces it.
if [[ -z "${TSIP}" ]]; then
  t_skip "no Tailscale address, so nothing is promised to a phone"
else
  GAPS="$(tailscale_promise_gaps "${TSIP}" "$(host_listeners || true)" 2>/dev/null || true)"
  if [[ -z "${GAPS}" ]]; then
    t_ok "tailscale_promise_gaps: everything advertised on ${TSIP} is really bound"
  else
    t_fail "tailscale_promise_gaps: ${GAPS}"
  fi
fi

# =============================================================================
printf '\n=============================================================\n'
printf '%s passed, %s failed, %s skipped\n' \
  "${PASSED}" "${FAILED}" "${SKIPPED}"
printf '=============================================================\n'
(( FAILED == 0 ))
