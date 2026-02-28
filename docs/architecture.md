# Sovereign AI Stack Architecture

## Overview

The PAIML sovereign AI stack is a complete, self-contained ML infrastructure built entirely from Rust components. No third-party ML frameworks, vector databases, or orchestration tools are used.

## Component Layers

```
┌─────────────────────────────────────────────────────┐
│                   Applications                       │
│        (speech, RAG, inference APIs)                 │
├─────────────┬─────────────┬─────────────────────────┤
│  realizar   │ whisper-apr │     trueno-rag          │
│  (serving)  │   (ASR)     │  (retrieval)            │
├─────────────┴─────────────┴─────────────────────────┤
│                   ML Core                            │
│     aprender (models) + entrenar (training)          │
├──────────────────────────────────────────────────────┤
│                   Data Layer                         │
│  trueno-db (analytics) │ pacha (registry)            │
│  alimentar (ingest)    │ trueno-graph (graph DB)     │
├──────────────────────────────────────────────────────┤
│                   Compute Layer                      │
│  trueno (SIMD/GPU) │ repartir (distributed)          │
├──────────────────────────────────────────────────────┤
│                   Infrastructure                     │
│  pepita (isolation) │ renacer (observability)         │
│  forjar (deployment) │ batuta (orchestration)         │
└──────────────────────────────────────────────────────┘
```

## Data Flow

### Inference (Stack 01)

```
Client Request → realizar (HTTP API)
                   → aprender (model loading)
                   → trueno (SIMD compute)
                   → Response
```

### Training (Stack 02)

```
Dataset → entrenar (training loop)
            → aprender (model ops)
            → trueno (GPU compute)
            → Checkpoint/Model
```

### RAG (Stack 03)

```
Documents → trueno-rag (chunking + embedding)
              → trueno (SIMD compute)
              → trueno-db (vector storage)

Query → trueno-rag (embedding + retrieval)
          → trueno-db (similarity search)
          → realizar (generation)
          → Response
```

### Data Pipeline (Stack 07)

```
Raw Data → alimentar (ingest + preprocess)
             → Dataset (JSONL/Parquet)
             → entrenar (fine-tune)
             → Model
             → realizar (serve)
```

### Full Stack (Stack 06)

```
                    ┌──────────────────┐
                    │   monitor-box    │
                    │  renacer tracing │
                    │  Grafana + Jaeger│
                    │  pacha registry  │
                    └────────┬─────────┘
                             │ OTLP traces
            ┌────────────────┼────────────────┐
            │                │                │
     ┌──────▼──────┐  ┌─────▼──────┐  ┌─────▼──────┐
     │   gpu-box   │  │  rag-box   │  │ worker-box │
     │  realizar   │  │ trueno-db  │  │  repartir  │
     │  entrenar   │  │ trueno-rag │  │  worker    │
     │             │  │ whisper-apr│  │            │
     └─────────────┘  └────────────┘  └────────────┘
```

## Machine Roles

| Role | Purpose | Typical Machine |
|------|---------|-----------------|
| `gpu-compute` | Model serving and training | GPU server (NVIDIA) |
| `inference` | Realizar model serving | GPU server |
| `training` | Entrenar fine-tuning | GPU server |
| `rag` | RAG pipeline + vector DB | CPU/GPU server |
| `speech` | Whisper-APR ASR | GPU server |
| `worker` | Repartir distributed execution | CPU server |
| `observability` | Renacer + Grafana + Jaeger | CPU server |
| `registry` | Pacha model/data registry | CPU server |
| `pipeline` | alimentar → entrenar → realizar | GPU server |

## Port Assignments

| Port | Service | Component |
|------|---------|-----------|
| 3000 | Grafana UI | renacer-observability |
| 4317 | OTLP gRPC | renacer-observability |
| 5433 | trueno-db | trueno-db-analytics |
| 8070 | Pacha registry | pacha-registry |
| 8080 | Inference API | realizar-serve |
| 8090 | RAG API | trueno-rag-pipeline |
| 8095 | ASR API | whisper-apr-asr |
| 9000 | Worker | repartir-worker |
| 16686 | Jaeger UI | renacer-observability |

## Testing

All stacks use `transport: container` with docker containers. The `forjar-test-target` image provides a minimal Ubuntu environment with systemd, curl, and build essentials.

To test a stack:

```bash
# Validate config syntax and DAG
forjar validate -f stacks/01-inference/forjar.yaml

# Plan (resolves templates, shows resource graph)
forjar plan -f stacks/01-inference/forjar.yaml

# Apply (creates container, applies resources, verifies)
forjar apply -f stacks/01-inference/forjar.yaml

# Check for drift after manual changes
forjar drift -f stacks/01-inference/forjar.yaml
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

Use `policy.parallel_machines: true` for concurrent multi-machine deployment.
Use `policy.serial: 1` for rolling deploys across a fleet.
