#!/usr/bin/env bash
# scripts/install_webui.sh — run Open WebUI (the phone chat app) in Docker.
# Uses host networking so the container reaches the loopback-only Ollama API.
# Idempotent: re-running recreates the container from the current .env, and
# chat history survives in the 'open-webui' docker volume.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_env

WEBUI_IMAGE="ghcr.io/open-webui/open-webui:main"

main() {
  step "Installing Open WebUI"
  if [[ "${SKIP_DOCKER}" == "true" ]]; then
    die "SKIP_DOCKER=true in .env — Open WebUI needs Docker. Set SKIP_DOCKER=false and re-run scripts/install_docker.sh first."
  fi
  have docker || die "Docker is not installed. Run scripts/install_docker.sh first (or ./setup.sh)."
  docker info >/dev/null 2>&1 || as_root docker info >/dev/null 2>&1 \
    || die "The Docker daemon is not running. Start it with: sudo systemctl start docker"

  if ! as_root docker image inspect "${WEBUI_IMAGE}" >/dev/null 2>&1; then
    net_guard "Pulling the Open WebUI image"
  fi
  info "Pulling ${WEBUI_IMAGE} (uses the cached image if offline)..."
  as_root docker pull "${WEBUI_IMAGE}" || warn "Could not pull the image — will try the locally cached copy."

  if as_root docker container inspect "${WEBUI_CONTAINER}" >/dev/null 2>&1; then
    info "Recreating existing container '${WEBUI_CONTAINER}' with current .env settings..."
    as_root docker rm -f "${WEBUI_CONTAINER}" >/dev/null
  fi

  local base_url
  base_url="$(ollama_url)"
  info "Starting Open WebUI on port ${WEBUI_PORT} (Ollama at ${base_url}, signup=${WEBUI_ENABLE_SIGNUP})..."
  as_root docker run -d \
    --name "${WEBUI_CONTAINER}" \
    --network=host \
    -e OLLAMA_BASE_URL="${base_url}" \
    -e PORT="${WEBUI_PORT}" \
    -e ENABLE_SIGNUP="${WEBUI_ENABLE_SIGNUP}" \
    -v open-webui:/app/backend/data \
    --restart unless-stopped \
    "${WEBUI_IMAGE}" >/dev/null

  local running
  running="$(as_root docker inspect -f '{{.State.Running}}' "${WEBUI_CONTAINER}" 2>/dev/null || echo false)"
  [[ "${running}" == "true" ]] || die "Container '${WEBUI_CONTAINER}' is not running. Logs: sudo docker logs ${WEBUI_CONTAINER}"

  info "Waiting for Open WebUI to answer on http://127.0.0.1:${WEBUI_PORT} (first start can take ~1 minute)..."
  wait_for_webui 180 \
    || die "Open WebUI did not answer after 180s. Logs: sudo docker logs ${WEBUI_CONTAINER}"
  ok "Open WebUI is up on port ${WEBUI_PORT}."
  info "From your phone (with Tailscale connected): http://<tailscale-ip>:${WEBUI_PORT} — see docs/PHONE.md"
}

main "$@"
