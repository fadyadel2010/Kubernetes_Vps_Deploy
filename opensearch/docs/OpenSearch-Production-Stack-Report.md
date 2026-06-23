# Shopixy OpenSearch Production Stack Report

## Executive Summary

This document describes the final production-ready OpenSearch stack deployed for Shopixy and the engineering decisions made during implementation, validation, monitoring integration, backup preparation, and bootstrap automation.

The objective of this project was to create a fully automated, repeatable, production-grade OpenSearch deployment that can be recreated on a new VPS with minimal manual intervention.

The final solution provides:

* OpenSearch Cluster Operator Management
* Multi-Node OpenSearch Cluster
* Prometheus Monitoring Integration
* Grafana Dashboard Integration
* Snapshot Backup Infrastructure
* Automated Bootstrap Deployment
* Idempotent Infrastructure Provisioning
* Production Validation Procedures

---

# Architecture Overview

The final architecture consists of four major layers:

## Layer 1: Kubernetes Platform

Environment:

* K3s Kubernetes Cluster
* Single VPS deployment
* Containerized infrastructure
* Helm-based package management

Responsibilities:

* Scheduling
* Networking
* Service Discovery
* Stateful Workload Management
* Persistent Volume Management

---

## Layer 2: OpenSearch Operator

Namespace:

```text
opensearch-system
```

Deployment:

```text
opensearch-operator
```

Purpose:

The OpenSearch Operator is responsible for managing the lifecycle of OpenSearch clusters through Kubernetes Custom Resources.

Responsibilities:

* Cluster provisioning
* StatefulSet management
* Node orchestration
* Rolling updates
* Cluster recovery
* Security initialization

The operator is installed once and remains responsible for all OpenSearch clusters managed within Kubernetes.

---

## Layer 3: OpenSearch Cluster

Namespace:

```text
opensearch
```

Cluster:

```text
shopixy-search
```

Cluster Characteristics:

* 3 Node Cluster
* OpenSearch Version 2.8.0
* Cluster Health Monitoring
* Stateful Persistent Storage
* Internal Service Discovery

Node Roles:

Each node serves as:

* Cluster Manager
* Data Node
* Ingest Node

This configuration was selected to provide simplicity and resiliency for the current Shopixy workload.

Cluster Status:

```text
Health: Green
Nodes: 3
Phase: Running
```

---

## Layer 4: Monitoring Stack

Monitoring is provided through Prometheus and Grafana.

### Prometheus Exporter

Component:

```text
prometheus-elasticsearch-exporter
```

Namespace:

```text
opensearch
```

Purpose:

Expose OpenSearch metrics in Prometheus format.

Examples of collected metrics:

* Cluster Health
* Node Statistics
* JVM Metrics
* Index Metrics
* Shard Metrics
* Snapshot Metrics
* Storage Metrics

### ServiceMonitor

Namespace:

```text
prometheus
```

Purpose:

Automatically register OpenSearch metrics with Prometheus Operator.

Result:

Prometheus automatically discovers and scrapes OpenSearch metrics without manual configuration.

---

## Grafana Integration

Grafana was integrated with Prometheus metrics.

The selected dashboard provides:

* Cluster Health
* JVM Usage
* Heap Consumption
* CPU Usage
* Node Utilization
* Index Statistics
* Search Throughput
* Indexing Throughput
* Shard Distribution

Monitoring validation confirmed:

* Exporter operational
* Prometheus scraping operational
* Metrics visible in Grafana
* Dashboards rendering successfully

---

# Backup Architecture

The backup strategy uses OpenSearch snapshots.

Infrastructure Components:

Secrets:

```text
opensearch-s3-credentials
opensearch-snapshot-job
```

CronJob:

```text
opensearch-snapshot
```

Purpose:

Provide automated snapshot execution through Kubernetes.

Current Scope:

The bootstrap deploys backup infrastructure only.

It does not:

* Create snapshots
* Restore snapshots
* Perform disaster recovery testing

These activities are intentionally separated into operational runbooks.

This design keeps bootstrap deployment focused on infrastructure provisioning.

---

# Bootstrap Architecture

A production bootstrap process was implemented.

Main entrypoint:

```text
bootstrap.sh
```

Responsibilities:

1. Namespace Verification
2. Helm Repository Verification
3. Operator Verification
4. Cluster Verification
5. Backup Infrastructure Deployment
6. Monitoring Deployment
7. Validation

The bootstrap process is fully idempotent.

---

# Idempotent Design Principles

A key design requirement was repeatable execution.

Before performing any action, the bootstrap checks whether the resource already exists.

Examples:

Namespace:

```text
If exists -> Skip
Else -> Create
```

Operator:

```text
If installed -> Skip
Else -> Install
```

Cluster:

```text
If exists -> Skip
Else -> Deploy
```

Monitoring:

```text
Upgrade or Install
```

This allows the bootstrap to be safely executed multiple times.

---

# Problems Encountered During Implementation

Several challenges were identified and resolved.

## Duplicate Operator Deployment

Issue:

A second OpenSearch Operator instance was accidentally deployed in the application namespace.

Result:

* Duplicate operators
* Resource ownership confusion
* Bootstrap inconsistencies

Resolution:

Removed the duplicate operator and retained the original operator installed in:

```text
opensearch-system
```

Final State:

Only one active OpenSearch Operator remains.

---

## Legacy CRD Discovery

Issue:

The cluster exposed two OpenSearch API groups:

```text
opensearch.opster.io
opensearch.org
```

Investigation confirmed that the production cluster uses:

```text
opensearch.org/v1
```

The bootstrap was updated accordingly.

---

## Exporter Authentication

Issue:

Prometheus Exporter initially failed to authenticate against OpenSearch.

Root Cause:

Missing authentication credentials in exporter configuration.

Resolution:

Embedded authenticated OpenSearch URI in exporter configuration.

Result:

Prometheus successfully collected cluster metrics.

---

# Production Validation Results

The final stack successfully passed validation.

Verified Areas:

## Operator

PASS

* Installed
* Running
* Managing cluster resources

## Cluster

PASS

* Health Green
* Three Nodes Available
* Stateful Services Operational

## Monitoring

PASS

* Exporter Running
* ServiceMonitor Registered
* Prometheus Scraping Metrics
* Grafana Dashboards Functional

## Backup Infrastructure

PASS

* Secrets Created
* CronJob Installed
* Snapshot Infrastructure Ready

## Bootstrap

PASS

* Repeatable
* Idempotent
* Production Safe

---

# Final Certification

OpenSearch Stack Certification Result:

```text
PASS
```

Certified Areas:

* Cluster Management
* Monitoring Integration
* Backup Infrastructure
* Bootstrap Automation
* Production Deployment Readiness

Status:

PRODUCTION READY

```
```
