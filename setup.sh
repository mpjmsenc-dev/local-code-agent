#!/usr/bin/env bash
# setup.sh — one-shot installer for the whole local-code-agent stack:
# Ollama (local LLM) + aider (terminal coding agent) + Open WebUI (phone
# chat) + Tailscale (private access) + auto-tune + netmode kill switch.
#
# Fully unattended when non-interactive (this is how deploy/do-user-data.sh
# calls it on a fresh DigitalOcean droplet). Safe to re-run at any time.
#
# Usage: sudo ./setup.sh          (from the checkout; takes several minutes)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/scripts/lib.sh"
load_env

# Every failing exit has to carry a verdict line, not just the orderly one at
# the end of main.
#
# Three separate things read setup.sh's OUTPUT rather than its status:
# deploy/do-user-data.sh promises the log "always ends with exactly one of
# three lines" and then says "its verdict line is above"; docs/YOUR-TURN.md
# step 2 tells the user to watch the log for exactly one of two lines; and
# scripts/motd.sh classifies the install by grepping for them. A die() printed
# none of the three. Measured on a log ending in "Model pull failed": with the
# verdict line install_state says 'failed'; without it, 'running' for fifteen
# minutes and 'stalled' after that. So the SSH banner told someone whose
# install was over that it was still going, and do-user-data.sh pointed at a
# verdict line that did not exist.
#
# An EXIT trap rather than fixing the die() calls one by one, because most of
# these exits are not die() at all: the nine installer scripts main runs are
# bare under 'set -e', and any of them aborting exits setup.sh with no verdict
# by exactly the same route.
VERDICT_PRINTED=false
verdict_on_exit() {
  local rc=$?
  # Only on failure, and only when main did not get to say it itself. '--help'
  # exits 0 before any side effect and must stay silent.
  if (( rc != 0 )) && [[ "${VERDICT_PRINTED}" != "true" ]]; then
    setup_verdict false || true
  fi
  return 0
}
trap verdict_on_exit EXIT

