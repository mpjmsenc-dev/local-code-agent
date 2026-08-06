#!/usr/bin/env bash
# update.sh — update the whole stack safely, in the right order:
#
#   back up  ->  fetch new code  ->  re-run setup  ->  prove it still works
#
# The backup comes FIRST on purpose. setup.sh upgrades OS packages, aider,
# Ollama and (via auto-tune) possibly the model itself; if any of that goes
# wrong you want a restore point that predates it, not one taken afterwards.
#
# Usage:
#   ./update.sh              back up, update, re-run setup, self-test
#   ./update.sh --check      show what WOULD change; touch nothing
#   ./update.sh --no-backup  skip the backup (not recommended)
#   ./update.sh --yes        never prompt (for cron/unattended use)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/scripts/lib.sh"
load_env

usage() { sed -n '/^# Usage:/,/^set /{ /^set /!p; }' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# fetch_failed BRANCH — never returns; dies naming the reason the fetch had.
#
# The one line this replaces blamed the network for everything:
#
#   die "Could not reach the remote. Check connectivity, and whether the kill
#        switch is on: netmode.sh status"
#
# A branch that is not on the remote fails the same fetch. Measured, on a
# checkout whose branch had no upstream:
#
#   $ git fetch --quiet origin no-such-branch-xyz
#   fatal: couldn't find remote ref no-such-branch-xyz
#   exit=128
#
# ...and the reader is then sent to check their connection and toggle a kill
# switch, neither of which has anything to do with it. Worse, net_guard three
# lines above has ALREADY died if netmode is offline, so the kill switch is the
# one cause this message can be sure it is not.
#
# The classification is git's own exit status, not its English: 'ls-remote
# --exit-code' returns 2 for "connected, no matching ref" and 128 for "could
# not connect", both documented and both locale-independent. Measured here: 0
# for a branch that exists, 2 for one that does not, 128 against an unreachable
# host. Grepping "couldn't find remote ref" would work until someone's box is
# not in English.
#
# Only ever runs on the failure path, so the extra round trip costs nothing in
# the normal case.
fetch_failed() {
  local branch="$1" rc=0
  git -C "${SCRIPT_DIR}" ls-remote --exit-code --heads origin "${branch}" >/dev/null 2>&1 || rc=$?
  case "${rc}" in
    2)
      die "The branch this checkout is on ('${branch}') does not exist on the remote, so there is nothing to update from. The remote itself answered fine. Switch to the branch you track — git -C ${SCRIPT_DIR} checkout main — and re-run, or push '${branch}' first if it is yours."
      ;;
    0)
      # The remote answered AND has the branch, so neither the network nor the
      # branch is the problem. Usually a full disk or an unwritable .git.
      die "The remote is reachable and '${branch}' is on it, but the fetch still failed — git's own message is above. Check free space (df -h ${SCRIPT_DIR}) and that .git is writable."
      ;;
    *)
      die "Could not reach the remote. Check connectivity, and whether the kill switch is on: ${SCRIPT_DIR}/netmode.sh status"
      ;;
  esac
}

