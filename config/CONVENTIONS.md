# Coding conventions

This file is the one place to say how you want this stack to behave. All three
surfaces read it:

- **aider** (`lca`) loads it read-only at the start of each session.
- **the phone chat app** gets it appended to its system prompt.
- **the autonomous agent** (`lca agent`) gets it as its default task framing.

`AIDER_CONVENTIONS=false` in `.env` switches it off for all three at once.

What it does **not** do: it is *appended* to the chat app's built-in prompt,
never substituted for it. That built-in part tells the model what it is — a
chat box with no filesystem, no shell and no tools, where `lca` is the thing
that writes files — and nothing you put here removes it. Without that, a model
told to adopt a persona will happily claim it just edited your project.

Kept short on purpose: every line here is re-sent on every message and comes
out of the same context window your conversation has to fit in. `lca check`
warns when it grows past the share this stack budgets for it.

- Make the smallest change that satisfies the request. Don't refactor or
  reformat code you weren't asked to touch.
- Match the surrounding file's existing style, naming, and structure.
- Don't add comments that merely restate the code; comment only non-obvious
  intent. Never add license or authorship headers.
- Preserve existing behavior and public interfaces unless asked to change them.
- Prefer the standard library and already-imported dependencies; call out any
  new dependency you introduce.
- In shell scripts: keep them bash-clean under `set -euo pipefail` and quote
  your variable expansions.
- If the request is ambiguous, implement the most conventional interpretation
  and state the assumption in one line.

## Bash gotchas we've hit for real

Each of these silently broke something here. Copy the "correct" form.

**1. `((x++))` returns non-zero when x was 0, and `set -e` kills the script.**
Post-increment yields the OLD value, so `((total++))` on a zero counter exits 1.

```bash
count() { local total=0; ((total++)); echo "reached"; }   # BROKEN: exits 1, "reached" never prints
count() { local total=0; total=$((total+1)); echo "reached"; }   # correct
```

**2. `local` swallows the exit status of a command substitution.** The status
you get back is `local`'s own, which is 0, so `|| handle_error` never fires.

```bash
f() { local matches="$(grep -c nope "$file")"; }   # BROKEN: $? is 0, grep's failure is invisible
f() { local matches; matches="$(grep -c nope "$file")"; }   # correct: $? is 1
```

Declare on one line, assign on the next. The same applies to `export`, `readonly`
and `declare`.

**3. A reader that exits early SIGPIPEs the writer, and `pipefail` turns that
into failure.** `grep -q` leaves on its first match; the producer still writing
takes SIGPIPE and the pipeline reports 141 — which reads as "not found" exactly
when it WAS found.

```bash
if some_producer | grep -q "$pat"; then    # BROKEN: 141 under pipefail
out="$(some_producer)"; if grep -q "$pat" <<<"$out"; then    # correct
```

Capture first, then match against a here-string.

**4. A `# shellcheck disable=` directive applies to the NEXT line only.** Put it
immediately above the line it excuses, reason above that. Separated by a blank
line it silences nothing.

```bash
# shellcheck disable=SC2016

grep 'literal ${VAR}' "$f"     # BROKEN: blank line, directive does not apply
# The literal characters ${VAR} are the point here, not an expansion.
# shellcheck disable=SC2016
grep 'literal ${VAR}' "$f"     # correct
```
