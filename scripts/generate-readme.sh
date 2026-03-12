#!/usr/bin/env bash
# Generate README.md from live data.
#
# This script is the SOLE owner of README.md. Manual edits will be overwritten.
#
# Usage:
#   ./scripts/generate-readme.sh                    # generate README.md
#   ./scripts/generate-readme.sh --check            # diff-check only (CI mode)
#
# Called by:
#   - .github/workflows/generate-readme.yml (on push to main, daily)
#   - infra clean-room pipeline (after stack matrix sync)
#
# To update README.md content, edit THIS script, not README.md.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
README="$REPO_ROOT/README.md"
CHECK_MODE=false

if [[ "${1:-}" = "--check" ]]; then
  CHECK_MODE=true
fi

# ── GitHub org ──────────────────────────────────────────────────────
ORG="paiml"
NIGHTLY_TAG="nightly"

# ── Component registry ──────────────────────────────────────────────
# Format: "binary|repo_slug|version|layer|description|ci_workflow"
# ci_workflow: the YAML filename for the CI badge (most use ci.yml)
COMPONENTS=(
  "realizar|realizar|v0.8|Application|Model serving (GGUF, SafeTensors, CUDA)|ci.yml"
  "apr|aprender|v0.27|ML Core|Model inspection, inference, training CLI|ci.yml"
  "trueno-monitor|trueno|v0.16|Compute|SIMD/GPU engine + TUI monitor|ci.yml"
  "trueno-rag|trueno-rag|v0.2|Application|RAG pipeline (embed, index, query)|ci.yml"
  "entrenar|entrenar|v0.7|ML Core|Training engine (LoRA, QLoRA, classification)|ci.yml"
  "alimentar|alimentar|v0.2|Data|Ingestion, preprocessing, dedup|ci.yml"
  "batuta|batuta|v0.6|Infra|Orchestration, mutation testing, oracle|ci.yml"
  "forjar|forjar|v0.5|Infra|Infrastructure-as-Code provisioning|ci.yml"
  "pmat|paiml-mcp-agent-toolkit|v0.4|Infra|Code quality, work tracking, coverage|ci.yml"
  "copia|copia|v0.1|Infra|Sovereign file sync|ci.yml"
  "pzsh|pzsh|v0.1|Infra|Sub-10ms shell framework|ci.yml"
  "renacer|renacer|v0.10|Infra|Syscall tracing, Jaeger, Grafana|ci.yml"
  "repartir|repartir|v2.0|Compute|Distributed execution workers|jidoka-gates.yml"
  "whisper-apr|whisper.apr|v0.2|Application|Speech recognition (Whisper)|ci.yml"
  "pepita|pepita|v0.1|Infra|Kernel namespace isolation, seccomp|ci.yml"
  "simular|simular|v0.3|Infra|Simulation engine|jidoka-gates.yml"
  "pacha|pacha|v0.2|Data|Model/data registry, BLAKE3 checksums|ci.yml"
)

# ── Stack matrix (injected by clean-room CI between markers) ────────
# This section is replaced by infra/machines/clean-room/sync-cookbook-readme.sh
# after each clean-room gate run. If no results exist yet, show placeholder.
generate_stack_matrix() {
  if grep -q "STACK_MATRIX_START" "$README" 2>/dev/null; then
    # Preserve existing matrix data (it's injected by the clean-room pipeline)
    local in_block=false
    local matrix=""
    while IFS= read -r line; do
      if [[ "$line" == *"STACK_MATRIX_START"* ]]; then
        in_block=true
        continue
      fi
      if [[ "$line" == *"STACK_MATRIX_END"* ]]; then
        in_block=false
        continue
      fi
      if $in_block; then
        matrix+="$line"$'\n'
      fi
    done < "$README"
    printf '%s' "$matrix"
  else
    echo ""
    echo "*(Awaiting first clean-room run — see [How to Update](#how-to-update))*"
    echo ""
  fi
}