main() {
  local check_only=false do_backup=true assume_yes=false arg
  for arg in "$@"; do
    case "${arg}" in
      --check)     check_only=true ;;
      --no-backup) do_backup=false ;;
      --yes|-y)    assume_yes=true ;;
      -h|--help)   usage; exit 0 ;;
      *)           usage; die "Unknown option: ${arg}" ;;
    esac
  done

  have git || die "git is not installed — cannot update."
  [[ -d "${SCRIPT_DIR}/.git" ]] \
    || die "${SCRIPT_DIR} is not a git checkout, so there is nothing to update from. If you unpacked a tarball, re-install over it with the one-liner from the README: curl -fsSL https://raw.githubusercontent.com/mpjmsenc-dev/local-code-agent/main/install.sh | bash"

  step "Checking for updates"
  local branch
  branch="$(git -C "${SCRIPT_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
  [[ "${branch}" != "HEAD" ]] \
    || die "The checkout is in a detached HEAD state. Pick a branch first: git -C ${SCRIPT_DIR} checkout main"

  net_guard "Fetching updates"
  if ! git -C "${SCRIPT_DIR}" fetch --quiet origin "${branch}"; then
    fetch_failed "${branch}"   # always dies, naming the cause it actually found
  fi

  local behind
  behind="$(git -C "${SCRIPT_DIR}" rev-list --count "HEAD..origin/${branch}" 2>/dev/null || echo 0)"
  if [[ "${behind}" == "0" ]]; then
    ok "Already up to date with origin/${branch}."
  else
    info "${behind} new commit(s) on origin/${branch}:"
    git -C "${SCRIPT_DIR}" log --oneline --no-decorate "HEAD..origin/${branch}" | sed 's/^/    /'
  fi

  # Local edits to tracked files would be lost or cause a conflict. Say so now,
  # while nothing has been touched, rather than failing halfway through.
  local dirty
  dirty="$(git -C "${SCRIPT_DIR}" status --porcelain --untracked-files=no)"
  if [[ -n "${dirty}" ]]; then
    warn "You have local modifications to tracked files:"
    printf '%s\n' "${dirty}" | sed 's/^/    /'
    warn "(.env is not tracked, so your settings are safe either way.)"
  fi

  if [[ "${check_only}" == "true" ]]; then
    ok "--check: nothing was changed."
    exit 0
  fi

  if [[ "${behind}" == "0" ]]; then
    info "No new code, but re-running setup still refreshes OS packages, aider and the model."
  fi
  if [[ "${assume_yes}" != "true" ]]; then
    confirm "Update now? (a backup is taken first unless --no-backup)" \
      || die "Update cancelled — nothing was changed."
  fi

  # --- 1. backup (the restore point must predate the update) ------------------
  if [[ "${do_backup}" == "true" ]]; then
    step "Backing up before updating"
    if "${SCRIPT_DIR}/backup.sh"; then
      ok "Backup complete — restore with ${SCRIPT_DIR}/restore.sh if this update goes wrong."
    else
      warn "Backup FAILED. Continuing would leave you without a restore point."
      # '-t 0' as well as --yes: confirm() auto-answers YES when stdin is not a
      # terminal, which is right for an install prompt and exactly wrong here.
      # A cron'd or piped update without --yes therefore sailed past a FAILED
      # backup and updated with no restore point — the precise case the --yes
      # branch refuses. Unattended is unattended, however it got that way.
      if [[ "${assume_yes}" != "true" && -t 0 ]]; then
        confirm "Continue updating anyway?" || die "Update cancelled — nothing was changed."
      else
        die "Backup failed and this is not an interactive session; refusing to update unattended without a restore point. Fix the backup, or re-run with --no-backup if you accept the risk."
      fi
    fi
  else
    warn "--no-backup: no restore point is being created."
  fi

  # --- 2. new code ------------------------------------------------------------
  if [[ "${behind}" != "0" ]]; then
    step "Applying ${behind} new commit(s)"
    # --ff-only: never invent a merge commit in a user's checkout, and fail
    # loudly if their local edits diverge instead of silently discarding them.
    git -C "${SCRIPT_DIR}" merge --ff-only "origin/${branch}" \
      || die "Could not fast-forward — you have local commits or conflicting edits. Resolve them (git -C ${SCRIPT_DIR} status), then re-run."
    # bin/ included: that is where the 'lca' command lives, and an update that
    # adds a new one there must leave it runnable.
    chmod +x "${SCRIPT_DIR}"/*.sh "${SCRIPT_DIR}"/scripts/*.sh "${SCRIPT_DIR}"/bin/* 2>/dev/null || true
    ok "Now at $(git -C "${SCRIPT_DIR}" log --oneline -1 --no-decorate)"
  fi

  # --- 3. re-run setup (idempotent: upgrades packages, aider, Ollama, model) ---
  step "Re-running setup"
  # Explicitly, not bare under 'set -e': setup.sh failing here is the single
  # most likely way an update goes wrong, and dying silently would take the
  # user straight past the one thing they need to know — that a restore point
  # was taken minutes ago, before any of this.
  if ! "${SCRIPT_DIR}/setup.sh" </dev/null; then
    warn "Setup did not finish cleanly — its verdict line is above."
    if [[ "${do_backup}" == "true" ]]; then
      warn "Roll back to the pre-update state with: ${SCRIPT_DIR}/restore.sh"
    fi
    die "Update stopped after setup reported errors. Diagnose with: ${SCRIPT_DIR}/check-system.sh"
  fi

  # --- 4. prove it still works ------------------------------------------------
  step "Verifying the updated stack"
  if "${SCRIPT_DIR}/scripts/selftest.sh"; then
    ok "Update complete and verified."
  else
    warn "The stack updated, but the self-test did not pass — see the failures above."
    warn "If the update broke something, restore the pre-update backup: ${SCRIPT_DIR}/restore.sh"
    exit 1
  fi
}

# 'exit $?' on the SAME line as the call, not the next one.
#
# The merge above can replace THIS file — an update that changes update.sh
# does exactly that — and bash reads a script incrementally from an open fd.
# When main returns, bash reads whatever now sits at its old byte offset in
# the new file. Measured: with a longer replacement it executed a fragment of
# a comment line and exited 127, immediately after printing "Update complete
# and verified". A cron'd update would have reported failure for a success.
#
# A separate 'exit' line would be read at that same stale offset and never
# run. Both commands have to come out of one parse, so there is no next read.
main "$@"; exit $?
