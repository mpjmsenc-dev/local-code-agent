# Contributing

This repo is built to be extended by an **AI coding agent with a human
reviewer** — you point aider (or Claude Code) at a task, it edits the scripts,
and every change lands through a pull request you review before it merges.
The tooling below makes that loop safe: nothing reaches `main` that hasn't
passed the exact checks CI runs.

## The loop

```
  agent edits  ──▶  make gates  ──▶  git push  ──▶  CI (7 jobs)  ──▶  you review the PR  ──▶  merge
  (aider / CC)      (local, fast)     (pre-push        (real installs      (diff + green ticks)
                                       hook reruns      on clean VMs)
                                       gates)
```

`make gates` runs the same three checks as CI's `lint`/`test` jobs. That is two
of CI's seven, and the other five need a clean machine: system artifacts, a
fresh install through `setup.sh`, the minimal-base dependency check, a real
Ollama install and generation, and the chat app's container. So a green local
run is a fast way to catch a missing semicolon, **not** a promise of a green PR
— `.githooks/pre-push` says the same thing, and a gate in the suite keeps both
of them honest about it.

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

## Run `make hooks` first — this is not optional advice

`.githooks/pre-push` runs `make gates` before anything reaches GitHub, and it
does nothing until `make hooks` points git at it. A fresh clone does not have
it enabled.

This is worth stating plainly because it has already cost a red build. A commit
went out with a ShellCheck failure in it, from a session where every other
commit had been linted by hand: the check was chained with `;` instead of
`&&`, so `make lint` printed `Error 1` immediately above a successful push. The
hook would have refused that push. Hand-running the gates works right up until
the one time the shell does not do what you read.

If you are driving this repo with an agent, enable it on the agent's checkout
too. The loop is *edit → gates → push*, and the hook is what makes the middle
step non-optional rather than remembered.

## Local gates

| Command | What it does |
|---|---|
| `make gates` | `syntax` + `lint` + `test` — the full pre-push gate; matches CI |
| `make lint` | `shellcheck -x -P SCRIPTDIR` on every script (zero findings required) |
| `make syntax` | `bash -n` on every script |
| `make test` | both unit suites (library helpers + netmode ruleset) |
| `make coverage` | which `lib.sh` functions no test touches — a report, not a gate |
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

## Eight shell traps that turn a gate into decoration

All eight were shipped here at least once. They matter more in an assertion
than in ordinary code, because each one fails *silently in the passing
direction* — the gate keeps reporting green, or red, for the wrong reason.

That framing was itself a trap. This section said "more than in ordinary code"
for months while trap #1 sat in `scripts/ask.sh`, killing
`lca logs | lca ask` — the first command TROUBLESHOOTING.md recommends —
with exit 141 and no output at all, on every input over 64 KiB. Read these as
rules about bash, not as rules about tests.

**1. `cmd | grep -q PATTERN` under `set -o pipefail`.** `grep -q` exits the
instant it matches, closing the pipe; the writer is killed by SIGPIPE and the
pipeline reports 141. So the check fails *because* the pattern was found —
whenever the writer still has a write in flight, which makes it look
intermittent. Do not reason about whether the output "fits": this suite lost a
run to `sed uninstall.sh | grep -q` on a **9.5 KiB** file, comfortably inside
the 64 KiB pipe buffer, then passed five times on byte-identical code. `sed`
writes in blocks, so the race needs an unlucky schedule, not a big file. Size
only changes the odds. Capture first, then match a herestring:

```bash
out="$(some_command 2>&1)"
grep -q 'expected' <<<"${out}" || { echo "FAIL: ..."; exit 1; }
```

The same shape with `head -c` instead of `grep -q` is how `lca ask` lost its
piped input: `printf '%s' "${var}" | head -c 12000` returns 141 as soon as
`${var}` outgrows the pipe buffer, and errexit exits mid-assignment. To take a
prefix of a variable, slice it — `"${var:0:12000}"` — and never build a pipe
you only intend to half-read.

**`awk` with an `exit` is the same reader, and it is the one that keeps getting
written anyway.** `sed file | awk '/start/ { inb = 1 } inb && /^}/ { exit }'` is
the standard way this suite reads one function out of a script, and every one of
them is the trap above wearing a different hat: awk stops reading at the closing
brace, `sed` is still writing, SIGPIPE, 141. It turned CI red on
`ollama_models_dir`, which sits halfway up `lib.sh` — the largest file here, so
~600 lines were still queued. The identical checks against `motd.sh` have never
failed because that file fits inside the buffer, which is luck, not design. If
you need a function's body, read the whole file first:

```bash
body="$(sed -n '/^the_function() {/,/^}/p' "${REPO}/scripts/lib.sh")"
awk '...' <<<"${body}"
```

A `sed` range reads to the end and exits early nowhere. All ten call sites in
`tests/test-lib.sh` have been converted and a gate now forbids the shape
outright — blanket, not scoped to awk programs that visibly `exit`, because the
safe ones are safe only until someone adds an `exit` to them.

