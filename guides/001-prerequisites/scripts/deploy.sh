#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Guide 001: Prerequisites & Cluster Setup
# =============================================================================
# What this does (5 steps):
#   1. Validates tools and AWS access
#   2. Deploys CloudFormation stack (VPC + EKS + Karpenter IAM, ~20 min)
#   3. Configures kubectl and waits for system nodes
#   4. Installs Karpenter via Helm
#   5. Applies all NodePools (system, cpu, gpu, gpu-spot)
#
# Run once before any other guide. ~25 minutes total.
#
# Cost while running:  ~$0.23/hr  (EKS control plane + 2x t3.medium + NAT GW)
# Cost after destroy:  $0.00
#
# Override defaults via env vars:
#   export AWS_PROFILE=my-profile
#   export CLUSTER_NAME=my-cluster
#   export AWS_REGION=us-west-2
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFT_FILE="$SCRIPT_DIR/../cloudformation/eks-karpenter.yaml"
NP_FILE="$SCRIPT_DIR/../k8s/karpenter-nodepool.yaml"

# ── Configuration ─────────────────────────────────────────────────────────────
AWS_PROFILE="${AWS_PROFILE:-anvesh-aws-profile}"
AWS_REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-llms-on-eks}"
CFT_STACK="${CFT_STACK:-llms-on-eks-stack}"
KARPENTER_VERSION="${KARPENTER_VERSION:-1.15.1}"

export AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"

# ── Banner ─────────────────────────────────────────────────────────────────────
cat << EOF

╔══════════════════════════════════════════════════════════════╗
║   LLMs on EKS — Guide 001: Prerequisites & Cluster Setup    ║
╠══════════════════════════════════════════════════════════════╣
║  Profile:          ${AWS_PROFILE}
║  Region:           ${AWS_REGION}
║  Cluster:          ${CLUSTER_NAME}
║  CFT Stack:        ${CFT_STACK}
║  Karpenter:        v${KARPENTER_VERSION}
╚══════════════════════════════════════════════════════════════╝

EOF

# ── Pre-flight: tools ─────────────────────────────────────────────────────────
echo "[ Pre-flight ] Required tools"

check_tool() {
  local name="$1"
  local version_cmd="$2"
  if command -v "$name" &>/dev/null; then
    local ver
    ver=$(eval "$version_cmd" 2>&1 | head -1)
    echo "  ✅  $name: $ver"
  else
    echo "  ❌  $name not found — install it before running this script"
    exit 1
  fi
}

check_tool "aws"     "aws --version"
check_tool "kubectl" "kubectl version --client --short 2>/dev/null || kubectl version --client 2>&1"
check_tool "helm"    "helm version --short 2>/dev/null || helm version 2>&1"

# ── Pre-flight: AWS identity ───────────────────────────────────────────────────
echo ""
echo "[ Pre-flight ] AWS identity"
if CALLER=$(aws sts get-caller-identity --output json 2>&1); then
  ARN=$(echo "$CALLER" | python3 -c "import sys,json; print(json.load(sys.stdin)['Arn'])")
  ACCOUNT=$(echo "$CALLER" | python3 -c "import sys,json; print(json.load(sys.stdin)['Account'])")
  echo "  ✅  $ARN"
  echo "  ✅  Account: $ACCOUNT | Region: $AWS_REGION"
else
  echo "  ❌  AWS access failed: $CALLER"
  echo "      Run: aws configure --profile $AWS_PROFILE"
  exit 1
fi

# ── Step 1: CloudFormation ────────────────────────────────────────────────────
echo ""
echo "[ 1/5 ] Deploying CloudFormation stack (~20 min)"
echo "        Stack: $CFT_STACK"
echo "        Creates: VPC, EKS 1.32, system node group, OIDC,"
echo "                 Karpenter IAM + SQS + EventBridge rules"
echo ""

aws cloudformation deploy \
  --template-file "$CFT_FILE" \
  --stack-name    "$CFT_STACK" \
  --parameter-overrides \
      EKSClusterName="$CLUSTER_NAME" \
      ProjectTag="llms-on-eks" \
  --capabilities CAPABILITY_NAMED_IAM \
  --tags \
      project=llms-on-eks \
      guide=001-prerequisites \
      managed-by=cloudformation \
  --profile  "$AWS_PROFILE" \
  --region   "$AWS_REGION" \
  --no-fail-on-empty-changeset

echo ""
echo "  ✅  CloudFormation stack deployed."

# ── Read stack outputs ─────────────────────────────────────────────────────────
echo ""
echo "[ 2/5 ] Reading stack outputs"

