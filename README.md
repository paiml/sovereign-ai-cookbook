# Sovereign AI Cookbook

Forjar deployment configs for the complete PAIML/APR sovereign AI stack. No third-party dependencies — every component is built from the PAIML ecosystem.

## Quick Start

```bash
# Validate a stack config
forjar validate -f stacks/01-inference/forjar.yaml

# Plan (dry-run, shows resource DAG)
forjar plan -f stacks/01-inference/forjar.yaml

# Apply (deploys to docker containers)
forjar apply -f stacks/01-inference/forjar.yaml

# Check for drift
forjar drift -f stacks/01-inference/forjar.yaml
```

## Stacks

| Stack | Description | Components |
|-------|-------------|------------|
| [01-inference](stacks/01-inference/) | Single-machine model serving | realizar |
| [02-training](stacks/02-training/) | GPU training pipeline | entrenar |
| [03-rag](stacks/03-rag/) | Retrieval-augmented generation | trueno-db, trueno-rag, realizar |
| [04-speech](stacks/04-speech/) | Speech recognition | whisper-apr |
| [05-distributed-inference](stacks/05-distributed-inference/) | Multi-node inference | repartir, realizar |
| [06-full-stack](stacks/06-full-stack/) | Complete sovereign AI lab | all components |
| [07-data-pipeline](stacks/07-data-pipeline/) | Ingest → train → serve | alimentar, entrenar, realizar |
| [08-observability](stacks/08-observability/) | Monitoring and tracing | renacer, Jaeger, Grafana |

## Recipes

Reusable building blocks in `recipes/`:

| Recipe | Component | Purpose |
|--------|-----------|---------|
| `realizar-serve` | realizar v0.8.0 | Model serving (GGUF, safetensors) |
| `entrenar-train` | entrenar v0.7.3 | Training, LoRA, quantization |
| `trueno-rag-pipeline` | trueno-rag v0.2.2 | RAG embedding + retrieval |
| `trueno-db-analytics` | trueno-db v0.3.15 | Analytics/vector database |
| `alimentar-ingest` | alimentar v0.2.6 | Data ingestion + preprocessing |
| `whisper-apr-asr` | whisper-apr v0.2.4 | Speech recognition |
| `pacha-registry` | pacha v0.2.5 | Model/data registry |
| `pepita-sandbox` | pepita v0.1.0 | Kernel isolation (io_uring) |

Recipes from forjar core (referenced, not duplicated):

| Recipe | Purpose |
|--------|---------|
| `repartir-worker` | Distributed execution worker |
| `renacer-observability` | Syscall tracing + Grafana |
| `sovereign-ai-stack` | Meta-recipe coordination layer |

## Stack Components

| Component | Binary | Version | Purpose |
|-----------|--------|---------|---------|
| aprender | `aprender` | v0.27.2 | ML library (models, inference) |
| realizar | `realizar` | v0.8.0 | Model serving |
| entrenar | `entrenar` | v0.7.3 | Training, LoRA, quantization |
| trueno | `trueno-monitor` | v0.16.1 | SIMD/GPU compute engine |
| trueno-rag | `trueno-rag` | v0.2.2 | RAG pipeline |
| trueno-db | `trueno-db` | v0.3.15 | Analytics database |
| alimentar | `alimentar` | v0.2.6 | Data loading/distribution |
| repartir | `repartir-worker` | v2.0.3 | Distributed computing |
| renacer | `renacer` | v0.10.0 | Syscall tracing/observability |
| batuta | `batuta` | v0.6.6 | Project orchestration |
| pepita | `pepita` | v0.1.0 | Kernel isolation |
| pacha | `pacha` | v0.2.5 | Model/data registry |
| simular | `simular` | v0.3.1 | Simulation engine |
| whisper-apr | `whisper-apr` | v0.2.4 | Speech recognition |

## Testing

All stacks use docker container targets for testing. Every machine uses `transport: container` with ephemeral containers that are created on `forjar apply` and destroyed after verification.

```bash
# Validate all stacks
make validate

# Plan all stacks
make plan

# Run from forjar source tree
make validate FORJAR=../forjar
```

## Production Deployment

To deploy to real machines, change the machine transport from `container` to `ssh`:

```yaml
machines:
  gpu-box:
    hostname: gpu-prod-01
    addr: 10.0.1.10
    user: deploy
    arch: x86_64
    ssh_key: ~/.ssh/deploy_key
    roles: [gpu-compute]
```

## Architecture

See [docs/architecture.md](docs/architecture.md) for how components fit together.