Converting them is mechanical but not scriptable: a first attempt in bulk broke
two gates by mis-detecting where an awk program ended (the line closed `' || {`),
and it left them running awk with **no input at all** — still exiting 0, still
reported as passing. If you ever redo this kind of sweep, change one call site
at a time, and prove each converted gate still fails when you break the thing it
watches. An unchanged assertion count proves nothing: a vacuous gate counts too.

**2. `grep -q PATTERN && { echo FAIL; exit 1; }` under `set -e`.** Here a
*non*-matching grep is the passing case, and the AND-list's non-zero status
aborts the step anyway. Use `if`/`fi` for negative assertions.

Be precise about *why*, because the obvious explanation is wrong and it has
been written into this repo incorrectly at least once. `set -e` **exempts**
every command in an `&&` list except the last, so a false left side does not
abort anything:

```bash
f() { local x=1; (( x > 9 )) && x=2; }   # f returns 1 — the trap
g() { local x=1; (( x > 9 )) && x=2; echo hi; }   # g returns 0 — harmless
```

The damage is confined to the **last statement of a function**, where the
list's status silently becomes the function's exit status — which in a `check`
is the difference between pass and fail. Mid-function it is merely untidy.
Verified by running both, not by reasoning about the manual.

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

**5. A whole-file scan that finds its own explanatory comment.** The most
repeated mistake in this repository, by a distance. You
write a check that greps for `webui_prompt_comparable`, and directly above it
you write a comment explaining that the fix was to call
`webui_prompt_comparable`. The grep finds the comment. The gate now passes on
code that has none of the thing it is checking for, and it will pass forever.

It is invisible in review because both halves are correct on their own, and it
survives mutation testing unless the mutation happens to remove the comment
too. Strip comments before scanning:

```bash
code="$(sed 's/#.*//' "${file}")"
grep -q 'the_helper' <<<"${code}"
```

Where a scan must run over the whole file, spell the needle so it cannot match
itself — `'/bin/pyth[o]n'`, `'[$]{...}'` — and say in a comment that that is
why it is written oddly, or the next person will "fix" it.

**6. A multi-byte character in a regex, under a locale you did not choose.**
`grep`'s `.` matches a *byte* under the POSIX/C locale, and these docs are full
of en and em dashes at three bytes each. `[0-9]{4,5}.[0-9]{4,5}` matched
`4096–16384` in an interactive shell and matched nothing inside the suite,
where `LC_CTYPE=POSIX`. Use a range wide enough for the encoding — `.{1,3}` —
or match on the digits alone and never on what sits between them. A bracket
expression containing a multi-byte character is worse still: `[–-]` is three
bytes inside `[]`, not one character.

**7. `exec {FD}>file 2>/dev/null` — the `2>/dev/null` is not part of the
open.** `exec` with redirections and *no command* applies every one of them to
the running shell. That trailing muffle silenced stderr for the whole rest of
`backup.sh`: on a filesystem with no space left, the tar failure's own
`die()` — "Could not write … (disk full? check: `df -h`)" — went to
`/dev/null`, and a nightly backup failed with exit 1 and a completely blank
stderr. Measured, before and after. Nothing needs muffling here anyway: a
failing `exec` redirect returns non-zero and prints its own diagnostic rather
than killing the shell, so `exec {FD}>lock || { warn …; return 0; }` is both
safe and quiet enough. `exec somecmd 2>/dev/null` is fine — with a command,
the redirection goes to the command.

And one that is not a trap in the code but in the *coverage*: a function can be
thoroughly gated and never once executed. Two of the functions that write this
project's firewall ruleset were guarded only by greps for their source text —
the only ways to run them are `netmode.sh offline` and `harden`, which a suite
must not do, so nothing ever did. `make coverage` answers "what does no test
touch?" in one command. Read its own caveats first: it measures functions run
in the suite's shell, and the house style for a behavioural test is a child
`bash -c`, which it cannot see.

**8. `awk '/x/ { exit 0 } END { exit 1 }'` — the rule-level `exit` runs `END`
too.** `exit` in an awk rule sets the status and *then* executes the `END`
block, so an `END { exit 1 }` underneath silently overwrites it and the check
fails on code that is correct. Both times this was hit here, the gate reported
a real ordering as wrong. Let `END` decide alone:

