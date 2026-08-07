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
Usage: lca model <model> [--remove-old]   (or update-model.sh directly)
       lca model --list               models already downloaded
       lca model --list-recommended   what fits THIS machine's RAM

Examples:
  lca model qwen2.5-coder:14b
  lca model qwen2.5-coder:32b --remove-old
EOF
}

# list_recommended — print each supported family's rung for this machine's RAM,
# marking what is already downloaded. Uses tune.sh's ladder so this can never
# disagree with what auto-tune would actually choose.
list_recommended() {
  local ram fam small mid big pick note
  ram="$(detect_ram_gib)"
  step "What each family gives you on this machine (${ram} GiB RAM detected)"
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
    # model_fits_ram is tune.sh's own sizing check, and it rejects some of these
    # rungs outright — deepseek-coder-v2:16b and codellama:13b on an 8 GiB box.
    # Listing them under a heading that said "Models that fit this machine" was
    # a straight contradiction of the code one function away: auto-tune would
    # refuse them and fall back to qwen2.5-coder.
    note=""
    if ! model_fits_ram "${pick}" "${ram}"; then
      note="  (too big for ${ram} GiB — auto-tune would fall back to qwen2.5-coder)"
    elif have ollama && model_present "${pick}"; then
      note="  (already downloaded)"
    fi
    printf '  %-22s -> %s%s\n' "${fam}" "${pick}" "${note}"
  done
  info "Switch with:  lca model <model>   (pins it, disables auto-tune)"
  info "Or keep auto-tune and set MODEL_FAMILY=<family> in .env, then: lca tune"
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

  # Sized BEFORE the download, not after it. choose_for_ram already refuses to
  # auto-pick something this machine cannot hold, and says why in its own
  # comment — "silently pulling ~10 GB and then OOMing on first use is the worst
  # outcome". The manual pin, which is the path where a person types a size by
  # hand and is therefore the likeliest place to overreach, had no such check:
  # 'lca model qwen2.5-coder:32b' on a 16 GiB box pulled ~20 GB over a VPS line
  # and only then failed model_responds with "Does this machine have enough RAM
  # for it?" — a question the code could have answered before the first byte.
  #
  # pull_model already does this for DISK ("Asked BEFORE the download, not after
  # it"). This is the same guarantee for RAM, using the ladder's own rule rather
  # than a second copy of it, and an unparseable tag returns "fits" so an
  # unusual naming scheme is never turned into a refusal.
  #
  # A warning, not a refusal: the machine may be about to be resized, and the
  # person typed a specific model on purpose.
  local ram
  ram="$(detect_ram_gib)"
  if ! model_fits_ram "${new_model}" "${ram}"; then
    warn "'${new_model}' looks too big for ${ram} GiB of RAM (roughly 0.6 GB per billion parameters, plus about 1 GB). It will most likely fail to load, or thrash. 'lca model --list-recommended' shows what fits."
    confirm "Continue anyway?" \
      || die "Cancelled — nothing was downloaded and MODEL_NAME is unchanged (still ${old_model})."
  fi

  if model_present "${new_model}"; then
    ok "Model '${new_model}' is already downloaded."
  else
    net_guard "Downloading ${new_model}"
    pull_model "${new_model}" || die "Pull failed — MODEL_NAME is unchanged (still ${old_model})."
    model_present "${new_model}" || die "'${new_model}' still not present after pull — MODEL_NAME is unchanged."
  fi

  info "Validating '${new_model}' with a real generation. It is loaded first, which on a CPU-only box has been measured at up to 5 minutes..."
  if ! model_responds "${new_model}"; then
    die "'${new_model}' did not produce a response — MODEL_NAME is unchanged (still ${old_model}). $(model_silence_reason)"
  fi
  ok "'${new_model}' validated."

  write_env_or_die MODEL_NAME "${new_model}" \
    "'${new_model}' is downloaded and working — only the .env line naming it as the default did not change, so the old ${old_model} is still what starts."
  ok "Default model is now '${new_model}'."

  if [[ "${AUTO_TUNE}" == "true" ]]; then
    # The one write here whose failure is worse than not having tried:
    # MODEL_NAME has just landed, and without AUTO_TUNE=false beside it the
    # next boot re-picks a model from RAM and silently undoes the pin.
    write_env_or_die AUTO_TUNE false \
      "MODEL_NAME was written but AUTO_TUNE was not, so auto-tune will override your choice on the next boot — set AUTO_TUNE=false in .env by hand once there is room."
    warn "AUTO_TUNE has been set to false — a manual pin would otherwise be overridden by auto-tune on the next boot."
    info "Re-enable spec-based auto selection anytime with: AUTO_TUNE=true in .env, then ${SCRIPT_DIR}/scripts/tune.sh"
  fi

  if [[ "${remove_old}" == "true" && "${old_model}" != "${new_model}" ]]; then
    if model_present "${old_model}"; then
      if confirm "Remove the previous default '${old_model}' from disk?"; then
        # Reported, not fatal. A bare 'ollama rm' under set -e ends the script
        # HERE — after MODEL_NAME and AUTO_TUNE have both been written, and
        # before the two lines below that say the chat app is still running the
        # old model and needs 'lca apply'. Failing to reclaim some disk would
        # have silently swallowed the one instruction this command exists to
        # give, on the run where the user asked for the most to happen.
        if ollama rm "${old_model}"; then
          ok "Removed '${old_model}'."
        else
          warn "Could not remove '${old_model}' — it is still on disk. The switch itself is done. Retry with: ollama rm ${old_model}"
        fi
      else
        info "Keeping '${old_model}' on disk."
      fi
    else
      info "Previous default '${old_model}' is not on disk — nothing to remove."
    fi
  fi

  # aider does read .env on every run, so that half is true. The chat app does
  # not: MODEL_NAME is baked in at creation as '-e DEFAULT_MODELS=', and a
  # container's environment is fixed for its lifetime — 'webui.sh restart' is
  # stop+start of the SAME container and cannot change it. This line sent
  # people to a command that could not do what it promised, while webui_drift
  # listed MODEL_NAME, 'lca check' reported it, and both of them said 'lca
  # apply'. Three surfaces, one of them wrong, on the one setting this script
  # exists to change.
  info "aider picks the new default up on its own — it reads .env on every run."
  if [[ "${ENABLE_WEBUI}" == "true" && "${SKIP_DOCKER}" != "true" ]]; then
    info "The chat app does not: it was created with the old model baked in, and only re-creating it changes that. Apply it with: sudo ${REPO_ROOT}/bin/lca apply"
  fi
}

main "$@"
