#!/usr/bin/env bash
# setup.sh — one-shot installer for the whole local-code-agent stack:
# Ollama (local LLM) + aider (terminal coding agent) + Open WebUI (phone
# chat) + Tailscale (private access) + auto-tune + netmode kill switch.
#
# Fully unattended when non-interactive (this is how deploy/do-user-data.sh
# calls it on a fresh DigitalOcean droplet). Safe to re-run at any time.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/scripts/lib.sh"
load_env

DONE_LINE="SETUP COMPLETE — local-code-agent is ready."
FAIL_LINE="SETUP FINISHED WITH ERRORS — run ${SCRIPT_DIR}/check-system.sh and see docs/TROUBLESHOOTING.md"

main() {
  step "local-code-agent setup starting"
  info "Target: $(uname -m) · $(detect_ram_gib) GiB RAM · $(nproc) vCPU"
  chmod +x "${SCRIPT_DIR}"/*.sh "${SCRIPT_DIR}"/scripts/*.sh

  # Tracks whether every load-bearing step succeeded. A zero-terminal user
  # watches the install log for the exact final line, so the healthy line
  # must NOT print when something essential (the model, the final check)
  # failed — otherwise they proceed onto a broken stack.
  local setup_ok=true

  "${SCRIPT_DIR}/scripts/install_dependencies.sh"
  "${SCRIPT_DIR}/scripts/install_git.sh"
  "${SCRIPT_DIR}/scripts/install_docker.sh"
  "${SCRIPT_DIR}/scripts/install_python.sh"
  "${SCRIPT_DIR}/scripts/install_ollama.sh"

  # Auto-tune BEFORE the model pull so we download the right model for this
  # machine's RAM straight away.
  "${SCRIPT_DIR}/scripts/tune.sh"
  load_env  # tune.sh may have rewritten MODEL_NAME / OLLAMA_CONTEXT_LENGTH

  step "Ensuring model '${MODEL_NAME}' is available"
  if have ollama && wait_for_ollama 30; then
    if model_present "${MODEL_NAME}"; then
      ok "Model '${MODEL_NAME}' already downloaded."
    else
      net_guard "Downloading ${MODEL_NAME}"
      pull_model "${MODEL_NAME}" || die "Model pull failed — cannot continue without a model."
    fi
    info "Smoke test: asking ${MODEL_NAME} for a real generation (first load can take a minute)..."
    if model_responds "${MODEL_NAME}"; then
      ok "Model '${MODEL_NAME}' generates text — inference works."
    else
      die "Model '${MODEL_NAME}' did not respond. Check RAM headroom (free -h) and: journalctl -u ollama"
    fi
  else
    warn "Ollama is not reachable — skipping model pull and smoke test (re-run ./setup.sh once Ollama runs)."
    setup_ok=false
  fi

  if [[ "${ENABLE_WEBUI}" == "true" && "${SKIP_DOCKER}" != "true" ]]; then
    # A WebUI failure (e.g. the Docker daemon isn't running on a no-systemd
    # host) must NOT abort the rest of setup — the terminal stack still works.
    if ! "${SCRIPT_DIR}/scripts/install_webui.sh"; then
      warn "Open WebUI did not come up (Docker daemon down?) — continuing without it; run scripts/install_webui.sh once Docker is running."
      setup_ok=false
    fi
  else
    info "Open WebUI disabled (ENABLE_WEBUI=${ENABLE_WEBUI}, SKIP_DOCKER=${SKIP_DOCKER}) — skipping."
  fi

  "${SCRIPT_DIR}/scripts/install_tailscale.sh"

  step "Installing the 'lca' command"
  # Daily use should be 'cd ~/project && lca', not the full path to a script in
  # /opt. Symlink rather than copy, so it always tracks this checkout.
  if can_root; then
    if as_root ln -sfn "${SCRIPT_DIR}/bin/lca" /usr/local/bin/lca 2>/dev/null; then
      ok "'lca' is on your PATH — try: lca help"
    else
      warn "Could not create /usr/local/bin/lca — use ${SCRIPT_DIR}/bin/lca directly."
    fi
  else
    info "No root available — skipping the 'lca' symlink; use ${SCRIPT_DIR}/bin/lca."
  fi

  step "Installing boot services (auto-tune + netmode persistence)"
  "${SCRIPT_DIR}/scripts/tune.sh" --install-service
  "${SCRIPT_DIR}/netmode.sh" --install-service
  # Apply the always-on inbound guard now so the WebUI/Ollama ports are not
  # publicly reachable even before the first reboot.
  "${SCRIPT_DIR}/netmode.sh" harden || warn "Could not apply the inbound guard now — it will be applied on the next boot."

  step "Final system check"
  if "${SCRIPT_DIR}/check-system.sh"; then
    ok "All system checks passed."
  else
    warn "Some system checks did not pass — review the summary above (docs/TROUBLESHOOTING.md helps)."
    setup_ok=false
  fi

  # --- Next steps -----------------------------------------------------------
  local ts_ip="<tailscale-ip>"
  if have tailscale && tailscale status >/dev/null 2>&1; then
    ts_ip="$(tailscale ip -4 2>/dev/null | head -1 || echo '<tailscale-ip>')"
  fi
  step "Next steps"
  info "1. Private phone access: sudo tailscale up   (then open the printed URL to log in)"
  info "2. Chat from your phone: http://${ts_ip}:${WEBUI_PORT}  (install the Tailscale app on the phone first — docs/PHONE.md)"
  info "3. Code in the terminal: cd <your-project> && ${SCRIPT_DIR}/run-agent.sh"
  info "4. Internet kill switch: sudo ${SCRIPT_DIR}/netmode.sh offline|online|status"
  info "5. Health check anytime: ${SCRIPT_DIR}/check-system.sh"
  info "6. Prove it end-to-end:  ${SCRIPT_DIR}/scripts/selftest.sh   (a.k.a. make smoke)"
  info "7. Automatic daily backups (optional): sudo ${SCRIPT_DIR}/backup.sh --install-timer"
  # Printed plain (no log prefix): docs/YOUR-TURN.md tells users to watch the
  # install log for exactly one of these final lines.
  if [[ "${setup_ok}" == "true" ]]; then
    printf '\n%b%s%b\n' "${C_GREEN}${C_BOLD}" "${DONE_LINE}" "${C_RESET}"
  else
    printf '\n%b%s%b\n' "${C_YELLOW}${C_BOLD}" "${FAIL_LINE}" "${C_RESET}"
  fi
}

main "$@"
