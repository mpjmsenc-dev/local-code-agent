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