# ── Status dashboard table (CI + Nightly in one place) ──────────────
generate_status_dashboard() {
  echo "| Component | Binary | CI | Nightly |"
  echo "|-----------|--------|----|---------|"
  for entry in "${COMPONENTS[@]}"; do
    IFS='|' read -r binary repo version layer desc ci_wf <<< "$entry"
    local repo_url="https://github.com/${ORG}/${repo}"
    local ci_badge="https://github.com/${ORG}/${repo}/actions/workflows/${ci_wf}/badge.svg"
    local ci_url="https://github.com/${ORG}/${repo}/actions/workflows/${ci_wf}"
    local nightly_badge="https://github.com/${ORG}/${repo}/actions/workflows/nightly.yml/badge.svg"
    local nightly_url="https://github.com/${ORG}/${repo}/releases/tag/${NIGHTLY_TAG}"
    echo "| [${repo}](${repo_url}) | \`${binary}\` | [![CI](${ci_badge})](${ci_url}) | [![Nightly](${nightly_badge})](${nightly_url}) |"
  done
}

# ── Nightly binaries table ──────────────────────────────────────────
generate_binary_table() {
  echo "| Binary | Repo | Layer | Description | Platforms |"
  echo "|--------|------|-------|-------------|-----------|"
  for entry in "${COMPONENTS[@]}"; do
    IFS='|' read -r binary repo version layer desc ci_wf <<< "$entry"
    local repo_url="https://github.com/${ORG}/${repo}"
    # Platform availability
    local platforms="Linux, macOS, Windows"
    if [[ "$binary" = "trueno-monitor" ]]; then
      platforms="Linux"
    fi
    echo "| \`${binary}\` | [${repo}](${repo_url}) | ${layer} | ${desc} | ${platforms} |"
  done
}

# ── Component stack table (by layer) ──────────────────────────────
generate_component_table() {
  echo "| Component | Binary | Version | Layer | Description | crates.io |"
  echo "|-----------|--------|---------|-------|-------------|-----------|"
  for entry in "${COMPONENTS[@]}"; do
    IFS='|' read -r binary repo version layer desc ci_wf <<< "$entry"
    local repo_url="https://github.com/${ORG}/${repo}"
    # crates.io link (repo slug = crate name for most; exceptions mapped)
    local crate_name="$repo"
    case "$repo" in
      paiml-mcp-agent-toolkit) crate_name="pmat" ;;
      whisper.apr) crate_name="whisper-apr" ;;
    esac
    local crate_link="[${crate_name}](https://crates.io/crates/${crate_name})"
    echo "| [${repo}](${repo_url}) | \`${binary}\` | ${version} | ${layer} | ${desc} | ${crate_link} |"
  done
}

# ── Generate README ─────────────────────────────────────────────────
STACK_MATRIX=$(generate_stack_matrix)
BINARY_TABLE=$(generate_binary_table)
COMPONENT_TABLE=$(generate_component_table)
STATUS_DASHBOARD=$(generate_status_dashboard)

cat > "${README}.tmp" << 'HEADER'
<!-- AUTO-GENERATED by scripts/generate-readme.sh — do NOT edit manually.
     To change this file, edit scripts/generate-readme.sh and push to main.
     The generate-readme workflow will regenerate and commit. -->

<p align="center">
  <img src=".github/hero.svg" alt="Sovereign AI Cookbook" width="1200" />
</p>

<p align="center">
  <strong>Forjar deployment configs for the complete PAIML sovereign AI stack.</strong><br/>
  17 Rust components -- 10 deployment stacks -- 14 recipes -- zero third-party runtime dependencies.
</p>

HEADER

cat >> "${README}.tmp" << EOF
---

## Status Dashboard

All CI and nightly build status across the sovereign stack.

${STATUS_DASHBOARD}

---

## Quick Start

