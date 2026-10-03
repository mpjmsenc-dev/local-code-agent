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

# ff_only_failed BRANCH — never returns; dies naming the reason the merge had.
#
# Same argument as fetch_failed above, and the same measured failure. The one
# line this replaces was:
#
#   die "Could not fast-forward — you have local commits or conflicting edits.
#        Resolve them (git -C ${SCRIPT_DIR} status), then re-run."
#
# ...which offers the reader two causes, names neither file nor fix, and sends
# them to a command whose whole output was ' M config/CONVENTIONS.md'. Walked
# in a container: no local commits, no conflict, one modified file — and the
# message named none of that. Collisions with local edits are handled before
# the merge now, so by the time this runs the cause is almost always the other
# one, and git's own counter says which.
ff_only_failed() {
  local branch="$1" ahead=0
  ahead="$(git -C "${SCRIPT_DIR}" rev-list --count "origin/${branch}..HEAD" 2>/dev/null || echo 0)"
  if (( ahead > 0 )); then
    die "Your checkout has ${ahead} commit(s) of its own that are not on origin/${branch}, so taking the new code would be a merge and this script will not invent one in your checkout. See yours with: git -C ${SCRIPT_DIR} log --oneline origin/${branch}..HEAD — then either push them, or move them aside (git -C ${SCRIPT_DIR} branch my-work && git -C ${SCRIPT_DIR} reset --hard origin/${branch}) and re-run."
  fi
  die "The fast-forward to origin/${branch} failed and it is not local commits — git's own message is above and says more than this can. Check free space (df -h ${SCRIPT_DIR}) and that ${SCRIPT_DIR}/.git is writable, then re-run. Nothing was applied."
}

