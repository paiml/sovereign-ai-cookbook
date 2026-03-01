<p align="center">
  <img src=".github/hero.svg" alt="Sovereign AI Cookbook" width="1200" />
</p>

<p align="center">
  <strong>Forjar deployment configs for the complete PAIML sovereign AI stack.</strong><br/>
  Zero third-party dependencies. 8 stacks. 12 recipes. 86 resources. Docker targets for testing.
</p>

---

## Quick Start

```bash
git clone https://github.com/paiml/sovereign-ai-cookbook
cd sovereign-ai-cookbook

# Validate a stack config
forjar validate -f stacks/01-inference/forjar.yaml

# Plan (dry-run — shows resource DAG)
forjar plan -f stacks/01-inference/forjar.yaml

# Apply (deploys to ephemeral docker containers)
forjar apply -f stacks/01-inference/forjar.yaml

# Check for drift (BLAKE3 verification)
forjar drift -f stacks/01-inference/forjar.yaml
```

## Stacks

Each stack is a complete, deployable `forjar.yaml` targeting docker containers. Swap `transport: container` to `ssh` for production.

| Stack | What it deploys | Components | Resources |
|-------|-----------------|------------|-----------|
| [01-inference](stacks/01-inference/) | Single-machine model serving | realizar | 11 |
| [02-training](stacks/02-training/) | GPU training pipeline | entrenar | 9 |
| [03-rag](stacks/03-rag/) | Retrieval-augmented generation | trueno-db, trueno-rag, realizar | 35 |
| [04-speech](stacks/04-speech/) | Speech recognition | whisper-apr | 10 |
| [05-distributed-inference](stacks/05-distributed-inference/) | Multi-node inference | repartir, realizar | 22 |
| **[06-full-stack](stacks/06-full-stack/)** | **Complete sovereign AI lab** | **all components** | **86** |
| [07-data-pipeline](stacks/07-data-pipeline/) | Ingest, train, serve | alimentar, entrenar, realizar | 29 |
| [08-observability](stacks/08-observability/) | Monitoring and tracing | renacer, Jaeger, Grafana | 10 |
| [09-qwen-coder](stacks/09-qwen-coder/) | Local coding assistant | aprender (apr-cli) | 16 |

### Clean-Room Test Matrix

<!-- STACK_MATRIX_START -->

