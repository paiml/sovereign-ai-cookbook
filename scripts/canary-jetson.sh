#!/bin/bash
# canary-jetson.sh — Nightly canary pipeline for Jetson Orin Nano
# Runs on intel (self-hosted runner), tests against jetson (192.168.50.53)
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

# Phase 4: End game — compiled binary + probador
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
mkdir -p $CANARY/baselines
cp $CANARY/probar-load.json $CANARY/baselines/$DATE.json 2>/dev/null || true
cp $CANARY/probar-load.json $CANARY/baselines/latest.json 2>/dev/null || true

echo "=== Canary complete: $(date) ==="
jq '.status' $CANARY/check.json
jq '.gates_passed' $CANARY/qa.json
jq '{rps: .throughput_rps, p50: .latency_p50_ms}' $CANARY/probar-load.json
