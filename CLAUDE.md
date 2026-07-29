# CLAUDE.md — project instructions for Claude Code

## Project context

local-code-agent is a fully private, self-hosted AI stack (Ollama + aider +
Open WebUI + Tailscale) for Ubuntu 24.04 VMs. Everything is bash; every
script must stay `bash -n` clean and ShellCheck-clean
(`shellcheck -x -P SCRIPTDIR *.sh scripts/*.sh deploy/*.sh tests/*.sh`),
and CI (.github/workflows/ci.yml) must stay green — it runs unit tests plus
real E2E installs on every push. Never weaken a CI gate to make it pass.

ULTRACODE STANDING ORDER for every future task in this repo:
- Treat every substantive task (build, refactor, audit, multi-file change, debugging) as a
  workflow task: plan first, orchestrate subagents / parallel workstreams whenever genuinely
  useful, verify results before reporting. The user grants standing permission for workflow
  orchestration — never ask, just do it.
- Reason at maximum available depth on every turn; never trade depth for speed.
- Trivial turns (status questions, one-liners) may be answered directly.
- If a task would clearly benefit from true ultracode mode and this turn is not running in it,
  end with one line: 'Tip: resend with ultracode for full workflow mode.'
