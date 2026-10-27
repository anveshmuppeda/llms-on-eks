# Guide 001 — Prerequisites & Cluster Setup

## What You Learn

- How Amazon EKS cluster networking is structured (VPC, public/private subnets, NAT Gateway)
- What Karpenter is and why it replaces Cluster Autoscaler for GPU workloads
- How EKS OIDC + IRSA grants pods permission to call AWS services (EBS CSI, Karpenter)
- How Karpenter NodePools and EC2NodeClasses define what nodes get provisioned
- How EKS Access Entries replace aws-auth ConfigMap editing

## Overview

This is the **single setup guide** for the entire series. Run it once.
It provisions a shared EKS cluster that every subsequent guide deploys workloads onto.

**Time**: ~25 minutes (CloudFormation takes ~20 min)  
**AWS cost**: ~$0.23/hr ongoing while cluster is running  
**GPU required**: ❌ No

> ⚠️ **Learning guide** — IAM policies and security groups are intentionally broad
> so nothing blocks you while exploring. Tighten for production.

---

## What Gets Created

### Local tools (installed by you before running deploy.sh)

| Tool | Purpose | Install |
|------|---------|---------|
| AWS CLI v2 | AWS API calls | `brew install awscli` |
| kubectl | Kubernetes cluster management | `brew install kubectl` |
| Helm 3 | Install Karpenter | `brew install helm` |
| Docker | Local container testing | Docker Desktop |
| jq | JSON parsing in scripts | `brew install jq` |
| Python 3.11+ | Script utilities | `brew install python@3.11` |

### AWS infrastructure (CloudFormation)

| Resource | Details | Cost |
|----------|---------|------|
| VPC | 10.20.0.0/16, 2 AZs | — |
| Public subnets (×2) | 10.20.1.0/24, 10.20.2.0/24 — ALB lives here | — |
| Private subnets (×2) | 10.20.10.0/24, 10.20.11.0/24 — nodes live here | — |
| NAT Gateway | One, in public subnet 1 | $0.045/hr + data |
| Internet Gateway | Attached to VPC | — |
| Route tables | Public (→ IGW) and private (→ NAT) | — |
| NACLs | Allow-all public + private | — |
| Security groups | Control plane SG + node SG (all VPC traffic allowed) | — |
| EKS cluster | v1.32, public+private endpoint, all logging enabled | $0.10/hr |
| OIDC provider | Enables IRSA for Karpenter + EBS CSI | — |
| System node group | 2× t3.medium, AL2023, private subnets, no taint | $0.04/hr |
| EKS add-ons | vpc-cni, coredns, kube-proxy, ebs-csi, efs-csi, pod-identity | — |
| `KarpenterNodeRole` | IAM role for Karpenter-provisioned EC2 instances | — |
| `KarpenterControllerPolicy` | IAM policy for Karpenter controller pod | — |
| `KarpenterControllerRole` | IRSA role → `kube-system/karpenter` service account | — |
| EKS Access Entry | Registers Karpenter node role as EC2_LINUX identity | — |
| SQS queue | Interruption queue, 300s TTL, long-polling | negligible |
| EventBridge rules | spot interrupt, rebalance, health, state-change → SQS | — |

### Kubernetes (Helm + kubectl)

| Resource | Details |
|----------|---------|
| Karpenter | v1.15.1, `kube-system` namespace |
| NodePool `system` | t3.medium/large — Prometheus, Grafana, LiteLLM |
| NodePool `cpu` | t3.xlarge/2xlarge, m6i — CPU inference (Guide 002) |
| NodePool `gpu` | g5/g4dn on-demand — GPU inference (Guide 003+) |
| NodePool `gpu-spot` | g5/g4dn spot — load testing (Guide 009+) |

---

## Architecture

```
                    ┌──────────────────────────────────────────────────┐
Internet ── IGW ────┤  VPC: 10.20.0.0/16                              │
                    │                                                  │
                    │  Public  10.20.1  ←── ALB (Guide 005+)          │
                    │  Public  10.20.2  ←── ALB                       │
                    │       │                                          │
                    │     NAT GW                                       │
                    │       │                                          │
                    │  Private 10.20.10 ←── EKS nodes                 │
                    │  Private 10.20.11 ←── EKS nodes                 │
                    └──────────────────────────────────────────────────┘

EKS: llms-on-eks  (EKS 1.32)
  │
  ├── System Node Group: 2× t3.medium  (always-on, $0.04/hr)
  │     CoreDNS, aws-node, kube-proxy, Karpenter controller
  │
  └── Karpenter NodePools — zero nodes until a workload requests one
        system    → t3.medium/large  (monitoring, gateway)
        cpu       → t3.xlarge/2xlarge, m6i  (CPU inference, Guide 002)
        gpu       → g5/g4dn on-demand  (GPU inference, Guide 003+)
        gpu-spot  → g5/g4dn spot       (load testing, Guide 009+)
```

