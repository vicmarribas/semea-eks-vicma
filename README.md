# semea-eks-vicma

Kubernetes manifests and automation scripts for the **SEMEA SE demo EKS cluster** (`semea-eks-vicma`, `us-east-1`).  
Deploys a three-tier stock-trading demo app (frontend / backend / PostgreSQL) with full Datadog observability, Karpenter node autoscaling, and an Observability Pipelines Worker for intelligent log routing.

> Maintained by the SEMEA Solutions Engineering team. Fork freely for customer demos.

---

## What's in this repo

```
semea-eks-vicma/
├── charts/
│   └── stock-demo/             # Helm chart — deploy for any customer with one command
├── manifests/
│   ├── karpenter/
│   │   ├── ec2nodeclass.yaml    # AWS node configuration (AMI, subnets, SGs)
│   │   └── nodepool.yaml       # Default (spot+on-demand) + critical on-demand pools
│   ├── stock-app/
│   │   ├── namespace.yaml      # stock-demo namespace with DD Admission Controller label
│   │   ├── postgres.yaml       # PostgreSQL + PVC (EBS gp3) + DD autodiscovery annotations
│   │   ├── stock-backend.yaml  # Python API with Unified Service Tagging
│   │   └── stock-frontend.yaml # Node.js UI, exposed via LoadBalancer
│   └── datadog/
│       ├── values-datadog-agent.yaml   # Helm values: APM, logs, NPM, Admission Controller
│       └── values-opw.yaml             # Observability Pipelines Worker Helm values
├── scripts/
│   ├── bootstrap-cluster.sh    # One-shot full install (EBS CSI → Karpenter → DD → app)
│   ├── create-dashboard.py     # Deploys the Datadog monitoring dashboard via API
│   └── teardown.sh             # Removes app + DD components (keeps EKS cluster)
└── dashboards/
    └── (dashboard JSON exported from Datadog)
```

---

## Helm chart — quick deploy for any customer

The `charts/stock-demo` chart is the fastest way for SEMEA SEs to stand up the full stack against any EKS cluster. It wraps all three tiers (frontend, backend, PostgreSQL) with sensible defaults you override per customer.

### Minimal install

```bash
helm install stock-demo ./charts/stock-demo \
  --set customer=acme \
  --set datadog.apiKey=xxx
```

This creates the namespace `stock-acme` and deploys everything into it.

### Full customer demo with common overrides

```bash
helm install stock-demo ./charts/stock-demo \
  --set customer=acme \
  --set datadog.apiKey=xxx \
  --set datadog.env=acme-poc \
  --set replicaCount.backend=3 \
  --set images.backend.tag=v1.2.3 \
  --set "ipAllowlist[0]=203.0.113.10/32"
```

### All configurable values

| Flag | Default | What it controls |
|------|---------|------------------|
| `customer` | `demo` | Namespace (`stock-<customer>`), labels, Datadog tags |
| `datadog.apiKey` | — | **Required.** Stored in a Kubernetes Secret. |
| `datadog.env` | `demo` | Unified Service Tagging `env` on all pods |
| `datadog.site` | `datadoghq.com` | Datadog site (EU: `datadoghq.eu`) |
| `images.backend.tag` | `latest` | Backend image tag |
| `images.frontend.tag` | `latest` | Frontend image tag |
| `images.postgres.tag` | `15-alpine` | PostgreSQL image tag |
| `replicaCount.backend` | `2` | Backend replica count |
| `replicaCount.frontend` | `2` | Frontend replica count |
| `ipAllowlist` | `[]` (open) | CIDRs for `loadBalancerSourceRanges` on the frontend LB |
| `postgres.password` | `stockpass` | PostgreSQL password |
| `postgres.storage` | `10Gi` | PVC size (requires EBS CSI driver) |
| `postgres.storageClass` | `gp3` | StorageClass name |

### Upgrade and teardown

```bash
# Change replica count without redeploying everything
helm upgrade stock-demo ./charts/stock-demo --set customer=acme --set datadog.apiKey=xxx --set replicaCount.backend=4

# Remove all resources (keeps EKS cluster)
helm uninstall stock-demo
kubectl delete namespace stock-acme
```

---

## Prerequisites

| Component | Notes |
|-----------|-------|
| **EKS cluster** | `semea-eks-vicma` in `us-east-1`. Provision with `eksctl` or Terraform. Needs OIDC provider for IRSA. |
| **EBS CSI driver** | Required for PostgreSQL PVC (`gp3` StorageClass). IAM role `AmazonEKS_EBS_CSI_DriverRole` must exist. |
| **Karpenter** | IAM roles `KarpenterControllerRole-semea-eks-vicma` and `KarpenterNodeRole-semea-eks-vicma` must exist. Subnet and SG tags `karpenter.sh/discovery: semea-eks-vicma` must be set. |
| **Datadog API key** | From your org at `app.datadoghq.com`. Needs `metrics_write`, `logs_write`, `apm_write` scopes. |
| **Datadog App key** | Required only for `create-dashboard.py`. Needs `dashboards_write` scope. |
| **Local tools** | `aws`, `kubectl`, `helm` (≥ 3.12), `python3`, `datadog-api-client` pip package |