```awk
/opens/  { seen = 1 }
/uses/   { if (!done) { done = 1; in_order = seen } }
END      { exit (done && in_order) ? 0 : 1 }
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

## A scalar flag named like an array elsewhere fails ShellCheck

`shellcheck -x` follows `source`, and it tracks a variable's *type* across
everything it has read — the file under test and every file that file sources.
So a local scalar in `tests/test-lib.sh`:

```bash
local drifted=0            # SC2178: "used as an array but now assigned a string"
```

trips on `scripts/lib.sh` declaring `local drifted=()` inside an unrelated
function. The scopes are genuinely separate and the code is correct; ShellCheck
is not scope-aware here, and the repo lints clean, so the warning has to go.

This cost three separate cycles in one day — `bad`, `stale`, `drifted` — each
found only at `make lint` after the tests were already green. Give error flags
and accumulators a name specific to what they count: `recipe_mismatch`,
`recipe_drift`, `accepts`/`rejects`. It reads better anyway, and the generic
names are exactly the ones already taken.

## Settings that are *applied* are a bug factory

Most of `.env` is read fresh on every run. A few settings are **applied** to
something long-lived — a systemd drop-in, a docker container, a systemd timer,
an nftables ruleset — at the moment that thing is created. Editing `.env`
afterwards changes nothing until it is rebuilt, and nothing about that is
visible: no error, no log line, just the old behaviour continuing.

Five separate bugs in this repository came from exactly that, and each was
silent in a different way: a keep-alive that never took effect, a chat app
still accepting signups after its owner closed them, backups on a cadence
nobody chose, a chat app pointed at an Ollama port nothing listened on, and an
inbound guard still dropping the port a service had moved off — leaving the
unauthenticated Ollama API answering on the new one, publicly, while
`lca apply` said everything matched. Four of them had documentation telling
users to edit the key.

The guard is the one to learn from, because it had a comparison *and* a fix
command and was still wrong: the fix only ever ran as a side effect of
re-creating the chat app container, so with the chat app switched off nothing
re-applied it. Being reachable from `lca apply` is not the same as being
converged by it.

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

## Advice is part of the product, and it is tested like it

Half of what this project does is tell someone what to type next. A sentence
that names the wrong command is a defect in the same way a wrong exit code is,
and it is worse in one respect: the reader follows it, gets a second failure on
top of the first, and has no way to tell which of the two was our fault. Five
gates in `tests/test-lib.sh` enforce that, all of them written after shipping
the thing they now catch.

**1. Every flag we name must be one that script documents.** Every
`some-script.sh --flag` in the README, in `docs/`, in `lca check`'s output or
in `bin/lca` has to appear in that script's header, `usage()` or help text, or
CI fails naming the pair. `lca check` spent a while recommending
`netmode.sh --install-service`: it works, and it appears in no usage text
anywhere, so a reader who tried to look it up before running it as root found
nothing. A script advertising `[... args...]` is exempt because it forwards
what it does not recognise — `run-agent.sh` hands everything to aider — and it
is exempt for that reason, not by name.

**2. Every path we name must resolve from anywhere.** `bin/lca` never `cd`s,
deliberately: aider has to see *your* project. So the normal way to run any of
this is `lca check` from `~/my-project`, and the health check answered
`(./webui.sh start)`. Build paths from `${SCRIPT_DIR}` or `${REPO_ROOT}`. The
gate erases both before matching, so anything relative still standing is real,
and it covers `usage()` bodies as well as message helpers — `webui.sh`'s usage
was where the last one hid.

**3. Docs use the `lca` form, or say where to stand.** `lca backup` works from
anywhere; `./backup.sh` in a block with no `cd` does not. `./setup.sh` is the
exception that proves it — there is no `lca setup` and cannot be one before the
install — so any fenced block running a `./script.sh` must contain a `cd`.

**4. `--help` explains, and does nothing else.** `lca test --help` used to run
the whole acceptance suite, minutes of real generation, because `selftest.sh`
never looked at `"$@"`. `lca restore --help` answered "Backup file not found:
--help" from the command that wipes a docker volume. `lca harden --help`
applied the firewall, because `netmode.sh` ignored everything after its
subcommand and `bin/lca` forwards trailing arguments verbatim. Every script
`bin/lca` dispatches to is now *run* with `--help` in CI and must exit 0 with
usage inside a timeout — the timeout is part of the assertion, since a script
that ignores the flag and does its job is the failure being caught.

**5. That list has to stay complete.** A second gate reads `bin/lca`'s dispatch
table and fails if it names a script the `--help` list does not cover, so a new
subcommand cannot arrive untested.

When a check like #4 could fail destructively, exercise it through the harmless
sibling: the `--help` test drives `netmode.sh status`, not `harden`, because a
test that proved `harden --help` is safe by running `harden` would be its own
worst outcome. Pair it with a structural check — that the argument validation
sits *above* the dispatch — to cover what the safe path cannot reach.

## The system prompt is code, and it has to be measured

`lca_system_prompt()` in `scripts/lib.sh` is shipped to every user and read by
the model on every single message. Editing it feels like editing prose. It is
not: it is the program the assistant runs, and the only way to know what a
change does is to run it against the model that will actually execute it.

Two rules, both learned by getting them wrong:

**Test on the smallest rung, not the biggest.** A base 8 GB droplet runs
`qwen2.5-coder:3b`. Wording that a 7b follows without effort, a 3b ignores
completely — the first fix here read perfectly on 7b while 3b still produced
the exact failure it was written to prevent. If it is not verified on 3b, it
is not verified.

**Rules lose to a model's priors; concrete triggers win.** These two say the
same thing, and against 3b on a real user's request they do not perform
remotely alike:

| Prompt says | Hands over | Leads with it | Doomed tutorial |
|---|---|---|---|
| nothing about it — what shipped before | 0/8 | 0/8 | **8/8** |
| "when a request needs files created or edited" | 1/4 | 0/4 | 3/4 |
| "when asked to build, create, make or add…" + "Open with exactly:" | **8/8** | **8/8** | 0/8 |

The middle two rows differ in nothing but that sentence, so the sentence is
what moved it.

The abstraction asks a 3 billion parameter model to classify a request before
it can obey. Its prior — "someone asked for an app, write a tutorial" — wins
that argument every time. Naming the user's own verbs removes the
classification step, and saying *where the answer goes* beats saying what it
should contain.

**There is a bench for this — use it.** `scripts/prompt-bench.sh` asks the real
model the three questions that matter and counts the outcomes:

```bash
scripts/prompt-bench.sh -n 6                 # the prompt as it stands
scripts/prompt-bench.sh -n 6 -f candidate.txt   # a change, same -n
scripts/prompt-bench.sh -n 6 -m qwen2.5-coder:3b   # pin the smallest rung
```

Three questions must hand over (`build me an app`, the same with a feature
list, and the starter question the chat's own empty screen offers) and two must
**not** (`how do I take a backup`, `explain list vs tuple` — the second is what
the chat is *for*).
A change has to hold all three columns at once, which is the difficulty: the
guard that fixed the backup hijack had to be checked against the build case,
and the line that made answers say *where* had to be checked against both.

It is deliberately outside `make test` and CI — it needs a running model and
minutes of CPU, and CI has neither. Its **classifiers** are unit-tested there,
because a wrong matcher makes every future measurement wrong in a way nobody
would notice; two already did.

So: run each candidate several times (they are sampled, so one generation
proves nothing), count outcomes, and put the counts in the commit message.
**Use `-n 20`, and the same seeds either side.** Six is not enough — not just
wide, but wrong: one change read 5/6 then 2/6 at `-n 6` (a regression) and
12/20 then 16/20 at matched seeds (an improvement). The same prompt pair read
2/6 and 3/6 at one seed range and 8/10 and 2/10 at another. Also check the change does
not fire on questions it should not — a handover rule strong enough to beat
the tutorial reflex can easily hijack "what does this error mean?", and a chat
that answers everything with `cd ~/my-project && lca` has been made useless in
the course of making it honest.

**Do not name the wrong answer, even to rule it out.** Measured on the 3b
rung, n=10 each, against the starter question that asks for "the exact command
for the terminal case":

| Wording | Names the bare command |
|---|---|
| `the bare word 'lca' — not 'lca ask'` (shipped) | 6/10 |
| adding `with nothing after it` | **9/10** |
| `every 'lca <word>' is a server command… 'lca apply' changes settings` | **1/10** |

The last row is the lesson: mentioning `lca apply` as a counter-example taught
the model to answer `lca apply`. State what the command **is**; do not
enumerate what it is not. The winning change was one clause, and the other
bench questions were re-run to prove it cost nothing elsewhere.

**Describing an argument slot invites the model to fill it.** The same lesson
from the other side, measured at `-n 20` on the same seeds. The prompt's
command table says `lca logs   recent logs from Ollama, the chat app and the
installer` and never mentions that it takes one of four fixed sources, so
naming them looked like plain accuracy:

| | invented an `lca` command |
|---|---|
| shipped wording | 2/20 |
| naming the log sources | **9/20** |

It started passing a source and guessing it wrong — `lca logs systemd`. The
handover metrics did not move either way. Two experiments now point the same
direction: more detail about how a command *can* be used costs more than it
buys, while an example of the right answer is safe.

**A command you put in the prompt is a command you are shipping — run it.**
Once the handover fired reliably, it was reliably handing out
`cd ~/my-project && lca`, which dies on `cd: No such file or directory` for
anyone who does not already have that directory — i.e. most of the people who
ask for an app to be built. Getting the model to say a thing and having the
thing work are two separate problems, and the second one is invisible from the
prompt. Run the literal line in a throwaway `HOME`, and check the model
reproduces it *whole*: a longer recipe is only a fix if it survives the copy
(this one did, 6/6 verbatim — but that was worth measuring, not assuming).

**A comment on its own line survives the copy; a trailing one does not.** The
answers are read on a phone, so the recipe has to say where it runs. Three
forms, same information, measured the same way:

| Where the "where" lives | says where |
|---|---|
| an instruction — "Add one line: that goes in a terminal…" | 1/6 |
| `#` comment on its **own line** above the command | **5/6** |
| the same words trailing the command line itself | **0/5** |