---

## Step-by-Step

### 1 — Install local tools

```bash
# macOS
brew install awscli kubectl helm jq python@3.11
# Docker Desktop: https://www.docker.com/products/docker-desktop/
```

### 2 — Configure AWS profile

```bash
aws configure --profile anvesh-aws-profile
# Enter: Access Key ID, Secret Key, Region (us-east-1), Output (json)

# Verify
aws sts get-caller-identity --profile anvesh-aws-profile
```

### 3 — Set environment variables

```bash
export AWS_PROFILE=anvesh-aws-profile
export AWS_REGION=us-east-1
```

### 4 — Deploy everything

```bash
bash guides/001-prerequisites/scripts/deploy.sh
```

### 5 — Verify

```bash
bash guides/001-prerequisites/scripts/verify.sh
```

Expected output:
```
[ 1/4 ] Local Tools
  ✅  aws: aws-cli/2.x.x
  ✅  kubectl: v1.32.x
  ✅  helm: v3.x.x
  ✅  docker: Docker version 24.x
  ✅  jq: jq-1.7
  ✅  python3: Python 3.11.x

[ 2/4 ] AWS Access
  ✅  arn:aws:iam::463470985368:user/anvesh
  ✅  Account: 463470985368 | Region: us-east-1
  ✅  GPU quota: 8 vCPUs

[ 3/4 ] CloudFormation Stack
  ✅  llms-on-eks-stack: CREATE_COMPLETE

[ 4/4 ] Cluster Health
  ✅  Nodes: 2/2 Ready
  ✅  kube-system/kube-dns: 2 running
  ✅  kube-system/karpenter: 1 running
  ✅  vpc-cni / coredns / kube-proxy / aws-ebs-csi-driver
  ✅  aws-efs-csi-driver / eks-pod-identity-agent
  ✅  NodePools: system, cpu, gpu, gpu-spot

  ✅  All checks passed — ready for Guide 002 and 003!
```

---

## GPU Quota

By default, new AWS accounts have **0 GPU vCPUs** (quota L-417A185B). Guide 003+ needs GPUs.

Check now:
```bash
aws service-quotas get-service-quota \
  --service-code ec2 \
  --quota-code   L-417A185B \
  --profile      anvesh-aws-profile
```

Request increase (24–48 hours):
> AWS Console → Service Quotas → EC2 → "Running On-Demand G and VT instances"  
> Request at least **8 vCPUs** (one g5.xlarge = 4 vCPUs)

---

## Key Concepts Explained

### Why Karpenter instead of Cluster Autoscaler?

Cluster Autoscaler scales existing node groups. Karpenter provisions the exact right EC2
instance for each workload — picking the cheapest instance that fits the pod's resource
requests. It also terminates nodes within minutes of them becoming empty (scale to zero).

For GPU workloads this is critical: you don't want a `g5.xlarge` ($1.01/hr) sitting idle
because no LLM is running.

### Why IRSA instead of node IAM roles?

IRSA (IAM Roles for Service Accounts) gives each Kubernetes service account its own AWS
identity, scoped to exactly the permissions it needs. Karpenter's controller pod needs
to create EC2 instances; the EBS CSI pod needs to create volumes. Neither needs the other's
permissions. IRSA enforces this boundary cleanly.

### How the NodePools work

```
vLLM pod requests: nvidia.com/gpu: "1"
                   nodeSelector: node-type: gpu

Karpenter sees the pending pod → finds gpu NodePool → looks at instance requirements
→ picks cheapest available g5.xlarge → provisions it → pod schedules on it

Pod deleted → g5.xlarge sits idle for 5 min → Karpenter terminates it
```

---

## Cost Estimate

| Resource | $/hr | $/day (24h) | $/month |
|----------|------|------------|---------|
| EKS control plane | $0.10 | $2.40 | $72 |
| 2× t3.medium (system NG) | $0.04 | $0.96 | $29 |
| NAT Gateway | $0.045 | $1.08 | $33 |
| EBS (2× 50Gi system nodes) | $0.01 | $0.24 | $7 |
| **Cluster baseline** | **$0.195** | **$4.68** | **$141** |

> This baseline cost is amortised across all guides that use the shared cluster.
> All GPU/CPU inference costs are **zero** when no workloads are running.

---

## Cleanup

When done with all guides:

```bash
bash guides/001-prerequisites/scripts/destroy.sh
```

---

## Next Guides

- [Guide 002 — CPU Inference with vLLM](../002-cpu-inference-vllm/README.md)
- [Guide 003 — GPU Inference with vLLM](../003-gpu-inference-vllm/README.md)