main() {
  # Above every side effect. This installs packages, services and a model as
  # root, so answering "--help" by starting is the worst possible reading of
  # it — and it was the reading: './setup.sh --help' began installing.
  case "${1:-}" in
    -h|--help)
      sed -n '2,/^[^#]/p' "${BASH_SOURCE[0]}" | grep '^#' | sed 's/^# \{0,1\}//'
      exit 0
      ;;
  esac
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

  # Bare on purpose, and only these four: base packages, git, the venv that
  # holds aider, and Ollama itself. Without any one of them there is no stack
  # at all, so stopping is the honest outcome and the EXIT trap above still
  # prints a verdict. Every OTHER step below is something the install can
  # finish without, and each is guarded accordingly — a gate in
  # tests/test-lib.sh fails if a new bare call joins this list.
  "${SCRIPT_DIR}/scripts/install_dependencies.sh"
  "${SCRIPT_DIR}/scripts/install_git.sh"
  # Docker is not one of those. Its only job here is to run the chat app, which
  # .env can switch off and which setup already treats as non-fatal — so a
  # Docker failure was aborting the install over precisely the component the
  # next block is happy to continue without, taking the model pull, the 'lca'
  # command, the boot services and the inbound guard with it.
  if ! "${SCRIPT_DIR}/scripts/install_docker.sh"; then
    warn "Docker did not install — continuing without the chat app; aider and 'lca ask' are unaffected. Re-run sudo ${SCRIPT_DIR}/scripts/install_docker.sh later, or set SKIP_DOCKER=true in .env if you do not want it."
    setup_ok=false
  fi
  "${SCRIPT_DIR}/scripts/install_python.sh"
  "${SCRIPT_DIR}/scripts/install_ollama.sh"

  # Auto-tune BEFORE the model pull so we download the right model for this
  # machine's RAM straight away.
  #
  # Not fatal, though: all this step does is choose a model tag, and .env
  # already holds a usable one. Bare, a failure here took the model pull, the
  # chat app, the 'lca' command, the login banner, both boot services, the
  # inbound guard and the final check with it — over the choice between two
  # model names.
  if ! "${SCRIPT_DIR}/scripts/tune.sh"; then
    warn "Auto-tune could not pick a model for this machine — continuing with .env's current MODEL_NAME. Re-run later with: sudo ${SCRIPT_DIR}/scripts/tune.sh"
    setup_ok=false
  fi
  load_env  # tune.sh may have rewritten MODEL_NAME / OLLAMA_CONTEXT_LENGTH

  step "Ensuring model '${MODEL_NAME}' is available"
  # Announced, and it STARTS Ollama rather than only polling for it. The bare
  # wait gave up after 30 silent seconds and marked the whole install failed,
  # when restarting the service it had just installed would usually have fixed
  # it — a worse outcome reached more slowly, and with nothing on screen.
  # A missing model is recorded, not fatal — the same treatment the 'Ollama is
  # not reachable' branch below already gives the identical outcome.
  #
  # Dying here skipped everything after this point: the 'lca' command, the
  # login banner that would have reported the failure, the boot services, and
  # 'netmode.sh harden' — so a droplet that ran out of disk during the pull was
  # left with Ollama installed and running and no inbound guard in front of it.
  # None of those steps need a model. Setup still reports failure at the end,
  # and check-system.sh names the missing model in the summary above it.
  local have_model=true
  if have ollama && ensure_ollama_up_announced 30; then
    if model_present "${MODEL_NAME}"; then
      ok "Model '${MODEL_NAME}' already downloaded."
    else
      net_guard "Downloading ${MODEL_NAME}"
      if ! pull_model "${MODEL_NAME}"; then
        warn "Could not download '${MODEL_NAME}' — the rest of the stack is still being installed, but nothing can answer a question until this succeeds. Common cause: no disk space (df -h). Retry with: sudo ${SCRIPT_DIR}/setup.sh"
        have_model=false
        setup_ok=false
      fi
    fi
    if [[ "${have_model}" == "true" ]]; then
      info "Smoke test: asking ${MODEL_NAME} for a real generation. The model is loaded first, which on a CPU-only box has been measured at up to 5 minutes..."
      if model_responds "${MODEL_NAME}"; then
        ok "Model '${MODEL_NAME}' generates text — inference works."
        smoke_tested=true
      else
        warn "Model '${MODEL_NAME}' did not respond — $(model_silence_reason)"
        setup_ok=false
      fi
    fi
  else
    warn "Ollama is not reachable — skipping model pull and smoke test (re-run sudo ${SCRIPT_DIR}/setup.sh once Ollama runs)."
    setup_ok=false
  fi

  if [[ "${ENABLE_WEBUI}" == "true" && "${SKIP_DOCKER}" != "true" ]]; then
    # A WebUI failure (e.g. the Docker daemon isn't running on a no-systemd
    # host) must NOT abort the rest of setup — the terminal stack still works.
    if ! "${SCRIPT_DIR}/scripts/install_webui.sh"; then
      warn "Open WebUI did not come up (Docker daemon down?) — continuing without it; run sudo ${SCRIPT_DIR}/scripts/install_webui.sh once Docker is running."
      setup_ok=false
    fi
  else
    info "Open WebUI disabled (ENABLE_WEBUI=${ENABLE_WEBUI}, SKIP_DOCKER=${SKIP_DOCKER}) — skipping."
  fi

  # Guarded for the same reason as the chat app two lines up, and it is the
  # same reason: Tailscale is the phone-access half of this stack, and the
  # terminal half works without it. Bare, a transient network failure here
  # aborted setup before the 'lca' command, the login banner, the boot services
  # and the inbound guard — none of which need Tailscale — had been installed.
  if ! "${SCRIPT_DIR}/scripts/install_tailscale.sh"; then
    warn "Tailscale did not install — continuing without private phone access; the terminal stack is unaffected. Re-run sudo ${SCRIPT_DIR}/scripts/install_tailscale.sh when the network is stable, or set SKIP_TAILSCALE=true in .env if you reach this box over a private network of your own."
    setup_ok=false
  fi

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
  # Neither is fatal, and both were. They install systemd units, which can fail
  # on a masked unit or a systemd a container will not let us enable — and they
  # sit two lines above the inbound guard and three above the final check, so
  # a bare failure here left the ports unguarded and the install unverified,
  # having already done everything else correctly.
  if ! "${SCRIPT_DIR}/scripts/tune.sh" --install-service; then
    warn "The on-boot auto-tune service could not be installed — resizing this VM will not re-pick the model until you run 'sudo lca tune' yourself. Continuing."
    setup_ok=false
  fi
  if ! "${SCRIPT_DIR}/netmode.sh" --install-service; then
    warn "The netmode boot service could not be installed — the kill switch's state will not survive a reboot. Continuing."
    setup_ok=false
  fi
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
  # Coding first, and not only as a statement of priorities — it is the
  # dependency order. 'lca' needs nothing beyond what just finished
  # installing, while phone access needs 'tailscale up' and an app installed
  # on a second device. The shorter path was printed fourth, underneath two
  # chat steps and 'lca ask', which is the door that cannot write files and
  # looks the most like the one that can. Someone who reads three lines and
  # stops has been pointed away from the product every time.
  info "1. Code in the terminal: cd <your-project> && lca   (edits real files, commits each change)"
  info "2. Ask one question:     lca ask \"how do I find the biggest files here?\"   (answers only — no files)"
  # Conditional, because this same run tolerates a failed Tailscale install and
  # carries on by design — so the unconditional version handed a command that
  # setup.sh had just finished failing to provide, in its own closing advice.
  # Same rule motd.sh and 'lca chat' follow.
  if have tailscale; then
    info "3. Private phone access: sudo tailscale up   (then open the printed URL to log in)"
  elif [[ "${SKIP_TAILSCALE}" == "true" ]]; then
    info "3. Private phone access: skipped (SKIP_TAILSCALE=true) — reach port ${WEBUI_PORT} over your own private network"
  else
    info "3. Private phone access: Tailscale did not install — retry: sudo ${SCRIPT_DIR}/scripts/install_tailscale.sh"
  fi
  info "4. Chat from your phone: lca chat   — prints http://${ts_ip}:${WEBUI_PORT} as a QR code to scan"
  info "   Install the Tailscale app on the phone first — docs/PHONE.md"
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
  #
  # Set first, so the EXIT trap does not print a second, contradictory verdict
  # underneath this one when setup_ok is false.
  VERDICT_PRINTED=true
  setup_verdict "${setup_ok}"
}

main "$@"
