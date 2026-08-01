#!/usr/bin/env bash
# run-agent.sh — start aider (the terminal coding agent) against the local
# Ollama model, from WHATEVER directory you are in. This script never cd's:
# aider must run inside YOUR project directory so it sees your files/git.
#
# Usage: cd ~/my-project && /opt/local-code-agent/run-agent.sh [aider args...]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/scripts/lib.sh"
load_env

main() {
  local aider
  aider="$(aider_bin)"
  [[ -x "${aider}" ]] || die "aider is not installed at ${aider}. Run: ${REPO_ROOT}/scripts/install_python.sh"
  require_cmd curl jq

  # Ollama must be up before aider starts. ensure_ollama_up_announced both
  # STARTS it — the systemd service where there is one and root to do it, a
  # background server otherwise — and says so while it happens.
  #
  # The old shape only announced on the systemd-with-root path, and on every
  # other host fell through to a bare 'wait_for_ollama 60': sixty seconds of
  # silence, polling for a server that nothing was starting, before advising
  # 'systemctl restart' on a machine with no systemd. That is this project's
  # headline command doing nothing, invisibly, and then giving instructions
  # that cannot work.
  if ! ensure_ollama_up_announced 60; then
    if systemd_available; then
      die "Ollama API is not reachable at $(ollama_url). Try: sudo systemctl restart ollama — then check: ${REPO_ROOT}/check-system.sh"
    fi
    die "Ollama API is not reachable at $(ollama_url), and this host has no systemd to manage it. Start it yourself ('ollama serve') — then check: ${REPO_ROOT}/check-system.sh"
  fi

  if ! model_present "${MODEL_NAME}"; then
    warn "Model '${MODEL_NAME}' is not downloaded yet."
    if confirm "Pull '${MODEL_NAME}' now?"; then
      net_guard "Downloading ${MODEL_NAME}"
      pull_model "${MODEL_NAME}" || die "Could not pull '${MODEL_NAME}'."
    elif [[ "$(netmode_state)" == "offline" ]]; then
      die "Cannot start aider without the model, and netmode is OFFLINE. Run: sudo ${REPO_ROOT}/netmode.sh online — then: ollama pull ${MODEL_NAME}"
    else
      die "Cannot start aider without the model. Pull it with: ollama pull ${MODEL_NAME}"
    fi
  fi

  # Tell aider the model's REAL usable context so it budgets the repo map,
  # chat history and files to fit what Ollama will actually process. Without
  # this, aider trusts litellm's generic metadata (32k for qwen2.5-coder) while
  # the server runs at OLLAMA_CONTEXT_LENGTH, and any bigger prompt is silently
  # truncated by Ollama. Regenerated every run, so it always tracks auto-tune.
  local meta_dir meta_file input_tokens output_tokens window
  read -r input_tokens output_tokens < <(aider_token_budget "${OLLAMA_CONTEXT_LENGTH:-8192}")
  # Use the budget's own sum as the window everywhere, so a corrupt/empty
  # OLLAMA_CONTEXT_LENGTH (which aider_token_budget rounds up to its 8192
  # fallback) can never make the metadata and the printed window disagree.
  window=$(( input_tokens + output_tokens ))
  meta_dir="${HOME}/.cache/local-code-agent"
  mkdir -p "${meta_dir}"
  meta_file="${meta_dir}/aider.model.metadata.json"
  cat > "${meta_file}" <<EOF
{
  "ollama_chat/${MODEL_NAME}": {
    "max_input_tokens": ${input_tokens},
    "max_output_tokens": ${output_tokens},
    "max_tokens": ${window}
  }
}
EOF

  # Edit format and repo-map size make a large difference to output quality on
  # small local models — see aider_edit_format()/aider_map_tokens(). AUTO picks
  # per model/window; set LCA_EDIT_FORMAT in .env to force one.
  local edit_format map_tokens
  edit_format="${LCA_EDIT_FORMAT:-auto}"
  if [[ "${edit_format}" == "auto" ]]; then
    edit_format="$(aider_edit_format "${MODEL_NAME}")"
  fi
  map_tokens="$(aider_map_tokens "${OLLAMA_CONTEXT_LENGTH:-8192}")"

  local -a aider_args=(
    --config "${REPO_ROOT}/config/aider.conf.yml"
    --model-metadata-file "${meta_file}"
    --model "ollama_chat/${MODEL_NAME}"
    --edit-format "${edit_format}"
    --map-tokens "${map_tokens}"
  )
  # Prime the model with concise coding conventions (read-only) so a small
  # local model makes tighter, in-style edits. Costs a little context, so it is
  # skippable via AIDER_CONVENTIONS=false for the smallest (4096) windows.
  local conventions="${REPO_ROOT}/config/CONVENTIONS.md"
  if [[ "${AIDER_CONVENTIONS:-true}" == "true" && -f "${conventions}" ]]; then
    aider_args+=( --read "${conventions}" )
    info "Priming with coding conventions (config/CONVENTIONS.md; AIDER_CONVENTIONS=false to skip)"
  fi

  info "Starting aider with ollama_chat/${MODEL_NAME} in $(pwd)"
  info "Context budget: ${input_tokens} prompt + ${output_tokens} reply = ${window}-token window"
  info "Edit format: ${edit_format} · repo map: ${map_tokens} tokens (LCA_EDIT_FORMAT=auto picks per model)"
  # aider talks to Ollama through litellm, which needs OLLAMA_API_BASE and
  # the ollama_chat/ model prefix.
  export OLLAMA_API_BASE
  OLLAMA_API_BASE="$(ollama_url)"
  exec "${aider}" "${aider_args[@]}" "$@"
}

main "$@"
