#!/usr/bin/env bash
# bootstrap-cluster.sh — full setup for semea-eks-vicma
# Run once after the EKS cluster is provisioned via eksctl or Terraform.
# Prerequisites: aws CLI, kubectl, helm, eksctl all on PATH.
set -euo pipefail

CLUSTER_NAME="semea-eks-vicma"
REGION="us-east-1"
DD_NAMESPACE="datadog"
OPW_NAMESPACE="observability-pipelines"
STOCK_NAMESPACE="stock-demo"

# Source AWS credentials
# shellcheck source=/dev/null
source /tmp/aws_env.sh

echo "==> Updating kubeconfig for ${CLUSTER_NAME}"
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${REGION}"

# ── 1. EBS CSI Driver ────────────────────────────────────────────────────────
echo "==> Installing EBS CSI driver"
helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver
helm repo update
helm upgrade --install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver \
  --namespace kube-system \
  --set controller.serviceAccount.create=true \
  --set controller.serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=\
"arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/AmazonEKS_EBS_CSI_DriverRole"

# Create gp3 StorageClass
kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF

# ── 2. Karpenter ─────────────────────────────────────────────────────────────
echo "==> Installing Karpenter"
KARPENTER_VERSION="1.3.3"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

helm repo add karpenter https://charts.karpenter.sh
helm repo update
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "${KARPENTER_VERSION}" \
  --namespace kube-system \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.interruptionQueue=${CLUSTER_NAME}" \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:aws:iam::${ACCOUNT_ID}:role/KarpenterControllerRole-${CLUSTER_NAME}" \
  --wait

echo "==> Applying Karpenter NodePool and EC2NodeClass"
kubectl apply -f manifests/karpenter/ec2nodeclass.yaml
kubectl apply -f manifests/karpenter/nodepool.yaml

# ── 3. Datadog Secrets ───────────────────────────────────────────────────────
echo "==> Creating Datadog secrets"
# Set these before running the script:
# export DD_API_KEY=<your-api-key>
# export DD_APP_KEY=<your-app-key>
: "${DD_API_KEY:?Set DD_API_KEY env var}"
: "${DD_APP_KEY:?Set DD_APP_KEY env var}"

kubectl create namespace "${DD_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic datadog-secret \
  --namespace "${DD_NAMESPACE}" \
  --from-literal=api-key="${DD_API_KEY}" \
  --from-literal=app-key="${DD_APP_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

# ── 4. Datadog Agent ─────────────────────────────────────────────────────────
echo "==> Installing Datadog Agent"
helm repo add datadog https://helm.datadoghq.com
helm repo update
helm upgrade --install datadog datadog/datadog \
  --namespace "${DD_NAMESPACE}" \
  -f manifests/datadog/values-datadog-agent.yaml \
  --wait

# ── 5. Stock App ─────────────────────────────────────────────────────────────
echo "==> Deploying stock-demo application"
kubectl apply -f manifests/stock-app/namespace.yaml

# Create app secrets
: "${POSTGRES_PASSWORD:=stockpass}"
kubectl create secret generic stock-secrets \
  --namespace "${STOCK_NAMESPACE}" \
  --from-literal=postgres-password="${POSTGRES_PASSWORD}" \
  --from-literal=database-url="postgresql://stockuser:${POSTGRES_PASSWORD}@stock-db:5432/stockdb" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f manifests/stock-app/postgres.yaml
kubectl apply -f manifests/stock-app/stock-backend.yaml
kubectl apply -f manifests/stock-app/stock-frontend.yaml

echo "==> Waiting for stock-demo pods..."
kubectl rollout status deployment/stock-db       -n "${STOCK_NAMESPACE}" --timeout=120s
kubectl rollout status deployment/stock-backend  -n "${STOCK_NAMESPACE}" --timeout=120s
kubectl rollout status deployment/stock-frontend -n "${STOCK_NAMESPACE}" --timeout=120s

# ── 6. Observability Pipelines Worker (optional) ─────────────────────────────
echo "==> Skipping OPW install (set INSTALL_OPW=true to enable)"
if [[ "${INSTALL_OPW:-false}" == "true" ]]; then
  : "${OPW_PIPELINE_ID:?Set OPW_PIPELINE_ID env var}"
  : "${OPW_PIPELINE_KEY:?Set OPW_PIPELINE_KEY env var}"

  kubectl create namespace "${OPW_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret generic opw-secret \
    --namespace "${OPW_NAMESPACE}" \
    --from-literal=api-key="${DD_API_KEY}" \
    --from-literal=pipeline-key="${OPW_PIPELINE_KEY}" \
    --dry-run=client -o yaml | kubectl apply -f -

  helm upgrade --install opw datadog/observability-pipelines-worker \
    --namespace "${OPW_NAMESPACE}" \
    --set pipelineId="${OPW_PIPELINE_ID}" \
    -f manifests/datadog/values-opw.yaml \
    --wait
fi

# ── 7. Dashboard ─────────────────────────────────────────────────────────────
echo "==> Creating Datadog monitoring dashboard"
python3 scripts/create-dashboard.py

echo ""
echo "==> Done! Cluster is ready."
echo "    Stock frontend LB: $(kubectl get svc stock-frontend -n ${STOCK_NAMESPACE} -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo 'pending')"
echo "    Run: kubectl get pods -n ${STOCK_NAMESPACE}"
