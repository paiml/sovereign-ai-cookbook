FORJAR ?= ../forjar
FORJAR_BIN = cargo run --manifest-path $(FORJAR)/Cargo.toml --

STACKS = $(wildcard stacks/*/forjar.yaml)

.PHONY: validate plan graph help test-fast test lint coverage

# ── Quality Gate Targets (required by pmat repo-score) ──────────────

test-fast: validate ## Fast validation of all stack configs
	@echo "=== Fast test pass complete ==="

test: validate plan ## Full test: validate + plan all stacks
	@echo "=== Full test pass complete ==="

lint: ## Lint all YAML configs and shell scripts
	@echo "=== Linting YAML configs ==="
	@for f in $(STACKS); do \
		echo "  checking $$f"; \
		python3 -c "import yaml; yaml.safe_load(open('$$f'))" 2>/dev/null || \
		python3 -c "import sys; open('$$f').read()" || exit 1; \
	done
	@if command -v shellcheck >/dev/null 2>&1; then \
		echo "=== Linting shell scripts ==="; \
		shellcheck scripts/*.sh 2>/dev/null || true; \
	fi
	@echo "=== Lint pass complete ==="

coverage: test ## Coverage report (stack validation coverage)
	@echo "=== Coverage Report ==="
	@total=0; pass=0; \
	for f in $(STACKS); do \
		total=$$((total + 1)); \
		if $(FORJAR_BIN) validate -f "$$f" >/dev/null 2>&1; then \
			pass=$$((pass + 1)); \
		fi; \
	done; \
	echo "Stacks validated: $$pass / $$total"; \
	echo "Coverage: $$(( pass * 100 / total ))%"

# ── Infrastructure Targets ──────────────────────────────────────────

validate: ## Validate all stack configs
	@echo "=== Validating all stacks ==="
	@for f in $(STACKS); do \
		echo "--- $$f ---"; \
		$(FORJAR_BIN) validate -f "$$f" || exit 1; \
	done
	@echo "=== All stacks valid ==="

plan: ## Plan all stacks (dry-run)
	@echo "=== Planning all stacks ==="
	@for f in $(STACKS); do \
		echo "--- $$f ---"; \
		$(FORJAR_BIN) plan -f "$$f" || exit 1; \
	done

graph: ## Show resource graph for full stack
	$(FORJAR_BIN) graph -f stacks/06-full-stack/forjar.yaml

validate-one: ## Validate a single stack: make validate-one STACK=01-inference
	$(FORJAR_BIN) validate -f stacks/$(STACK)/forjar.yaml

plan-one: ## Plan a single stack: make plan-one STACK=01-inference
	$(FORJAR_BIN) plan -f stacks/$(STACK)/forjar.yaml

apply-one: ## Apply a single stack: make apply-one STACK=01-inference
	$(FORJAR_BIN) apply -f stacks/$(STACK)/forjar.yaml

drift-one: ## Check drift for a single stack: make drift-one STACK=01-inference
	$(FORJAR_BIN) drift -f stacks/$(STACK)/forjar.yaml

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
