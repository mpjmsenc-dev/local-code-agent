#!/usr/bin/env bash
# agent.sh — the autonomous agent tier (OpenHands), the step up from 'lca'.
#
# 'lca' runs aider: it edits files in the directory you are standing in, one
# request at a time, and you read the diff. This runs an agent that plans
# multi-step work and carries it out inside its own Docker sandbox — installing
# packages, running builds, starting services — without stopping to confirm
# each step. That is the point of it and it is also the whole of its risk, so
# it is off by default (ENABLE_AGENT) and it is never reachable from the public
# internet: the same inbound guard that covers the chat app covers this port,
# and it is the more important of the two to keep closed.
#
# Everything it does happens on this machine. The model is the local Ollama —
# there is no API key to leak because there is no API.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/scripts/lib.sh"
load_env

usage() {
  cat <<EOF
Usage: lca agent <command>       (or agent.sh directly)

Commands:
  start     Start the agent (pulls the images on first run — several GB)
  stop      Stop it (its workspace and settings are kept in ~/.openhands)
  restart   Restart it
  status    Container state + HTTP health on port ${AGENT_PORT}
  url       The address to open on your phone, over Tailscale
  logs      Follow the agent's logs (Ctrl-C to stop)
  watch     Supervise a run in progress: stop it at the step ceiling, the
            wall-clock limit, or when the same failure keeps repeating

Limits for an unattended run live in .env:
  AGENT_MAX_ITERATIONS=${AGENT_MAX_ITERATIONS}   AGENT_TIMEOUT_MINUTES=${AGENT_TIMEOUT_MINUTES}   AGENT_STUCK_STRIKES=${AGENT_STUCK_STRIKES}

Enable it with ENABLE_AGENT=true in .env, then: sudo lca apply
Full notes, including what it costs and where it is weak: docs/AGENT.md
EOF
}

# agent_health — HTTP reachable on the port it publishes.
agent_health() {
  local port="${1:-${AGENT_PORT}}"
  curl -fsS --max-time 5 -o /dev/null "http://127.0.0.1:${port}/" 2>/dev/null
}

require_enabled() {
  [[ "${ENABLE_AGENT}" == "true" ]] || die "The agent tier is off. Set ENABLE_AGENT=true in .env, then: sudo lca apply"
}

start_agent() {
  require_enabled
  require_cmd docker curl
  docker_daemon_reachable || die "Cannot reach the Docker daemon as '$(whoami)'. $(docker_unreachable_advice)"

  if agent_container_running; then
    ok "The agent is already running: $(agent_url_line)"
    return 0
  fi

  # The port must be free before docker binds it, for the reason
  # install_webui.sh spells out at length: a squatter answering the port makes
  # a crash-looping container look healthy. Checked against the SAME port the
  # container will publish, and refused rather than worked around.
  # Captured, then matched against a here-string. 'ss | grep -q' SIGPIPEs the
  # producer and returns 141 under pipefail, which reads as "port is free"
  # exactly when it was taken — install_webui.sh carries the same two lines and
  # the same reason, and the direction of the failure is why it is worth them:
  # a missed match means docker cannot bind, the container crash-loops under
  # --restart unless-stopped, and the squatter answers the health probe.
  local listeners=""
  have ss && listeners="$(ss -ltn 2>/dev/null || true)"
  if [[ -n "${listeners}" ]] && grep -qE ":${AGENT_PORT}[[:space:]]" <<<"${listeners}"; then
    die "Port ${AGENT_PORT} is already in use, so the agent cannot bind it. See what holds it (sudo ss -tlnp | grep :${AGENT_PORT}), or set AGENT_PORT in .env to a free port and re-run: sudo lca apply"
  fi
  if [[ "${AGENT_PORT}" == "${WEBUI_PORT}" ]]; then
    die "AGENT_PORT and WEBUI_PORT are both ${AGENT_PORT}. The chat app runs with --network=host, so the two would fight for one socket. Give the agent its own port in .env."
  fi

  # Recreate rather than start a stale container: its port mapping and its
  # model settings are baked in at creation, so a container made before an
  # .env edit would keep answering with the old ones.
  if agent_container_exists; then
    info "Removing the previous agent container so this one gets the current .env settings..."
    as_root docker rm -f "${AGENT_CONTAINER}" >/dev/null 2>&1 || true
  fi

  local model base_url instructions
  model="$(agent_llm_model "${MODEL_NAME}")"
  base_url="$(agent_llm_base_url)"
  # The same instructions file aider reads and the chat app is given, so the
  # third surface does not become the one place the user's preferences are
  # ignored. Passed as the agent's default task framing; empty when the file is
  # absent or AIDER_CONVENTIONS is off, and an empty -e is simply not added.
  instructions="$(lca_user_instructions)"
  info "Starting the agent on port ${AGENT_PORT}, using ${model} at ${base_url}"
  info "First run downloads several GB of images — this takes a while."

  # --add-host is what makes host.docker.internal resolve to this machine, and
  # without it the agent cannot see Ollama at all. The docker socket is what
  # lets it start its own sandbox containers; that is also why this tier is
  # opt-in, and docs/AGENT.md says so in those words.
  local extra_env=()
  if [[ -n "${instructions}" ]]; then
    # LLM_SYSTEM_PROMPT_SUFFIX is not a documented OpenHands variable, so this
    # does not pretend it is one: the file is also mounted where the agent can
    # read it, and docs/AGENT.md says which of the two is guaranteed. An env
    # var that may do nothing is fine only when something else does the job.
    extra_env+=( -e "LCA_USER_INSTRUCTIONS=${instructions}" )
  fi

  as_root docker run -d \
    --name "${AGENT_CONTAINER}" \
    --restart unless-stopped \
    ${extra_env[@]+"${extra_env[@]}"} \
    -v "${REPO_ROOT}/config/CONVENTIONS.md:/.openhands/lca-instructions.txt:ro" \
    -e AGENT_SERVER_IMAGE_REPOSITORY="${AGENT_RUNTIME_IMAGE}" \
    -e AGENT_SERVER_IMAGE_TAG="${AGENT_RUNTIME_TAG}" \
    -e LLM_MODEL="${model}" \
    -e LLM_BASE_URL="${base_url}" \
    -e LLM_API_KEY=local-llm \
    -e LOG_ALL_EVENTS=true \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "${HOME}/.openhands:/.openhands" \
    -p "127.0.0.1:${AGENT_PORT}:3000" \
    --add-host host.docker.internal:host-gateway \
    "${AGENT_IMAGE}" >/dev/null \
    || die "Could not start the agent container. Its own output: lca agent logs"

  ok "Agent started. ${AGENT_CONTAINER} is running."
  info "It may take a minute to answer while it unpacks. Then: $(agent_url_line)"
  seed_agent_settings
}

