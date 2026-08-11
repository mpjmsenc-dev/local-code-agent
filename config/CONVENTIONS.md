# Coding conventions

How this stack should behave. Read by **aider** (`lca`), the **chat app** and
the **agent**; `AIDER_CONVENTIONS=false` switches it off for all three. It is
*appended* to the chat app's prompt, never substituted — that part tells the
model it has no filesystem and no tools. Short on purpose: it is re-sent on
every message.

- Make the smallest change that satisfies the request; don't refactor code you
  weren't asked to touch.
- Match the surrounding file's style, naming and structure.
- Comment non-obvious intent only. No license or authorship headers.
- Preserve existing behavior and public interfaces unless asked to change them.
- Prefer the stdlib and already-imported deps; call out any new one.
- In shell: bash-clean under `set -euo pipefail`, and quote your expansions.
- If the request is ambiguous, take the most conventional reading and state the
  assumption in one line.

## Bash gotchas we've hit for real

Each silently broke something here. Copy the "correct" form.

**1. `((x++))` returns non-zero when x was 0, so `set -e` kills the script** —
post-increment yields the OLD value.

```bash
f() { local n=0; ((n++)); echo hi; }      # BROKEN: exits 1, never prints
f() { local n=0; n=$((n+1)); echo hi; }   # correct
```

**2. `local` swallows the exit status of a command substitution** — you get
`local`'s own 0, so `|| handle_error` never fires. Declare, then assign; same
for `export`/`readonly`.

```bash
f() { local m="$(grep -c x "$f")"; }      # BROKEN: $? is 0
f() { local m; m="$(grep -c x "$f")"; }   # correct: $? is 1
```

**3. A reader that exits early SIGPIPEs the writer, and `pipefail` makes that a
failure.** `grep -q` leaves on its first match, so the pipeline is 141 — "not
found" when it WAS. Capture first, then match.

```bash
if producer | grep -q "$pat"; then                       # BROKEN: 141
out="$(producer)"; if grep -q "$pat" <<<"$out"; then     # correct
```

**4. `# shellcheck disable=` applies to the NEXT line only** — put it directly
above the line it excuses, reason above that.

```bash
# shellcheck disable=SC2016
                        # BROKEN: a blank line here excuses nothing
grep 'x ${VAR}' "$f"
```

**5. A test that greps for a NAME passes on the definition.** Three gates here
were written that way in one day; each stayed green after every caller was
deleted. Drive the behaviour instead.

```bash
grep -q 'helper' lib.sh             # BROKEN: lib.sh defines helper
[[ "$(under_test)" == expected ]]   # correct: drive it
