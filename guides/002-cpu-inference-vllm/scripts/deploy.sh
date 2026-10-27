#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Guide 002: CPU Inference with vLLM
# =============================================================================
# Deploys vLLM (CPU backend) on a t3.xlarge Karpenter node.
# Model: meta-llama/Llama-3.2-3B-Instruct
#
# Cost:  ~$0.40/hr while running ($0.23 cluster + $0.17 t3.xlarge)
# Time:  ~15 min  (~8 min first run: model download; ~2 min from cache)
#
# Prerequisite: Guide 001 cluster running + kubectl configured
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_FILE="$SCRIPT_DIR/../k8s/vllm-cpu.yaml"

AWS_PROFILE="${AWS_PROFILE:-anvesh-aws-profile}"
CLUSTER_NAME="${CLUSTER_NAME:-llms-on-eks}"
NAMESPACE="llm-serving"
HF_TOKEN="${HF_TOKEN:-}"

cat << 'EOF'

╔══════════════════════════════════════════════════════════════╗
║   LLMs on EKS — Guide 002: CPU Inference with vLLM         ║
╠══════════════════════════════════════════════════════════════╣
║  Model:   meta-llama/Llama-3.2-3B-Instruct                  ║
║  Node:    t3.xlarge  (Karpenter cpu NodePool)               ║
║  API:     OpenAI-compatible  port 8000                      ║
║  Cost:    ~$0.40/hr while running                           ║
╚══════════════════════════════════════════════════════════════╝

EOF

# Pre-flight: cluster reachable?
if ! kubectl cluster-info &>/dev/null 2>&1; then
  echo "❌  kubectl cannot reach the cluster."
  echo "    Run: aws eks update-kubeconfig --name $CLUSTER_NAME --profile $AWS_PROFILE --region us-east-1"
  exit 1
fi
echo "✅  Cluster reachable: $(kubectl config current-context)"

# ── Step 1: Namespace + HuggingFace token ─────────────────────────────────────
echo ""
echo "[ 1/4 ] Setting up namespace and HuggingFace token..."

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

if kubectl get secret hf-token -n "$NAMESPACE" &>/dev/null; then
  echo "  ✅  Secret hf-token already exists — skipping"
else
  if [[ -z "$HF_TOKEN" ]]; then
    echo ""
    echo "  Llama 3.2 3B is a gated model — a HuggingFace token is required."
    echo "  Get yours: https://huggingface.co/settings/tokens"
    echo "  Request access: https://huggingface.co/meta-llama/Llama-3.2-3B-Instruct"
    echo ""
    read -rsp "  Enter HF_TOKEN (input hidden): " HF_TOKEN
    echo ""
  fi
  kubectl create secret generic hf-token \
    -n "$NAMESPACE" \
    --from-literal=token="$HF_TOKEN"
  echo "  ✅  Secret hf-token created"
fi

# ── Step 2: Apply manifests ────────────────────────────────────────────────────
echo ""
echo "[ 2/4 ] Applying vllm-cpu.yaml..."
# The manifest does NOT contain the hf-token Secret (removed to prevent overwrite).
# The real secret was already created in step 1.
kubectl apply -f "$K8S_FILE"

echo ""
echo "  Karpenter will now provision a t3.xlarge (~2 min)."
echo "  vLLM will then download the model (~8 min first run)."
echo "  Watch: kubectl logs -n $NAMESPACE -l app=vllm-cpu -f"

# ── Step 3: Wait for pod ready ─────────────────────────────────────────────────
echo ""
echo "[ 3/4 ] Waiting for vLLM to be Ready (timeout: 15 min)..."

kubectl wait pod \
  -n "$NAMESPACE" \
  -l app=vllm-cpu \
  --for condition=Ready \
  --timeout=900s

echo ""
echo "  ✅  vLLM pod is Ready"

# ── Step 4: Smoke test ─────────────────────────────────────────────────────────
echo ""
echo "[ 4/4 ] Running smoke test..."

kubectl port-forward -n "$NAMESPACE" svc/vllm-cpu 8000:8000 &
PF_PID=$!
trap "kill $PF_PID 2>/dev/null || true" EXIT
sleep 4

echo "  Sending test prompt..."
if RESP=$(curl -sf http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"llama-3.2-3b","messages":[{"role":"user","content":"What is Amazon EKS in one sentence?"}],"max_tokens":60}' 2>&1); then
  TEXT=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'].strip())" 2>/dev/null)
  echo "  ✅  Response: $TEXT"
else
  echo "  ⚠️   Smoke test failed: $RESP"
fi

kill $PF_PID 2>/dev/null || true

cat << 'EOF'

╔══════════════════════════════════════════════════════════════╗
║   ✅  Guide 002 deployed!                                   ║
╠══════════════════════════════════════════════════════════════╣
║                                                              ║
║  Test it:                                                    ║
║    bash guides/002-cpu-inference-vllm/scripts/test.sh       ║
║                                                              ║
║  Or manually:                                                ║
║    kubectl port-forward -n llm-serving svc/vllm-cpu 8000:8000 & ║
║    curl http://localhost:8000/v1/chat/completions \          ║
║      -H 'Content-Type: application/json' \                  ║
║      -d '{"model":"llama-3.2-3b","messages":[               ║
║           {"role":"user","content":"Hello!"}]}'              ║
║                                                              ║
║  Next:  Guide 003 — GPU Inference (100x faster)             ║
╚══════════════════════════════════════════════════════════════╝
EOF
