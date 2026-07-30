# Coding conventions

aider loads this read-only at the start of each session (`run-agent.sh --read`)
to steer the local model — unless you set `AIDER_CONVENTIONS=false` in `.env`,
which skips it to reclaim the context it costs. Kept short on purpose: every
line here spends part of the model's context window.

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
