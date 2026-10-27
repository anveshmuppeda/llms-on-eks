#!/usr/bin/env bash
# =============================================================================
# verify.sh — Guide 001: Prerequisites & Cluster Setup
# =============================================================================
# Checks 4 things:
#   1. Required local tools (aws, kubectl, helm, docker, jq, python3)
#   2. AWS access and GPU quota
#   3. CloudFormation stack status
#   4. EKS cluster health (nodes, add-ons, Karpenter, NodePools)
#
# Safe to run at any time. Exit code = number of failures.
# =============================================================================

set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-anvesh-aws-profile}"
AWS_REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-llms-on-eks}"
CFT_STACK="${CFT_STACK:-llms-on-eks-stack}"

export AWS_PROFILE AWS_REGION

PASS="✅"; FAIL="❌"; WARN="⚠️ "
errors=0

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   LLMs on EKS — Guide 001: Verification                    ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# ── Section 1: Local Tools ────────────────────────────────────────────────────
echo ""
echo "[ 1/4 ] Local Tools"
check_tool() {
  local name="$1"
  local version_cmd="$2"
  if command -v "$name" &>/dev/null; then
    local ver
    ver=$(eval "$version_cmd" 2>&1 | head -1)
    echo "  $PASS  $name: $ver"
  else
    echo "  $FAIL  $name: not found"
    errors=$((errors+1))
  fi
}

check_tool "aws"     "aws --version"
check_tool "kubectl" "kubectl version --client --short 2>/dev/null || kubectl version --client 2>&1"
check_tool "helm"    "helm version --short 2>/dev/null || helm version 2>&1"
check_tool "docker"  "docker --version"
check_tool "jq"      "jq --version"
check_tool "python3" "python3 --version"

# ── Section 2: AWS Access ─────────────────────────────────────────────────────
echo ""
echo "[ 2/4 ] AWS Access"
if CALLER=$(aws sts get-caller-identity --output json 2>&1); then
  ARN=$(echo "$CALLER"     | python3 -c "import sys,json; print(json.load(sys.stdin)['Arn'])")
  ACCT=$(echo "$CALLER"    | python3 -c "import sys,json; print(json.load(sys.stdin)['Account'])")
  echo "  $PASS  $ARN"
  echo "  $PASS  Account: $ACCT | Region: $AWS_REGION"
else
  echo "  $FAIL  AWS access failed — run: aws configure --profile $AWS_PROFILE"
  errors=$((errors+1))
fi

# GPU quota check
echo ""
echo "  GPU quota (G/VT on-demand vCPUs, quota code L-417A185B):"
if QUOTA=$(aws service-quotas get-service-quota \
    --service-code ec2 --quota-code L-417A185B \
    --query 'Quota.Value' --output text 2>/dev/null); then
  if awk "BEGIN{exit !($QUOTA > 0)}"; then
    echo "  $PASS  Current quota: $QUOTA vCPUs  (ready for GPU guides)"
  else
    echo "  $WARN  Current quota: $QUOTA vCPUs  — request increase for Guide 003+"
    echo "         Console → Service Quotas → EC2 → Running On-Demand G and VT instances"
    echo "         Request at least 8 vCPUs (1x g5.xlarge = 4 vCPUs)"
  fi
else
  echo "  $WARN  Could not check GPU quota"
fi

# ── Section 3: CloudFormation Stack ───────────────────────────────────────────
echo ""
echo "[ 3/4 ] CloudFormation Stack"
if STATUS=$(aws cloudformation describe-stacks \
    --stack-name "$CFT_STACK" \
    --query "Stacks[0].StackStatus" \
    --output text 2>/dev/null); then
  if [[ "$STATUS" == "CREATE_COMPLETE" || "$STATUS" == "UPDATE_COMPLETE" ]]; then
    echo "  $PASS  $CFT_STACK: $STATUS"
  else
    echo "  $WARN  $CFT_STACK: $STATUS"
  fi
else
  echo "  $WARN  Stack not found — run: bash scripts/deploy.sh"
fi

# ── Section 4: Cluster Health ─────────────────────────────────────────────────
echo ""
echo "[ 4/4 ] Cluster Health"

if ! kubectl cluster-info &>/dev/null 2>&1; then
  echo "  $WARN  kubectl cannot reach cluster — run:"
  echo "         aws eks update-kubeconfig --name $CLUSTER_NAME --profile $AWS_PROFILE --region $AWS_REGION"
  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  if [[ $errors -eq 0 ]]; then
    echo "║   $PASS  Tools OK but cluster not reachable yet.           ║"
  else
    echo "║   $FAIL  $errors error(s) — fix above before proceeding.     ║"
  fi
  echo "╚══════════════════════════════════════════════════════════════╝"
  exit $errors
fi

# Nodes
TOTAL=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready" || echo 0)
echo "  $PASS  Nodes: $READY/$TOTAL Ready"
echo ""
kubectl get nodes -L node-type,karpenter.sh/nodepool 2>/dev/null | sed 's/^/  /'

# Core pods
echo ""
echo "  Core pods:"
# Map: "display-name:grep-pattern"
for pair in "coredns:coredns" "karpenter:karpenter" "aws-node:aws-node"; do
  DISPLAY="${pair%%:*}"; PATTERN="${pair##*:}"
  # Use printf to count — avoids wc -l newline artifacts and grep -c exit-1 issue
  RUNNING=0
  while IFS= read -r line; do
    echo "$line" | grep -q "Running" && RUNNING=$((RUNNING + 1))
  done < <(kubectl get pods -n kube-system --no-headers 2>/dev/null | grep "$PATTERN")
  if [[ $RUNNING -gt 0 ]]; then
    echo "  $PASS  kube-system/$DISPLAY: $RUNNING running"
  else
    echo "  $WARN  kube-system/$DISPLAY: not confirmed running (may still be starting)"
  fi
done

# Add-ons
echo ""
echo "  EKS Add-ons:"
ADDONS=$(aws eks list-addons --cluster-name "$CLUSTER_NAME" \
  --query "addons[]" --output text 2>/dev/null | tr '\t' '\n')
for addon in vpc-cni coredns kube-proxy aws-ebs-csi-driver aws-efs-csi-driver eks-pod-identity-agent; do
  if echo "$ADDONS" | grep -qx "$addon"; then
    echo "  $PASS  $addon"
  else
    echo "  $WARN  $addon — not found"
  fi
done

# NodePools
echo ""
echo "  Karpenter NodePools:"
if kubectl get nodepools --no-headers 2>/dev/null | grep -q .; then
  kubectl get nodepools 2>/dev/null | sed 's/^/  /'
else
  echo "  $WARN  No NodePools — run: kubectl apply -f k8s/karpenter-nodepool.yaml"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
if [[ $errors -eq 0 ]]; then
  echo "║  $PASS  All checks passed — ready for Guide 002 and 003!  ║"
else
  echo "║  $FAIL  $errors error(s) — fix above before running guides.  ║"
fi
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

exit $errors
