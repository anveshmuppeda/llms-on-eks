# Guide 002 — CPU Inference with vLLM

## What You Learn

- How vLLM's CPU backend works (same tool, same image, same API as GPU guides)
- How Karpenter provisions a node on demand when a workload requests one
- How the OpenAI-compatible API works — same request format as GPT-4
- How EBS PVCs cache model weights so restarts are fast (no re-download)
- Why CPU inference is dramatically slower than GPU, and how to measure it
- How to debug real EKS issues: DNS on Karpenter nodes, shared memory limits, RAM sizing

---

## Overview

This guide runs `meta-llama/Llama-3.2-1B-Instruct` on a Karpenter-provisioned `t3.2xlarge`
using vLLM's CPU backend. No GPU required.

**Why vLLM on CPU instead of Ollama?**
Same image and API format as Guide 003 (GPU). Switching from CPU to GPU in the next guide
is a 5-line manifest change — no new tool to learn, no rewrite.

| Attribute | Value |
|-----------|-------|
| Model | `meta-llama/Llama-3.2-1B-Instruct` |
| Image | `vllm/vllm-openai-cpu:v0.32.0` |
| Instance | `t3.2xlarge` (8 vCPU, 32GB RAM) — Karpenter `cpu` NodePool |
| API | OpenAI-compatible, port 8000 |
| Time to deploy | ~15 min (first run: ~12 min startup; subsequent restarts: ~5 min from cache) |
| AWS cost | ~$0.56/hr while running |
| GPU required | No |
| Prerequisite | [Guide 001](../001-prerequisites/README.md) deployed and verified |

> **Note on model choice**: Llama 3.2 3B requires 13.7GB RAM just for weights, leaving no
> room for KV cache on a 16GB t3.xlarge. The 1B model uses 6.6GB, fits comfortably on t3.2xlarge
> (32GB), and is appropriate for learning the stack. See the [GPU guide](../003-gpu-inference-vllm/README.md)
> for production-scale models (Llama 3.1 8B, etc.).

---

## Architecture

```
Your laptop
    |  kubectl port-forward 8000:8000
    v
Service: vllm-cpu  (ClusterIP, port 8000, namespace: llm-serving)
    |
    v
Pod: vllm-cpu  (t3.2xlarge, Karpenter cpu NodePool)
    |   Image: vllm/vllm-openai-cpu:v0.32.0
    |   Model: meta-llama/Llama-3.2-1B-Instruct
    |   Backend: CPU (BF16, AVX-512)
    |   KV cache: 131,072 tokens (4GB RAM)
    |   Max concurrent: 64 requests (at 2048 tokens each)
    |
    +-- PVC: vllm-model-cache (EBS gp3, 30Gi)
            Weights cached at /model-cache
            Download once (~30s), reused on restart
```

---

## Step 1 — Deploy

```bash
cd /path/to/llms-on-eks
export AWS_PROFILE=anvesh-aws-profile
export AWS_REGION=us-east-1

bash guides/002-cpu-inference-vllm/scripts/deploy.sh
```

The script does 4 things:

| Step | Action | Time |
|------|--------|------|
| 1 | Create `llm-serving` namespace + `hf-token` Secret | <1 min |
| 2 | `kubectl apply` — StorageClass, PVC, Deployment, Service | <1 min |
| 3 | Karpenter provisions `t3.2xlarge` node | ~2 min |
| 4 | vLLM downloads model (first run: ~30s / cached: instant), compiles, starts | ~10 min first run |

Watch what's happening live in another terminal:

```bash
# Watch Karpenter provision the node
kubectl get nodes -L node-type -w

# Watch vLLM startup (model download, compile, serve)
kubectl logs -n llm-serving -l app=vllm-cpu -f
```

---

## Startup Log Walkthrough

Here is what the actual startup looks like — measured from the real deployment:

```
01:08:05  vLLM 0.32.0 starting
01:08:22  Resolved architecture: LlamaForCausalLM
01:08:37  OpenMP threads: cores [4,5,6], reserved: [7]
01:08:51  Distributed init: world_size=1, backend=gloo
01:08:52  Initializing model took 0.33s

          Downloading weights (first run only):
01:08:52 → 01:09:22  Download: 2.30 GiB in 30.5s

          Loading weights into memory:
01:09:22 → 01:09:23  Load safetensors: 0.67s
01:09:26  Model loaded: 6.56 GiB memory used, total 34.9s

          AOT compilation (torch.compile — runs once per node):
01:09:26 → 01:10:31  Warming up for compilation...
01:10:31  Saved AOT compiled function to cache
01:11:27  Initial profiling/warmup: 55.6s

          KV cache allocation:
01:11:31  KV cache: 4.0 GiB → 131,072 tokens
01:11:31  Max concurrency: 64 simultaneous requests (at 2048 tokens)
01:11:32  Engine init complete: 126.2s total

01:11:36  Routes registered (/v1/chat/completions, /v1/completions, ...)
01:11:36  Started server process [1]
01:11:36  Application startup complete.  ← READY
```

