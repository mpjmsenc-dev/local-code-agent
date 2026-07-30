#!/usr/bin/env bash
# update-model.sh — switch the default model safely:
#   pull → verify present → validate with a real generation → only then
#   commit MODEL_NAME to .env. Optionally remove the old default afterwards.
#
# Pinning a model manually implies AUTO_TUNE=false (set for you, announced),
# otherwise the next boot's auto-tune would override your choice.
#
# Usage:
#   update-model.sh --list                 show installed models
#   update-model.sh MODEL [--remove-old]   switch default to MODEL
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/scripts/lib.sh"
load_env

usage() {
  cat <<EOF
Usage: update-model.sh <model> [--remove-old]
       update-model.sh --list

Examples:
  update-model.sh qwen2.5-coder:14b
  update-model.sh qwen2.5-coder:32b --remove-old
EOF
}

main() {
  local new_model="" remove_old=false arg
  for arg in "$@"; do
    case "${arg}" in
      --list)
        require_cmd ollama
        info "Installed models:"
        ollama list
        exit 0
        ;;
      --remove-old) remove_old=true ;;
      -h|--help) usage; exit 0 ;;
      -*) usage; die "Unknown option: ${arg}" ;;
      *)
        [[ -z "${new_model}" ]] || { usage; die "Only one model may be given."; }
        new_model="${arg}"
        ;;
    esac
  done
  [[ -n "${new_model}" ]] || { usage; exit 1; }

  require_cmd ollama curl jq
  step "Switching default model to '${new_model}'"

  if ! wait_for_ollama 5; then
    # can_root guard: as_root die()s (exits) with neither root nor sudo, and
    # '|| true' cannot catch an exit — the script would abort here instead of
    # falling through to the clear "API not reachable" message below.
    if systemd_available && can_root; then
      info "Ollama is not answering — starting the service..."
      as_root systemctl start ollama || true
    fi
    wait_for_ollama 60 || die "Ollama API is not reachable at $(ollama_url)."
  fi

  local old_model="${MODEL_NAME}"
  if [[ "${new_model}" == "${old_model}" ]]; then
    info "'${new_model}' is already the default — verifying it anyway."
  fi

  if model_present "${new_model}"; then
    ok "Model '${new_model}' is already downloaded."
  else
    net_guard "Downloading ${new_model}"
    pull_model "${new_model}" || die "Pull failed — MODEL_NAME is unchanged (still ${old_model})."
    model_present "${new_model}" || die "'${new_model}' still not present after pull — MODEL_NAME is unchanged."
  fi

  info "Validating '${new_model}' with a real generation (first load can take a while)..."
  if ! model_responds "${new_model}"; then
    die "'${new_model}' did not produce a response — MODEL_NAME is unchanged (still ${old_model}). Does this machine have enough RAM for it?"
  fi
  ok "'${new_model}' validated."

  set_env_var MODEL_NAME "${new_model}"
  ok "Default model is now '${new_model}'."

  if [[ "${AUTO_TUNE}" == "true" ]]; then
    set_env_var AUTO_TUNE false
    warn "AUTO_TUNE has been set to false — a manual pin would otherwise be overridden by auto-tune on the next boot."
    info "Re-enable spec-based auto selection anytime with: AUTO_TUNE=true in .env, then scripts/tune.sh"
  fi

  if [[ "${remove_old}" == "true" && "${old_model}" != "${new_model}" ]]; then
    if model_present "${old_model}"; then
      if confirm "Remove the previous default '${old_model}' from disk?"; then
        ollama rm "${old_model}"
        ok "Removed '${old_model}'."
      else
        info "Keeping '${old_model}' on disk."
      fi
    else
      info "Previous default '${old_model}' is not on disk — nothing to remove."
    fi
  fi

  info "aider and Open WebUI pick the new default up automatically (WebUI may need: ./webui.sh restart)."
}

main "$@"
