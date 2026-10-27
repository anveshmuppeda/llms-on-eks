# LLMs on EKS

**Hands-on guide series for running open-source Large Language Models on Amazon EKS.**

Each guide is a self-contained directory with working infrastructure code, Kubernetes manifests,
shell scripts, real benchmark results, and a detailed README. Provision the shared EKS cluster
once in Guide 001 — every subsequent guide deploys a new workload on top of it.

![Guides Released](https://img.shields.io/badge/guides_released-2-brightgreen)
![EKS](https://img.shields.io/badge/Amazon_EKS-1.32-FF9900?logo=amazon-aws&logoColor=white)
![Karpenter](https://img.shields.io/badge/Karpenter-v1.15.1-326CE5?logo=kubernetes&logoColor=white)
![vLLM](https://img.shields.io/badge/vLLM-0.32.0-7B2FBE)
![License](https://img.shields.io/badge/license-Apache_2.0-blue)

---

## Quick Start

```bash
git clone https://github.com/anveshmuppeda/llms-on-eks
cd llms-on-eks

export AWS_PROFILE=your-aws-profile
export AWS_REGION=us-east-1

# Step 1: Deploy the shared EKS cluster (once, ~25 min)
bash guides/001-prerequisites/scripts/deploy.sh
bash guides/001-prerequisites/scripts/verify.sh

# Step 2: Run Llama 3.2 1B on CPU — no GPU, no quota needed
bash guides/002-cpu-inference-vllm/scripts/deploy.sh

# Step 3: Test it
kubectl port-forward -n llm-serving svc/vllm-cpu 8000:8000 &
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"llama-3.2-1b","messages":[{"role":"user","content":"What is Karpenter?"}],"max_tokens":150}'
```

---

## Available Guides

| # | Guide | What you learn | GPU | Cost/hr | Time |
|---|-------|---------------|:---:|---------|------|
| [001](guides/001-prerequisites/README.md) | Prerequisites & Cluster Setup | EKS 1.32, Karpenter v1.15.1, NodePools, CloudFormation | ❌ | ~$0.23 | ~25 min |
| [002](guides/002-cpu-inference-vllm/README.md) | CPU Inference with vLLM | vLLM CPU backend, OpenAI API, EBS model cache, benchmarks | ❌ | ~$0.56 | ~15 min |
| [003](guides/003-gpu-inference-vllm/README.md) | GPU Inference with vLLM | NVIDIA A10G, GPU scheduling, 200× throughput vs CPU | ✅ | ~$1.24 | ~15 min |

---

## Coming Soon

| # | Guide | What you'll build |
|---|-------|------------------|
| 004 | Model Storage on EFS | Shared ReadWriteMany PVC — one download, N vLLM pods |
| 005 | LiteLLM Gateway | Unified OpenAI endpoint, API keys, multi-model routing |
| 006 | KEDA Autoscaling | Scale inference pods on request queue depth, scale-to-zero |
| 007 | NVIDIA GPU Operator | GPU driver install, device plugin, DCGM metrics |
| 008 | Observability | Prometheus + Grafana dashboards for TTFT, throughput, GPU util |
| 009 | Load Testing | genai-perf benchmarks, Locust scenarios, spike test autoscaler |
| 010 | SGLang Inference | SGLang vs vLLM comparison, structured output, higher throughput |
| 011 | Multi-Node 70B | EFA networking, tensor parallelism, Llama 3.1 70B |
| 012 | NVIDIA NIM | NGC model catalog, enterprise-grade serving |

---

## How the Shared Cluster Works

One EKS cluster, provisioned once in Guide 001. All guides reuse it.

```
EKS: llms-on-eks  (EKS 1.32, CloudFormation-managed)
│
├── System Managed Node Group
│     2x t3.medium, always-on ($0.04/hr)
│     Hosts: CoreDNS, aws-node, Karpenter controller
│
└── Karpenter NodePools  (zero nodes when idle — $0 cost)
      ┌─────────────┬──────────────────────────────────────────┐
      │ NodePool    │ Instances           │ Used by             │
      ├─────────────┼──────────────────────────────────────────┤
      │ cpu         │ t3.xlarge/2xlarge   │ Guide 002 CPU infer │
      │ gpu         │ g5.xlarge/12xlarge  │ Guide 003+ GPU infer│
      │ gpu-spot    │ g5/g4dn spot        │ Guide 009 load test │
      │ system      │ t3.medium/large     │ monitoring, gateway │
      └─────────────┴──────────────────────────────────────────┘
```

GPU nodes are terminated within ~5 minutes of deleting a workload.
You only pay for compute while an LLM is actually running.

---

## Real Benchmark Results (Guide 002)

Measured on **t3.2xlarge (8 vCPU, 32GB RAM)** with **Llama 3.2 1B Instruct (CPU, BF16)**:

| Request type | Output tokens | Latency | Throughput |
|-------------|:---:|---:|---:|
| Short factual | 41 | 6,945ms | 5.9 tok/s |
| Medium explanation | 113 | 15,482ms | 7.3 tok/s |
| Code generation | 150 | 20,172ms | 7.4 tok/s |
| Long generation | 200 | 26,768ms | 7.5 tok/s |

Guide 003 (GPU, g5.xlarge, A10G 24GB): **~1,500 tok/s, ~80ms TTFT** — ~200× faster.

---

## Technology Stack

| Layer | Technology | Version |
|-------|-----------|---------|
| Kubernetes | Amazon EKS | 1.32 |
| Node autoscaling | Karpenter | v1.15.1 |
| GPU management | NVIDIA GPU Operator | 24.x |
| Primary inference | vLLM | 0.32.0 |
| Advanced inference | SGLang | — |
| API gateway | LiteLLM | — |
| Autoscaling | KEDA | — |
| Observability | Prometheus + Grafana + DCGM | — |
| Model storage | Amazon EFS | — |
| Load testing | genai-perf, Locust | — |
| Infrastructure | AWS CloudFormation | — |

---

## Cost at a Glance

| Scenario | $/hr | $/day (active 8hr) |
|----------|------|-------------------|
| Cluster idle (no workloads) | $0.23 | $1.84 |
| + Guide 002 CPU inference running | $0.56 | $4.51 |
| + Guide 003 GPU inference running | $1.24 | $9.92 |
| After deleting all workloads | $0.23 | $1.84 |

> **Scale to zero**: Karpenter terminates idle nodes automatically.
> The $0.23/hr baseline covers only the EKS control plane, 2x t3.medium system nodes, and NAT Gateway.

---

## Repository Structure

```
llms-on-eks/
├── README.md                         ← you are here
├── .gitignore
├── LICENSE
│
├── guides/                           ← one self-contained guide per directory
│   ├── 001-prerequisites/
│   │   ├── cloudformation/           ← eks-karpenter.yaml (VPC + EKS + IAM)
│   │   ├── k8s/                      ← karpenter-nodepool.yaml
│   │   └── scripts/                  ← deploy.sh / verify.sh / destroy.sh
│   ├── 002-cpu-inference-vllm/
│   │   ├── k8s/                      ← vllm-cpu.yaml
│   │   └── scripts/                  ← deploy.sh / test.sh
```

---

## Author

**Anvesh Muppeda** — AWS · Kubernetes · GenAI Infrastructure

[![GitHub](https://img.shields.io/badge/GitHub-anveshmuppeda-181717?logo=github)](https://github.com/anveshmuppeda)

---

## License

[Apache 2.0](LICENSE)
