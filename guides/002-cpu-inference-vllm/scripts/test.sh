#!/usr/bin/env bash
# =============================================================================
# test.sh — Guide 002: CPU Inference with vLLM
# =============================================================================
# Port-forwards to vllm-cpu, sends test prompts, measures latency.
# Run after deploy.sh completes.
# =============================================================================

set -euo pipefail

NAMESPACE="llm-serving"
SVC="vllm-cpu"
MODEL="llama-3.2-1b"
PORT=8000

# Start port-forward
kubectl port-forward -n "$NAMESPACE" svc/"$SVC" "${PORT}:${PORT}" &
PF_PID=$!
trap "kill $PF_PID 2>/dev/null || true" EXIT
sleep 3

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   Guide 002 — vLLM CPU Test  (model: $MODEL)              ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# List models
echo ""
echo "Available models:"
curl -sf http://localhost:${PORT}/v1/models \
| python3 -c "
import sys, json
for m in json.load(sys.stdin)['data']:
    print(f'  - {m[\"id\"]}')
" 2>/dev/null || echo "  (could not list models)"

# Test prompts
PROMPTS=(
  "What is Amazon EKS? One sentence."
  "What is the difference between CPU and GPU inference for LLMs?"
  "Write a Python function that checks if a string is a palindrome."
)

for PROMPT in "${PROMPTS[@]}"; do
  echo ""
  echo "──────────────────────────────────────────────────────────────"
  printf "  Prompt: %s\n" "$PROMPT"
  echo ""

  START=$(date +%s%3N)
  RESP=$(curl -sf http://localhost:${PORT}/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d "$(python3 -c "
import json, sys
print(json.dumps({
  'model': '$MODEL',
  'messages': [{'role': 'user', 'content': '''$PROMPT'''}],
  'max_tokens': 250
}))
")")
  END=$(date +%s%3N)
  LATENCY=$((END - START))

  echo "$RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
msg    = d['choices'][0]['message']['content'].strip()
usage  = d.get('usage', {})
prompt_toks = usage.get('prompt_tokens', 0)
compl_toks  = usage.get('completion_tokens', 0)
print(f'  Response: {msg}')
print(f'  Tokens:   {prompt_toks} prompt + {compl_toks} completion = {prompt_toks+compl_toks} total')
" 2>/dev/null

  printf "  Latency:  %dms\n" "$LATENCY"
done

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  CPU throughput: ~8–12 tok/s on t3.xlarge                  ║"
echo "║  GPU throughput: ~1500 tok/s on g5.xlarge  (Guide 003)     ║"
echo "║  That is ~100x faster for the same API call.               ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
