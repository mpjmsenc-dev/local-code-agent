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

  # With --network=host the container binds ${WEBUI_PORT} directly. If another
  # process already holds it, Open WebUI's backend can't bind and crash-loops
  # under --restart unless-stopped — but a squatter answering the port would
  # still make our health probe pass and print a false success. Refuse up
  # front with a clear message. (Our own old container was removed just above.)
  if have ss && ss -ltn 2>/dev/null | grep -qE ":${WEBUI_PORT}[[:space:]]"; then
    die "Port ${WEBUI_PORT} is already in use by another process. Change WEBUI_PORT in .env and re-run scripts/install_webui.sh, or stop the other service. See docs/TROUBLESHOOTING.md (Port ${WEBUI_PORT} / WebUI port already in use)."
  fi

  # Open WebUI seeds these two settings from the environment only when the key
  # is NOT already in its database — Config.seed_defaults is explicit that
  # "Existing DB values take precedence over defaults". So they take effect on a
  # first install and are ignored on every later one. Note whether the data
  # volume already existed so we can say that out loud instead of letting a
  # .env edit look like it applied.
  local volume_existed=false
  if as_root docker volume inspect open-webui >/dev/null 2>&1; then
    volume_existed=true
  fi

  # Give the chat a system prompt and suggestions that fit a private coding
  # assistant. Stock Open WebUI ships neither: no system prompt at all, and
  # starter prompts about vocabulary exams and the Roman Empire.
  local params_env=() suggestions_env=()
  if have jq; then
    # -c keeps it on one line: an env value with embedded newlines is legal but
    # awkward to inspect with 'docker inspect' and easy to mangle in a log.
    params_env=( -e "DEFAULT_MODEL_PARAMS=$(lca_system_prompt | jq -Rsc '{system: .}')" )
    if [[ -r "${REPO_ROOT}/config/prompt-suggestions.json" ]] \
       && jq -e . "${REPO_ROOT}/config/prompt-suggestions.json" >/dev/null 2>&1; then
      suggestions_env=( -e "DEFAULT_PROMPT_SUGGESTIONS=$(jq -c . "${REPO_ROOT}/config/prompt-suggestions.json")" )
    fi
  else
    warn "jq is not installed — the chat will start without our system prompt and starter questions."
  fi

  local base_url
  base_url="$(ollama_url)"
  info "Starting Open WebUI on port ${WEBUI_PORT} (Ollama at ${base_url}, signup=${WEBUI_ENABLE_SIGNUP})..."
  # Telemetry opt-outs so the container does not phone home (matches the
  # privacy claim in docs/FAQ.md); host networking reaches loopback Ollama.
  as_root docker run -d \
    --name "${WEBUI_CONTAINER}" \
    --network=host \
    -e OLLAMA_BASE_URL="${base_url}" \
    -e PORT="${WEBUI_PORT}" \
    -e ENABLE_SIGNUP="${WEBUI_ENABLE_SIGNUP}" \
    -e DEFAULT_MODELS="${MODEL_NAME}" \
    -e WEBUI_NAME="${WEBUI_NAME}" \
    ${params_env[@]+"${params_env[@]}"} \
    ${suggestions_env[@]+"${suggestions_env[@]}"} \
    -e DO_NOT_TRACK=true \
    -e SCARF_NO_ANALYTICS=true \
    -e ANONYMIZED_TELEMETRY=false \
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

  if [[ "${volume_existed}" == "true" && ${#params_env[@]} -gt 0 ]]; then
    info "Existing chat data found, so Open WebUI keeps the settings already in its database."
    info "To change the assistant's default system prompt or starter questions now, edit them in the WebUI itself (Admin Panel → Settings)."
  fi

  # Open WebUI binds all interfaces (host networking). Apply the always-on
  # inbound guard so ${WEBUI_PORT} is reachable only over loopback and
  # Tailscale, never from a public IP — this is what makes the "never
  # exposed" guarantee in the docs actually true. Warn-only: a box without
  # nftables should still finish the install.
  "${REPO_ROOT}/netmode.sh" harden \
    || warn "Could not apply the inbound guard — ${WEBUI_PORT} may be publicly reachable. Run: sudo ${REPO_ROOT}/netmode.sh harden (needs nftables)."

  info "From your phone (with Tailscale connected): http://<tailscale-ip>:${WEBUI_PORT} — see docs/PHONE.md"
}

main "$@"