The instruction fails because a 3b model will not narrate context on request.
The trailing comment fails for a different and more useful reason: the model
reproduces a block line by line and drops what hangs off the end of a line. So
"put it in what gets copied" is not enough — it has to be its own line to get
copied.

That last row also nearly cost a gate. Accepting it would have meant relaxing
the pattern that requires the recipe line to end at `lca`, which is the gate
that catches the `lca ask` misdirection. Loosening a gate to fit a new shape is
how gates stop gating; it was worth measuring before touching it, and the
measurement said don't.

**Read a real answer before you trust a threshold.** Every proxy metric here
has been wrong at least once, always in a way that looked like a product
defect:

| The metric said | The truth was |
|---|---|
| "handed over 1/6" | the pattern missed "run `lca` in your project directory" |
| "tutorial 1/3 on 7b" | the detector counted our *own* recipe's `mkdir` |
| "truncated 2/4" | the harness capped generation at 400 tokens |
| "complete file 1/4" | a correct `config.py` is 3 lines; the threshold wanted 5 |

Each cost a round trip, and two of them nearly went into a commit message as
findings. When a number moves in the direction you expected, that is when to
be most suspicious of it — dump one raw generation and read it before drawing
any conclusion. The fourth row was found that way after the third had already
been found that way.

**Count the failure, not the success.** Scoring "did it say the right thing?"
means writing a regex for every phrasing of right, and the one used here quietly
missed "run `lca` in your project directory" — so every reported success rate
was a floor, not a rate. Scoring the *failure* is far more reliable: "did it
start a numbered multi-file tutorial" has one obvious shape and no synonyms
worth chasing. Prefer the metric that cannot flatter you.

