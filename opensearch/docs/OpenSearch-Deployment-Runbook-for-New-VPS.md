# OpenSearch Deployment Runbook for New VPS

## Purpose

This runbook describes the complete process for deploying the Shopixy OpenSearch production stack on a brand-new VPS.

The objective is to achieve a fully operational OpenSearch environment with:

* OpenSearch Operator
* 3-Node OpenSearch Cluster
* Snapshot Infrastructure
* Prometheus Monitoring
* Grafana Integration
* Automated Bootstrap Deployment

Expected Result:

```text
OpenSearch Cluster Health: GREEN
Nodes: 3
Monitoring: Operational
Snapshots: Infrastructure Ready
Bootstrap: PASS
```

---

# Prerequisites

Before starting deployment, ensure the following infrastructure already exists.

Required Components:

* Linux VPS
* K3s Kubernetes Cluster
* Helm
* kubectl
* jq
* curl

Verify:

```bash
kubectl get nodes

helm version

kubectl version

jq --version

curl --version
```

All commands must succeed before continuing.

---

# Repository Deployment

Clone the Shopixy Infrastructure Repository.

Example:

```bash
git clone <repository-url>

cd k8s-labs/opensearch
```

Verify structure:

```bash
tree -L 2
```

Expected directories:

```text
bootstrap/
cluster/
monitoring/
operator/
snapshots/
scripts/
```

---

# Configuration Review

Review cluster configuration.

Files:

```text
cluster/opensearch-cluster.yaml
operator/values.yaml
monitoring/exporter-values.yaml
```

Verify:

* Storage sizes
* Resource limits
* Node counts
* Snapshot settings
* Monitoring configuration

Modify only if infrastructure requirements differ from production defaults.

---

# Secrets Preparation

Verify all required secrets exist in source control or secure secret storage.

Required files:

```text
snapshots/minio-s3-secret.yaml

snapshots/snapshot-secret.yaml

monitoring/exporter-secret.yaml
```

Confirm values before deployment.

Do not deploy placeholder credentials.

---

# Bootstrap Deployment

Run the bootstrap process.

```bash
sudo bash bootstrap.sh
```

The bootstrap performs:

1. Namespace Validation
2. Helm Repository Validation
3. OpenSearch Operator Deployment
4. OpenSearch Cluster Deployment
5. Cluster Readiness Validation
6. Backup Infrastructure Deployment
7. Monitoring Deployment
8. Final Validation

Expected runtime:

```text
10 - 30 minutes
```

depending on VPS performance and storage initialization speed.

---

# Bootstrap Expected Output

Expected high-level workflow:

```text
Namespace
Operator
Cluster
Backup Infrastructure
Monitoring
Validation
```

Successful completion:

```text
OpenSearch Bootstrap Completed Successfully
```

No errors should be present.

---

# Post-Deployment Validation

Validate cluster health.

```bash
kubectl get opensearchclusters.opensearch.org -A
```

Expected:

```text
HEALTH   NODES   PHASE
green    3       RUNNING
```

---

Validate OpenSearch pods.

```bash
kubectl get pods -n opensearch
```

Expected:

```text
shopixy-search-core-0
shopixy-search-core-1
shopixy-search-core-2
```

All pods must be:

```text
READY 1/1
STATUS Running
```

---

Validate operator.

```bash
kubectl get deployment -n opensearch-system
```

Expected:

```text
opensearch-operator
```

Status:

```text
READY 1/1
```

---

# Monitoring Validation

Verify exporter deployment.

```bash
kubectl get deployment \
-n opensearch
```

Expected:

```text
opensearch-exporter-prometheus-elasticsearch-exporter
```

Status:

```text
READY 1/1
```

---

Verify ServiceMonitor.

```bash
kubectl get servicemonitor -A \
| grep opensearch
```

Expected:

```text
opensearch-exporter-prometheus-elasticsearch-exporter
```

---

Verify Prometheus scraping.

Open Prometheus UI.

Query:

```promql
elasticsearch_cluster_health_status
```

Expected:

```text
Results Returned
```

---

Verify additional metrics.

```promql
elasticsearch_cluster_health_active_shards

elasticsearch_indices_docs

elasticsearch_filesystem_data_available_bytes

elasticsearch_jvm_memory_used_bytes
```

Expected:

```text
Results Returned
```

---

# Grafana Validation

Open Grafana.

Import the approved OpenSearch dashboard.

Verify visibility of:

* Cluster Health
* JVM Metrics
* Heap Usage
* CPU Usage
* Node Utilization
* Index Statistics
* Storage Metrics
* Search Throughput

Expected:

All panels display live data.

No datasource errors.

---

# Backup Infrastructure Validation

Verify secrets.

```bash
kubectl get secret \
-n opensearch
```

Expected:

```text
opensearch-s3-credentials

opensearch-snapshot-job
```

---

Verify CronJob.

```bash
kubectl get cronjob \
-n opensearch
```

Expected:

```text
opensearch-snapshot
```

Status:

```text
SUSPEND False
```

---

Verify CronJob schedule.

Expected:

```text
0 */6 * * *
```

or the currently approved production schedule.

---

# Operational Notes

The bootstrap intentionally does NOT:

* Create snapshots
* Restore snapshots
* Perform retention tests
* Perform disaster recovery tests
* Register repositories dynamically

These tasks belong to operational procedures and certification workflows.

The bootstrap is responsible only for infrastructure deployment.

---

# Re-Running Bootstrap

The bootstrap is fully idempotent.

Safe:

```bash
sudo bash bootstrap.sh
```

multiple times.

Behavior:

```text
Existing resources → SKIP

Missing resources → CREATE

Installed releases → VERIFY

Monitoring → UPGRADE/VERIFY
```

No manual cleanup is required before re-execution.

---

# Troubleshooting

## Cluster Not Green

Check:

```bash
kubectl get pods -n opensearch
```

Review pod logs:

```bash
kubectl logs \
-pod-name- \
-n opensearch
```

---

## Exporter Not Running

Check:

```bash
kubectl logs deployment/opensearch-exporter-prometheus-elasticsearch-exporter \
-n opensearch
```

Verify:

```text
Authentication
ServiceMonitor
OpenSearch URL
```

---

## Prometheus Not Scraping

Check:

```bash
kubectl get servicemonitor -A
```

Verify:

```text
release labels
namespace selection
```

---

# Deployment Acceptance Criteria

The deployment is accepted only when:

```text
Operator Running                    PASS

Cluster Health Green               PASS

Three Nodes Available              PASS

Exporter Running                   PASS

ServiceMonitor Registered          PASS

Prometheus Metrics Available       PASS

Grafana Dashboard Operational      PASS

Snapshot Infrastructure Ready      PASS

Bootstrap Completed Successfully   PASS
```

---

# Final Result

When all acceptance criteria pass:

```text
Shopixy OpenSearch Deployment

STATUS: PRODUCTION READY
```