main() {
  local check_only=false do_backup=true assume_yes=false arg
  for arg in "$@"; do
    case "${arg}" in
      --check)     check_only=true ;;
      --no-backup) do_backup=false ;;
      --yes|-y)    assume_yes=true ;;
      -h|--help)   usage; exit 0 ;;
      *)           usage >&2; die "Unknown option: ${arg}" ;;
    esac
  done

  have git || die "git is not installed — cannot update."
  [[ -d "${SCRIPT_DIR}/.git" ]] \
    || die "${SCRIPT_DIR} is not a git checkout, so there is nothing to update from. If you unpacked a tarball, re-install over it with the one-liner from the README: curl -fsSL https://raw.githubusercontent.com/mpjmsenc-dev/local-code-agent/main/install.sh | bash"

  step "Checking for updates"
  # '|| echo HEAD' turned every way git can refuse into "detached HEAD state",
  # and a real detached HEAD is not one of them: that case SUCCEEDS and prints
  # the word HEAD. A non-zero exit means git would not answer at all.
  #
  # Measured as an ordinary user against a checkout owned by root — which is
  # what 'sudo setup.sh' and the install one-liner both leave behind, on the
  # documented path where you install as root and then use 'lca' as yourself:
  #
  #   $ git -C /home/user/local-code-agent rev-parse --abbrev-ref HEAD
  #   fatal: detected dubious ownership in repository at '...'
  #   To add an exception for this directory, call:
  #       git config --global --add safe.directory /home/user/local-code-agent
  #
  #   $ lca update --check
  #   [FAIL] The checkout is in a detached HEAD state. Pick a branch first:
  #          git -C /home/user/local-code-agent checkout main
  #
  # The checkout was on a branch the whole time, and the suggested command
  # fails exactly the same way. git had already printed the fix; this threw it
  # away and invented a different problem.
  #
  # git's own text is passed through rather than summarised: it names the
  # directory and the exact 'safe.directory' line to run, which is more than
  # this could reconstruct.
  local branch rc=0
  branch="$(git -C "${SCRIPT_DIR}" rev-parse --abbrev-ref HEAD 2>&1)" || rc=$?
  if (( rc != 0 )); then
    die "Could not read the current branch of ${SCRIPT_DIR}, so there is nothing to update from yet. git said: ${branch}"
  fi
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
  #
  # This used to stop at "you have local modifications", followed by "(.env is
  # not tracked, so your settings are safe either way)" — a reassurance about
  # the one file that was never at risk, printed at the exact moment a tracked
  # one was. Walked in a container: edit config/CONVENTIONS.md, which this
  # project calls the file that steers all three surfaces and documents as
  # yours to edit, then take a release that also touches it. git refuses the
  # merge, and the update dies with "you have local commits or conflicting
  # edits. Resolve them (git status), then re-run" — there were no local
  # commits, there was no conflict, git status showed one modified file, and
  # nothing named it or said what to do. The recovery a reader would reach for,
  # 'git stash', drops their house rules on the floor unless they know about
  # 'stash pop'.
  #
  # So the question is not "is anything modified" but "does the update touch
  # what you modified", which is the only case that cannot just proceed.
  local -a local_edits=() incoming=() collisions=()
  mapfile -t local_edits < <(git -C "${SCRIPT_DIR}" diff --name-only HEAD 2>/dev/null)
  if [[ "${behind}" != "0" ]]; then
    mapfile -t incoming < <(git -C "${SCRIPT_DIR}" diff --name-only "HEAD..origin/${branch}" 2>/dev/null)
  fi
  local mine theirs
  for mine in "${local_edits[@]}"; do
    for theirs in "${incoming[@]}"; do
      if [[ "${mine}" == "${theirs}" ]]; then
        collisions+=("${mine}")
        break
      fi
    done
  done
  local pretty=""
  if (( ${#collisions[@]} )); then
    pretty="$(printf '%s, ' "${collisions[@]}")"; pretty="${pretty%, }"
  fi

  if (( ${#local_edits[@]} )); then
    warn "You have local modifications to tracked files:"
    printf '    %s\n' "${local_edits[@]}"
    if (( ${#collisions[@]} )); then
      warn "The update changes ${pretty} too, so your version and the new one are about to meet."
      info "Your edits will be set aside, the new code applied, and your edits replayed on top — automatically, in that order. Nothing is discarded."
    else
      info "The update does not touch any of them, so they carry straight over."
    fi
    info "(.env is not tracked and is never touched by an update, whatever happens above.)"
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
    # Their edits, set aside by us rather than by them. A merge cannot run over
    # a modified file it wants to change, and the two ways out of that are to
    # discard the edit or to move it — so this moves it, and moves it back.
    local stashed=false
    if (( ${#collisions[@]} )); then
      info "Setting your edits to ${pretty} aside..."
      if git -C "${SCRIPT_DIR}" stash push --quiet \
           --message "lca update: your edits, set aside automatically" \
           -- "${collisions[@]}"; then
        stashed=true
      else
        die "Could not set your local edits to ${pretty} aside (git's message is above), so nothing was applied and your files are exactly as you left them. Save them yourself — cp ${SCRIPT_DIR}/${collisions[0]} ~/ — then: git -C ${SCRIPT_DIR} checkout -- ${pretty} && ${SCRIPT_DIR}/update.sh"
      fi
    fi
    # --ff-only: never invent a merge commit in a user's checkout, and fail
    # loudly if their local commits diverge instead of silently discarding them.
    if ! git -C "${SCRIPT_DIR}" merge --ff-only "origin/${branch}"; then
      if [[ "${stashed}" == "true" ]]; then
        git -C "${SCRIPT_DIR}" stash pop --quiet \
          || warn "Your edits to ${pretty} could not be put back automatically. They are safe: git -C ${SCRIPT_DIR} stash list"
      fi
      ff_only_failed "${branch}"   # always dies, naming the cause it found
    fi
    if [[ "${stashed}" == "true" ]]; then
      # Not --quiet: on a conflict git's own output names the files and the
      # markers, and this is the one moment the reader needs that detail.
      if git -C "${SCRIPT_DIR}" stash pop; then
        ok "Your edits to ${pretty} are back, on top of the new code."
      else
        warn "The new code is in, but your edits to ${pretty} could not be replayed on top of it — the same lines changed on both sides."
        warn "Nothing is lost. Your version is still saved AND is written into the file(s) above between <<<<<<< markers: the half labelled 'Updated upstream' is the new code, the half labelled 'Stashed changes' is yours. Keep what you want, then: git -C ${SCRIPT_DIR} stash drop"
        # '--ours', measured, not remembered. In a stash-pop conflict 'ours' is
        # HEAD — the code that just arrived — and 'theirs' is the stash, i.e.
        # the user's own edits. The first draft of this line said --theirs, and
        # would have told someone asking for the shipped file that they wanted
        # the one they were trying to abandon.
        warn "To abandon your version instead and take the new file as it ships: git -C ${SCRIPT_DIR} checkout --ours -- ${pretty} && git -C ${SCRIPT_DIR} stash drop"
      fi
    fi
    # bin/ included: that is where the 'lca' command lives, and an update that
    # adds a new one there must leave it runnable. Read back, not assumed: this
    # was 'chmod ... || true' followed by "Now at <commit>", so an update that
    # shipped a new command and could not make it executable said the same
    # words as one that worked, and the reader met the failure later as
    # "lca: Permission denied".
    chmod +x "${SCRIPT_DIR}"/*.sh "${SCRIPT_DIR}"/scripts/*.sh "${SCRIPT_DIR}"/bin/* 2>/dev/null || true
    local unrunnable=() f
    for f in "${SCRIPT_DIR}"/*.sh "${SCRIPT_DIR}"/scripts/*.sh "${SCRIPT_DIR}"/bin/*; do
      if [[ -f "${f}" && ! -x "${f}" ]]; then
        unrunnable+=("${f##*/}")
      fi
    done
    if (( ${#unrunnable[@]} )); then
      warn "The new code is in, but $(printf '%s ' "${unrunnable[@]}")could not be made executable — running them will fail with 'Permission denied'. Fix with: sudo chmod +x ${SCRIPT_DIR}/${unrunnable[0]}"
    fi
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
    # Only when there is a pre-update state to go back TO. With no new commits
    # this offered "roll back to the pre-update state" over a checkout that had
    # not changed: the code is byte-identical to the backup's, so restoring can
    # only undo what setup itself just managed to do, and overwrite a .env and
    # a model list that are newer than the archive. Measured in a container —
    # "Already up to date with origin/main" and, forty lines later, restore.sh.
    if [[ "${do_backup}" == "true" && "${behind}" != "0" ]]; then
      warn "Roll back to the pre-update state with: ${SCRIPT_DIR}/restore.sh"
    elif [[ "${behind}" == "0" ]]; then
      info "No new code was applied — this checkout is what it was before you ran this — so there is nothing to roll back. What failed is setup, above."
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