\`\`\`bash
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
\`\`\`

## Stacks

Each stack is a complete, deployable \`forjar.yaml\` targeting docker containers. Swap \`transport: container\` to \`ssh\` for production.

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
| [09-edge-inference](stacks/09-edge-inference/) | Jetson Orin Nano edge inference | realizar, trueno | 18 |
| [09-qwen-coder](stacks/09-qwen-coder/) | Local coding assistant | aprender (apr-cli) | 16 |

### Clean-Room Test Matrix

<!-- STACK_MATRIX_START -->
${STACK_MATRIX}
<!-- STACK_MATRIX_END -->

## Sovereign Stack Components

Every component is a standalone Rust binary with zero third-party runtime dependencies. All are published to [crates.io](https://crates.io) and built nightly from \`main\`.

${COMPONENT_TABLE}

## Nightly Binary Releases

Every component ships cross-platform nightly binaries built from \`main\` via GitHub Actions. Binaries are statically linked (musl on Linux) and require no runtime dependencies.

${BINARY_TABLE}

> **Install any binary:**
> \`\`\`bash
> # Download from nightly release (example: forjar on Linux x86_64)
> curl -L -o forjar https://github.com/paiml/forjar/releases/download/nightly/forjar-x86_64-unknown-linux-musl
> chmod +x forjar && mv forjar ~/.cargo/bin/
>
> # Or provision automatically via forjar (type: github_release)
> forjar apply -f stacks/06-full-stack/forjar.yaml
> \`\`\`

## Architecture

\`\`\`
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
\`\`\`

All stacks use \`transport: container\` with ephemeral docker containers. Forjar creates the container, applies all resources (packages, files, services, firewall rules, cron jobs), verifies convergence with BLAKE3 hashing, and tears down after testing.

See [docs/architecture.md](docs/architecture.md) for data flow diagrams and port assignments.

## Recipes

Reusable building blocks in [\`recipes/\`](recipes/). Each recipe is machine-agnostic -- stacks bind them to specific machines.

| Recipe | Component | What it configures |
|--------|-----------|-------------------|
| [\`realizar-serve\`](recipes/realizar-serve.yaml) | realizar | GPU model serving (GGUF, safetensors), systemd unit, firewall, health check |
| [\`entrenar-train\`](recipes/entrenar-train.yaml) | entrenar | Training config (learning rate, epochs, LoRA rank), GPU setup, checkpoints |
| [\`trueno-rag-pipeline\`](recipes/trueno-rag-pipeline.yaml) | trueno-rag | Embedding + retrieval pipeline, backed by trueno-db |
| [\`trueno-db-analytics\`](recipes/trueno-db-analytics.yaml) | trueno-db | Analytics/vector database, WAL, compaction |
| [\`alimentar-ingest\`](recipes/alimentar-ingest.yaml) | alimentar | Data ingestion, preprocessing, dedup, scheduled cron |
| [\`whisper-apr-asr\`](recipes/whisper-apr-asr.yaml) | whisper-apr | ASR service, model download, VAD, beam search |
| [\`pacha-registry\`](recipes/pacha-registry.yaml) | pacha | Model/data registry, BLAKE3 checksums, GC |
| [\`pepita-sandbox\`](recipes/pepita-sandbox.yaml) | pepita | Kernel namespace isolation, overlay filesystem, seccomp |
| [\`repartir-worker\`](recipes/repartir-worker.yaml) | repartir | Distributed execution worker, TLS, systemd |
| [\`renacer-observability\`](recipes/renacer-observability.yaml) | renacer | Syscall tracing, Jaeger, Grafana, OTLP |
| [\`batuta-agent\`](recipes/batuta-agent.yaml) | batuta | Autonomous agent runtime, mutation testing daemon |
| [\`jetson-edge-base\`](recipes/jetson-edge-base.yaml) | (platform) | Jetson Orin Nano base: JetPack CUDA, Rust toolchain, sovereign tools |
| [\`sovereign-ai-stack\`](recipes/sovereign-ai-stack.yaml) | (meta) | Fleet coordination, health dashboard, inventory |
| [\`apr-inference-server\`](recipes/apr-inference-server.yaml) | aprender | GPU inference with model download, BLAKE3 verification |

## Testing

All stacks deploy to ephemeral docker containers — no SSH, no root, no real hardware required.

\`\`\`bash
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
\`\`\`

## Production Deployment

Replace container transport with SSH for real machines:

\`\`\`yaml
machines:
  gpu-box:
    hostname: gpu-prod-01.internal
    addr: 10.0.1.10
    user: deploy
    arch: x86_64
    ssh_key: ~/.ssh/deploy_key
    roles: [gpu-compute, inference]
\`\`\`

Use \`policy.parallel_machines: true\` for concurrent multi-machine deployment. Use \`policy.serial: 1\` for rolling deploys.

## How to Update

README.md is **auto-generated**. Never edit it directly.

| What to change | Where to edit | How it deploys |
|----------------|---------------|----------------|
| README content, layout, badges | \`scripts/generate-readme.sh\` | Push to main → workflow regenerates |
| Stack test matrix | *(automatic)* | Clean-room CI injects results between \`STACK_MATRIX\` markers |
| Component versions, layers, descriptions | \`COMPONENTS\` array in \`scripts/generate-readme.sh\` | Push to main → workflow regenerates |
| CI + nightly badges | *(automatic)* | Generated from \`COMPONENTS\` array |
| Component table, nightly links | *(automatic)* | Generated from \`COMPONENTS\` array |

\`\`\`bash
# Preview locally
./scripts/generate-readme.sh

# CI check mode (fails if README.md is stale)
./scripts/generate-readme.sh --check
\`\`\`

## Related Repositories

| Project | Purpose | Link |
|---------|---------|------|
| [forjar](https://github.com/paiml/forjar) | Infrastructure as Code (deploys this cookbook) | [Book](https://github.com/paiml/forjar/tree/main/docs/book) |
| [aprender](https://github.com/paiml/aprender) | ML library (models, inference, training) | [crates.io](https://crates.io/crates/aprender) |
| [trueno](https://github.com/paiml/trueno) | SIMD/GPU compute engine (pure Rust PTX) | [crates.io](https://crates.io/crates/trueno) |
| [realizar](https://github.com/paiml/realizar) | Model serving (GGUF, SafeTensors, CUDA) | [crates.io](https://crates.io/crates/realizar) |
| [entrenar](https://github.com/paiml/entrenar) | Training engine (LoRA, QLoRA) | [crates.io](https://crates.io/crates/entrenar) |
| [trueno-rag](https://github.com/paiml/trueno-rag) | RAG pipeline (embed, index, query) | [crates.io](https://crates.io/crates/trueno-rag) |
| [batuta](https://github.com/paiml/batuta) | Orchestration, mutation testing, oracle | [crates.io](https://crates.io/crates/batuta) |
| [paiml-mcp-agent-toolkit](https://github.com/paiml/paiml-mcp-agent-toolkit) | Code quality, work tracking, coverage | [crates.io](https://crates.io/crates/pmat) |
| [apr-cookbook](https://github.com/paiml/apr-cookbook) | 202 Rust ML code examples | [Examples](https://github.com/paiml/apr-cookbook/tree/main/examples) |

## License

MIT
EOF

# ── Check mode or write mode ───────────────────────────────────────
if $CHECK_MODE; then
  if diff -q "${README}.tmp" "$README" > /dev/null 2>&1; then
    rm -f "${README}.tmp"
    echo "README.md is up to date."
    exit 0
  else
    echo "README.md is stale. Run ./scripts/generate-readme.sh to regenerate."
    diff -u "$README" "${README}.tmp" | head -40
    rm -f "${README}.tmp"
    exit 1
  fi
else
  mv "${README}.tmp" "$README"
  echo "Generated $README"
fi
