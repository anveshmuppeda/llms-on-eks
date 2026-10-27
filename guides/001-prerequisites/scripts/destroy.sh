#!/usr/bin/env bash
# =============================================================================
# destroy.sh — Guide 001: Prerequisites & Cluster Setup
# =============================================================================
# ⚠️  WARNING: Destroys ALL infrastructure — EKS cluster, VPC, IAM, SQS.
# Run this only when you are completely done with all guides.
#
# Steps:
#   1. Delete LLM namespaces  (triggers Karpenter node drain)
#   2. Remove Karpenter NodePools + Helm release
#   3. Delete CloudFormation stack (~15 min)
#   4. Clean up kubeconfig
# =============================================================================

set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-anvesh-aws-profile}"
AWS_REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-llms-on-eks}"
CFT_STACK="${CFT_STACK:-llms-on-eks-stack}"

export AWS_PROFILE AWS_REGION

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   ⚠️   DESTROY — Guide 001: All Infrastructure             ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  %-58s ║\n" "  Cluster:    $CLUSTER_NAME"
printf "║  %-58s ║\n" "  CFT Stack:  $CFT_STACK"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  This will permanently delete the EKS cluster, VPC,        ║"
echo "║  all IAM roles, the SQS queue, and all EBS volumes.        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
read -rp "  Type 'yes' to confirm: " CONFIRM
[[ "$CONFIRM" == "yes" ]] || { echo "Cancelled."; exit 0; }

echo ""
echo "[ 1/4 ] Deleting LLM namespaces (triggers GPU/CPU node drain)..."
for ns in llm-serving llm-monitoring llm-gateway; do
  kubectl delete namespace "$ns" --ignore-not-found=true 2>/dev/null || true
done
echo "  Waiting 60s for Karpenter to terminate provisioned nodes..."
sleep 60

echo ""
echo "[ 2/4 ] Removing Karpenter NodePools and Helm release..."
kubectl delete nodepools --all           2>/dev/null || true
kubectl delete ec2nodeclasses --all      2>/dev/null || true
helm uninstall karpenter --namespace kube-system 2>/dev/null || echo "  (already removed)"

echo ""
echo "[ 3/4 ] Deleting CloudFormation stack (~15 min)..."
aws cloudformation delete-stack \
  --stack-name "$CFT_STACK" \
  --profile    "$AWS_PROFILE" \
  --region     "$AWS_REGION"

echo "  Waiting for stack deletion..."
aws cloudformation wait stack-delete-complete \
  --stack-name "$CFT_STACK" \
  --profile    "$AWS_PROFILE" \
  --region     "$AWS_REGION"

echo "  ✅  Stack deleted."

echo ""
echo "[ 4/4 ] Removing kubeconfig context..."
CTX=$(kubectl config get-contexts -o name 2>/dev/null | grep "$CLUSTER_NAME" | head -1 || true)
[[ -n "$CTX" ]] && kubectl config delete-context "$CTX" 2>/dev/null || true

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   ✅  All infrastructure destroyed. Cost is now \$0.00/hr   ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
