# Stack Integration: Hardware End-to-End Testing

**Status:** Draft
**Author:** Noah Gift / Claude Code
**Date:** 2026-03-04

## TL;DR

We have a tiny $200 robot brain (Jetson) that has a GPU, CPU, and runs ARM instead of Intel. It's the only machine we own that has **all three compute backends** at once. We want to:

1. **Build our AI tools on the big beefy server** (intel, 283GB RAM) because the tiny brain can't compile anything
2. **Ship the built binary + a small AI model to the tiny brain** over the local network
3. **Run `apr` on the tiny brain** — it loads the model, talks to it ("What is 2+2?"), and checks that every answer is correct on every backend (CPU ARM, GPU Vulkan, GPU CUDA)
4. **Report back** — did anything break?

That's it. It's a hardware smoke test. Like a canary in a coal mine — if `apr` can download a HuggingFace model, load it, chat with it, and get the right answers on this tiny ARM+GPU box, then our entire AI stack works on real hardware.

## Problem

The sovereign AI stack spans 12+ Rust crates across CPU (x86_64, aarch64), GPU (CUDA, Vulkan/wgpu), and WASM targets. Today's CI covers:

- **intel clean-room (x86_64 CPU):** unit tests, clippy, coverage — no GPU
- **lambda-labs (x86_64 + A100 GPU):** CUDA docker smoke tests — no wgpu Vulkan, no aarch64
- **GitHub Actions:** lint, format, doc build — no hardware

**Gaps:**

| Compute path | Tested today? | Where? |
|---|---|---|
| x86_64 CPU (SSE/AVX) | yes | intel CI |
| aarch64 CPU (NEON) | **no** | nowhere |
| CUDA (discrete GPU) | partial | lambda-labs docker |
| CUDA (unified memory) | **no** | nowhere |
| Vulkan/wgpu compute | **no** | nowhere |
| WGSL shader compilation | **no** | nowhere |
| Cross-compiled binary correctness | **no** | nowhere |
| Quantized model load + inference | **no** | nowhere |
| End-to-end pipeline (ingest → index → query → answer) | **no** | nowhere |

The Jetson Orin Nano 8GB is the only machine with **all three compute backends** (CPU NEON, CUDA Ampere, Vulkan wgpu) on real silicon. It becomes the hardware integration gate.

## Goals

1. **Canary gate:** every trueno/realizar/aprender release must pass hardware e2e before publish
2. **Regression detection:** catch silent GPU numerical drift, shader compilation failures, memory model bugs
3. **Profiling baseline:** track inference latency, memory watermark, FLOPS across releases
4. **Cross-compile validation:** prove aarch64 binaries work on real hardware
5. **Unified memory testing:** catch bugs that only manifest without PCIe copy semantics

## Non-Goals

- Large-scale training (8GB is too small)
- Load testing / throughput benchmarking (single device)
- Replace unit tests (those stay in CI)
- Compiling anything on the Jetson

## Build Architecture: intel Builds, Jetson Runs

**Hard constraint: the Jetson Orin Nano cannot compile these projects.**

| Resource | intel (192.168.50.100) | jetson (192.168.50.53) |
|---|---|---|
| CPU | 32-core Xeon W-3275M | 6-core Cortex-A78AE |
| RAM | 283 GB | 7.4 GiB (shared with GPU) |
| Role | **Builder** (self-hosted CI) | **Runner** (test execution only) |
| Toolchain | Rust stable + nightly, aarch64 cross-compile target | None (no rustc, no cargo) |
| Compiles | `apr` (apr-cli) → `aarch64-unknown-linux-gnu` | Nothing |
| Network | LAN 192.168.50.x | LAN 192.168.50.x |

**Why the Jetson can't compile:**
- 7.4 GiB is shared between CPU and GPU — `realizar` release builds need >8GB for linking alone
- 6-core A78AE at 1.5 GHz — a full `trueno` build takes 20+ minutes even on 32 cores
- No swap configured, and NVMe swap would thrash the GPU's unified memory pool

**Pipeline flow (self-hosted runner pattern):**

```
┌──────────────────────────────────────────────────────┐
│  intel (x86_64, 32-core, 283GB)                      │
│                                                      │
│  1. git pull aprender (has apr-cli)                  │
│  2. cross-compile apr → aarch64                      │
│     CARGO_TARGET_AARCH64_..._LINKER=aarch64-...      │
│     cargo +nightly build --release --target          │
│           aarch64-unknown-linux-gnu -p apr-cli       │
│  3. scp apr → jetson:~/.cargo/bin/                   │
│  4. copia sync test models → jetson:/data/models/    │
│     (BLAKE3 delta sync, only changed blocks)         │
│  5. ssh jetson 'apr check --json'         # Tier 1-2 │
│  6. ssh jetson 'apr qa model.gguf --json' # Tier 3   │
│  7. ssh jetson 'apr bench model.gguf'     # Tier 5   │
│  8. collect results ← jetson                         │
│  9. commit results to infra repo                     │
└──────────────────┬───────────────────────────────────┘
                   │ SSH (LAN)
┌──────────────────▼───────────────────────────────────┐
│  jetson (aarch64, 8GB unified, Ampere GPU)           │
│                                                      │
│  - Runs pre-built apr binary (cross-compiled)        │
│  - apr check: hardware probe, kernel correctness     │
│  - apr run/chat: model inference, chat e2e           │
│  - apr qa: falsifiable 10-gate QA checklist          │
│  - apr bench: throughput profiling                   │
│  - apr parity: GPU vs CPU equivalence check          │
│  - Never compiles, never installs crates             │
└──────────────────────────────────────────────────────┘
```

**intel provisions for this role via forjar:**
- `aarch64-linux-gnu-gcc` cross-linker (apt: `gcc-aarch64-linux-gnu`)
- `rustup target add aarch64-unknown-linux-gnu` (stable + nightly)
- Source repos cloned under `~/src/` (aprender, trueno, realizar, etc.)

**Model deployment:** Test models (~725MB total) are synced from intel to jetson via `copia sync` on first run. Subsequent runs use copia's BLAKE3 delta sync — only changed blocks transfer. Models live at `jetson:/home/noah/data/models/canary/`.

## Cross-Compile Readiness Audit (2026-03-04)

Verified cross-compilation to `aarch64-unknown-linux-gnu` for every crate in the canary dependency tree. This determines what can be tested today vs what needs upstream fixes.

### Compiles Clean (ready now)

| Crate | Version | Features | Notes |
|---|---|---|---|
| trueno | 0.16.2 | `gpu` (wgpu 27.0 Vulkan) | Full wgpu compute shaders on aarch64 |
| trueno-quant | 0.1 | (default) | K-quantization formats (Q4_K, Q5_K, Q6_K) |
| trueno-rag | 0.2.2 | `sqlite` | BM25 + FTS5 index, chunking, hybrid retrieval |
| aprender | 0.27.4 | `parallel,format-quantize` | MLP training, random forest, clustering |
| whisper.apr | 0.2 | `std,simd,parallel` | CPU transcription (no GPU yet) |
| forjar | 1.1.1 | (default) | Deployed, verified on Jetson |
| pmat | 3.6.1 | (default) | Deployed, verified on Jetson |
| pzsh | 0.3.5 | (default) | Deployed, verified on Jetson |
| copia | 0.1.3 | `cli` | Deployed, verified on Jetson |

