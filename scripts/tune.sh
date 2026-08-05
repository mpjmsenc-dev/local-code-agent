#!/usr/bin/env bash
# scripts/tune.sh — auto-tune the stack to this machine's RAM.
#
# This is the "resize the droplet and it adapts" feature: detect total RAM,
# pick the best model + context length from the ladder below, and apply it.
# A systemd oneshot (installed with --install-service) re-runs this on every
# boot, so a DigitalOcean resize or hypervisor spec change self-adapts.
#
# Ladder (RAM in GiB, rounded to nearest) — sizes come from MODEL_FAMILY in
# .env, so the same rungs work for any supported family:
#     < 9   <family>:small   ctx  4096
#    9-15   <family>:mid     ctx  8192
#   16-23   <family>:big     ctx  8192
#    >=24   <family>:big     ctx 16384   (larger sizes remain a manual choice)
# Default family qwen2.5-coder => 3b / 7b / 14b.
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
  local target="$1" m order="" fam small mid big
  fam="$(model_family)"
  read -r small mid big <<<"$(family_sizes "${fam}")"
  case "${target}" in
    *:"${big}") order="${fam}:${big} ${fam}:${mid} ${fam}:${small}" ;;
    *:"${mid}") order="${fam}:${mid} ${fam}:${small}" ;;
    *)          order="${fam}:${small}" ;;
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
# model_family — the family auto-tune picks from (MODEL_FAMILY in .env).
# Falls back to the default rather than inventing a tag, so a typo cannot make
# tune.sh try to pull something that does not exist.
model_family() {
  local fam="${MODEL_FAMILY:-qwen2.5-coder}"
  family_sizes "${fam}" >/dev/null 2>&1 || fam="qwen2.5-coder"
  printf '%s\n' "${fam}"
}

# family_sizes FAMILY — echo "SMALL MID BIG": the tags this family publishes for
# the three RAM rungs. Adding a family here is all it takes to support it.
# Sizes are the Ollama tags; each must exist for that family.
family_sizes() {
  # Every size here must RUN on the rung that selects it. The ladder's top rung
  # starts at 16 GiB, so "big" has to fit in ~16 GiB of RAM at q4 — roughly
  # 0.6 GB per billion parameters plus the context. Anything larger (llama3.1
  # 70b needs ~40 GB, codellama 34b ~19 GB) stays a MANUAL choice via
  # update-model.sh, because auto-tune pulling tens of GB and then OOMing on
  # first use is far worse than picking a smaller model that works.
  case "$1" in
    qwen2.5-coder)     printf '3b 7b 14b\n' ;;
    qwen3)             printf '4b 8b 14b\n' ;;
    deepseek-coder-v2) printf '16b 16b 16b\n' ;;   # only one practical size
    llama3.1)          printf '8b 8b 8b\n' ;;      # 70b/405b: manual only
    codellama)         printf '7b 13b 13b\n' ;;    # 34b: manual only
    *) return 1 ;;
  esac
}

