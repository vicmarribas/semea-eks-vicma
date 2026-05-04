#!/usr/bin/env bash
# teardown.sh — remove stock-demo app and optional Datadog components.
# Does NOT delete the EKS cluster itself.
set -euo pipefail

source /tmp/aws_env.sh

echo "==> Removing stock-demo application"
kubectl delete namespace stock-demo --ignore-not-found

echo "==> Removing Datadog Agent (Helm)"
helm uninstall datadog -n datadog 2>/dev/null || true
kubectl delete namespace datadog --ignore-not-found

echo "==> Removing OPW (Helm)"
helm uninstall opw -n observability-pipelines 2>/dev/null || true
kubectl delete namespace observability-pipelines --ignore-not-found

echo "==> Removing Karpenter NodePools"
kubectl delete nodepool --all 2>/dev/null || true
kubectl delete ec2nodeclass --all 2>/dev/null || true

echo "==> Done. EKS cluster semea-eks-vicma is still running."
echo "    To delete the cluster: eksctl delete cluster --name semea-eks-vicma --region us-east-1"