### Needs Minor Fix (1-2 lines each)

| Crate | Version | Features | Issue | Fix |
|---|---|---|---|---|
| trueno-gpu | 0.4.19 | `cuda` | `c_char` is `u8` on aarch64, `i8` on x86 — `CStr::from_ptr` type mismatch | Cast pointer `as *const c_char` in CUDA driver FFI |
| realizar | 0.8.0 | `gpu,cli` | `use fused_q4k_q8k_dot_4rows_avx512vnni` import not gated by `#[cfg(target_arch = "x86_64")]` | Add cfg gate to import in `parallel_k.rs` |

Both are trivial. The call sites are already cfg-gated — only the imports are missing the gate.

### Not Feasible for Cross-Compile

| Crate | Features | Issue | Workaround |
|---|---|---|---|
| trueno-rag | `embeddings` (fastembed) | ONNX Runtime requires native aarch64 build, no cross-compile support | Build on-device or use pre-built ONNX aarch64 wheels |
| whisper.apr | `webgpu` / `cuda` | Depends on trueno-gpu (blocked by c_char fix) | Fix trueno-gpu first, then this unblocks |
| realizar | `cuda` | Depends on trueno-gpu CUDA feature | Fix trueno-gpu first |

### Dependency Graph

```
apr-cli (aprender crate, cross-compiled for aarch64)
├── realizar (0.8, inference engine)
│   ├── trueno (0.16, gpu)     ← READY (wgpu 27.0 Vulkan)
│   ├── trueno-gpu (0.4, cuda) ← BLOCKED: c_char fix
│   │   └── libloading (libcuda.so, runtime)
│   └── trueno-quant (0.1)     ← READY (Q4_K dequant)
├── aprender (0.27, parallel)   ← READY (training, MLP, random forest)
│   └── trueno
├── entrenar (0.7, training)    ← READY (fine-tuning engine)
├── pacha (0.2, model registry) ← READY (HF download, cache)
├── trueno-explain (0.2)        ← READY (PTX analysis)
└── renacer (GPU tracing)       ← READY (profiling)

Separate binaries (also cross-compiled):
├── trueno-rag (0.2, sqlite)    ← READY (RAG pipeline tests)
├── whisper.apr (0.2, std,simd) ← READY (CPU transcription)
├── copia (0.1, cli)            ← READY (model delta sync)
└── forjar (1.1)                ← READY (already deployed)
```

**BLOCKED items (2 upstream fixes):**
- `trueno-gpu` c_char: blocks CUDA PTX path in realizar
- `realizar` AVX-512 cfg gate: blocks all realizar inference on aarch64

## Architecture

### Test Tiers

Inspired by the VOLTA equivalence checking approach (arXiv:2511.12638) and ELIB benchmarking framework (arXiv:2508.11269), tests are organized in graduated tiers. Each tier gates the next — if Tier 1 fails, Tier 2 doesn't run.

```
Tier 1: Probe          (< 5s)   — can we talk to the hardware?
Tier 2: Kernel          (< 15s)  — do compute kernels produce correct results?
Tier 3: Model           (< 60s)  — can we load and run a real model?
Tier 4: Pipeline        (< 120s) — does the full stack work end-to-end?
Tier 5: Profile         (< 60s)  — collect performance baselines
```

**Total budget: < 5 minutes.** Fast enough to run on every release, nightly, or on-demand.

### Tier 1: Hardware Probe

Verify compute backends are reachable. Zero math — just device enumeration.

| Test | What it proves | Expected | Ready? |
|---|---|---|---|
| `nvidia-smi` responds | CUDA driver loaded | Orin (nvgpu), 540.5.0, CUDA 12.6 | **yes** |
| `nvcc --version` | CUDA toolkit installed | 12.6.68 | **yes** |
| `vulkaninfo --summary` | Vulkan ICD present | Tegra Vulkan 1.3.251, NVIDIA proprietary | **yes** |
| `trueno::GpuBackend::is_available()` | wgpu adapter enumerable | true | **yes** |
| `trueno::GpuDevice::list_adapters()` | adapter details | Orin, Vulkan backend | **yes** |
| NEON feature detection | aarch64 SIMD available | `is_aarch64_feature_detected!("neon")` = true | **yes** |
| CUDA driver probe (trueno-gpu) | libcuda.so loadable | cuInit succeeds | after c_char fix |

**Confirmed hardware (2026-03-04):**
- GPU: NVIDIA Tegra Orin (nvgpu), compute capability 8.7, 1024 CUDA cores
- Vulkan: 1.3.251, NVIDIA proprietary driver 540.5.0
- CPU: Cortex-A78AE, features: fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics
- Memory: 7.4 GiB unified (CPU+GPU shared, 68 GB/s)
- Storage: 3.6TB NVMe, 22G used

**Fail = hard stop.** Driver or hardware issue — nothing else will work.

### Tier 2: Kernel Correctness

Run small, deterministic computations on each backend. Compare against known-good CPU f64 reference values. Inspired by trueno's existing `pixel_fkr` (Functional Kernel Regression) pattern.

| Test | Backend | Size | Tolerance | Ready? | What it catches |
|---|---|---|---|---|---|
| Vector add | CPU NEON | 10K | exact | **yes** | NEON codegen bugs |
| Vector add | wgpu Vulkan | 10K | exact | **yes** | WGSL shader compile, buffer binding |
| Vector add | CUDA PTX | 10K | exact | after fix | PTX codegen on Ampere |
| MatMul | CPU NEON | 128×128 | 1e-5 | **yes** | SIMD matmul correctness |
| MatMul | wgpu Vulkan | 128×128 | 1e-5 | **yes** | GPU matmul shader, tiling |
| MatMul | CUDA PTX | 128×128 | 1e-5 | after fix | PTX generation, launch config |
| Softmax | wgpu Vulkan | 1K | 1e-6 | **yes** | Numerical stability (exp overflow) |
| Softmax | CUDA PTX | 1K | 1e-6 | after fix | Same, CUDA path |
| Q4_K dequant | CPU | 256 | 1e-4 | **yes** | Quantization round-trip |
| Q4_K dequant | wgpu | 256 | 1e-4 | **yes** | GPU dequant kernel |
| Dot product | CPU NEON | 100K | 1e-5 | **yes** | Reduction correctness |
| Dot product | wgpu Vulkan | 100K | 1e-5 | **yes** | GPU reduction shader |

**Methodology:** Generate deterministic inputs (seeded RNG), compute reference on CPU f64, compare GPU f32 output. This is the VOLTA principle — equivalence between reference and optimized implementation.

**Phase 1 (now):** 9 of 12 tests — CPU NEON + wgpu Vulkan + quantization.
**Phase 2 (after trueno-gpu fix):** all 12 tests — adds CUDA PTX path.

**Fail = regression.** A kernel changed behavior. Block the release.

### Tier 3: Model Load + Inference

Prove the inference engine works end-to-end on real model files.

