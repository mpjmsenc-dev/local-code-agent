#!/usr/bin/env bash
# webui.sh — manage the Open WebUI container: start|stop|restart|status|logs
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/scripts/lib.sh"
load_env

usage() {
  cat <<EOF
Usage: webui.sh <command>

Commands:
  start     Start the Open WebUI container
  stop      Stop it (chat history is kept in the docker volume)
  restart   Restart it
  status    Container state + HTTP health on port ${WEBUI_PORT}
  logs      Follow the container logs (Ctrl-C to stop)

To (re)create the container after editing .env, run: scripts/install_webui.sh
EOF
}

container_exists() {
  as_root docker container inspect "${WEBUI_CONTAINER}" >/dev/null 2>&1
}

main() {
  local cmd="${1:-}"
  [[ -n "${cmd}" ]] || { usage; exit 1; }
  have docker || die "Docker is not installed. Run scripts/install_docker.sh first."

  case "${cmd}" in
    start)
      if container_exists; then
        as_root docker start "${WEBUI_CONTAINER}" >/dev/null
        info "Waiting for Open WebUI to answer on port ${WEBUI_PORT}..."
        wait_for_webui 120 || die "Container started but no HTTP answer after 120s — check: ./webui.sh logs"
        ok "Open WebUI started — http://<tailscale-ip>:${WEBUI_PORT}"
      else
        info "Container '${WEBUI_CONTAINER}' does not exist yet — creating it..."
        "${SCRIPT_DIR}/scripts/install_webui.sh"
      fi
      ;;
    stop)
      container_exists || die "Container '${WEBUI_CONTAINER}' does not exist."
      as_root docker stop "${WEBUI_CONTAINER}" >/dev/null
      ok "Open WebUI stopped (data kept in the 'open-webui' volume)."
      ;;
    restart)
      container_exists || die "Container '${WEBUI_CONTAINER}' does not exist — run scripts/install_webui.sh first."
      as_root docker restart "${WEBUI_CONTAINER}" >/dev/null
      info "Waiting for Open WebUI to answer on port ${WEBUI_PORT}..."
      wait_for_webui 120 || die "Restarted but no HTTP answer after 120s — check: ./webui.sh logs"
      ok "Open WebUI restarted."
      ;;
    status)
      if ! container_exists; then
        warn "Container '${WEBUI_CONTAINER}' does not exist — run scripts/install_webui.sh to create it."
        exit 1
      fi
      local state
      state="$(as_root docker inspect -f '{{.State.Status}}' "${WEBUI_CONTAINER}")"
      info "Container '${WEBUI_CONTAINER}': ${state}"
      if curl -fsS --max-time 5 "http://127.0.0.1:${WEBUI_PORT}" >/dev/null 2>&1; then
        ok "HTTP answering on port ${WEBUI_PORT}."
      else
        warn "No HTTP answer on port ${WEBUI_PORT} (still starting? check: webui.sh logs)"
        exit 1
      fi
      ;;
    logs)
      container_exists || die "Container '${WEBUI_CONTAINER}' does not exist."
      as_root docker logs -f "${WEBUI_CONTAINER}"
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