And prompt length is a real cost: it is spent on every message, out of a 4096
token context on the 3b rung. Cut what measurement shows does not work rather
than layering more words on top.

## Drive the behaviour. Reading the source for evidence of it is not a check

This is the single most common way a gate here has turned out to be
decoration, and it has now happened four times in two days:

| The gate | What it read | Why it could not fail |
|---|---|---|
| the conventions keyed-phrase gate | `config/CONVENTIONS.md`, raw | the editor note at the top lists every keyed phrase, so the grep always matched — for two sessions |
| `webui.sh` drift reporting | seven hand-written `check` lines naming seven keys | `webui_drift` grew an eighth; nothing noticed, and `WEBUI_BANNERS` drift printed nothing under a green health line |
| `every_installed_unit_is_removed` | `uninstall.sh`, for each unit's *name* | a file that merely mentions a unit passes; removal was never attempted |
| `net_guard_still_dies` | `net_guard`'s own body, for the string `die ` | stubbing the function to `return 0` leaves the body, and that string, exactly where they were |

Every one of them read source text as evidence that a behaviour happens, and
every one of them stayed green while the behaviour was gone. The last was
found by mutation sweep: stub each function in `scripts/lib.sh` to `return 0`,
run the suite, and see what still passes. **Forty-four functions survived.**
(Most have since been driven; the section below on what a real machine can
settle carries the current count and how the rest were dealt with.)

**So: drive the thing.** Call the function, with the world stubbed around it,
and assert on what it returns, prints or leaves behind. Nearly everything is
drivable with less setup than the grep took to write — the survivor section at
the end of `tests/test-lib.sh` drives a Tailscale address off a stubbed
`tailscale`, a relay address off a real unit file in the sandbox, and
`confirm`'s refusal through a real terminal via `script`.

**Where driving is genuinely impossible** — a real GPU, a real sudo refusal on
a suite that runs as root, a live container, a package install — a source grep
is allowed, and it must say so:

```bash
# SOURCE-GREP: this needs an NVIDIA card, which no runner here has. What it
# cannot check is that the parse is right for a real nvidia-smi.
gpu_probe_reads_the_largest_card() { ... }
```

**Extract-to-drive is not a source grep**, and it is the shape to reach for
when a script cannot be sourced (`agent.sh` and `check-system.sh` both run
`main` at the bottom). Pull the block out with `awk`, `eval` it with the world
stubbed, and assert on what it *did* — `numeric_complaints`,
`seeded_settings_payload` and `drift_case_block` all work this way. It still
reads source, so it still carries a `SOURCE-GREP:` marker, and the marker says
the one thing such a helper genuinely cannot check: that the extraction still
finds the right block. Every one of them fails loudly on an empty block, which
is what stops it asserting over nothing.

**A known false positive, so nobody thinks they have done something wrong.**
The classifier asks whether a function mentions a `${REPO}/` path *and* uses a
text tool. A gate that **runs** a repo script and greps its **output** does
both, and is the opposite of a source grep — `uninstall_says`,
`tune_dry_run_in` and `big_unknown_is_elided` are all in that position. They
carry a marker saying so. That is deliberate: a tighter rule would have to
guess which tool touched which path, and a classifier that guesses is the thing
this section exists to stop. A handful of false positives with an honest
sentence each is a better trade than one clever rule nobody can audit — and the
count only grows as gates are converted, because a driver is exactly the shape
the classifier mistakes for a source grep.