| Test | Model | Backend | Ready? | What it proves |
|---|---|---|---|---|
| GGUF parse | Qwen2.5-Coder-1.5B-Q4_K_M | CPU | after cfg fix | Model file parser on aarch64 |
| Tokenize round-trip | Qwen2.5-Coder tokenizer | CPU | after cfg fix | encode→decode identity |
| Forward pass (1 token) | Qwen2.5-Coder-1.5B-Q4_K_M | CPU | after cfg fix | Full transformer forward, CPU NEON |
| Forward pass (1 token) | Qwen2.5-Coder-1.5B-Q4_K_M | wgpu | after cfg fix | Full transformer forward, Vulkan |
| Generate 16 tokens | Qwen2.5-Coder-1.5B-Q4_K_M | CPU | after cfg fix | Autoregressive loop, KV cache |
| Generate 16 tokens | Qwen2.5-Coder-1.5B-Q4_K_M | wgpu | after cfg fix | Same, GPU path |
| Whisper tiny.en (5s WAV) | whisper-tiny.en | CPU | **yes** | Audio→mel→tokens→text |
| Whisper tiny.en (5s WAV) | whisper-tiny.en | wgpu | after both fixes | GPU-accelerated whisper |

**Removed from spec:** BGE-small embedding test. fastembed requires ONNX Runtime which cannot be cross-compiled. If needed later, build on-device or use a pre-built aarch64 ONNX package.

**Models stored on NVMe:** `/home/noah/data/models/canary/`
- `qwen2.5-coder-1.5b-instruct-q4k.apr` (~1GB) — native APR format, Q4_K quantized
- `whisper-tiny.en.bin` (~75MB)
- `canary-audio-5s.wav` (5-second test clip)

**Model preparation (on intel, one-time):**
```bash
apr import hf://Qwen/Qwen2.5-Coder-1.5B-Instruct -o qwen2.5-coder-1.5b-instruct.apr
apr quantize qwen2.5-coder-1.5b-instruct.apr --scheme q4k -o qwen2.5-coder-1.5b-instruct-q4k.apr
```

**Why .apr, not GGUF:** GGUF is llama.cpp's format — we use it in `qwen-coder-deploy` for parity benchmarking against ollama/llama.cpp. But the canary proves OUR stack. `.apr` is our native format: `apr import` → `apr quantize` → `apr compile` is the sovereign pipeline. No foreign formats in the critical path.

**Why 1.5B, not 0.5B:** 0.5B is useless for chat. 1.5B-Q4_K at ~1GB fits easily in 7.4GB unified memory (leaves ~6GB for KV cache + GPU). Same model already validated in `qwen-coder-deploy` (correctness: 6/6 pass, performance: baselined on RTX 4090).

**Determinism:** Use temperature=0, fixed seed. Output must match golden reference within tolerance.

**Phase 1 (now):** Whisper CPU transcription only.
**Phase 2 (after realizar cfg fix):** All GGUF/realizar tests unlock.
**Phase 3 (after both fixes):** Whisper GPU + CUDA inference.

**Fail = inference broken.** Model loading, attention, sampling, or KV cache regressed.

### Tier 4: Pipeline Integration

Full stack end-to-end: from raw input to actionable output.

| Test | Pipeline | Ready? | What it proves |
|---|---|---|---|
| Index → Query (BM25) | trueno-rag: index 10 markdown files → sparse query | **yes** | Chunking, FTS5, BM25 ranking |
| Index → Query (hybrid) | trueno-rag: index → hybrid query (BM25 + TF-IDF RRF) | **yes** | RRF fusion, scoring |
| Train → Export → Load | aprender: train micro MLP → .apr → verify file | **yes** | Training loop + model format |
| Train → Export → Infer | aprender → .apr → realizar load → predict | after cfg fix | Full ML pipeline |
| Sync → Verify | copia: sync test corpus to Jetson, verify checksums | **yes** | BLAKE3 file sync integrity |
| Transcribe → Index → Query | whisper.apr → trueno-rag → query | **yes** (CPU) | Audio-to-knowledge pipeline |

**Note:** `batuta oracle --answer` requires ANTHROPIC_API_KEY and network — excluded from offline canary. Can be a separate online integration test.

**Phase 1 (now):** 5 of 6 tests — RAG pipeline, aprender train+export, copia sync, whisper→RAG.
**Phase 2 (after cfg fix):** Full ML pipeline with realizar inference.

**Fail = integration broken.** Components work individually but fail when composed.

### Tier 5: Performance Profiling

Collect metrics. No pass/fail — just baselines tracked over time. Regressions flagged when latency exceeds 2× previous baseline or memory exceeds 1.5×.

| Metric | What | Unit | Ready? |
|---|---|---|---|
| MatMul throughput (NEON) | 512×512, CPU | GFLOPS | **yes** |
| MatMul throughput (wgpu) | 512×512, Vulkan | GFLOPS | **yes** |
| MatMul throughput (CUDA) | 512×512, PTX | GFLOPS | after fix |
| Inference latency (prefill) | TinyLlama, 128 token prompt | ms | after cfg fix |
| Inference latency (decode) | TinyLlama, per-token | ms/token | after cfg fix |
| Memory watermark | Peak RSS during inference | MB | after cfg fix |
| MBU | % of theoretical 68 GB/s bandwidth | % | after cfg fix |
| Whisper RTF | Real-time factor for 5s clip | ratio | **yes** (CPU) |
| wgpu adapter init | Time to create GPU device | ms | **yes** |
| CUDA kernel launch | MatMul launch overhead | μs | after fix |

**Output:** JSON file committed to `machines/jetson/canary/baselines/YYYY-MM-DD.json`

**Profiling tools:** `renacer` for GPU kernel tracing, `std::time::Instant` for wall clock, `/proc/self/status` for VmHWM.

## Implementation Phases

### Phase 1: Ship Now (no upstream changes)

Available immediately with crates that cross-compile clean today.

**Tier 1:** Full hardware probe (6/7 tests — all except CUDA driver probe).
**Tier 2:** CPU NEON + wgpu Vulkan kernels (9/12 tests).
**Tier 3:** Whisper CPU transcription (1/8 tests).
**Tier 4:** RAG pipeline, aprender training, copia sync, whisper→RAG (5/6 tests).
**Tier 5:** CPU + wgpu matmul throughput, whisper RTF, wgpu init time (4/10 metrics).

**Coverage: ~60% of full canary.** Enough to gate wgpu Vulkan and aarch64 NEON correctness.

### Phase 2: After trueno-gpu c_char Fix

One-line fix: cast `*const u8` to `*const c_char` in `trueno-gpu/src/driver/*.rs`.

**Unlocks:**
- Tier 1: CUDA driver probe
- Tier 2: All 3 CUDA PTX kernel tests
- Tier 5: CUDA matmul throughput, CUDA launch overhead

**Coverage: ~75% of full canary.** All three compute backends validated.

### Phase 3: After realizar cfg Gate Fix

One-line fix: add `#[cfg(target_arch = "x86_64")]` to AVX-512 import in `realizar/src/quantize/parallel_k.rs`.

**Unlocks:**
- Tier 3: All GGUF/realizar tests (parse, tokenize, forward, generate)
- Tier 4: Full ML pipeline (train → export → infer)
- Tier 5: All inference latency/memory/MBU metrics

**Coverage: 100% of canary.** Full end-to-end validation.

### Phase 4: Future (optional)

