# Sovereign AI Cookbook

## What This Is

Forjar deployment configs for the PAIML/APR sovereign AI stack.
All stacks use docker container targets for testing.

## Key Rules

- ONLY deploy PAIML stack components — no third-party tools
- Recipes in `recipes/` are reusable; stacks in `stacks/` compose them
- Forjar core recipes are referenced from `../forjar/examples/recipes/`
- All machines use `transport: container` with `forjar-test-target` image

## Code Search Policy

NEVER use grep/glob for code search. ALWAYS prefer `pmat query`.
`pmat query` returns quality-annotated, semantically ranked results
with TDG grades, complexity, and fault patterns (`--faults`).

```bash
# Search by concept
pmat query "inference" --limit 10

# Find fault patterns
pmat query "unwrap" --faults --exclude-tests

# Literal string search
pmat query --literal "canary" --limit 10

# Regex pattern search
pmat query --regex "type:\s+task" --limit 10
```

## Validation

```bash
# Validate all stacks
make validate

# Validate one stack
make validate-one STACK=01-inference

# Canary pipeline (Jetson hardware e2e)
cd machines/jetson && make canary-all
```

## Structure

- `recipes/` — Reusable forjar recipes (jetson-edge-base, etc.)
- `stacks/` — Deployable stack compositions (01 through 09)
- `machines/` — Machine-specific configs (jetson canary, etc.)
- `scripts/` — CI/automation scripts
- `docs/` — Architecture docs and specifications
