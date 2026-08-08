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

  # Checked BEFORE the model is loaded, which costs 20 seconds on this box even
  # warm: somebody who is in the wrong directory should be told while they are
  # still looking at the screen, not after the wait.
  #
  # Auto-commit is the whole safety net for a small model's unrequested edits —
  # see the note above AIDER_NO_AUTO_COMMIT below — and it needs a git repo.
  # commit_safety_state() explains where aider does and does not make one.
  case "$(commit_safety_state)" in
    home)
      warn "This is your home directory, and aider does not create a git repo here — so nothing will be committed, 'git diff HEAD~1' will have nothing to show you, and an edit you never asked for cannot be reverted."
      info "Better: mkdir -p ~/my-project && cd ~/my-project && lca"
      confirm "Start aider here anyway, with no undo?" \
        || die "Nothing started. cd into a project directory and run 'lca' again."
      ;;
    norepo)
      info "No git repo here yet — aider will offer to make one. Say yes: that is what turns each edit into a commit you can read with 'git diff HEAD~1' and undo with 'git revert'."
      ;;
  esac

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
    else
      die "Cannot start aider without the model. $(pull_advice "${MODEL_NAME}")"
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
  meta_file="${meta_dir}/aider.model.metadata.json"
  # Not bare under 'set -e'. This directory is shared with 'lca ask' and 'lca
  # speed', and it ends up root-owned the moment any of the three is run once
  # under sudo — after which THIS command, the headline one, died on a raw
  # "Permission denied" before aider ever started.
  #
  # It still stops, unlike the other two: the metadata is not decoration.
  # Without it aider trusts litellm's generic 32k figure while Ollama runs at
  # OLLAMA_CONTEXT_LENGTH and truncates anything longer, silently. So this dies
  # deliberately, saying what happened and what to look at.
  local meta_ok=true
  mkdir -p "${meta_dir}" 2>/dev/null || meta_ok=false
  if [[ "${meta_ok}" == "true" ]]; then
    ( cat > "${meta_file}" <<EOF
{
  "ollama_chat/${MODEL_NAME}": {
    "max_input_tokens": ${input_tokens},
    "max_output_tokens": ${output_tokens},
    "max_tokens": ${window}
  }
}
EOF
    ) 2>/dev/null || meta_ok=false
  fi
  [[ "${meta_ok}" == "true" ]] || die "Could not write ${meta_file}, and aider must not start without it: it would trust a generic 32k context while Ollama runs at ${window} and truncates anything longer, with no error. Usually this directory is root-owned from a run under sudo — check with: ls -ld ${meta_dir}"

  # Edit format and repo-map size make a large difference to output quality on
  # small local models — see aider_edit_format()/aider_map_tokens(). AUTO picks
  # per model/window; set LCA_EDIT_FORMAT in .env to force one.
  local edit_format map_tokens
  edit_format="${LCA_EDIT_FORMAT:-auto}"
  if [[ "${edit_format}" == "auto" ]]; then
    edit_format="$(aider_edit_format "${MODEL_NAME}")"
  # Warned about, not refused. aider accepts a dozen edit formats and someone
  # may well want one this project does not document — but a typo here is
  # answered by forty lines of aider's usage text ending in "invalid choice:
  # 'whole-file'", with nothing pointing at .env. Measured, on the one command
  # the whole stack is for.
  elif [[ "${edit_format}" != "whole" && "${edit_format}" != "diff" \
       && "${edit_format}" != "udiff" ]]; then
    warn "LCA_EDIT_FORMAT='${edit_format}' in ${ENV_FILE} is not one of auto, whole, diff or udiff. Passing it to aider anyway — if it rejects the value, that is why."
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

  # Auto-commit is ON by default and that is deliberate: it is the safety net
  # for a small model's unrequested edits. Every change lands as its own commit,
  # so 'git diff HEAD~1' shows exactly what was touched and 'git revert <sha>'
  # undoes one cleanly. Measured on qwen2.5-coder:7b: asked for two specific
  # changes, it made both correctly AND deleted an unrelated function it was
  # never asked about — recoverable only because the commit existed.
  #
  # The opt-out is for people who would rather inspect a dirty tree before
  # anything is recorded. It costs the per-change audit trail: several edits
  # pile up unstaged together, and undoing one of them becomes a manual job.
  if [[ "${AIDER_NO_AUTO_COMMIT:-false}" == "true" ]]; then
    aider_args+=( --no-auto-commits )
    warn "AIDER_NO_AUTO_COMMIT=true — edits will NOT be committed. Review with 'git diff' before you lose track of which change was which."
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