**Total cold-start time: ~3.5 minutes** (after node joins the cluster).
Subsequent restarts reuse the EBS cache — model loads in ~35 seconds, compile ~60s.

---

## Step 2 — Test

### Option A: Built-in test script

```bash
bash guides/002-cpu-inference-vllm/scripts/test.sh
```

### Option B: Manual curl

```bash
# Terminal 1 — keep running
kubectl port-forward -n llm-serving svc/vllm-cpu 8000:8000

# Terminal 2 — send requests
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama-3.2-1b",
    "messages": [{"role": "user", "content": "What is Amazon EKS?"}],
    "max_tokens": 150
  }'
```

### Option C: Python (OpenAI SDK)

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:8000/v1",
    api_key="none",  # vLLM does not require a key
)

response = client.chat.completions.create(
    model="llama-3.2-1b",
    messages=[{"role": "user", "content": "Explain Karpenter in one paragraph."}],
    max_tokens=200,
)

print(response.choices[0].message.content)
print(f"Tokens: {response.usage.prompt_tokens} in + {response.usage.completion_tokens} out")
```

### Other endpoints

```bash
# List available models
curl http://localhost:8000/v1/models

# Health check
curl http://localhost:8000/health

# Prometheus metrics
curl http://localhost:8000/metrics | grep vllm
```

---

## Actual Test Results

All results measured on **t3.2xlarge (8 vCPU, 32GB RAM)** running
**Llama 3.2 1B Instruct (BF16)** via `vllm/vllm-openai-cpu:v0.32.0`.

### Benchmark table

| Test | Prompt tokens | Output tokens | Latency | Throughput |
|------|:---:|:---:|---:|---:|
| Short factual | 44 | 41 | 6,945ms | 5.9 tok/s |
| Medium explanation | 55 | 113 | 15,482ms | 7.3 tok/s |
| Code generation | 47 | 150 | 20,172ms | 7.4 tok/s |
| Long generation | 55 | 200 | 26,768ms | 7.5 tok/s |
| Warm request | 49 | 100 | 14,423ms | 6.9 tok/s |

**Average throughput: ~6.8 tok/s** on a t3.2xlarge CPU node.

### Actual responses

**Test 1 — Short factual** (6.9s, 5.9 tok/s)
```
Prompt:   "What is Amazon EKS in one sentence?"
Response: "Amazon Elastic Container Service for Kubernetes (EKS) is a fully managed
           Kubernetes service offered by Amazon Web Services (AWS) that allows users
           to easily deploy and manage Kubernetes clusters on AWS."
```

**Test 2 — Medium explanation** (15.5s, 7.3 tok/s)
```
Prompt:   "Explain the difference between CPU and GPU inference for LLMs in 2-3 sentences."
Response: "CPU (Central Processing Unit) and GPU (Graphics Processing Unit) are two distinct
           components in a computer system, with CPU primarily handling general-purpose
           computing tasks and GPU focusing on graphics rendering and parallel processing..."
```

**Test 3 — Code generation** (20.2s, 7.4 tok/s)
```
Prompt:   "Write a Python function to check if a number is prime."
Response: (complete working Python function with docstring and helper function)
```

**Test 4 — Long generation** (26.8s, 7.5 tok/s)
```
Prompt:   "Explain how Karpenter works in Amazon EKS. Cover node provisioning and NodePools."
Response: "Karpenter is a Kubernetes cluster management tool that enables you to manage
           your Kubernetes cluster from a high-level perspective. In Amazon EKS, Karpenter
           works by provisioning nodes dynamically based on pending pod requirements..."
```

### CPU vs GPU comparison

| Metric | CPU (Guide 002) | GPU (Guide 003) | Difference |
|--------|:---:|:---:|:---:|
| Instance | t3.2xlarge | g5.xlarge | — |
| Model | Llama 3.2 1B | Llama 3.1 8B | 8× larger |
| Throughput | ~7 tok/s | ~1,500 tok/s | **~200× faster** |
| First token (TTFT) | ~2–3s | ~80ms | **~30× faster** |
| Max context | 2,048 tokens | 8,192 tokens | 4× longer |
| Cost/hr | $0.56 | $1.24 | 2.2× more |

The purpose of this guide is to **validate the full stack cheaply** before enabling GPU.
Same vLLM image, same API, same Python code — only the Kubernetes manifest changes.

---

## CPU vs GPU — The Only Diff in the Manifest

```diff
  # Image
- image: vllm/vllm-openai-cpu:v0.32.0
+ image: vllm/vllm-openai:latest

  # Model (upgrade to larger 8B since GPU has 24GB VRAM)
- "meta-llama/Llama-3.2-1B-Instruct"
+ "meta-llama/Llama-3.1-8B-Instruct"

  # Remove dtype flag (GPU image handles this automatically)
- "--dtype"
- "bfloat16"

  # Add GPU-specific flags
+ "--tensor-parallel-size"
+ "1"
+ "--gpu-memory-utilization"
+ "0.90"
+ "--max-model-len"
+ "8192"

  # Served model name
- "llama-3.2-1b"
+ "llama-3.1-8b"

  # Node selector