# model_fits_ram TAG RAM_GIB — rough q4 sizing: ~0.6 GB per billion parameters
# plus ~1 GB for context and overhead. Deliberately approximate; its only job is
# to stop the ladder selecting something that cannot possibly load. An
# unparseable tag returns true, so an unusual naming scheme is never blocked.
model_fits_ram() {
  local tag="${1##*:}" ram="$2" params
  params="${tag%[bB]}"
  [[ "${params}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 0
  awk -v p="${params}" -v r="${ram}" 'BEGIN{ exit !(p * 0.6 + 1 <= r) }'
}

choose_for_ram() {
  local ram="$1" fam small mid big
  fam="$(model_family)"
  read -r small mid big <<<"$(family_sizes "${fam}")"
  # Some families have no small size at all (deepseek-coder-v2 ships only 16b).
  # On a machine that cannot hold it, silently pulling ~10 GB and then OOMing on
  # first use is the worst outcome; fall back to a family that does fit and say
  # so, rather than honouring MODEL_FAMILY into a wall.
  if ! model_fits_ram "${fam}:${small}" "${ram}"; then
    warn "MODEL_FAMILY=${fam} has no size that fits ${ram} GiB (smallest is ${small}) — falling back to qwen2.5-coder. Pin it manually with 'lca model <name>' if you have the RAM."
    fam="qwen2.5-coder"
    read -r small mid big <<<"$(family_sizes "${fam}")"
  fi
  if (( ram < 9 )); then
    TUNE_MODEL="${fam}:${small}"
    TUNE_CTX=4096
  elif (( ram <= 15 )); then
    TUNE_MODEL="${fam}:${mid}"
    TUNE_CTX=8192
  elif (( ram <= 23 )); then
    TUNE_MODEL="${fam}:${big}"
    TUNE_CTX=8192
  else
    TUNE_MODEL="${fam}:${big}"
    TUNE_CTX=16384
  fi
}

install_service() {
  if ! systemd_available; then
    warn "systemd is not available here — skipping the on-boot auto-tune service. Run 'lca tune' manually after spec changes."
    return 0
  fi
  info "Installing on-boot auto-tune service (${TUNE_SERVICE})..."
  {
    echo "[Unit]"
    echo "Description=local-code-agent auto-tune (adapt model to current RAM)"
    echo "Wants=network-online.target"
    # docker.service too, now that a model change reconciles the chat app
    # container: ordered after network and Ollama alone, this ran while the
    # Docker daemon was still starting, apply.sh correctly reported it could
    # not look, and the container kept the old model until someone noticed.
    # 'After=' on a unit that does not exist is a no-op, so a SKIP_DOCKER box
    # is unaffected — and it is deliberately not Wants=, because this must not
    # pull Docker onto a machine that chose not to have it.
    echo "After=network-online.target ollama.service docker.service"
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
    -h|--help)
      # The header block above is the help text.
      sed -n '2,/^[^#]/p' "${BASH_SOURCE[0]}" | grep '^#' | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      die "Unknown option: ${1} — usage: lca tune [--dry-run]  (see: lca tune --help)"
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
      info "AUTO_TUNE is '${AUTO_TUNE}', not 'true' — a real run would keep the manual pin and change nothing."
    elif [[ "${TUNE_MODEL}" == "${MODEL_NAME}" && "${TUNE_CTX}" == "${OLLAMA_CONTEXT_LENGTH}" ]]; then
      info "Already tuned — a real run would change nothing."
    else
      info "A real run would switch to model=${TUNE_MODEL} context=${TUNE_CTX}."
    fi
    ok "Dry run complete; nothing was changed."
    exit 0
  fi

  if [[ "${AUTO_TUNE}" != "true" ]]; then
    # AUTO_TUNE=false means "do not re-pick the model from RAM". It does NOT
    # mean "ignore .env" — the pinned settings still have to reach the running
    # service. Without this, editing OLLAMA_KEEP_ALIVE (which .env.example
    # explicitly invites: "set this to -1 to keep the model resident") or
    # OLLAMA_CONTEXT_LENGTH changed nothing, forever, with nothing said. And
    # 'lca model' sets AUTO_TUNE=false for you, so this is the state anyone
    # who pinned a model is in.
    if resync_dropin_if_drifted; then
      ok "Applied your pinned settings: ${MODEL_NAME} (ctx ${OLLAMA_CONTEXT_LENGTH}, keep-alive ${OLLAMA_KEEP_ALIVE})."
      exit 0
    fi
    ok "AUTO_TUNE=false — keeping your manual pin: ${MODEL_NAME} (ctx ${OLLAMA_CONTEXT_LENGTH}). Nothing to do."
    exit 0
  fi

  # "Already tuned" has to mean the model is ON DISK, not merely named in .env.
  # Two exits above write .env before anything is pulled — when Ollama is not
  # installed yet, and when its API cannot be reached on a host without systemd
  # — and both tell the reader to re-run tune. Trusting .env alone made that
  # re-run answer "Already tuned ... Nothing to do" and fetch nothing, so the
  # advice this script gives about itself could never work: .env names a model
  # that is not there, and 'lca ask' and 'lca speed' then fail on it.
  if [[ "${TUNE_MODEL}" == "${MODEL_NAME}" && "${TUNE_CTX}" == "${OLLAMA_CONTEXT_LENGTH}" ]] \
     && { ! have ollama || model_present "${MODEL_NAME}"; }; then
    # .env already matches the ladder — but an earlier run may have written
    # .env and then been interrupted before re-rendering the drop-in, leaving
    # the running service on stale settings that the .env-only check can't
    # see. Re-converge the applied state if it drifted, then finish.
    if resync_dropin_if_drifted; then
      ok "Re-synced Ollama to ${MODEL_NAME} (ctx ${OLLAMA_CONTEXT_LENGTH})."
      exit 0
    fi
    ok "Already tuned for this machine (${MODEL_NAME}, ctx ${OLLAMA_CONTEXT_LENGTH}). Nothing to do."
    exit 0
  fi

  if ! have ollama; then
    # Called before Ollama exists (or on a stripped-down box): record the
    # decision so setup.sh's model-pull step uses it, and stop there.
    write_env_or_die MODEL_NAME "${TUNE_MODEL}"
    write_env_or_die OLLAMA_CONTEXT_LENGTH "${TUNE_CTX}" \
      "MODEL_NAME was written but the context length was not, so .env is half-tuned; set OLLAMA_CONTEXT_LENGTH=${TUNE_CTX} by hand or re-run 'lca tune' once there is room."
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
      write_env_or_die MODEL_NAME "${TUNE_MODEL}"
      write_env_or_die OLLAMA_CONTEXT_LENGTH "${TUNE_CTX}" \
        "MODEL_NAME was written but the context length was not, so .env is half-tuned; set OLLAMA_CONTEXT_LENGTH=${TUNE_CTX} by hand or re-run 'lca tune' once there is room."
      warn "Ollama API is not reachable and there is no systemd here — wrote tuned values to .env. Start it ('OLLAMA_HOST=${OLLAMA_HOST} ollama serve') and re-run 'lca tune' to apply."
      exit 0
    fi
    die "Ollama API is not reachable at $(ollama_url). Try: sudo systemctl restart ollama — then re-run 'lca tune'."
  fi

  # Nothing is persisted to .env or applied to the service until AFTER the
  # (optional) model validation below, so a validation failure leaves .env,
  # the drop-in and the running service consistent — never a phantom context.
  local old_model="${MODEL_NAME}" old_ctx="${OLLAMA_CONTEXT_LENGTH}"
  local chosen_model="${TUNE_MODEL}" validate=false
  # Not just "the name changed": a model that is already named in .env but
  # missing from disk has to be fetched too, or the fast path above would be
  # the only thing that could have pulled it — and it cannot.
  if [[ "${TUNE_MODEL}" != "${MODEL_NAME}" ]] || ! model_present "${TUNE_MODEL}"; then
    if [[ "${TUNE_MODEL}" != "${MODEL_NAME}" ]]; then
      info "Model change: ${MODEL_NAME} -> ${TUNE_MODEL}"
    else
      info "'${TUNE_MODEL}' is the right model for this machine but is not downloaded — fetching it."
    fi
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
        warn "netmode is OFFLINE and no fitting model is downloaded — will lower context to ${TUNE_CTX} but keep ${MODEL_NAME}. Run 'sudo ${SCRIPT_DIR%/scripts}/netmode.sh online' then 'lca tune' to finish."
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
    # Before render_ollama_dropin on purpose: if .env cannot be written, the
    # drop-in must not be either, or Ollama would run settings .env does not
    # name and every drift check would disagree with itself from then on.
    write_env_or_die MODEL_NAME "${chosen_model}"
    write_env_or_die OLLAMA_CONTEXT_LENGTH "${TUNE_CTX}" \
      "MODEL_NAME was written but the context length was not; Ollama has NOT been restarted, so nothing is running settings .env does not name. Re-run 'lca tune' once there is room."
    render_ollama_dropin
    restart_ollama
    if [[ "${old_model}" != "${chosen_model}" ]]; then
      info "Old model '${old_model}' was kept on disk as a rollback (remove with: ollama rm ${old_model})."
      # "Auto-tune applied" was applied to Ollama and to nothing else. The chat
      # app is created with '-e DEFAULT_MODELS=', and a container's environment
      # is fixed for its lifetime, so after a droplet resize — the headline
      # reason this runs on every boot — the phone went on offering the OLD
      # model while .env, the drop-in and this very line all said the new one.
      # Only 'lca check' knew, and only if someone ran it.
      #
      # Reconciled rather than reported, because nobody is watching a boot
      # oneshot. apply.sh is drift-driven, so the drop-in this function just
      # rendered costs nothing there, and it degrades on its own when docker is
      # down or root is unavailable instead of failing a boot.
      # The 'ok' goes FIRST and the reconciliation after it, so the last thing
      # printed is whichever is true. Ordered the other way, a failed
      # reconciliation warned and was then immediately followed by "Auto-tune
      # applied" — which is true of the tune and reads as the final word on the
      # whole thing.
      ok "Auto-tune applied: ${chosen_model} with a ${TUNE_CTX}-token context."
      if ! "${SCRIPT_DIR}/apply.sh"; then
        warn "…but the rest of the system could not be reconciled with it — the chat app may still offer '${old_model}'. Fix it with: sudo ${REPO_ROOT}/bin/lca apply"
      fi
    else
      ok "Auto-tune applied: context ${TUNE_CTX}; model unchanged (${chosen_model})."
    fi
  else
    ok "Already at the best-available config (${chosen_model}, ctx ${TUNE_CTX}); nothing to apply."
  fi

  # Last, after any restart_ollama above — a restart drops whatever is loaded,
  # so warming before it would be wasted. This is what makes the first message
  # after a reboot fast; see warm_model() for why it is detached.
  warm_model "${chosen_model}"
}

# Run main only when executed, so tests can source this file and unit-test
# choose_for_ram() directly.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
