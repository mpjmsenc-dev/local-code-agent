# Contributing

This repo is built to be extended by an **AI coding agent with a human
reviewer** — you point aider (or Claude Code) at a task, it edits the scripts,
and every change lands through a pull request you review before it merges.
The tooling below makes that loop safe: nothing reaches `main` that hasn't
passed the exact checks CI runs.

## The loop

```
  agent edits  ──▶  make gates  ──▶  git push  ──▶  CI (6 jobs)  ──▶  you review the PR  ──▶  merge
  (aider / CC)      (local, fast)     (pre-push        (real installs      (diff + green ticks)
                                       hook reruns      on clean VMs)
                                       gates)
```

`make gates` runs the same three checks as CI's `lint`/`test` jobs, so a green
local run means a green PR — no round-trips waiting on the runner to tell you
about a missing semicolon.

## One-time setup

```bash
make hooks   # installs the pre-push git hook (core.hooksPath=.githooks)
```

After that, every `git push` reruns `make gates` first and aborts the push if
anything fails. Bypass a single push with `git push --no-verify` (don't make a
habit of it — CI will just catch it later).

You also need ShellCheck locally, because the lint gate is non-negotiable:

```bash
sudo apt-get install -y shellcheck   # Ubuntu/Debian
```

## Local gates

| Command | What it does |
|---|---|
| `make gates` | `syntax` + `lint` + `test` — the full pre-push gate; matches CI |
| `make lint` | `shellcheck -x -P SCRIPTDIR` on every script (zero findings required) |
| `make syntax` | `bash -n` on every script |
| `make test` | both unit suites (library helpers + netmode ruleset) |
| `make dry-run` | preview the auto-tune decision without changing anything |
| `make check` | full `check-system.sh` health check (degrades gracefully) |

## What CI enforces

Every push and PR runs `.github/workflows/ci.yml`:

| Job | Proves |
|---|---|
| `lint` | `bash -n` clean + ShellCheck with zero findings |
| `test` | unit tests pass; `tune.sh --dry-run` changes nothing |
| `system` | nft ruleset + systemd units are valid; the inbound guard never filters SSH |
| `minimal-base` | `install_dependencies.sh` resolves every tool on a bare `ubuntu:24.04` |
| `e2e` | a real Ollama install generates text, and aider → backup/restore → uninstall all work |
| `webui` | Open WebUI container comes up and survives a volume backup/restore |

CI green is a floor, not a ceiling: the `minimal-base` and `e2e` jobs exist
because "passes on a preloaded runner" repeatedly hid bugs that only bit on a
bare VM (missing `zstd`, an unset `$HOME`). If you add a runtime dependency,
add it to the `minimal-base` assertion too.

## Ground rules

These mirror `CLAUDE.md` and are what a reviewer checks for:

- **Bash only**, `#!/usr/bin/env bash`, `set -euo pipefail`.
- **Idempotent** — every script must be safe to re-run.
- **Root through `as_root()`**, never a bare `sudo` sprinkled around.
- **ShellCheck-clean** under `-x -P SCRIPTDIR`; never silence a finding you can fix.
- **Never weaken a CI gate to make it pass.** If a gate is wrong, fix the gate
  honestly and say why in the PR.
- New behavior gets a test (`tests/`) where it's unit-testable.

## Four shell traps that turn a gate into decoration

All four were shipped here at least once. They matter more in an assertion
than in ordinary code, because each one fails *silently in the passing
direction* — the gate keeps reporting green, or red, for the wrong reason.

**1. `cmd | grep -q PATTERN` under `set -o pipefail`.** `grep -q` exits the
instant it matches, closing the pipe; the writer is killed by SIGPIPE and the
pipeline reports 141. So the check fails *because* the pattern was found —
but only once the output is big enough to still be writing, which makes it
look intermittent. Capture first, then match a herestring:

```bash
out="$(some_command 2>&1)"
grep -q 'expected' <<<"${out}" || { echo "FAIL: ..."; exit 1; }
```

**2. `grep -q PATTERN && { echo FAIL; exit 1; }` under `set -e`.** Here a
*non*-matching grep is the passing case, and the AND-list's non-zero status
aborts the step anyway. Use `if`/`fi` for negative assertions.

**3. `bash -c '! some_function'` in `tests/`.** A child shell has never
sourced `lib.sh`, so the function is "command not found" (exit 127) and `!`
turns that into a pass — a test that cannot fail. Call a local wrapper
function instead.

**4. Lint that depends on an untracked file.** `shellcheck -x` *follows*
`source`/`.` targets. A literal `. "${SOMEDIR}/.env"` resolves in a developer's
checkout, where `.env` exists, and fails in CI, where it never does (SC1091) —
so `make gates` passes locally and the build goes red. Keep runtime-path
sourcing out of the analyser's way (running it inside a quoted `bash -c` is
opaque to it) rather than reaching for a suppression. To check the CI
condition before pushing:

```bash
mv .env /tmp/ && make lint; mv /tmp/.env .
```

The habit that catches the first three: **mutate the thing under test and
confirm the test goes red.** A test that has never failed has not been tested.
The habit that catches the fourth: **ask what CI has that you don't, and what
you have that CI doesn't.**

And a warning about that habit, from this repo: a mutation that does not apply
looks exactly like a test that cannot fail. Twice, a `sed` that silently
matched nothing was read as "the test didn't catch it" and nearly cost a good
assertion. **Print proof the mutation landed** (`grep -c`) before believing
what the test says about it.

## Settings that are *applied* are a bug factory

Most of `.env` is read fresh on every run. A few settings are **applied** to
something long-lived — a systemd drop-in, a docker container, a systemd timer —
at the moment that thing is created. Editing `.env` afterwards changes nothing
until it is rebuilt, and nothing about that is visible: no error, no log line,
just the old behaviour continuing.

Four separate bugs in this repository came from exactly that, and each was
silent in a different way: a keep-alive that never took effect, a chat app
still accepting signups after its owner closed them, backups on a cadence
nobody chose, and a chat app pointed at an Ollama port nothing listened on.
Three of them had documentation telling users to edit the key.

So, when you add a setting that gets baked into something:

1. **Compare it back.** `webui_drift()` and `ollama_dropin_matches()` exist for
   this; add to them rather than writing a fourth comparison inline. Three
   inline copies is precisely how signups came to have no check at all.
2. **Make `lca apply` apply it**, so users need one command and not a table.
3. **Say which key drifted, and what it costs.** "PORT differs" and "anyone can
   still register an account" are not the same news.

`tests/test-lib.sh` enforces the first point generically: every `-e KEY=` that
`install_webui.sh` bakes into the container must be compared somewhere, so the
next one is caught without anyone noticing it. Prefer that shape of test — one
that fails for a class — over one more hand-written case.

## Reviewing a PR

The diff is the source of truth. Worth a close look:

1. **The green ticks** — all six jobs, not just `lint`. `e2e`/`webui` are where
   real breakage shows up.
2. **Idempotency and the no-systemd / offline paths** — the fragile parts of a
   provisioning stack are the second run and the degraded environment, not the
   happy path.
3. **Anything touching `netmode.sh`, nftables, or SSH** — a firewall mistake can
   lock you out of the box. Confirm the inbound guard still never references
   port 22 and the drop rule stays last in every chain.
