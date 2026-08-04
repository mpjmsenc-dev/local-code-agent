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
    die "SKIP_DOCKER=true in .env — Open WebUI needs Docker. Set SKIP_DOCKER=false and re-run ${REPO_ROOT}/scripts/install_docker.sh first."
  fi
  have docker || die "Docker is not installed. Run ${REPO_ROOT}/scripts/install_docker.sh first (or ${REPO_ROOT}/setup.sh)."
  # lib.sh's probe, which checks can_root before reaching for sudo. Written
  # out here as '... || as_root docker info || die', the as_root fired on a
  # host with neither root nor sudo and died with "Root privileges needed for:
  # docker info" — pre-empting the message on the very next line, which is the
  # one that tells the reader what to actually do.
  docker_daemon_reachable \
    || die "The Docker daemon is not reachable. Start it with: sudo systemctl start docker (or re-run this as root if you cannot sudo)."

  if ! as_root docker image inspect "${WEBUI_IMAGE}" >/dev/null 2>&1; then
    net_guard "Pulling the Open WebUI image"
  fi
  info "Pulling ${WEBUI_IMAGE} (uses the cached image if offline)..."
  as_root docker pull "${WEBUI_IMAGE}" || warn "Could not pull the image — will try the locally cached copy."

  # With --network=host the container binds ${WEBUI_PORT} directly. If another
  # process already holds it, Open WebUI's backend can't bind and crash-loops
  # under --restart unless-stopped — but a squatter answering the port would
  # still make our health probe pass and print a false success. Refuse up
  # front with a clear message.
  #
  # Checked BEFORE the old container is removed. The removal used to come
  # first, so our own listener could not trip the check — at the cost that a
  # port held by anyone ELSE meant a working chat app was destroyed and then
  # not replaced, by the one command whose job is to replace it. Whose listener
  # it is can be decided without destroying anything: if our container is
  # running it is the one holding the port, and if it is not running then any
  # listener belongs to someone else.
  local webui_running=false
  if as_root docker container inspect -f '{{.State.Running}}' "${WEBUI_CONTAINER}" 2>/dev/null \
     | grep -q true; then
    webui_running=true
  fi
  # Captured, then matched against a here-string — never 'ss | grep -q'. Under
  # 'set -o pipefail' a grep that exits on its first match SIGPIPEs the producer
  # and the pipeline returns 141, which reads as "not found" precisely when it
  # WAS found. motd.sh records the same trap beside current_run_log, and CI's
  # own assertions are written this way for the same reason; the listening-socket
  # table is the one producer here big enough to still be writing when grep
  # leaves.
  #
  # The direction of that failure is what makes it worth the two lines: a
  # missed match means the port looks free, docker run --network=host cannot
  # bind, the container crash-loops under --restart unless-stopped, and the
  # squatter answers the health probe — the false success this whole block
  # exists to prevent.
  local listeners=""
  if [[ "${webui_running}" != "true" ]] && have ss; then
    listeners="$(ss -ltn 2>/dev/null || true)"
  fi
  if [[ -n "${listeners}" ]] && grep -qE ":${WEBUI_PORT}[[:space:]]" <<<"${listeners}"; then
    die "Port ${WEBUI_PORT} is already in use by another process, and the chat app container is NOT what is holding it. Nothing has been changed — your existing container is untouched. Change WEBUI_PORT in .env and re-run ${REPO_ROOT}/scripts/install_webui.sh, or stop the other service. See docs/TROUBLESHOOTING.md (Port ${WEBUI_PORT} / WebUI port already in use)."
  fi

  if as_root docker container inspect "${WEBUI_CONTAINER}" >/dev/null 2>&1; then
    info "Recreating existing container '${WEBUI_CONTAINER}' with current .env settings..."
    as_root docker rm -f "${WEBUI_CONTAINER}" >/dev/null
  fi

  # These two settings are read from the environment on every start. Open WebUI
  # registers them as its in-memory defaults and only prefers a database row if
  # one exists — which happens when the value is edited inside the WebUI. So a
  # change here applies on re-run, EXCEPT for a setting the user has since
  # changed in Admin Settings, which stays theirs.
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
    -e ENABLE_OPENAI_API=false \
    -e ENABLE_VERSION_UPDATE_CHECK=false \
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
    info "Existing chat data kept. The assistant's system prompt and starter questions come from here,"
    info "unless you have changed them in the WebUI (Admin Panel → Settings) — a value edited there wins."
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
