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
  url       Print the address to open on your phone
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
  # 'url' only reads .env and Tailscale — it must keep working when Docker is
  # down or the container was never created, since that is exactly when someone
  # is trying to work out where their chat app lives.
  if [[ "${cmd}" == "url" ]]; then
    local ts_ip=""
    if have tailscale; then
      ts_ip="$(tailscale ip -4 2>/dev/null | head -1 || true)"
    fi
    if [[ -n "${ts_ip}" ]]; then
      ok "Open this on your phone:  http://${ts_ip}:${WEBUI_PORT}"
      # Point the phone's camera at this instead of typing an IP by hand. The
      # URL is always printed above as well: a terminal QR renders light
      # modules on a dark background, which almost every scanner reads but not
      # quite all, so this is a shortcut and never the only way in.
      # -m 2 keeps the quiet zone; without a margin many scanners refuse.
      if have qrencode; then
        echo
        qrencode -t ANSIUTF8 -m 2 "http://${ts_ip}:${WEBUI_PORT}" 2>/dev/null || true
      fi
      info "(the phone must be signed in to the same Tailscale account — docs/PHONE.md)"
    else
      warn "Tailscale has no IPv4 address yet — run: sudo tailscale up"
      info "Once connected: http://<tailscale-ip>:${WEBUI_PORT}"
    fi
    info "On this machine:  http://127.0.0.1:${WEBUI_PORT}"
    exit 0
  fi

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
      local state live_port key
      state="$("${DOCKER[@]}" inspect -f '{{.State.Status}}' "${WEBUI_CONTAINER}")"
      info "Container '${WEBUI_CONTAINER}': ${state}"
      # Settings are baked into the container when it is created, so editing
      # .env moves nothing until it is re-created. webui_drift() does the
      # comparing (one copy, in lib.sh — writing it out per key is how signups
      # came to have no check at all); the message stays specific per key,
      # because "PORT differs" and "anyone can still register an account" are
      # not the same news.
      live_port="$(webui_container_env PORT || true)"
      while read -r key; do
        [[ -n "${key}" ]] || continue
        case "${key}" in
          WEBUI_PORT)
            warn "Port drift: the container listens on ${live_port}, but .env says WEBUI_PORT=${WEBUI_PORT}. Apply it with: sudo lca apply" ;;
          MODEL_NAME)
            warn "Model drift: the chat app preselects '$(webui_container_env DEFAULT_MODELS || true)', but .env says MODEL_NAME=${MODEL_NAME} (auto-tune may have changed it). Apply it with: sudo lca apply" ;;
          WEBUI_ENABLE_SIGNUP)
            warn "Signup drift: the running chat app was started with signups $(webui_container_env ENABLE_SIGNUP | tr '[:lower:]' '[:upper:]' || true), but .env says WEBUI_ENABLE_SIGNUP=${WEBUI_ENABLE_SIGNUP}. Editing .env does NOT change a running container — apply it with: sudo lca apply" ;;
          OLLAMA_HOST)
            warn "Ollama address drift: the chat app talks to '$(webui_container_env OLLAMA_BASE_URL || true)', but .env now points Ollama at $(ollama_url). The phone will show no models until the container is re-created: sudo lca apply" ;;
          WEBUI_NAME)
            warn "Name drift: the chat app is titled '$(webui_container_env WEBUI_NAME || true)', but .env says WEBUI_NAME=${WEBUI_NAME}. Apply it with: sudo lca apply" ;;
        esac
      done < <(webui_drift || true)
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