cfn_out() {
  aws cloudformation describe-stacks \
    --stack-name "$CFT_STACK" \
    --query      "Stacks[0].Outputs[?OutputKey=='${1}'].OutputValue" \
    --output     text \
    --profile    "$AWS_PROFILE" \
    --region     "$AWS_REGION"
}

KARPENTER_NODE_ROLE_ARN=$(cfn_out "KarpenterNodeRoleArn")
KARPENTER_CTRL_ROLE_ARN=$(cfn_out "KarpenterControllerRoleArn")
KARPENTER_QUEUE_NAME=$(cfn_out "KarpenterInterruptionQueueName")

if [[ -z "$KARPENTER_NODE_ROLE_ARN" || -z "$KARPENTER_CTRL_ROLE_ARN" || -z "$KARPENTER_QUEUE_NAME" ]]; then
  echo "  ❌  Stack outputs are empty. Check CFN events:"
  echo "      aws cloudformation describe-stack-events --stack-name $CFT_STACK"
  exit 1
fi

printf "  %-30s %s\n" "KarpenterNodeRoleArn:"       "$KARPENTER_NODE_ROLE_ARN"
printf "  %-30s %s\n" "KarpenterControllerRoleArn:" "$KARPENTER_CTRL_ROLE_ARN"
printf "  %-30s %s\n" "KarpenterQueueName:"         "$KARPENTER_QUEUE_NAME"

# ── Step 2: kubeconfig + wait for nodes ───────────────────────────────────────
echo ""
echo "[ 3/5 ] Configuring kubectl"

aws eks update-kubeconfig \
  --name    "$CLUSTER_NAME" \
  --region  "$AWS_REGION" \
  --profile "$AWS_PROFILE"

echo "  ✅  Context: $(kubectl config current-context)"

echo ""
echo "        Waiting for system nodes (up to 5 min)..."
kubectl wait nodes \
  --selector  "node-type=system" \
  --for       condition=Ready \
  --timeout   300s \
  2>/dev/null || echo "  ⚠️   Timeout — nodes may still be joining, continuing..."

echo ""
kubectl get nodes -L node-type,eks.amazonaws.com/nodegroup 2>/dev/null | sed 's/^/  /'

# ── Step 3: Karpenter Helm install ────────────────────────────────────────────
echo ""
echo "[ 4/5 ] Installing Karpenter v${KARPENTER_VERSION}"

helm upgrade --install karpenter \
  oci://public.ecr.aws/karpenter/karpenter \
  --version   "$KARPENTER_VERSION" \
  --namespace kube-system \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.interruptionQueue=${KARPENTER_QUEUE_NAME}" \
  --set "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=${KARPENTER_CTRL_ROLE_ARN}" \
  --set "controller.resources.requests.cpu=500m" \
  --set "controller.resources.requests.memory=512Mi" \
  --set "controller.resources.limits.cpu=1" \
  --set "controller.resources.limits.memory=1Gi" \
  --wait \
  --timeout 5m

echo "  ✅  Karpenter v${KARPENTER_VERSION} installed"

# ── Step 4: NodePools ─────────────────────────────────────────────────────────
echo ""
echo "[ 5/5 ] Applying Karpenter NodePools"
echo "        system / cpu / gpu / gpu-spot"

# Substitute cluster name in NodePool YAML before applying
sed "s/llms-on-eks/${CLUSTER_NAME}/g" "$NP_FILE" | kubectl apply -f -

echo ""
echo "  EC2NodeClasses:"
kubectl get ec2nodeclasses -o wide 2>/dev/null | sed 's/^/    /'
echo ""
echo "  NodePools:"
kubectl get nodepools -o wide 2>/dev/null | sed 's/^/    /'

# ── Step 5: Summary ───────────────────────────────────────────────────────────
echo ""
cat << 'EOF'
╔══════════════════════════════════════════════════════════════╗
║   ✅  Guide 001 complete!                                   ║
╠══════════════════════════════════════════════════════════════╣
║                                                              ║
║  Cluster is ready. No LLM workloads running yet.            ║
║  GPU and CPU nodes cost $0 until you deploy a workload.     ║
║                                                              ║
║  Verify:  bash guides/001-prerequisites/scripts/verify.sh   ║
║                                                              ║
║  ── Next guides ───────────────────────────────────────────  ║
║  002 CPU inference:  bash guides/002-cpu-inference-vllm/    ║
║                           scripts/deploy.sh                 ║
║  003 GPU inference:  bash guides/003-gpu-inference-vllm/    ║
║                           scripts/deploy.sh                 ║
╚══════════════════════════════════════════════════════════════╝
EOF
