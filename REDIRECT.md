# This repository has moved

The content of `sovereign-ai-cookbook` has been consolidated into the
**APR Cookbook** umbrella project as part of the sovereign-stack
documentation centralization (spec: [docs/specifications/centralize-cookbooks](https://github.com/paiml/apr-cookbook/blob/main/docs/specifications/centralize-cookbooks.md)).

| Where it used to live | Where it lives now |
|-----------------------|--------------------|
| `recipes/*.yaml` (14 deployment recipes) | https://github.com/paiml/apr-cookbook/tree/main/examples/deployment-stacks/recipes |
| `stacks/01-09/` (10 multi-recipe stacks) | https://github.com/paiml/apr-cookbook/tree/main/examples/deployment-stacks/stacks (09-qwen-coder renamed to 10-qwen-coder to fix dup prefix) |
| `machines/jetson/` | https://github.com/paiml/apr-cookbook/tree/main/examples/machines/jetson |

Each YAML recipe additionally has a Rust loader/validator wrapper at
`apr-cookbook/examples/deployment-stacks/<recipe_name>.rs` that loads the YAML
via `include_str!`, validates required fields, and runs as part of the cookbook's
test suite — so any sovereign-side schema change trips a cookbook test.

This repository is now archived (read-only). Open issues and pull requests
have been closed. For new contributions, please use:

- **Cookbook examples and book**: https://github.com/paiml/apr-cookbook
- **forjar (the engine that consumes these YAMLs)**: https://github.com/paiml/forjar

Last live tag (rollback anchor): `pre-archive-2026-05`

For full migration rationale, see:
https://github.com/paiml/apr-cookbook/blob/main/docs/specifications/centralize-cookbooks.md
