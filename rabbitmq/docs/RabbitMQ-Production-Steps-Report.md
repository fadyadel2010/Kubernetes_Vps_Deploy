# RabbitMQ Production Deployment Runbook

## Shopixy Platform

Version: 1.0

Purpose:

Deploy a fully production-ready RabbitMQ Cluster on a new VPS from scratch.

Target Environment:

* Ubuntu Server
* K3s
* Prometheus
* Grafana

Final Result:

* 3 Node RabbitMQ Cluster
* TLS Enabled
* Monitoring Enabled
* Topology as Code
* Backup & Restore
* Bootstrap Automation

---

# Phase 0 - Prerequisites

Verify Kubernetes:

kubectl get nodes

Expected:

Node Ready

Verify StorageClass:

kubectl get storageclass

Expected:

local-path

Verify Monitoring Stack:

kubectl get pods -n prometheus

Expected:

Prometheus Running

Grafana Running

Verify Cert Manager:

kubectl get pods -n cert-manager

Expected:

All Pods Running

---

# Phase 1 - Repository Setup

Clone Repository:

k8s-labs/rabbitmq

Verify Structure:

namespace.yaml

cluster/

topology/

monitoring/

scripts/

bootstrap.env

bootstrap.sh

---

# Phase 2 - Namespace Creation

Apply:

namespace.yaml

Validate:

kubectl get ns rabbitmq

Expected:

rabbitmq namespace exists

---

# Phase 3 - RabbitMQ Operator Installation

Install:

RabbitMQ Cluster Operator

Namespace:

rabbitmq-system

Validate:

kubectl get deployment -n rabbitmq-system

Expected:

rabbitmq-cluster-operator

Ready = 1/1

---

# Phase 4 - Messaging Topology Operator

Install:

Messaging Topology Operator

Validate:

kubectl get deployment -n rabbitmq-system

Expected:

messaging-topology-operator

Ready = 1/1

Validate CRDs:

kubectl get crd | grep rabbitmq

Expected:

users.rabbitmq.com

vhosts.rabbitmq.com

permissions.rabbitmq.com

queues.rabbitmq.com

bindings.rabbitmq.com

exchanges.rabbitmq.com

---

# Phase 5 - RabbitMQ Cluster Deployment

Apply:

cluster/rabbitmq-cluster.yaml

Configuration:

Replicas = 3

CPU Request = 500m

CPU Limit = 2

Memory Request = 4Gi

Memory Limit = 4Gi

PVC Size = 50Gi

Storage Class = local-path

Validate:

kubectl get rabbitmqcluster -n rabbitmq

Expected:

ALLREPLICASREADY=True

RECONCILESUCCESS=True

Validate Pods:

kubectl get pods -n rabbitmq

Expected:

rabbitmq-server-0

rabbitmq-server-1

rabbitmq-server-2

All Running

---

# Phase 6 - Initial Cluster Validation

Run:

rabbitmqctl cluster_status

Expected:

3 Running Nodes

No Network Partitions

No Alarms

Quorum Status OK

---

# Phase 7 - TLS Infrastructure

Create:

tls/selfsigned-clusterissuer.yaml

Apply

Validate:

kubectl get clusterissuer

Expected:

READY=True

Create:

tls/rabbitmq-ca.yaml

Apply

Validate:

rabbitmq-ca-secret

Create:

tls/rabbitmq-ca-issuer.yaml

Apply

Validate:

Issuer Ready

Create:

tls/rabbitmq-server-cert.yaml

Apply

Validate:

rabbitmq-server-tls

Certificate Ready

---

# Phase 8 - Enable TLS

Update:

cluster/rabbitmq-cluster.yaml

Add:

tls:
secretName: rabbitmq-server-tls
caSecretName: rabbitmq-ca-secret

Apply

Wait Rolling Restart

Validate:

rabbitmq-diagnostics listeners

Expected:

5671

15671

15691

Available

---

# Phase 9 - Application Topology

Apply:

vhost-shopixy.yaml

Validate:

shopixy VHost Created

Apply:

user-shopixy-app.yaml

Validate:

User Created

Apply:

permissions-shopixy-app.yaml

Validate:

Read/Write/Configure Permissions

---

# Phase 10 - Messaging Layer

Create Exchange:

shopixy.events

Type:

topic

Create Queues:

orders

products

notifications

Queue Type:

quorum

Create Bindings:

orders.*

products.*

notifications.*

Validate:

RabbitMQ UI

Queues Visible

Bindings Visible

Exchange Visible

---

# Phase 11 - Monitoring

Create:

rabbitmq-servicemonitor.yaml

Initial Endpoint:

prometheus

Port:

15692

After TLS Migration:

prometheus-tls

Port:

15691

ServiceMonitor Configuration:

scheme: https

tlsConfig:
insecureSkipVerify: true

Validate:

Prometheus Targets

Expected:

3 / 3 UP

Validate:

Grafana Dashboard

RabbitMQ Metrics Visible

---

# Phase 12 - Backup System

Deploy:

scripts/backup.sh

Capabilities:

Definitions Export

Cluster Metadata Export

Node Data Backup

Archive Creation

Google Drive Upload

Retention Cleanup

Validate:

Backup Archive Created

Rclone Upload Successful

---

# Phase 13 - Restore System

Deploy:

scripts/restore.sh

Capabilities:

Cluster Shutdown

PVC Restore

Definitions Restore

Cluster Validation

Validate:

Successful Restore Test

Cluster Healthy

---

# Phase 14 - Bootstrap Automation

Configure:

bootstrap.env

Generate:

Application Secrets

Run:

bootstrap.sh

Capabilities:

Namespace

Operators

Cluster

Topology

Monitoring

Validation

Expected:

Fully Operational Cluster

---

# Phase 15 - Final Production Validation

Validate:

RabbitMQ Cluster

Validate:

TLS

Validate:

Prometheus

Validate:

Grafana

Validate:

Backup

Validate:

Restore

Validate:

Bootstrap

Validate:

RabbitMQ UI

Validate:

AMQPS

Expected Result:

PRODUCTION READY

---

# Final Production State

RabbitMQ Version:

4.2.6

Nodes:

3

Queue Type:

Quorum

TLS:

Enabled

Monitoring:

Enabled

Backup:

Enabled

Restore:

Enabled

Bootstrap:

Enabled

Certification Status:

PRODUCTION READY
