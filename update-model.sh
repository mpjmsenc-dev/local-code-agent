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
       update-model.sh --list               models already downloaded
       update-model.sh --list-recommended   what fits THIS machine's RAM

Examples:
  update-model.sh qwen2.5-coder:14b
  update-model.sh qwen2.5-coder:32b --remove-old
EOF
}

# list_recommended — print each supported family's rung for this machine's RAM,
# marking what is already downloaded. Uses tune.sh's ladder so this can never
# disagree with what auto-tune would actually choose.
list_recommended() {
  local ram fam small mid big pick note
  ram="$(detect_ram_gib)"
  step "Models that fit this machine (${ram} GiB RAM detected)"
  # Sourcing tune.sh recomputes SCRIPT_DIR from its own location, repointing
  # ours at scripts/. Harmless today because this function exits straight
  # after, but restoring it keeps the next edit from inheriting a landmine.
  local saved_dir="${SCRIPT_DIR}"
  # shellcheck source=scripts/tune.sh
  source "${SCRIPT_DIR}/scripts/tune.sh"
  SCRIPT_DIR="${saved_dir}"
  for fam in qwen2.5-coder qwen3 deepseek-coder-v2 llama3.1 codellama; do
    read -r small mid big <<<"$(family_sizes "${fam}")"
    if   (( ram < 9 ));  then pick="${fam}:${small}"
    elif (( ram <= 15 )); then pick="${fam}:${mid}"
    else                      pick="${fam}:${big}"
    fi
    note=""
    if have ollama && model_present "${pick}"; then note="  (already downloaded)"; fi
    printf '  %-22s -> %s%s\n' "${fam}" "${pick}" "${note}"
  done
  info "Switch with:  update-model.sh <model>   (pins it, disables auto-tune)"
  info "Or keep auto-tune and set MODEL_FAMILY=<family> in .env, then: ${SCRIPT_DIR}/scripts/tune.sh"
}

main() {
  local new_model="" remove_old=false arg
  for arg in "$@"; do
    case "${arg}" in
      --list)
        require_cmd ollama
        # Without this the raw client error surfaces — "could not connect to
        # ollama server, run 'ollama serve' to start it" — which is the wrong
        # instruction on a systemd box, where the server is a managed service.
        if ! wait_for_ollama 2 >/dev/null 2>&1; then
          ensure_ollama_up_announced 30 \
            || die "Ollama is not answering at $(ollama_url), so its models cannot be listed. Try: lca check"
        fi
        info "Installed models:"
        ollama list
        exit 0
        ;;
      --list-recommended)
        # Pulling a model is several GB and many minutes; knowing beforehand
        # which sizes actually fit this machine is cheaper than finding out
        # when it OOMs or thrashes.
        list_recommended
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

  # Same shape run-agent.sh had: announced only on the systemd-with-root path,
  # and on every other host a bare 60-second poll for a server nothing was
  # starting. ensure_ollama_up_announced starts it either way — the systemd
  # service where there is one, a background server otherwise — says so while
  # it happens, and stays silent when Ollama is already up.
  ensure_ollama_up_announced 60 \
    || die "Ollama API is not reachable at $(ollama_url). Check: ${REPO_ROOT}/check-system.sh"

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
    info "Re-enable spec-based auto selection anytime with: AUTO_TUNE=true in .env, then ${SCRIPT_DIR}/scripts/tune.sh"
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

  info "aider and Open WebUI pick the new default up automatically (WebUI may need: ${SCRIPT_DIR}/webui.sh restart)."
}

main "$@"