- fastembed/ONNX on aarch64 (build on-device or aarch64 ONNX wheels) — enables semantic embedding tests
- whisper.apr `webgpu` + `cuda` features — GPU-accelerated transcription
- `batuta oracle --answer` online integration test (requires API key)
- renacer GPU kernel tracing integration
- Nightly cron via forjar `command` resource

## Test Harness Design

### The Canary IS `apr`

**We do not need a custom canary binary.** `apr-cli` (from `aprender`) already has every capability needed:

| apr subcommand | Canary role | Tier |
|---|---|---|
| `apr check` | 10-stage self-test (integrity, GPU probe, format validation) | 1-2 |
| `apr run model.gguf "prompt"` | Zero-config inference from GGUF/SafeTensors/APR | 3 |
| `apr chat` | Interactive REPL chat (end-to-end generation loop) | 3 |
| `apr qa model.gguf` | Falsifiable 10-gate QA (golden output, throughput, parity) | 3-4 |
| `apr parity model.gguf` | GPU vs CPU equivalence (genchi genbutsu) | 2-3 |
| `apr bench model.gguf` | Throughput benchmarking (H12 >= 10 tok/s) | 5 |
| `apr profile model.gguf` | Roofline analysis, layer-by-layer, energy (RAPL) | 5 |
| `apr serve run model.gguf` | OpenAI-compatible HTTP server | 4 |
| `apr canary` | Built-in regression testing framework | 1-5 |
| `apr import hf://org/repo` | Download + convert from HuggingFace | setup |

**What `apr` bundles under the hood:**
- `realizar` — inference engine (GGUF/SafeTensors/APR, CPU+GPU dispatch)
- `trueno` — SIMD + wgpu Vulkan compute kernels
- `trueno-gpu` — CUDA PTX generation (after c_char fix)
- `trueno-quant` — K-quantization (Q4_K, Q5_K, Q6_K dequant)
- `pacha` — model registry/caching (Ollama-like `apr pull`)

This is the same pattern as `qwen-coder-deploy`: forjar provisions the binary + model, Makefile orchestrates test phases, JSON results collected for CI.

### HuggingFace → .apr → Chat: The Full Pipeline

The sovereign pipeline — no foreign formats in the critical path:

```
Step 0: Model preparation (on intel, one-time)
  apr import hf://Qwen/Qwen2.5-Coder-1.5B-Instruct -o qwen-1.5b.apr
  apr quantize qwen-1.5b.apr --scheme q4k -o qwen-1.5b-q4k.apr
  → HuggingFace SafeTensors → native .apr → quantized .apr (~1GB)

Step 1: Sync model to Jetson (intel → jetson, copia delta)
  copia sync ~/data/models/canary/ jetson:~/data/models/canary/

Step 2: Run on Jetson (zero-config, native .apr format)
  apr run ~/data/models/canary/qwen-1.5b-q4k.apr \
      --prompt "Write a Python fibonacci function" --max-tokens 128 --gpu

  Internal call chain:
  ┌─ realizar::format::detect_format() → APR
  ├─ realizar::apr::AprModel::load() → parse header, tensor metadata, vocab
  ├─ trueno-quant: Q4_K blocks → f16/f32 (NEON dequant on-the-fly)
  ├─ tokenize("Write a Python...") → [...]  (BPE from embedded vocab)
  ├─ forward pass: embed → RMSNorm → QKV → RoPE → Attention → FFN × 28 layers
  │   └─ each matmul dispatches: CPU NEON | wgpu Vulkan | CUDA PTX
  ├─ KV cache in unified memory (no PCIe copy — Jetson advantage)
  ├─ sample: temp=0, seed=42 → deterministic next token
  └─ decode → "def fibonacci(n):\n    if n <= 1:\n        return n\n    ..."

Step 3: QA gate (falsifiable assertions)
  apr qa ~/data/models/canary/qwen-1.5b-q4k.apr --json
  → 10 gates: golden output, throughput, format integrity, ...

Step 4: GPU/CPU parity
  apr parity ~/data/models/canary/qwen-1.5b-q4k.apr \
      --prompt "Write a Python fibonacci function" --assert
  → same prompt on CPU vs GPU, token-level comparison

Step 5: Profiling baseline
  apr bench ~/data/models/canary/qwen-1.5b-q4k.apr \
      --warmup 3 --iterations 10 --json
  → tok/s, TTFT, memory watermark

Step 6: End game — compiled binary (after codegen enhancement)
  # On intel:
  apr compile ~/data/models/canary/qwen-1.5b-q4k.apr \
      --target aarch64-unknown-linux-gnu --release --strip --lto \
      -o qwen-coder-jetson
  scp qwen-coder-jetson jetson:~/
  # On Jetson:
  ./qwen-coder-jetson --prompt "Write a Python fibonacci function"
  ./qwen-coder-jetson --serve --port 8080
  → one file, zero dependencies, sovereign stack proven
```

### Cross-Compile + Deploy (intel → jetson)

Follows the `qwen-coder-deploy` pattern: forjar provisions, Makefile orchestrates.