# seed_agent_settings — write the LLM settings the agent needs before it can
# start ANY conversation.
#
# The LLM_MODEL / LLM_BASE_URL environment variables the docs give are not
# enough on their own. Measured on a freshly started container: GET
# /api/v1/settings answers {"error":"Settings not found"}, and the first task
# submitted then dies inside the app with
#
#   File ".../user/auth_user_context.py", line 50, in get_user_info
#     assert settings is not None
#
# So a stack that looks healthy — container up, UI answering, 'lca agent
# status' green — cannot run a single task until somebody opens the settings
# screen by hand. That is a phone-first product asking for a desktop browser.
#
# POSTed once at start, and best-effort: a failure here is a warning, never a
# reason to fail a container that did start. It is idempotent, so a restart
# re-asserts .env's model rather than leaving a stale one from an older run.
seed_agent_settings() {
  local url="http://127.0.0.1:${AGENT_PORT}/api/v1/settings" body waited=0
  # Wait for the API rather than racing it: the container answers HTTP well
  # before this route exists.
  while (( waited < 90 )); do
    curl -fsS --max-time 3 -o /dev/null "${url}" 2>/dev/null && break
    # 404/500 still means the server is answering, which is all this needs.
    curl -sS --max-time 3 -o /dev/null "http://127.0.0.1:${AGENT_PORT}/" 2>/dev/null && break
    sleep 3; waited=$(( waited + 3 ))
  done
  body="$(jq -nc --arg m "$(agent_llm_model "${MODEL_NAME}")" \
                 --arg u "$(agent_llm_base_url)" \
        '{llm_model:$m, llm_base_url:$u, llm_api_key:"local-llm",
          agent:"CodeActAgent", language:"en", confirmation_mode:false}')"
  if curl -fsS --max-time 20 -X POST "${url}" -H 'Content-Type: application/json' \
       -d "${body}" >/dev/null 2>&1; then
    ok "Agent settings seeded: $(agent_llm_model "${MODEL_NAME}") at $(agent_llm_base_url)"
  else
    warn "Could not seed the agent's LLM settings, so its first task may fail with 'Settings not found'. Open ${AGENT_PORT}'s settings screen once, or re-run: lca agent restart"
  fi
}

agent_url_line() {
  local ip=""
  if have tailscale; then
    ip="$(tailscale ip -4 2>/dev/null | head -1 || true)"
  fi
  if [[ -n "${ip}" ]]; then
    printf 'http://%s:%s' "${ip}" "${AGENT_PORT}"
  else
    printf 'http://127.0.0.1:%s (no Tailscale address yet — see docs/PHONE.md)' "${AGENT_PORT}"
  fi
}

main() {
  local cmd="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "${cmd}" in
    start)   start_agent ;;
    stop)
      require_cmd docker
      # if/else, not 'A && B || C', which is not if-then-else: C runs when A
      # succeeds and B fails, so a stop that worked could still report that
      # nothing was running.
      if as_root docker stop "${AGENT_CONTAINER}" >/dev/null 2>&1; then
        ok "Agent stopped. Its workspace and settings are kept in ${HOME}/.openhands."
      else
        warn "The agent container was not running."
      fi
      ;;
    restart) main stop || true; main start ;;
    status)
      require_cmd docker
      if agent_container_running; then
        ok "Container '${AGENT_CONTAINER}': running"
      elif agent_container_exists; then
        warn "Container '${AGENT_CONTAINER}': exists but is not running (lca agent start)"
        return 1
      else
        warn "Container '${AGENT_CONTAINER}' does not exist (lca agent start)"
        return 1
      fi
      local live; live="$(agent_live_port 2>/dev/null || printf '%s' "${AGENT_PORT}")"
      if agent_health "${live}"; then
        ok "Agent answering on port ${live}"
      else
        warn "No answer on port ${live} yet (still unpacking? check: lca agent logs)"
        return 1
      fi
      ;;
    url)    printf '%s\n' "$(agent_url_line)" ;;
    logs)
      require_cmd docker
      as_root docker logs -f --tail 100 "${AGENT_CONTAINER}" \
        || die "Could not read the agent's logs (is it created? try: lca agent status)"
      ;;
    watch)  "${SCRIPT_DIR}/scripts/agent-watch.sh" "$@" ;;
    help|-h|--help) usage ;;
    "")     usage >&2; die "agent.sh needs a command." ;;
    *)      usage >&2; die "Unknown command: ${cmd}" ;;
  esac
}

main "$@"
