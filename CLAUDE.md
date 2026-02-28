# Sovereign AI Cookbook

## What This Is

Forjar deployment configs for the PAIML/APR sovereign AI stack. All stacks use docker container targets for testing.

## Key Rules

- ONLY deploy PAIML stack components — no third-party tools (Ollama, ChromaDB, etc.)
- Recipes in `recipes/` are reusable; stacks in `stacks/` compose them
- Forjar core recipes (repartir-worker, renacer-observability, sovereign-ai-stack) are referenced from `../forjar/examples/recipes/`, NOT duplicated
- All machines use `transport: container` with `forjar-test-target` image

## Validation

```bash
# Validate all stacks
make validate

# Validate one stack
make validate-one STACK=01-inference
```

## Structure

- `recipes/` — Reusable forjar recipes (realizar, entrenar, trueno-rag, etc.)
- `stacks/` — Deployable stack compositions (01-inference through 08-observability)
- `docs/` — Architecture documentation