`new_source_greps_are_justified` enforces it: a function in `tests/test-lib.sh`
that reads repo source with a text tool, is not in
`tests/source-grep-census.tsv`, and carries no `SOURCE-GREP:` line, fails the
suite. The census is a record of debt, not permission.

### What the census found, from reading all 278 of them

The list started as 286 grandfathered names with no reason beside any of them.
Two samples of a dozen each disagreed about how much of it was real debt — four
of twelve, then eight of twelve — so the whole population was read one gate at a
time instead. That read is `tests/source-grep-census.tsv`, and it is checked in
because a number nobody can re-derive is a number nobody should trust.

| | count | share | what it is |
|---|---|---|---|
| **A** | **153** | 55% | the claim is a runtime behaviour and the only evidence is that the source still says so. **This is the debt.** |
| B | 97 | 35% | the subject genuinely is text — a document, a message, a config value, agreement between two written artefacts, or an exhaustive absence rule over the source itself |
| FP | 28 | 10% | not debt: the gate drives its subject and greps the *result* |

153 of the suite's 1,239 checks, then — about one in eight — assert a runtime
behaviour and observe only text. `group_a_debt_has_not_grown` pins that number;
converting a gate moves its row from A to FP rather than deleting it, so the
count is a ratchet and not a promise.

That table is the measurement as taken. The population has grown since, because
the classifier was widened twice (see the blind spots below), and the A count
has come down as gates were converted; `tests/source-grep-census.tsv` is always
the current answer, and the ratchet in `group_a_debt_has_not_grown` moves with
it. What must never happen is the A count going up.

Two counting errors surfaced in the same read, and both flattered the old
number:

- **28 of the 296 names the scanner flags are helpers, not gates.**
  `probe_region`, `baked_keys`, `drift_case_block` and the rest extract source
  for a gate to judge. Their debt, if any, belongs to the gate that calls them,
  and counting them twice made the population look bigger than it was.
- **Ten gates read repo source only through one of those helpers, and the
  scanner cannot see them at all.** `every_drift_key_is_reported` compares two
  lists that `drift_keys` and `drift_arms` pulled out of the source; the
  `${REPO}/` path is in the helper, so the classifier's rule — *mentions a
  `${REPO}/` path **and** uses a text tool* — never fires on the gate. Moving a
  read into a helper is therefore a way to silence the meta-gate without
  changing anything, which is the same shape as everything else in this
  document: a thing that reports success having done nothing.

The census carries those ten anyway. They are labelled by what they do, not by
what the scanner can see.

**And a third route past the classifier, found later: a repo path held in a
variable.** `${APPLY}`, `${TESTS_DIR}`, `${CENSUS}` and `${DOC_SURFACES[@]}`
all hold paths inside the checkout, and the rule looked for the literal
`${REPO}/`. Seventeen more gates read source through one of them — including
three checks that grepped `apply.sh` for the *name* of an applier, which is the
weakest shape this document describes, sitting unclassified. The classifier
knows those four variables now. The lesson is not the variable list: it is that
a rule written as "the body contains this literal" will keep meeting shapes it
was not written for, and each one is invisible in exactly the way that matters.

The meta-gate is itself the kind of thing that becomes decoration, so it is
driven too: its classifier is run over a fixture holding one offending function
and one justified one, and asserted to tell them apart. Without that, a
classifier that silently matched nothing would be the same bug, one level up.

## A gate that is never run is worse than no gate

`tests/test-lib.sh` is a linear script: a function is a gate only because a
`check` line names it. Converting `install_is_truncation_safe` from a source
grep to a driven test replaced the body *and* the `check` line that ran it. The
suite stayed green, the census still counted the gate, `make gates` passed, and
the gate was dead — noticed only because a mutation of `install.sh` came back
killed by three *other* gates and not by that one.

Nothing in 19,000 lines could see it, so now something can. `tests/reachable.awk`
builds a test file's call graph — roots are `check` invocations and top-level
calls, edges are names mentioned inside a function body — and
`no_test_function_is_defined_and_never_run` fails on anything the graph cannot
reach, across every `tests/*.sh`.

It over-approximates deliberately: a name inside a string counts as a call, so
it errs towards silence rather than towards accusing live code. Two things it
found on its first run:

- `command_not_found_handle`, which bash calls itself. Exempt by name, with its
  reason, in `reachable.awk`'s own `exempt` list — and not in a shell array
  beside the gate, because an array naming it would be a top-level mention, so
  the exemption would root the name and the exemption machinery would be doing
  nothing.
- a whole verdict category in `tests/live-verify.sh` — WRONG, documented at the
  top of that file, counted, printed in the summary and included in the exit
  condition — whose reporting function no line ever called, so the column could
  only ever read zero. A column that always reads zero looks like a check being
  made. It was removed.

Its non-vacuity check is worth reading before you copy it: the probe file is a
*copy of `test-lib.sh` itself*, so the deliberately-dead function's name has to
be assembled from pieces. Written as one literal, the name appears in the copy
as a mention inside a live function — an edge — and the dead function comes
back reachable. That is the fourth time a scanner here has been fooled by text
about itself, and the first where the text was the fixture.

