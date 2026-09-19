# Makefile — developer convenience wrappers around the exact checks CI runs.
# Run `make gates` before pushing so your change matches CI locally. Handy for
# an AI-assisted loop: agent edits -> `make gates` -> open PR -> human review.
#
# Targets:
#   make gates    lint + syntax + unit tests (the pre-push gate; matches CI)
#   make lint     ShellCheck (zero findings required), same flags as CI
#   make syntax   bash -n on every script
#   make test     both unit suites (lib + netmode ruleset)
#   make coverage which lib.sh functions no test touches (a report, not a gate)
#   make live-verify  the agent tier against a REAL machine (read-only)
#   make dry-run  scripts/tune.sh --dry-run (detection only, changes nothing)
#   make check    ./check-system.sh (full health check; degrades gracefully)
#   make smoke    scripts/selftest.sh (live end-to-end round-trip on this box)
#   make bench    measure the assistant's system prompt against the real model
#   make hooks    install the pre-push git hook (runs `make gates` before push)
#   make hooks-status  is that hook armed in THIS clone? (a report, not a gate)
#   make help     list targets

SHELL := /usr/bin/env bash
# .githooks/* included. The pre-push hook is a bash script like any other, and
# it was the ONLY one in the repo that neither ShellCheck nor 'bash -n' ever
# saw — the gate that guards every push, ungated. It fails badly in both
# directions: a syntax error blocks every push, and a swallowed status lets red
# gates through, which is the one thing it exists to prevent.
SCRIPTS := $(wildcard *.sh scripts/*.sh deploy/*.sh tests/*.sh bin/* .githooks/*)

.PHONY: gates lint syntax test coverage live-verify dry-run check smoke bench hooks hooks-status help
.DEFAULT_GOAL := help

gates: syntax lint test ## The CI gates that can run locally (2 of CI's 7 jobs)
	@echo "== gates passed =="
	@$(MAKE) --no-print-directory hooks-status

lint: ## ShellCheck, same invocation as CI
	@command -v shellcheck >/dev/null || { echo "shellcheck not installed (apt-get install -y shellcheck)"; exit 1; }
	shellcheck -x -P SCRIPTDIR $(SCRIPTS)
	@echo "== shellcheck: zero findings =="

syntax: ## bash -n on every script
	@for f in $(SCRIPTS); do bash -n "$$f" || exit 1; done
	@echo "== bash -n: clean =="

test: ## Unit suites (library helpers + netmode ruleset)
	bash tests/test-lib.sh
	bash tests/test-netmode.sh

coverage: ## Report which lib.sh functions no test touches (a report, not a gate)
	bash tests/coverage.sh

# The only script under tests/ with no way in. It is the other half of the unit
# suite — same subjects, no stubs, a real docker and a real agent — and until
# this target existed the only record that it can be run at all was a sentence
# in docs/PROMPT-WINDOW.md.
live-verify: ## Drive the agent-tier gates against a REAL machine (read-only; needs a running tier)
	bash tests/live-verify.sh

dry-run: ## Preview the auto-tune decision without changing anything
	bash scripts/tune.sh --dry-run

check: ## Full system health check
	./check-system.sh

smoke: ## Live end-to-end acceptance test on this machine (Ollama + model + aider + WebUI)
	./scripts/selftest.sh

bench: ## Measure the assistant's system prompt against the real model (minutes, not seconds)
	./scripts/prompt-bench.sh

hooks-status: ## Is the pre-push hook armed in this clone? (a report, not a gate)
	@if [ "$$(git config --get core.hooksPath 2>/dev/null)" = ".githooks" ]; then \
		echo "== pre-push hook armed: 'make gates' runs on every push =="; \
	else \
		echo "== NOTE: the pre-push hook is NOT installed in this clone, so nothing runs these gates for you. Install it: make hooks =="; \
	fi

hooks: ## Install the pre-push gate hook (git runs `make gates` before every push)
	git config core.hooksPath .githooks
	@chmod +x .githooks/* 2>/dev/null || true
	@echo "== pre-push hook installed: pushes now run 'make gates' (bypass once with --no-verify) =="

help: ## Show this help
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-9s\033[0m %s\n", $$1, $$2}'
