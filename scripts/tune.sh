#!/usr/bin/env bash
# scripts/tune.sh — auto-tune the stack to this machine's RAM.
#
# This is the "resize the droplet and it adapts" feature: detect total RAM,
# pick the best model + context length from the ladder below, and apply it.
# A systemd oneshot (installed with --install-service) re-runs this on every
# boot, so a DigitalOcean resize or hypervisor spec change self-adapts.
#
# Ladder (RAM in GiB, rounded to nearest):
#     < 9   qwen2.5-coder:3b   ctx  4096
#    9-15   qwen2.5-coder:7b   ctx  8192
#   16-23   qwen2.5-coder:14b  ctx  8192
#    >=24   qwen2.5-coder:14b  ctx 16384   (32b remains a manual choice)
#
# Usage:
#   tune.sh                  detect and apply
#   tune.sh --dry-run        print detection + decision, change nothing
#   tune.sh --install-service  install the on-boot systemd oneshot
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

TUNE_SERVICE=/etc/systemd/system/local-code-agent-tune.service

# choose_for_ram RAM_GIB — sets TUNE_MODEL and TUNE_CTX per the ladder.
choose_for_ram() {
  local ram="$1"
  if (( ram < 9 )); then
    TUNE_MODEL="qwen2.5-coder:3b"
    TUNE_CTX=4096
  elif (( ram <= 15 )); then
    TUNE_MODEL="qwen2.5-coder:7b"
    TUNE_CTX=8192
  elif (( ram <= 23 )); then
    TUNE_MODEL="qwen2.5-coder:14b"
    TUNE_CTX=8192
  else
    TUNE_MODEL="qwen2.5-coder:14b"
    TUNE_CTX=16384
  fi
}

install_service() {
  if ! systemd_available; then
    warn "systemd is not available here — skipping the on-boot auto-tune service. Run tune.sh manually after spec changes."
    return 0
  fi
  info "Installing on-boot auto-tune service (${TUNE_SERVICE})..."
  {
    echo "[Unit]"
    echo "Description=local-code-agent auto-tune (adapt model to current RAM)"
    echo "Wants=network-online.target"
    echo "After=network-online.target ollama.service"
    echo ""
    echo "[Service]"
    echo "Type=oneshot"
    echo "ExecStart=${SCRIPT_DIR}/tune.sh"
    echo ""
    echo "[Install]"
    echo "WantedBy=multi-user.target"
  } | as_root tee "${TUNE_SERVICE}" >/dev/null
  as_root systemctl daemon-reload
  as_root systemctl enable local-code-agent-tune.service >/dev/null 2>&1 \
    || die "Could not enable local-code-agent-tune.service — check: systemctl status local-code-agent-tune"
  ok "Auto-tune will re-run on every boot (resize adapts automatically)."
}

main() {
  local dry_run=false
  case "${1:-}" in
    "") ;;
    --dry-run) dry_run=true ;;
    --install-service)
      install_service
      exit 0
      ;;
    *)
      die "Usage: tune.sh [--dry-run|--install-service]"
      ;;
  esac

  load_env

  local ram
  ram="$(detect_ram_gib)"
  choose_for_ram "${ram}"

  step "Auto-tune: detected ${ram} GiB RAM"
  info "Ladder decision: model=${TUNE_MODEL}  context=${TUNE_CTX}"
  info "Current config:  model=${MODEL_NAME}  context=${OLLAMA_CONTEXT_LENGTH}  AUTO_TUNE=${AUTO_TUNE}"
  info "(More vCPUs need no tuning — Ollama automatically uses all cores.)"

  if [[ "${dry_run}" == "true" ]]; then
    if [[ "${AUTO_TUNE}" != "true" ]]; then
      info "AUTO_TUNE=false — a real run would keep the manual pin and change nothing."
    elif [[ "${TUNE_MODEL}" == "${MODEL_NAME}" && "${TUNE_CTX}" == "${OLLAMA_CONTEXT_LENGTH}" ]]; then
      info "Already tuned — a real run would change nothing."
    else
      info "A real run would switch to model=${TUNE_MODEL} context=${TUNE_CTX}."
    fi
    ok "Dry run complete; nothing was changed."
    exit 0
  fi

  if [[ "${AUTO_TUNE}" != "true" ]]; then
    ok "AUTO_TUNE=false — keeping your manual pin: ${MODEL_NAME} (ctx ${OLLAMA_CONTEXT_LENGTH}). Nothing to do."
    exit 0
  fi

  if [[ "${TUNE_MODEL}" == "${MODEL_NAME}" && "${TUNE_CTX}" == "${OLLAMA_CONTEXT_LENGTH}" ]]; then
    ok "Already tuned for this machine (${MODEL_NAME}, ctx ${OLLAMA_CONTEXT_LENGTH}). Nothing to do."
    exit 0
  fi

  if ! have ollama; then
    # Called before Ollama exists (or on a stripped-down box): record the
    # decision so setup.sh's model-pull step uses it, and stop there.
    set_env_var MODEL_NAME "${TUNE_MODEL}"
    set_env_var OLLAMA_CONTEXT_LENGTH "${TUNE_CTX}"
    warn "Ollama is not installed yet — wrote the tuned values to .env; setup.sh will pull ${TUNE_MODEL}."
    exit 0
  fi

  # Make sure the server is up before pulling/validating.
  if ! wait_for_ollama 5; then
    if systemd_available; then
      info "Ollama API not answering — starting the service..."
      as_root systemctl start ollama || true
    fi
    wait_for_ollama 60 || die "Ollama API is not reachable at $(ollama_url). Start it (sudo systemctl start ollama) and re-run tune.sh."
  fi

  local old_model="${MODEL_NAME}"
  if [[ "${TUNE_MODEL}" != "${MODEL_NAME}" ]]; then
    info "Model change: ${MODEL_NAME} -> ${TUNE_MODEL}"
    if ! model_present "${TUNE_MODEL}"; then
      net_guard "Downloading ${TUNE_MODEL}"
      pull_model "${TUNE_MODEL}" || die "Could not pull ${TUNE_MODEL}; keeping ${MODEL_NAME} unchanged."
    fi
    info "Validating ${TUNE_MODEL} with a real generation (first load can take a minute)..."
    if ! model_responds "${TUNE_MODEL}"; then
      die "${TUNE_MODEL} did not produce a response — keeping ${MODEL_NAME} unchanged. Check RAM headroom with: free -h"
    fi
    ok "${TUNE_MODEL} validated."
  fi

  # Commit the decision: .env first, then the systemd drop-in, then restart.
  set_env_var MODEL_NAME "${TUNE_MODEL}"
  set_env_var OLLAMA_CONTEXT_LENGTH "${TUNE_CTX}"
  MODEL_NAME="${TUNE_MODEL}"
  OLLAMA_CONTEXT_LENGTH="${TUNE_CTX}"
  render_ollama_dropin
  restart_ollama

  if [[ "${old_model}" != "${TUNE_MODEL}" ]]; then
    info "Old model '${old_model}' was kept on disk as a rollback (remove with: ollama rm ${old_model})."
  fi
  ok "Auto-tune applied: ${TUNE_MODEL} with a ${TUNE_CTX}-token context."
}

# Run main only when executed, so tests can source this file and unit-test
# choose_for_ram() directly.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