```makefile
# In machines/jetson/Makefile
# Build runs on INTEL (self-hosted runner), not on jetson.

INTEL          := intel
APRENDER_SRC   := /home/noah/src/aprender
CROSS_DIR      := /tmp/cross-jetson
TARGET         := aarch64-unknown-linux-gnu
LINKER         := aarch64-linux-gnu-gcc
MODEL_DIR      := /home/noah/data/models/canary
MODEL          := $(MODEL_DIR)/qwen-1.5b-q4k.apr
CANARY_OUT     := machines/jetson/canary

# ── Model preparation (one-time, on intel) ───────────────────
canary-import:  ## Import from HuggingFace → .apr → quantize
    ssh $(INTEL) 'apr import hf://Qwen/Qwen2.5-Coder-1.5B-Instruct \
        -o $(MODEL_DIR)/qwen-1.5b.apr'
    ssh $(INTEL) 'apr quantize $(MODEL_DIR)/qwen-1.5b.apr \
        --scheme q4k -o $(MODEL)'

# ── Cross-compile apr-cli (on intel) ─────────────────────────
apr-build:  ## Cross-compile apr for aarch64
    ssh $(INTEL) 'cd $(APRENDER_SRC) && \
        CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=$(LINKER) \
        CC_aarch64_unknown_linux_gnu=$(LINKER) \
        cargo +nightly build --release \
            --target $(TARGET) \
            --target-dir $(CROSS_DIR) \
            -p apr-cli'

apr-build-cuda:  ## Cross-compile with CUDA (after trueno-gpu fix)
    ssh $(INTEL) 'cd $(APRENDER_SRC) && \
        CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=$(LINKER) \
        CC_aarch64_unknown_linux_gnu=$(LINKER) \
        cargo +nightly build --release \
            --target $(TARGET) \
            --target-dir $(CROSS_DIR) \
            -p apr-cli --features cuda'

# ── Deploy (intel → jetson) ──────────────────────────────────
apr-deploy: apr-build  ## Deploy apr binary to Jetson
    ssh $(INTEL) 'scp $(CROSS_DIR)/$(TARGET)/release/apr jetson:~/.cargo/bin/'

canary-models:  ## Sync .apr model to Jetson (copia delta)
    ssh $(INTEL) 'copia sync $(MODEL_DIR)/ jetson:$(MODEL_DIR)/'

# ── Canary tests (on jetson) ─────────────────────────────────
canary-check:  ## Tier 1-2: hardware probe + kernel correctness
    ssh jetson 'apr check --json' | tee $(CANARY_OUT)/check.json

canary-qa:  ## Tier 3: 10-gate falsifiable QA
    ssh jetson 'apr qa $(MODEL) --json' | tee $(CANARY_OUT)/qa.json

canary-parity:  ## Tier 3: GPU vs CPU equivalence
    ssh jetson 'apr parity $(MODEL) \
        --prompt "Write a Python fibonacci function" \
        --assert --json' | tee $(CANARY_OUT)/parity.json

canary-bench:  ## Tier 5: throughput profiling
    ssh jetson 'apr bench $(MODEL) \
        --warmup 3 --iterations 10 --json' \
        | tee $(CANARY_OUT)/bench.json

canary-chat:  ## Tier 4: end-to-end chat
    ssh jetson 'apr run $(MODEL) \
        --prompt "Write a Python fibonacci function" \
        --max-tokens 128'

# ── End game: compiled binary + probar verification ──────────
JETSON_URL     := http://192.168.50.53:8080
CORRECTNESS    := machines/jetson/canary/correctness.yaml

canary-compile:  ## Compile self-contained binary (model baked in)
    ssh $(INTEL) 'apr compile $(MODEL) \
        --target $(TARGET) --release --strip --lto \
        -o $(CROSS_DIR)/qwen-coder-jetson'
    ssh $(INTEL) 'scp $(CROSS_DIR)/qwen-coder-jetson jetson:~/'

canary-serve:  ## Start compiled binary as chat server on Jetson
    ssh -f jetson './qwen-coder-jetson --serve --port 8080'
    @echo "Waiting for server..."
    @until curl -sf $(JETSON_URL)/health > /dev/null 2>&1; do sleep 1; done
    @echo "[ok] Server ready at $(JETSON_URL)"

canary-test:  ## probador correctness tests against Jetson chat server
    probador llm test \
        --config $(CORRECTNESS) \
        --url $(JETSON_URL) \
        --runtime-name qwen-coder-jetson-aarch64 \
        --output $(CANARY_OUT)/probar-test.json

canary-load:  ## probador load test (concurrency=2, 30s — Jetson is small)
    probador llm load \
        --url $(JETSON_URL) \
        --concurrency 2 \
        --duration 30s \
        --warmup 5s \
        --runtime-name qwen-coder-jetson-aarch64 \
        --output $(CANARY_OUT)/probar-load.json

canary-bench-full:  ## probador multi-run benchmark with regression gate
    probador llm bench \
        --url $(JETSON_URL) \
        --runs 3 --duration 30s --warmup 5s \
        --concurrency 2 \
        --baseline $(CANARY_OUT)/baselines/latest.json \
        --fail-on-regression 50.0 \
        --runtime-name qwen-coder-jetson-aarch64 \
        --output $(CANARY_OUT)/probar-bench.json

canary-stop:  ## Stop Jetson chat server
    ssh jetson 'pkill -f qwen-coder-jetson || true'

# ── Full pipeline ────────────────────────────────────────────
canary: apr-deploy canary-models canary-check canary-qa canary-parity canary-bench canary-chat
    @echo "[ok] Canary phase 1 complete (apr + model file)."
    @jq '.status' $(CANARY_OUT)/check.json
    @jq '.gates_passed' $(CANARY_OUT)/qa.json

# End game: compiled binary + probar verification
canary-e2e: canary-compile canary-serve canary-test canary-load canary-stop
    @echo "[ok] End-to-end canary complete."
    @echo "Correctness:"; jq '.summary' $(CANARY_OUT)/probar-test.json
    @echo "Load:"; jq '{rps: .throughput_rps, p50: .latency_p50_ms, tok_s: .tokens_per_sec}' \
        $(CANARY_OUT)/probar-load.json

# Full pipeline including compiled binary
canary-all: canary canary-e2e
```

**Correctness test suite** (`machines/jetson/canary/correctness.yaml`):
```yaml
# Same structure as qwen-coder-deploy/prompts/correctness.yaml
tests:
  - name: basic_math
    messages:
      - role: user
        content: "What is 7 * 8? Reply with just the number."
    expect_contains: "56"
    max_tokens: 32
    temperature: 0.0

  - name: python_fibonacci
    messages:
      - role: user
        content: "Write a Python function that returns the nth fibonacci number."
    expect_contains: "def fib"
    max_tokens: 256
    temperature: 0.0

  - name: rust_hello
    messages:
      - role: user
        content: "Write a Rust program that prints hello world."
    expect_contains: "fn main"
    max_tokens: 128
    temperature: 0.0

  - name: json_output
    messages:
      - role: user
        content: "Return a JSON object with keys 'name' and 'age'. Name is Alice, age is 30."
    expect_pattern: '"name".*"Alice"'
    max_tokens: 128
    temperature: 0.0

  - name: code_explanation
    messages:
      - role: user
        content: "What does `vec![1,2,3].iter().map(|x| x*2).collect::<Vec<_>>()` do in Rust?"
    expect_pattern: "(?i)(double|multiply|2)"
    max_tokens: 256
    temperature: 0.0

  - name: sql_query
    messages:
      - role: user
        content: "Write a SQL query to find the top 5 users by order count."
    expect_pattern: "(?i)SELECT.*ORDER BY.*LIMIT"
    max_tokens: 256
    temperature: 0.0
```

