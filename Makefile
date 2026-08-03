# Makefile — developer convenience wrappers around the exact checks CI runs.
# Run `make gates` before pushing so your change matches CI locally. Handy for
# an AI-assisted loop: agent edits -> `make gates` -> open PR -> human review.
#
# Targets:
#   make gates    lint + syntax + unit tests (the pre-push gate; matches CI)
#   make lint     ShellCheck (zero findings required), same flags as CI
#   make syntax   bash -n on every script
#   make test     both unit suites (lib + netmode ruleset)
#   make dry-run  scripts/tune.sh --dry-run (detection only, changes nothing)
#   make check    ./check-system.sh (full health check; degrades gracefully)
#   make smoke    scripts/selftest.sh (live end-to-end round-trip on this box)
#   make bench    measure the assistant's system prompt against the real model
#   make hooks    install the pre-push git hook (runs `make gates` before push)
#   make help     list targets

SHELL := /usr/bin/env bash
SCRIPTS := $(wildcard *.sh scripts/*.sh deploy/*.sh tests/*.sh bin/*)

.PHONY: gates lint syntax test dry-run check smoke bench hooks help
.DEFAULT_GOAL := help

gates: syntax lint test ## Everything CI gates on, locally
	@echo "== gates passed =="

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

dry-run: ## Preview the auto-tune decision without changing anything
	bash scripts/tune.sh --dry-run

check: ## Full system health check
	./check-system.sh

smoke: ## Live end-to-end acceptance test on this machine (Ollama + model + aider + WebUI)
	./scripts/selftest.sh

bench: ## Measure the assistant's system prompt against the real model (minutes, not seconds)
	./scripts/prompt-bench.sh

hooks: ## Install the pre-push gate hook (git runs `make gates` before every push)
	git config core.hooksPath .githooks
	@chmod +x .githooks/* 2>/dev/null || true
	@echo "== pre-push hook installed: pushes now run 'make gates' (bypass once with --no-verify) =="

help: ## Show this help
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-9s\033[0m %s\n", $$1, $$2}'
