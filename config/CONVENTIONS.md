# Coding conventions

How this stack should behave. Read by all three surfaces — **aider** (`lca`),
the **phone chat app** and the **agent** — and switched off for all three by
`AIDER_CONVENTIONS=false`. It is *appended* to the chat app's built-in prompt,
never substituted: that part tells the model it has no filesystem and no
tools.

Kept short on purpose: it is re-sent on every message, out of the context your
conversation needs. `lca check` warns if it outgrows its share.

- Make the smallest change that satisfies the request; don't refactor or
  reformat code you weren't asked to touch.
- Match the surrounding file's style, naming and structure.
- Comment only non-obvious intent, never what the code already says. No
  license or authorship headers.
- Preserve existing behavior and public interfaces unless asked to change them.
- Prefer the standard library and already-imported dependencies; call out any
  new one.
- In shell scripts: keep them bash-clean under `set -euo pipefail` and quote
  your variable expansions.
- If the request is ambiguous, take the most conventional reading and state
  the assumption in one line.

## Bash gotchas we've hit for real

Each silently broke something here. Copy the "correct" form.

**1. `((x++))` returns non-zero when x was 0, so `set -e` kills the script.**
Post-increment yields the OLD value.

```bash
f() { local n=0; ((n++)); echo hi; }        # BROKEN: exits 1, never prints
f() { local n=0; n=$((n+1)); echo hi; }     # correct
```

**2. `local` swallows the exit status of a command substitution** — you get
`local`'s own 0, so `|| handle_error` never fires. Declare, then assign; same
for `export`/`readonly`.

```bash
f() { local m="$(grep -c nope "$f")"; }   # BROKEN: $? is 0
f() { local m; m="$(grep -c nope "$f")"; }   # correct: $? is 1
```

**3. A reader that exits early SIGPIPEs the writer, and `pipefail` makes that a
failure.** `grep -q` leaves on its first match, so the pipeline is 141 — "not
found" exactly when it WAS found. Capture first, then match.

```bash
if some_producer | grep -q "$pat"; then    # BROKEN: 141 under pipefail
out="$(some_producer)"; if grep -q "$pat" <<<"$out"; then    # correct
```

**4. `# shellcheck disable=` applies to the NEXT line only** — put it
immediately above the line it excuses.

```bash
# shellcheck disable=SC2016

grep 'literal ${VAR}' "$f"     # BROKEN: blank line, directive does not apply
# shellcheck disable=SC2016
grep 'literal ${VAR}' "$f"     # correct
```