**Key details:**
- `.apr` format end-to-end — `apr import` → `apr quantize` → `apr compile`. No GGUF.
- `probador llm test` runs FROM intel (or dev laptop) against `http://jetson:8080` — no need to cross-compile probador
- `probador llm bench` has `--fail-on-regression 50.0` — 50% regression tolerance (Jetson is slow, but shouldn't get 2x worse)
- `canary-e2e` is the complete end game: compile → serve → test → load → stop
- `canary-all` runs both phases: apr+model first, then compiled binary + probar verification
- Concurrency=2 and duration=30s — Jetson only has 7.4GB, don't OOM it

### Why This Is Better Than a Custom Canary Crate

| | Custom `canary` binary | `apr` (apr-cli) |
|---|---|---|
| Maintenance | New crate to maintain, test, version | Already exists, tested, 1000+ test files |
| Coverage | Would reimplement apr's test logic | Uses THE production code path |
| Model support | Would need to wrap realizar | realizar is already wired in |
| GPU dispatch | Would need to wrap trueno | trueno is already wired in |
| HuggingFace | Would need pacha integration | `apr pull` already works |
| Chat template | Would need to reimplement | `apr chat` auto-detects templates |
| QA gates | Would need to define gates | `apr qa` has 10 falsifiable gates |
| Profiling | Would need to wrap renacer | `apr profile` has roofline analysis |
| Format support | GGUF only? | GGUF + SafeTensors + APR |
| Offline mode | Would need to implement | `apr --offline` already enforces sovereignty |

The `qwen-coder-deploy` repo proves this pattern works: forjar provisions, `apr serve` runs inference, `probador` tests correctness, `apr bench`/`apr profile` collects metrics. The Jetson canary is the same pattern on aarch64 hardware.

### Nightly Automation: GitHub Actions Self-Hosted Runner

**Exactly the same pattern as `qwen-coder-deploy`.**

intel is already a GitHub Actions self-hosted runner. The canary nightly runs as a workflow in the `sovereign-ai-cookbook` repo:

**`.github/workflows/canary-nightly.yml`:**
```yaml
name: Jetson Canary

on:
  schedule:
    - cron: '0 6 * * *'  # 6am UTC (2am ET) daily
  workflow_dispatch: {}   # manual trigger via GitHub UI

jobs:
  canary:
    runs-on: self-hosted  # intel (192.168.50.100)
    steps:
      - uses: actions/checkout@v4

      - name: Canary pipeline
        run: bash scripts/canary-jetson.sh

      - name: Commit results
        run: |
          git add machines/jetson/canary/
          git commit -m "canary: $(date +%Y-%m-%d) jetson nightly results" || echo "No changes"
          git push
```

**`scripts/canary-jetson.sh`:**
```bash
#!/bin/bash
set -euo pipefail
DATE=$(date +%Y%m%d)

echo "=== Jetson Canary: $(date) ==="

# Phase 1: Cross-compile apr for aarch64 (on intel, we ARE intel)
echo "--- Cross-compiling apr-cli → aarch64 ---"
cd ~/src/aprender
CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc \
CC_aarch64_unknown_linux_gnu=aarch64-linux-gnu-gcc \
cargo +nightly build --release --target aarch64-unknown-linux-gnu \
    -p apr-cli --target-dir /tmp/cross-jetson

# Phase 2: Deploy binary + model to Jetson
echo "--- Deploying to Jetson ---"
scp /tmp/cross-jetson/aarch64-unknown-linux-gnu/release/apr jetson:~/.cargo/bin/
copia sync ~/data/models/canary/ jetson:~/data/models/canary/

# Phase 3: Run canary tests on Jetson (via SSH)
CANARY=machines/jetson/canary
MODEL=~/data/models/canary/qwen-1.5b-q4k.apr
cd ~/src/sovereign-ai-cookbook

echo "--- Tier 1-2: Hardware probe + kernel correctness ---"
ssh jetson "apr check --json" > $CANARY/check.json

echo "--- Tier 3: Model QA ---"
ssh jetson "apr qa $MODEL --json" > $CANARY/qa.json

echo "--- Tier 3: GPU/CPU parity ---"
ssh jetson "apr parity $MODEL --prompt 'Write a fibonacci function' --assert --json" \
    > $CANARY/parity.json || true

echo "--- Tier 5: Throughput ---"
ssh jetson "apr bench $MODEL --warmup 3 --iterations 10 --json" \
    > $CANARY/bench.json

# Phase 4: End game — compiled binary + probar
echo "--- Compiling self-contained binary ---"
apr compile ~/data/models/canary/qwen-1.5b-q4k.apr \
    --target aarch64-unknown-linux-gnu --release --strip --lto \
    -o /tmp/cross-jetson/qwen-coder-jetson
scp /tmp/cross-jetson/qwen-coder-jetson jetson:~/

echo "--- Starting chat server on Jetson ---"
ssh jetson 'pkill -f qwen-coder-jetson || true'
ssh -f jetson './qwen-coder-jetson --serve --port 8080'
timeout 60 bash -c 'until curl -sf http://192.168.50.53:8080/health >/dev/null 2>&1; do sleep 2; done'

echo "--- probador correctness tests ---"
probador llm test \
    --config $CANARY/correctness.yaml \
    --url http://192.168.50.53:8080 \
    --runtime-name qwen-coder-jetson-aarch64 \
    --output $CANARY/probar-test.json || true

echo "--- probador load test ---"
probador llm load \
    --url http://192.168.50.53:8080 \
    --concurrency 2 --duration 30s --warmup 5s \
    --runtime-name qwen-coder-jetson-aarch64 \
    --output $CANARY/probar-load.json || true

echo "--- Stopping Jetson server ---"
ssh jetson 'pkill -f qwen-coder-jetson || true'

# Phase 5: Archive baselines
cp $CANARY/probar-load.json $CANARY/baselines/$DATE.json 2>/dev/null || true
cp $CANARY/probar-load.json $CANARY/baselines/latest.json 2>/dev/null || true

echo "=== Canary complete: $(date) ==="
jq '.status' $CANARY/check.json
jq '.gates_passed' $CANARY/qa.json
jq '{rps: .throughput_rps, p50: .latency_p50_ms}' $CANARY/probar-load.json
```

**Trigger points:**

| Trigger | What runs | How |
|---|---|---|
| **Nightly 6am UTC** | Full canary-all (compile + deploy + test + serve + probar) | GitHub Actions `schedule` cron |
| **Manual** | Same | GitHub Actions `workflow_dispatch` (click "Run workflow") |
| **trueno/realizar release tag** | `make canary` (no compiled binary, just apr + model) | GitHub Actions `repository_dispatch` or manual |
| **Post-provision** | `make verify` (Tier 1 only — GPU, tools, SSH) | Manual after `forjar apply` |
| **On-demand from dev laptop** | `make canary-all` in `machines/jetson/Makefile` | Manual SSH |

### Result Storage

```
machines/jetson/canary/
  latest.json              # most recent run
  baselines/
    2026-03-04.json        # daily snapshots
    2026-03-04-trueno-0.17.json  # release-tagged
  golden/
    matmul-128x128-f32.bin # reference outputs (committed)
    qwen-coder-1.5b-fibonacci.txt    # expected generation
```

## Falsifiable Artifacts (Popperian Evidence)

We can't prove the stack works. We can only **try to break it** and show it survived. Each artifact below is a falsification attempt — if any one fails, the stack is broken.

### The Binaries: What Must Link + Run

Each binary proves a **slice of the stack** compiles, links, and executes on aarch64+GPU hardware. If `cargo build --target aarch64-unknown-linux-gnu` succeeds, that's ~200K lines of Rust proven to link. If the binary runs and produces correct output on the Jetson, that's proven to execute.

| Binary | What it proves | Crates exercised | Size |
|---|---|---|---|
| **`apr`** | **The whole inference stack.** GGUF parse, tokenize, Q4_K dequant, transformer forward pass, KV cache, sampling, chat — on CPU NEON, wgpu Vulkan, CUDA PTX. | realizar, trueno, trueno-gpu, trueno-quant, aprender, pacha, entrenar, renacer | ~60MB |
| `trueno-rag` | RAG pipeline: chunk, index, BM25, hybrid retrieval, FTS5. | trueno-rag, trueno-db | ~15MB |
| `whisper.apr` | Audio→mel→tokens→text transcription on CPU SIMD. | whisper-apr, trueno | ~20MB |
| `copia` | BLAKE3 file sync integrity (used to deploy models). | copia | ~3MB |
| `forjar` | Infrastructure-as-code (already deployed + verified). | forjar | ~22MB |
| `pmat` | Code quality + work tracking. | pmat | ~33MB |

**`apr` is the primary artifact.** If `apr run model.gguf "What is 2+2?"` produces `"4"` on the Jetson, it means:
- GGUF parser works on aarch64 (endianness, mmap alignment, page size)
- BPE tokenizer produces correct IDs from embedded vocab
- Q4_K dequantization is correct on NEON (128-bit SIMD)
- Every matmul in every transformer layer produces correct output
- RoPE positional encoding works on ARM
- KV cache doesn't corrupt across autoregressive steps
- Softmax is numerically stable on f32
- Sampling at temperature=0 is deterministic across architectures
- Chat template formatting doesn't break model input
- The output is coherent text, not garbage

Every one of those is a falsification opportunity. If any fails, `apr` produces wrong output or crashes.

### The Evidence: JSON Falsification Reports

Each JSON file is a machine-readable record of falsification attempts:

| Artifact | Falsification attempt | Pass condition | Fail means |
|---|---|---|---|
| `check.json` | Can we find the GPU? Can we enumerate Vulkan? Can we load libcuda.so? | All 10 stages pass | Driver/hardware broken |
| `qa.json` | Can we break the model? Wrong golden output? Corrupt tokenizer? Format violation? | All 10 gates pass | Inference regressed |
| `parity.json` | Does GPU produce different tokens than CPU for the same prompt at temp=0? | Token IDs match exactly | Kernel numerical bug |
| `bench.json` | Did throughput regress >2x from baseline? Did memory exceed 1.5x? | Within tolerance of baseline | Performance regression |
| `golden/qwen-coder-1.5b-fibonacci.txt` | Does `apr run --max-tokens 128` produce the exact same code as last known-good run? | Byte-for-byte match | Forward pass or sampling changed |
| **`probar-test.json`** | Can the compiled binary serve correct responses? Math, code gen, JSON, SQL — 6 assertions via `probador llm test` | All 6 tests pass (substring + regex) | Compiled chat server produces wrong output |
| **`probar-load.json`** | Does the compiled chat server handle concurrent requests without crashing? | RPS > 0, error_rate < 5%, p99 < timeout | Server OOMs, deadlocks, or crashes under load |
| **`probar-bench.json`** | Did the compiled server regress >50% from baseline? Multi-run, 95% CI | `--fail-on-regression 50.0` passes | Significant performance regression |

### What "Green" Means

If all artifacts are green, the following Popperian statement holds:

> "We attempted to falsify the sovereign AI stack on aarch64+Ampere hardware through 8 independent falsification artifacts: hardware probe, kernel correctness, model QA, GPU/CPU parity, golden output, chat server correctness (`probador llm test`), concurrent load survival (`probador llm load`), and performance regression detection (`probador llm bench`). All attempts failed to find a defect. The stack withstands falsification at this level of rigor."

This is committed to the repo as evidence. Anyone can reproduce it: `make canary-all`.

### What "Red" Means

Any single red artifact is a **release blocker**. The specific failure tells you exactly what broke:

- `check.json` red → hardware/driver issue (not our bug, but blocks testing)
- `qa.json` red → inference regression (find which gate failed, bisect the commit)
- `parity.json` red → GPU kernel produces different results than CPU (trueno/trueno-gpu bug)
- `bench.json` red → performance regression (acceptable if intentional, block if not)
- Golden mismatch → forward pass changed (could be intentional improvement, requires review)
- `probar-test.json` red → compiled chat server produces wrong answers (the end-game binary is broken)
- `probar-load.json` red → server can't handle concurrent requests (OOM, deadlock, crash)
- `probar-bench.json` red → >50% regression from baseline (something got significantly slower)

### The Ultimate Artifact: `apr compile` (llamafile-style)

The strongest possible falsification artifact is a **single self-contained binary** with the model weights baked in — no separate model file, no dependencies, no runtime. Like llamafile, but built from our stack.

```bash
# On intel: HuggingFace → APR → quantize → compile (one-time)
apr import hf://Qwen/Qwen2.5-Coder-1.5B-Instruct -o qwen-1.5b.apr
apr quantize qwen-1.5b.apr --scheme q4k -o qwen-1.5b-q4k.apr
apr compile qwen-1.5b-q4k.apr \
    --target aarch64-unknown-linux-gnu \
    --release --strip --lto \
    -o qwen-coder-jetson

# Deploy: one file, ~1GB
scp qwen-coder-jetson jetson:~/

# On Jetson: run it — one binary, zero dependencies, sovereign stack end-to-end
./qwen-coder-jetson --prompt "Write a Python fibonacci function"
./qwen-coder-jetson --serve --port 8080  # OpenAI-compatible chat server
```

**What this single binary proves (Popperian):**

| Step | What it falsifies |
|---|---|
| `apr import` succeeded | HuggingFace download, SafeTensors parse, APR format write |
| `apr quantize` succeeded | Weight quantization (Q4_K_M), numerical correctness |
| `apr compile --target aarch64` succeeded | Cross-compilation, `include_bytes!` model embedding, linking |
| Binary runs on Jetson | aarch64 ELF is valid, all deps link, no missing symbols |
| Correct output | GGUF/APR parse, tokenizer, dequant, every matmul, attention, KV cache, sampling |

**If this binary produces coherent code on the Jetson, the entire sovereign AI stack withstands falsification in a single artifact.**

**Current state of `apr compile`:** APR-SPEC §4.16. Generates a Cargo project with `include_bytes!` model embedding, supports `--target aarch64-unknown-linux-gnu`, has `--release --strip --lto` optimization flags. However, the codegen (`compile_codegen.rs`) currently generates a **deployment shell** that only prints metadata. It does not wire `realizar` for inference dispatch.

**What we will implement:** `compile_codegen.rs` will generate:
1. A `Cargo.toml` that depends on `realizar` (+ `trueno`, `trueno-quant`) — same deps as `apr run`
2. A `main.rs` that calls `realizar::run_inference()` with the embedded model bytes
3. `--prompt` flag for single-shot generation
4. `--serve --port N` flag for an OpenAI-compatible `/v1/chat/completions` endpoint
5. `--chat` flag for interactive REPL

This is the same inference path `apr run` and `apr serve` already use — the codegen just needs to emit it instead of printing metadata.

**Artifact set (ordered by falsification strength):**

| Artifact | What it is | Falsification strength |
|---|---|---|
| **`qwen-coder-jetson`** | Self-contained binary (model + engine fused, `apr compile`) | **Maximum** — one file proves everything |
| `apr` + `.apr` model | Separate engine + model | High — proves inference, model is external |
| `check.json` / `qa.json` | JSON test reports | Medium — proves individual gates |
| `bench.json` | Performance baselines | Low — proves performance, not correctness |

**The end game is `qwen-coder-jetson`.** A single ~1GB aarch64 binary that you `scp` to the Jetson, run, and it chats. No runtime, no model files, no dependencies. If it produces correct code completions on ARM+GPU, the sovereign AI stack is proven end-to-end.

**Interim (until codegen is complete):** `apr` + separate `.apr` model file. Same tests, same falsification — just two files instead of one.

## Intel Provisioning Required

intel needs the aarch64 cross-compilation toolchain added to its forjar.yaml:

```yaml
# In machines/intel/forjar.yaml — add to resources:

cross-compile-deps:
  type: package
  machine: intel
  provider: apt
  packages:
    - gcc-aarch64-linux-gnu
    - g++-aarch64-linux-gnu

cross-compile-target-stable:
  type: task
  machine: intel
  command: "rustup target add aarch64-unknown-linux-gnu"
  check: "rustup target list --installed | grep -q aarch64-unknown-linux-gnu"

cross-compile-target-nightly:
  type: task
  machine: intel
  command: "rustup +nightly target add aarch64-unknown-linux-gnu"
  check: "rustup +nightly target list --installed | grep -q aarch64-unknown-linux-gnu"
```

intel also needs `jetson` in its `~/.ssh/config` so it can SSH to the Jetson for deploy + run:

```
Host jetson
    HostName 192.168.50.53
    User noah
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
```

## Upstream Fixes Required

### Fix 1: trueno-gpu c_char (Priority: P1)

**File:** `trueno-gpu/src/driver/*.rs` (CUDA FFI layer)
**Issue:** `c_char` is `i8` on x86_64, `u8` on aarch64. `CStr::from_ptr` expects `*const c_char`.
**Fix:** Replace `*const u8` / `*mut u8` with `*const c_char` / `*mut c_char` or cast at call sites.
**Impact:** Unlocks CUDA PTX on aarch64 (Tier 2 CUDA tests, Tier 5 CUDA profiling).
**LOC:** ~2 lines changed.

### Fix 2: realizar AVX-512 cfg gate (Priority: P1)

**File:** `realizar/src/quantize/parallel_k.rs`
**Issue:** `use super::fused_k::fused_q4k_q8k_dot_4rows_avx512vnni` import is not gated by `#[cfg(target_arch = "x86_64")]`. The call sites already have the gate — only the import is missing.
**Fix:** Add `#[cfg(target_arch = "x86_64")]` before the import.
**Impact:** Unlocks all realizar inference on aarch64 (Tier 3, Tier 4, Tier 5).
**LOC:** 1 line added.

## Resolved Questions

1. ~~**Vulkan ICD on Jetson:**~~ **CONFIRMED.** JetPack 6.2.2 ships Vulkan 1.3.251 with NVIDIA proprietary driver 540.5.0. `vulkaninfo --summary` enumerates `NVIDIA Tegra Orin (nvgpu)` as `PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU`. wgpu will find this adapter.

2. ~~**CUDA PTX cross-compilation:**~~ **FEASIBLE after c_char fix.** trueno-gpu generates PTX from Rust (no nvcc dependency). The PTX is text that runs on any CUDA compute capability. Cross-compile produces the PTX generator binary; actual PTX emission happens at runtime on-device via libcuda.so.

3. ~~**Custom canary binary vs existing tools:**~~ **RESOLVED: use `apr` (apr-cli).** `apr-cli` already has `check`, `qa`, `parity`, `bench`, `profile`, `canary`, `run`, `chat`, `serve` — every capability the canary needs. No custom crate. Cross-compile `apr-cli` for aarch64 on intel, deploy to Jetson, run `apr` subcommands. This follows the proven `qwen-coder-deploy` pattern.

4. ~~**Build architecture:**~~ **RESOLVED: intel builds, Jetson runs.** The Jetson (7.4GiB shared RAM, 6-core A78AE) cannot compile these projects. intel (283GB, 32-core Xeon) cross-compiles `apr-cli` → `aarch64-unknown-linux-gnu`, deploys via SSH, Jetson only executes pre-built binaries.

## Open Questions

1. **Unified memory semantics:** wgpu's buffer model assumes discrete GPU with explicit copies. Does the Orin's unified memory cause unexpected behavior in `map_async` / `unmap`? Needs empirical testing in Tier 2.

2. ~~**Model download automation:**~~ **RESOLVED.** Models are synced from intel to jetson via `make canary-models` (copia delta sync). Intel caches models at `~/data/models/canary/`. First run: ~725MB transfer. Subsequent: only changed blocks. No forjar `source:` needed — models are too large for base64 transport.

3. **Baseline drift policy:** How much performance regression is acceptable before blocking? Proposal: 2× latency or 1.5× memory = warning, 3× = hard fail.

4. **Notification:** Should canary failures page? Or just commit a red status to the repo?

5. **Nightly toolchain requirement:** trueno-rag uses `round_char_boundary` (unstable). Should we stabilize this dependency, or accept nightly for canary builds?

## References

- [VOLTA: Equivalence Checking of ML GPU Kernels](https://arxiv.org/abs/2511.12638) — formal verification of GPU kernel correctness across hand-written, LLM-generated, and compiler-generated implementations
- [ELIB: Edge LLM Inference Benchmarking](https://arxiv.org/abs/2508.11269) — MBU (Memory Bandwidth Utilization) metric and edge device benchmarking framework across 3 platforms and 5 quantized models
- [Sustainable LLM Inference for Edge AI](https://arxiv.org/abs/2504.03360) — quantized LLM evaluation on edge devices measuring energy efficiency, output accuracy, and inference latency with Joulescope hardware monitoring
- [Edge AI in Practice: Survey and Deployment Framework](https://www.mdpi.com/2079-9292/14/24/4877) — five-stage deployment methodology: requirement definition, model selection, optimization, hardware alignment, deployment
- [ML-EXRAY: Visibility into ML Deployment on the Edge](https://arxiv.org/abs/2111.04779) — layer-level debugging for cloud-to-edge deployment, catches preprocessing bugs, quantization issues, suboptimal kernels
- [Khronos Vulkan Validation Layers: GPU-AV](https://github.com/KhronosGroup/Vulkan-ValidationLayers/blob/main/docs/gpu_validation.md) — runtime shader validation via instrumentation; cannot run in headless CI with mock ICD, needs real device
- [GPU Kernel Scientist: LLM-Driven Kernel Optimization](https://arxiv.org/abs/2506.20807) — automated GPU kernel optimization with correctness validation
- trueno `pixel_fkr` pattern — existing functional kernel regression tests in `trueno/tests/pixel_fkr/wgpu_validation.rs`
- `qwen-coder-deploy` — production reference implementation of the forjar→apr serve→probador→bench pipeline on x86_64+RTX 4090, with MLPerf-compliant benchmarking methodology (v2.0), NVIDIA Nsight kernel profiling, and nightly automation
- `probador` (`probar llm`) — sovereign LLM testing framework: `test` (structured correctness assertions), `load` (concurrent load with p50/p95/p99), `bench` (multi-run with regression gates), `report` (Markdown tables). Runs from any machine against HTTP endpoint.

## Appendix: Hardware Specs (Verified 2026-03-04)

**Jetson Orin Nano 8GB (P3767-0005)**
- SoC: NVIDIA Orin (Cortex-A78AE + Ampere GPU, 1024 CUDA cores)
- Memory: 7.4 GiB LPDDR5 unified (CPU+GPU shared, 68 GB/s)
- Storage: 3.6TB NVMe (WD), 22G used, ext4 on `/dev/nvme0n1p1`
- CUDA: 12.6.68 (compute capability 8.7)
- Vulkan: 1.3.251 (NVIDIA proprietary driver 540.5.0)
- JetPack: 6.2.2+b24 / L4T R36.5.0
- CPU features: fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics fphp asimdhp cpuid asimdrdm lrcpc dcpop asimddp uscat ilrcpc flagm paca pacg
- Power: 25W default (MAXN SUPER available via nvpmodel -m 0)
- IP: 192.168.50.53 (LAN), SSH alias: `jetson`