## A tool that parses source must tell code from commentary about code

Three times in one session the tooling was fooled by text *about itself*, and
all three were the same mistake wearing different clothes:

| What happened | Why |
|---|---|
| A gate's `SOURCE-GREP:` marker was matched anywhere in the comment block above it — so the section's own prose *explaining what a marker is for* justified the function underneath it. Deleting that function's real marker changed nothing. | the scanner did not require the marker to *begin* a comment line, so an explanation counted as an excuse |
| A scanner treated a one-line `f() { …; }` as an unterminated body and attributed **the entire rest of the file** to it. The baseline generated from it was wrong by ~90 entries. | the scanner handled one shape of the thing it parses and met another |
| A driven test was reclassified as a source grep because a comment in it ends *"and this still passed."* — which contains `sed`. | the scanner matched substrings, in comments, and drew a conclusion about code from prose |

The rule that falls out:

- **Strip or skip comments before drawing a conclusion about code.** A comment
  mentioning `grep` is not a grep; a comment naming a function is not a call.
  Several gates here already do `sed 's/#.*//'` first and say why — that is the
  habit, not a flourish.
- **Match tokens as tokens.** `sed` inside "passed" is not a call to `sed`.
- **Handle every shape of the construct you parse,** especially the one-liner.
  If your scanner finds function bodies by looking for a line that is `}`, a
  `f() { …; }` will silently swallow the file.
- **Drive the scanner over a fixture containing the shapes that would fool it.**
  This is the only one of the four that catches the case you did not think of,
  and it is why `source_grep_gates` and `justified_gates` are run over
  `SG_FIXTURE` — which now holds a one-liner, a prose mention of `sed`, and a
  comment explaining the marker, because those are the three that got through.

The same applies to anything that *edits* source. The mutation harness patches
function bodies by regex, and `ok()   { … }` — three spaces before the brace —
did not match the fixed-string shapes it started with. It reported
`UNPATCHABLE` rather than lying, which is the difference between a harness that
can be trusted and one that cannot; but the list of functions it sweeps is now
derived from the same pattern that patches them, so the two cannot disagree
about what a definition looks like.

And it takes a lock. Two sweeps once ran at the same time — a relaunch whose
predecessor's `xargs` had been reparented to `init` rather than killed with its
parent — both appending to one results file and copying trees into the same
directories. 123 result lines over 73 functions, every tree liable to be
overwritten mid-run by the other sweep. It looked exactly like a result, which
is the whole theme: **anything that writes verdicts to a shared place needs to
be the only thing writing there, and needs to say so rather than assume it.**
When you kill a background pipeline, kill the process *group* — a bare `kill`
on the parent leaves the `xargs` running and adopted by `init`.

## What only a real machine can settle, and how to settle it

A mutation sweep stubs every function in `scripts/lib.sh` to `return 0` and
runs the suite. Forty-four survived the first round. Most were then driven, and
the twenty-nine that were left were listed here — grouped by tier, with a
command and a pass condition for each — as work that needed a droplet.

**Most of that list was an excuse.** Twenty-six of the twenty-nine are parsers
over the output of one command: `docker container inspect`, `docker container
port`, `docker ps`, `ollama list`, `curl …/api/ps`. A recorded sample of that
output settles each of them here, in a second, with **both** answers — so a
probe that always says yes and one that always says no each fail. They are
driven in `tests/test-lib.sh` under *"the probes a mutation sweep could not
kill"*, and the stubs are shell **functions**, because `have docker` asks
`command -v`, which finds a function.

They were then mutation-checked rather than assumed: each target stubbed to
`return 0` in a complete copy of the repo, the suite run, the gate expected to
fail. **Twenty-six of twenty-seven killed, control passing.** The one survivor
was a gate that stubbed the very function it was meant to be testing, which is
the failure this whole document is about arriving from the inside; it now
drives the real one with `curl` stubbed instead.

Two of the twenty-six cannot be stubbed and are not:

- `ollama_bg_env` reads `/proc/<pid>/environ`, so its gate launches a **real**
  process named `ollama` — a copy of `sleep` — with the environment under test.
- `start_ollama_bg` launches through `nohup env … ollama serve`, and `env(1)`
  cannot run a shell function, so its gate puts a real file on `PATH` (through
  `make_stub_dir`/`stub_path`, because a stub directory `sudo` cannot see is
  how a test passes here and fails on a runner that escalates).

Driving `start_ollama_bg` is also what found the command-less `exec` that
silenced stderr for the rest of every `lca` command on a host without systemd.
Nothing in a source grep of that function looks wrong.

### What is actually left

| What | Where | Pass condition |
|---|---|---|
| `gpu_state`, `has_nvidia_gpu` **on a real card** | an NVIDIA host — not the droplet | `lca speed` classifies placement as `active`/`split`/`idle` rather than quoting Ollama's string. The suite settles what these do with and without `nvidia-smi`; what it cannot settle is whether the parse is right for a real one. |
| the no-hang rule for a **sudoer with a password** | a box with a configured sudoers entry — an account is not enough | `sudo -k`, then `lca check`, then the login banner: neither prompts, neither hangs, and both report the firewall / daemon / container as **UNKNOWN** rather than claiming a state they could not read |

