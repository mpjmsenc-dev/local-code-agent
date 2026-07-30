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

# largest_present_within TARGET — echo the largest already-downloaded
# qwen2.5-coder ladder model no larger than TARGET, or nothing (exit 1).
# Used to downgrade safely when a pull is impossible (offline / no network).
largest_present_within() {
  local target="$1" m order=""
  case "${target}" in
    *:14b) order="qwen2.5-coder:14b qwen2.5-coder:7b qwen2.5-coder:3b" ;;
    *:7b)  order="qwen2.5-coder:7b qwen2.5-coder:3b" ;;
    *)     order="qwen2.5-coder:3b" ;;
  esac
  for m in ${order}; do
    if model_present "${m}"; then
      printf '%s\n' "${m}"
      return 0
    fi
  done
  return 1
}

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
    echo "ExecStart=\"${SCRIPT_DIR}/tune.sh\""
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
    # .env already matches the ladder — but an earlier run may have written
    # .env and then been interrupted before re-rendering the drop-in, leaving
    # the running service on stale settings that the .env-only check can't
    # see. Re-converge the applied state if it drifted, then finish.
    if have ollama && systemd_available && ! ollama_dropin_matches; then
      warn "Config drift: the ollama drop-in does not match .env — re-rendering and restarting to re-sync."
      render_ollama_dropin
      restart_ollama
      ok "Re-synced Ollama to ${MODEL_NAME} (ctx ${OLLAMA_CONTEXT_LENGTH})."
      exit 0
    fi
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

  # jq is needed for the real-generation validation below.
  require_cmd jq

  # Make sure the server is up before pulling/validating (starts it via systemd
  # or, on a systemd-less host, a detached `ollama serve`).
  if ! ensure_ollama_up 60; then
    if ! systemd_available; then
      # No service manager and we couldn't bring the API up — record the
      # decision so it applies once Ollama is running, and degrade gracefully
      # instead of dying with a systemctl hint that cannot work here.
      set_env_var MODEL_NAME "${TUNE_MODEL}"
      set_env_var OLLAMA_CONTEXT_LENGTH "${TUNE_CTX}"
      warn "Ollama API is not reachable and there is no systemd here — wrote tuned values to .env. Start it ('OLLAMA_HOST=${OLLAMA_HOST} ollama serve') and re-run tune.sh to apply."
      exit 0
    fi
    die "Ollama API is not reachable at $(ollama_url). Try: sudo systemctl restart ollama — then re-run tune.sh."
  fi

  # Nothing is persisted to .env or applied to the service until AFTER the
  # (optional) model validation below, so a validation failure leaves .env,
  # the drop-in and the running service consistent — never a phantom context.
  local old_model="${MODEL_NAME}" old_ctx="${OLLAMA_CONTEXT_LENGTH}"
  local chosen_model="${TUNE_MODEL}" validate=false
  if [[ "${TUNE_MODEL}" != "${MODEL_NAME}" ]]; then
    info "Model change: ${MODEL_NAME} -> ${TUNE_MODEL}"
    if model_present "${TUNE_MODEL}"; then
      validate=true
    elif [[ "$(netmode_state)" == "offline" ]]; then
      # Can't download while the kill switch is engaged. On a downgrade we
      # must NOT keep a too-big model live (it will OOM), so fall back to the
      # largest model already on disk that fits this RAM tier.
      if chosen_model="$(largest_present_within "${TUNE_MODEL}")"; then
        warn "netmode is OFFLINE — cannot pull ${TUNE_MODEL}; using already-downloaded ${chosen_model} for this RAM tier."
      else
        chosen_model="${MODEL_NAME}"
        warn "netmode is OFFLINE and no fitting model is downloaded — will lower context to ${TUNE_CTX} but keep ${MODEL_NAME}. Run 'sudo ${SCRIPT_DIR%/scripts}/netmode.sh online' then tune.sh to finish."
      fi
    else
      # Online: try for the ideal model. A persistent failure falls back to
      # the best already-present model; the next boot re-attempts the pull.
      if pull_model "${TUNE_MODEL}"; then
        validate=true
      else
        warn "Could not pull ${TUNE_MODEL} — falling back to the best already-downloaded model."
        chosen_model="$(largest_present_within "${TUNE_MODEL}" || true)"
        [[ -n "${chosen_model}" ]] || chosen_model="${MODEL_NAME}"
      fi
    fi
  fi

  if [[ "${validate}" == "true" ]]; then
    info "Validating ${chosen_model} with a real generation (first load can take a minute)..."
    if ! model_responds "${chosen_model}"; then
      die "${chosen_model} did not produce a response — nothing changed (still ${old_model}, ctx ${old_ctx}). Check RAM headroom with: free -h"
    fi
    ok "${chosen_model} validated."
  fi

  # Apply only if something actually changed. When the ladder's target model
  # is unobtainable (offline with no fallback, or a persistently failing
  # pull) chosen_model stays == old_model; without this guard the on-boot
  # oneshot would re-render the identical drop-in and restart Ollama every
  # boot (dropping the loaded model + a ~90s wait) for zero config change.
  MODEL_NAME="${chosen_model}"
  OLLAMA_CONTEXT_LENGTH="${TUNE_CTX}"
  if [[ "${chosen_model}" != "${old_model}" || "${old_ctx}" != "${TUNE_CTX}" ]] || ! ollama_dropin_matches; then
    set_env_var MODEL_NAME "${chosen_model}"
    set_env_var OLLAMA_CONTEXT_LENGTH "${TUNE_CTX}"
    render_ollama_dropin
    restart_ollama
    if [[ "${old_model}" != "${chosen_model}" ]]; then
      info "Old model '${old_model}' was kept on disk as a rollback (remove with: ollama rm ${old_model})."
      ok "Auto-tune applied: ${chosen_model} with a ${TUNE_CTX}-token context."
    else
      ok "Auto-tune applied: context ${TUNE_CTX}; model unchanged (${chosen_model})."
    fi
  else
    ok "Already at the best-available config (${chosen_model}, ctx ${TUNE_CTX}); nothing to apply."
  fi
}

# Run main only when executed, so tests can source this file and unit-test
# choose_for_ram() directly.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