- node-type: cpu
+ node-type: gpu

  # Tolerations (GPU nodes have a taint — CPU nodes do not)
+ tolerations:
+   - key: nvidia.com/gpu
+     value: "true"
+     effect: NoSchedule

  # Resources
- limits.cpu: "4"
- limits.memory: "16Gi"
+ limits.nvidia.com/gpu: "1"
```

---

## vLLM CPU Flags Explained

| Flag / Env var | Value | Why |
|---|---|---|
| `--dtype bfloat16` | `bfloat16` | BF16 on x86 with AVX-512 — 2× faster than FP32 |
| `--max-model-len 2048` | `2048` | Max context window; reduce to save RAM |
| `--max-num-seqs 4` | `4` | Max concurrent requests on CPU |
| `--served-model-name` | `llama-3.2-1b` | Name clients use in API requests |
| `VLLM_CPU_KVCACHE_SPACE` | `4` | GB of RAM reserved for KV cache (request+response buffers) |
| `OMP_NUM_THREADS` | `4` | OpenMP threads for CPU math ops |

---

## Startup Phases Explained

| Phase | What happens | Time (1B model) |
|-------|-------------|-----------------|
| Container pull | Docker image download (1.2GB) | ~60s first time, 0s cached |
| Model download | Weights from HuggingFace to EBS PVC | ~30s first time, 0s cached |
| Weight loading | Weights read from disk into RAM | ~35s |
| AOT compilation | torch.compile builds optimised CPU kernels | ~60s |
| KV cache setup | Allocate RAM for request/response buffers | ~3s |
| **Ready** | `/health` returns 200, readiness probe passes | — |

Total cold start (node already up): **~3.5 minutes**
Subsequent restarts (model cached on EBS): **~2 minutes**

---

## Issues Encountered and Fixed

These were real issues hit during deployment — documented here so you don't hit them:

| Issue | Symptom | Fix |
|-------|---------|-----|
| Wrong vLLM image | `RuntimeError: Failed to infer device type` | Use `vllm/vllm-openai-cpu` not `vllm/vllm-openai` |
| Ambiguous `--device` flag | `error: ambiguous option: --device` | CPU image defaults to CPU — remove the flag entirely |
| `/dev/shm` too small | `RuntimeError: Insufficient space in /dev/shm` (needs 160MB, got 64MB) | Add `emptyDir: medium: Memory` volume at `/dev/shm` |
| DNS failure on Karpenter nodes | `Temporary failure in name resolution` | EC2NodeClass must include the EKS cluster SG (`aws:eks:cluster-name` tag) |
| Out of memory for KV cache | `Available memory (0.46 GiB) less than requested KV (8 GiB)` | Reduce `VLLM_CPU_KVCACHE_SPACE` and use larger instance (t3.2xlarge) |

---

## Cost Estimate

| Resource | Details | $/hr | $/day (8hr) |
|----------|---------|------|-------------|
| EKS cluster baseline | From Guide 001 | $0.23 | $1.84 |
| t3.2xlarge (Karpenter cpu pool) | 8 vCPU, 32GB, on-demand | $0.33 | $2.64 |
| EBS 30Gi gp3 (model cache) | Persists weights across restarts | $0.004 | $0.03 |
| **Total while vLLM running** | | **$0.56** | **$4.51** |
| After `kubectl delete -f k8s/vllm-cpu.yaml` | Only cluster baseline | $0.23 | $1.84 |

Karpenter terminates the t3.2xlarge within ~10 minutes of deleting the pod.

> **Cost tip**: The EBS PVC persists after pod deletion (by design — preserves model cache).
> Delete it manually if you want to save $0.003/hr:
> `kubectl delete pvc vllm-model-cache -n llm-serving`

---

## Cleanup

Keep the cluster running for Guide 003, just remove this workload:

```bash
kubectl delete -f guides/002-cpu-inference-vllm/k8s/vllm-cpu.yaml
```

Karpenter will terminate the t3.2xlarge in ~10 minutes.
The EBS PVC is deleted with the namespace resources — model re-downloads on next deploy.

---

## Key Observations

1. **Same API as GPT-4** — the `/v1/chat/completions` endpoint is identical to OpenAI's. Any
   code that works with OpenAI works here with `base_url` changed to `http://localhost:8000/v1`.

2. **AOT compilation is one-time** — torch.compile runs once on a fresh node and caches to
   `/root/.cache/vllm/`. Second startup on the same node skips compilation entirely.

3. **Throughput scales with output length** — the 200-token test shows 7.5 tok/s while the
   41-token test shows 5.9 tok/s. vLLM batches tokens internally, so longer sequences
   amortise the per-request overhead.

4. **TTFT (time to first token) is ~2–3 seconds** — this is the prefill phase where the model
   processes your input. The GPU version does this in ~80ms.

5. **Karpenter did its job** — the node appeared automatically when the pod was scheduled
   (no manual instance launch), and will disappear automatically when the pod is deleted.

---

## Next Steps

- [Guide 003 — GPU Inference with vLLM](../003-gpu-inference-vllm/README.md) — same API, 200× faster
