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

main() {
  step "local-code-agent setup starting"
  info "Target: $(uname -m) · $(detect_ram_gib) GiB RAM · $(nproc) vCPU"
  # bin/ included: that is where the 'lca' command lives.
  chmod +x "${SCRIPT_DIR}"/*.sh "${SCRIPT_DIR}"/scripts/*.sh "${SCRIPT_DIR}"/bin/* 2>/dev/null || true

  # Settings added since this machine was first installed are invisible in its
  # own .env until they are written there. 'lca update' re-runs setup, so this
  # is the natural moment to catch an old install up. Values already set are
  # never touched.
  sync_env_keys
  load_env

  # Tracks whether every load-bearing step succeeded. A zero-terminal user
  # watches the install log for the exact final line, so the healthy line
  # must NOT print when something essential (the model, the final check)
  # failed — otherwise they proceed onto a broken stack.
  local setup_ok=true
  # Set only by a generation that actually succeeded below. The final health
  # check re-runs the same probe, which costs up to a minute on CPU; it is
  # skipped only when we have already proved inference works ourselves.
  local smoke_tested=false

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
  # Announced, and it STARTS Ollama rather than only polling for it. The bare
  # wait gave up after 30 silent seconds and marked the whole install failed,
  # when restarting the service it had just installed would usually have fixed
  # it — a worse outcome reached more slowly, and with nothing on screen.
  if have ollama && ensure_ollama_up_announced 30; then
    if model_present "${MODEL_NAME}"; then
      ok "Model '${MODEL_NAME}' already downloaded."
    else
      net_guard "Downloading ${MODEL_NAME}"
      pull_model "${MODEL_NAME}" || die "Model pull failed — cannot continue without a model."
    fi
    info "Smoke test: asking ${MODEL_NAME} for a real generation (first load can take a minute)..."
    if model_responds "${MODEL_NAME}"; then
      ok "Model '${MODEL_NAME}' generates text — inference works."
      smoke_tested=true
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

  step "Installing the login banner"
  # So that SSHing in answers "is it ready?" without the user having to know
  # which log to tail. Never fatal: a box without update-motd is still a
  # perfectly working install.
  "${SCRIPT_DIR}/scripts/motd.sh" --install || warn "Could not install the login banner — everything else is unaffected."

  step "Installing boot services (auto-tune + netmode persistence)"
  "${SCRIPT_DIR}/scripts/tune.sh" --install-service
  "${SCRIPT_DIR}/netmode.sh" --install-service
  # Apply the always-on inbound guard now so the WebUI/Ollama ports are not
  # publicly reachable even before the first reboot.
  "${SCRIPT_DIR}/netmode.sh" harden || warn "Could not apply the inbound guard now — it will be applied on the next boot."

  step "Final system check"
  # Every probe except one is instant. The exception — asking the model to
  # generate — is the same test the smoke test above already ran and died on
  # if it failed, so repeating it here buys nothing and costs the installer up
  # to a minute of apparent hang on a CPU box.
  #
  # Conditional on purpose. If Ollama was unreachable the smoke test never
  # ran, and this is then the only thing that would prove inference works at
  # all — a --quick there would report a healthy stack nobody had tested.
  local -a check_args=()
  if [[ "${smoke_tested}" == "true" ]]; then
    check_args+=( --quick )
  fi
  if "${SCRIPT_DIR}/check-system.sh" ${check_args[@]+"${check_args[@]}"}; then
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
  # Teach the short command, not the long paths — 'lca' is the intended
  # interface now, and a next-steps list that contradicts it is how a tool ends
  # up with two half-remembered ways to do everything.
  info "1. Private phone access: sudo tailscale up   (then open the printed URL to log in)"
  info "2. Chat from your phone: lca chat   — prints http://${ts_ip}:${WEBUI_PORT} as a QR code to scan"
  info "   Install the Tailscale app on the phone first — docs/PHONE.md"
  info "3. Ask one question:     lca ask \"how do I find the biggest files here?\""
  info "4. Code in the terminal: cd <your-project> && lca"
  info "5. Prove it end-to-end:  lca test        · health check: lca check"
  info "6. When something looks wrong: lca logs   · when it feels slow: lca speed"
  info "7. Internet kill switch: sudo lca offline | sudo lca online | sudo lca status"
  info "8. Update the stack:     lca update      (backs up first)"
  info "9. Daily backups (optional): sudo ${SCRIPT_DIR}/backup.sh --install-timer"
  info "All commands: lca help"
  # Printed plain (no log prefix): docs/YOUR-TURN.md tells users to watch the
  # install log for exactly one of these final lines. setup_verdict also
  # returns the matching status, and because this is main's last command that
  # becomes setup.sh's exit code — which is what deploy/do-user-data.sh and
  # update.sh branch on.
  setup_verdict "${setup_ok}"
}

main "$@"