---

## Step-by-step guide

### 1 — Source AWS credentials

```bash
source /tmp/aws_env.sh
aws eks update-kubeconfig --name semea-eks-vicma --region us-east-1
kubectl get nodes
```

### 2 — Install EBS CSI driver and gp3 StorageClass

The bootstrap script handles this, but you can also run it standalone:

```bash
helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver
helm repo update
helm upgrade --install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver \
  --namespace kube-system \
  --set controller.serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=\
  arn:aws:iam::<ACCOUNT_ID>:role/AmazonEKS_EBS_CSI_DriverRole
```

Verify: `kubectl get storageclass gp3`

### 3 — Install Karpenter

```bash
kubectl apply -f manifests/karpenter/ec2nodeclass.yaml
kubectl apply -f manifests/karpenter/nodepool.yaml
```

The default NodePool provisions both **spot and on-demand** instances (`c`, `m`, `r` families, 2–8 vCPU).  
A second `on-demand-critical` pool with a `workload-type: critical` taint is reserved for stateful workloads (PostgreSQL, Datadog Agent).

Verify: `kubectl get nodepools`

### 4 — Install the Datadog Agent

```bash
export DD_API_KEY=<your-api-key>
export DD_APP_KEY=<your-app-key>

kubectl create namespace datadog
kubectl create secret generic datadog-secret -n datadog \
  --from-literal=api-key="$DD_API_KEY" \
  --from-literal=app-key="$DD_APP_KEY"

helm repo add datadog https://helm.datadoghq.com && helm repo update
helm upgrade --install datadog datadog/datadog \
  -n datadog -f manifests/datadog/values-datadog-agent.yaml --wait
```

The Helm values enable: **APM** (port 8126), **log collection** (all containers), **NPM**, **Admission Controller** (auto-injects APM libraries), **Cluster Agent** with HPA metrics provider.

### 5 — Deploy the stock-demo app

```bash
kubectl apply -f manifests/stock-app/namespace.yaml
kubectl create secret generic stock-secrets -n stock-demo \
  --from-literal=postgres-password=stockpass \
  --from-literal=database-url=postgresql://stockuser:stockpass@stock-db:5432/stockdb

kubectl apply -f manifests/stock-app/postgres.yaml
kubectl apply -f manifests/stock-app/stock-backend.yaml
kubectl apply -f manifests/stock-app/stock-frontend.yaml

kubectl get pods -n stock-demo
```

All pods use **Unified Service Tagging** (`env`, `service`, `version` labels) and Datadog autodiscovery annotations for PostgreSQL.

### 6 — (Optional) Install Observability Pipelines Worker

```bash
export OPW_PIPELINE_ID=<pipeline-id-from-datadog-ui>
export OPW_PIPELINE_KEY=<pipeline-key>
INSTALL_OPW=true bash scripts/bootstrap-cluster.sh
```

OPW routes logs by severity: debug/info → **Flex Logs** (cheap storage), warn/error → **Standard Index** (full search).  
Monitor throughput with the `vector.processed_events_total` metric split by `component_id`.

### 7 — Deploy the monitoring dashboard

```bash
pip install datadog-api-client
export DD_API_KEY=<your-api-key>
export DD_APP_KEY=<your-app-key>
python3 scripts/create-dashboard.py
```

The script creates **"EKS Stock App — semea-eks-vicma"** with four monitoring rows:

| Row | What it shows |
|-----|---------------|
| EKS Nodes (Karpenter) | Total, spot, on-demand node counts + timeseries |
| Pod Resource Utilisation | CPU & memory as % of requests and limits |
| OPW Throughput | Events/sec routed to Flex Logs vs Standard Index |
| stock-backend APM | Request rate, error rate %, dual-series timeseries |

### 8 — Run everything at once

```bash
export DD_API_KEY=<your-api-key>
export DD_APP_KEY=<your-app-key>
bash scripts/bootstrap-cluster.sh
```

---

## Teardown

To remove the app and Datadog components (EKS cluster remains):

```bash
bash scripts/teardown.sh
```

To delete the cluster entirely:

```bash
eksctl delete cluster --name semea-eks-vicma --region us-east-1
```

---

## Lab reference

This repo is the companion artifact for the **SEMEA SE EKS + Datadog lab guide**.  
Key topics covered in the lab:

- EKS cluster setup with OIDC and IRSA
- Karpenter spot/on-demand node management
- Datadog Admission Controller for zero-touch APM injection
- Unified Service Tagging for correlated traces, logs, and metrics
- Observability Pipelines Worker for cost-optimised log routing
- Custom Datadog dashboards via the API

---

## Contributing

PRs welcome. If you adapt this for a customer demo, please tag widgets with `customer:<name>` in Datadog and open a PR with any reusable manifests.
