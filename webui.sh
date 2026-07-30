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

# Talk to docker the least-privileged way that actually works, decided once.
# scripts/install_docker.sh adds the user to the docker group, so plain 'docker'
# normally works: using as_root unconditionally would trigger a needless sudo
# password prompt (breaking non-interactive use), and with neither root nor sudo
# as_root would die() mid-command instead of giving a usable message.
DOCKER=(docker)
select_docker() {
  if docker info >/dev/null 2>&1; then
    DOCKER=(docker)
  elif can_root && as_root docker info >/dev/null 2>&1; then
    DOCKER=(as_root docker)
  else
    return 1
  fi
  return 0
}

container_exists() {
  "${DOCKER[@]}" container inspect "${WEBUI_CONTAINER}" >/dev/null 2>&1
}

main() {
  local cmd="${1:-}"
  [[ -n "${cmd}" ]] || { usage; exit 1; }
  have docker || die "Docker is not installed. Run scripts/install_docker.sh first."
  select_docker || die "Cannot reach the Docker daemon as '$(id -un)'. Start it (sudo systemctl start docker), or add yourself to the docker group (scripts/install_docker.sh) and log out/in, or re-run this as root."

  case "${cmd}" in
    start)
      if container_exists; then
        "${DOCKER[@]}" start "${WEBUI_CONTAINER}" >/dev/null
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
      "${DOCKER[@]}" stop "${WEBUI_CONTAINER}" >/dev/null
      ok "Open WebUI stopped (data kept in the 'open-webui' volume)."
      ;;
    restart)
      container_exists || die "Container '${WEBUI_CONTAINER}' does not exist — run scripts/install_webui.sh first."
      "${DOCKER[@]}" restart "${WEBUI_CONTAINER}" >/dev/null
      info "Waiting for Open WebUI to answer on port ${WEBUI_PORT}..."
      wait_for_webui 120 || die "Restarted but no HTTP answer after 120s — check: ./webui.sh logs"
      ok "Open WebUI restarted."
      ;;
    status)
      if ! container_exists; then
        warn "Container '${WEBUI_CONTAINER}' does not exist — run scripts/install_webui.sh to create it."
        exit 1
      fi
      local state live_port
      state="$("${DOCKER[@]}" inspect -f '{{.State.Status}}' "${WEBUI_CONTAINER}")"
      info "Container '${WEBUI_CONTAINER}': ${state}"
      # The port is baked into the container's env when it is created
      # (--network=host plus -e PORT=...). Editing WEBUI_PORT in .env does not
      # move a running container, so without this check status probes a port the
      # container never listened on and blames it for "not answering".
      live_port="$("${DOCKER[@]}" inspect -f '{{range .Config.Env}}{{println .}}{{end}}' \
        "${WEBUI_CONTAINER}" 2>/dev/null | sed -n 's/^PORT=//p' | head -1)"
      if [[ -n "${live_port}" && "${live_port}" != "${WEBUI_PORT}" ]]; then
        warn "Port drift: the container listens on ${live_port}, but .env says WEBUI_PORT=${WEBUI_PORT}. Apply the new port with: scripts/install_webui.sh"
      fi
      if webui_responds; then
        ok "Open WebUI /health answering on port ${WEBUI_PORT}."
      else
        if [[ -n "${live_port}" && "${live_port}" != "${WEBUI_PORT}" ]]; then
          die "No /health answer on port ${WEBUI_PORT} — because the running container is on ${live_port} (see the port drift above). Re-create it with: scripts/install_webui.sh"
        fi
        warn "No /health answer on port ${WEBUI_PORT} (still starting? crash-looping? check: webui.sh logs)"
        exit 1
      fi
      ;;
    logs)
      container_exists || die "Container '${WEBUI_CONTAINER}' does not exist."
      "${DOCKER[@]}" logs -f "${WEBUI_CONTAINER}"
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