`systemd_available` is half-settled and honestly so: a host with no `systemctl`
cannot have systemd, and the suite asserts that anywhere. Which of the two
answers a given machine gives is that machine's business, not a gate's.
`apt_get` is covered by CI's `minimal-base` job, on a bare `ubuntu:24.04`.

Everything else that used to be on this list — `confirm`'s refusing branch,
`netmode_state`, `tailscale_ip4`, `host_listeners`, `ollama_relay_unit_address`,
`agent_workspace_dir`, `venv_python`, `load_env_readonly`, `model_load_notice`,
`root_for_probe`, and the twenty-six above — is driven in the suite now.

The rule that came out of it, and it is the useful part:

> **Assume it does not need a real machine until you have tried to settle it
> here.** A function that only parses one command's output needs a sample of
> that output, not the machine that produces it. Writing "needs a droplet"
> beside it costs nothing today and buys a list nobody works through.


## Run it broken, not working

The happy path is the least informative state to test here, and by a wide
margin. In one day of work on this repo, five of six bugs found by hand came
from running a command on a machine that was *already* degraded, and every one
of them was invisible on a healthy box:

| What was broken | What the command said | The truth |
|---|---|---|
| No WebUI container | "already matches .env" | nothing existed to match |
| Docker daemon stopped | "not created yet — create it with install_webui.sh" | the container may exist; that command cannot work either |
| Ollama not running | *(25 seconds of nothing)* | it was starting the server, silently |
| Ollama not running | ollama's own "run 'ollama serve'" | wrong on a systemd box — that spawns a second server |
| Output captured, not a terminal | plan printed, but not into the pipe | the plan was on stderr |

Two habits fall out of that:

- **Before finishing a command, run it with the thing it depends on turned
  off.** No container, no daemon, no server, no network. A repair command is
  reached for precisely when something is already wrong, so the degraded
  message is the one users actually read.
- **Capture the output; don't just look at it.** `out="$(cmd)"` shows what a
  pipe, a redirect or a CI step sees. A terminal merges stdout and stderr and
  hides the difference — which is exactly how a `--dry-run` whose plan went to
  stderr looked perfect by hand.

And when a probe cannot answer, say so rather than guessing: "no container"
and "cannot reach the daemon" are different facts, and every docker probe
collapses them into the same non-zero exit. A confident wrong line is worse
than an admitted unknown.

## Run it as somebody else, on a real terminal

The account is a state like any other, and it is the one nobody tests: this
project is developed as root, so every path that needs root simply worked.
Create a throwaway user, give it no sudo rights, and run the command under a
**pty** — `sudo -n` behaves completely differently from an interactive sudo,
and a pipe hides the difference:

```bash
sudo useradd -m lcaprobe          # no groups, no sudo, no password
# python3 -c 'import pty; pty.spawn(...)' as that uid, with a time limit
```

The bound is the point. An interactive sudo on a real terminal does not fail,
it **waits**, so the failure mode is a command that never returns — which no
`|| true`, no `2>/dev/null` and no exit-status assertion will ever notice. One
afternoon of this found five, all invisible as root:

| Command | As root | As a user who is not a passwordless sudoer |
|---|---|---|
| the login banner (every SSH login) | 0.10s | two lines, then waits for ever |
| `lca check` | full report | stalls twice; then "docker daemon not responding" and chat app "does not exist", both false |
| `lca status` | full report | two lines, then waits for ever |
| `lca webui status` | full report | *nothing at all*, then waits for ever |
| `lca logs` | full output | ollama section, then waits for ever |

The rule that came out of it, gated in `tests/test-lib.sh`:

- **An action the user asked for** → `can_root`. A password prompt is fair;
  they typed `lca apply`, `webui.sh start`. Refusing where it used to work
  would be the worse trade.
- **A probe that only reports** → `can_root_now` (root, or `sudo -n` works).
  A prompt here is a stall in something nobody asked to run.
- **Either way, never ask silently.** If a typed command is about to escalate,
  print the reason first. A bare `[sudo] password for ...` under a command
  that has produced no output reads as a hang, not as a question.

Two traps in gating this:

- `can_root_now` **contains** `can_root`, so "the fix is present" greps clean
  while a leftover bare call sits three lines below it. That is exactly how
  four of the five above survived a fix to the fifth. Match `can_root([^_]|$)`
  and require *both* directions: the strict call present, no loose call left.
- A `timeout` wrapper does not bound a password prompt. `sudo timeout 15 cmd`
  bounds `cmd`; the prompt happens before `timeout` is ever exec'd. If the
  point is "this must not hang", the order has to be `timeout sudo`, or the
  escalation must not be interactive at all.

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