*No results yet — run `make -f machines/clean-room/Makefile clean-room-sovereign-ai-cookbook` from the [infra](https://github.com/paiml/infra) repo.*

<!-- STACK_MATRIX_END -->

## Recipes

Reusable building blocks in `recipes/`. Each recipe is machine-agnostic — stacks bind them to specific machines.

| Recipe | Component | What it configures |
|--------|-----------|-------------------|
| `realizar-serve` | realizar v0.8.0 | GPU model serving (GGUF, safetensors), systemd unit, firewall, health check |
| `entrenar-train` | entrenar v0.7.3 | Training config (learning rate, epochs, LoRA rank), GPU setup, checkpoints |
| `trueno-rag-pipeline` | trueno-rag v0.2.2 | Embedding + retrieval pipeline, backed by trueno-db |
| `trueno-db-analytics` | trueno-db v0.3.15 | Analytics/vector database, WAL, compaction |
| `alimentar-ingest` | alimentar v0.2.6 | Data ingestion, preprocessing, dedup, scheduled cron |
| `whisper-apr-asr` | whisper-apr v0.2.4 | ASR service, model download, VAD, beam search |
| `pacha-registry` | pacha v0.2.5 | Model/data registry, BLAKE3 checksums, GC |
| `pepita-sandbox` | pepita v0.1.0 | Kernel namespace isolation, overlay filesystem, seccomp |
| `repartir-worker` | repartir v2.0.3 | Distributed execution worker, TLS, systemd |
| `renacer-observability` | renacer v0.10.0 | Syscall tracing, Jaeger, Grafana, OTLP |
| `sovereign-ai-stack` | (meta) | Fleet coordination, health dashboard, inventory |
| `apr-inference-server` | aprender | GPU inference with model download, BLAKE3 verification |

## Architecture

```
                    ┌──────────────────┐
                    │   monitor-box    │
                    │  renacer tracing │
                    │  Grafana + Jaeger│
                    │  pacha registry  │
                    └────────┬─────────┘
                             │
            ┌────────────────┼────────────────┐
            │                │                │
     ┌──────▼──────┐  ┌─────▼──────┐  ┌─────▼──────┐
     │   gpu-box   │  │  rag-box   │  │ worker-box │
     │  realizar   │  │ trueno-db  │  │  repartir  │
     │  entrenar   │  │ trueno-rag │  │  worker    │
     │             │  │ whisper-apr│  │            │
     └─────────────┘  └────────────┘  └────────────┘
```

All stacks use `transport: container` with ephemeral docker containers. Forjar creates the container, applies all resources (packages, files, services, firewall rules, cron jobs), verifies convergence with BLAKE3 hashing, and tears down after testing.

See [docs/architecture.md](docs/architecture.md) for data flow diagrams and port assignments.

## Stack Components

| Component | Binary | Version | Layer |
|-----------|--------|---------|-------|
| realizar | `realizar` | v0.8.0 | Application — model serving |
| whisper-apr | `whisper-apr` | v0.2.4 | Application — speech recognition |
| trueno-rag | `trueno-rag` | v0.2.2 | Application — RAG pipeline |
| entrenar | `entrenar` | v0.7.3 | ML Core — training |
| aprender | `aprender` | v0.27.2 | ML Core — models + inference |
| trueno-db | `trueno-db` | v0.3.15 | Data — analytics database |
| alimentar | `alimentar` | v0.2.6 | Data — ingestion |
| pacha | `pacha` | v0.2.5 | Data — model/data registry |
| trueno | `trueno-monitor` | v0.16.1 | Compute — SIMD/GPU engine |
| repartir | `repartir-worker` | v2.0.3 | Compute — distributed execution |
| renacer | `renacer` | v0.10.0 | Infra — syscall tracing |
| pepita | `pepita` | v0.1.0 | Infra — kernel isolation |
| batuta | `batuta` | v0.6.6 | Infra — orchestration |
| simular | `simular` | v0.3.1 | Infra — simulation |

## Testing

All stacks deploy to ephemeral docker containers — no SSH, no root, no real hardware required.

```bash
# Validate all stacks
make validate

# Plan all stacks (shows resource DAGs)
make plan

# Validate a single stack
make validate-one STACK=03-rag

# Apply a single stack
make apply-one STACK=01-inference

# Check drift after manual changes
make drift-one STACK=01-inference
```

## Production Deployment

Replace container transport with SSH for real machines:

```yaml
machines:
  gpu-box:
    hostname: gpu-prod-01.internal
    addr: 10.0.1.10
    user: deploy
    arch: x86_64
    ssh_key: ~/.ssh/deploy_key
    roles: [gpu-compute, inference]
```

Use `policy.parallel_machines: true` for concurrent multi-machine deployment. Use `policy.serial: 1` for rolling deploys.

## Writing Custom Stacks

Compose recipes in a new `stacks/` directory:

```yaml
version: "1.0"
name: my-stack

machines:
  box:
    hostname: box
    addr: container
    transport: container
    container:
      image: forjar-test-target
      ephemeral: true
      init: true

resources:
  serving:
    type: recipe
    machine: box
    recipe: realizar-serve
    inputs:
      model_path: /opt/models/my-model.gguf
      port: 8080
      user: realizar
```

Add a `recipes` symlink so forjar finds the shared recipes:

```bash
cd stacks/my-stack
ln -s ../../recipes recipes
```

## PAIML Stack

| Project | Purpose | Link |
|---------|---------|------|
| [forjar](https://github.com/paiml/forjar) | Infrastructure as Code (deploys this cookbook) | [Book](https://github.com/paiml/forjar/tree/main/docs/book) |
| [apr-cookbook](https://github.com/paiml/apr-cookbook) | 202 Rust ML code examples | [Examples](https://github.com/paiml/apr-cookbook/tree/main/examples) |
| [aprender](https://github.com/paiml/aprender) | ML library (models, inference) | [crates.io](https://crates.io/crates/aprender) |
| [trueno](https://github.com/paiml/trueno) | SIMD/GPU compute engine | [crates.io](https://crates.io/crates/trueno) |

## License

MIT
