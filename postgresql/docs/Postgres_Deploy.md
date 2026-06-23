# Shopixy PostgreSQL Infrastructure Documentation

## Kubernetes + CloudNativePG Production Deployment

Version: 1.0
Environment: Kubernetes (K3s)
Database: PostgreSQL 17
Operator: CloudNativePG (CNPG) 1.29.1

---

# 1. Overview

This document describes the complete PostgreSQL production environment used by Shopixy.

The infrastructure is designed to provide:

* High Availability (HA)
* Automatic Failover
* Streaming Replication
* Connection Pooling
* Monitoring & Observability
* Backup & Restore
* Infrastructure as Code
* Fully Automated Bootstrap

---

# 2. Architecture

## Components

### CloudNativePG Operator

Responsible for:

* PostgreSQL cluster lifecycle management
* Replica creation
* Failover orchestration
* TLS management
* Monitoring integration

Namespace:

```text
cnpg-system
```

---

### PostgreSQL Cluster

Cluster Name:

```text
shopixy-postgres
```

Configuration:

```text
PostgreSQL Version: 17
Instances: 3
Storage: 20Gi per node
```

Nodes:

```text
shopixy-postgres-1
shopixy-postgres-2
shopixy-postgres-3
```

---

### Replication

Replication Type:

```text
Streaming Replication
```

Topology:

```text
Primary
 ├── Replica 1
 └── Replica 2
```

CloudNativePG automatically:

* Creates replicas
* Maintains replication
* Rebuilds failed replicas

---

### Automatic Failover

If the primary node becomes unavailable:

```text
Primary Failure
      ↓
CNPG Detection
      ↓
Replica Promotion
      ↓
Service Redirection
```

No manual intervention required.

Failover testing was successfully completed.

---

# 3. Kubernetes Services

## Read/Write Service

```text
shopixy-postgres-rw
```

Purpose:

```text
Application writes
Primary connections
```

Port:

```text
5432
```

---

## Read Service

```text
shopixy-postgres-r
```

Purpose:

```text
General reads
```

Port:

```text
5432
```

---

## Read Only Service

```text
shopixy-postgres-ro
```

Purpose:

```text
Replica reads
Reporting
Analytics
```

Port:

```text
5432
```

---

# 4. PgBouncer

## Purpose

Connection pooling.

Benefits:

* Reduced PostgreSQL connection overhead
* Better concurrency
* Improved scalability

---

## Pooler Configuration

Pooler Name:

```text
shopixy-pgbouncer
```

Mode:

```text
transaction
```

Instances:

```text
2
```

Service:

```text
shopixy-pgbouncer
```

---

## Application Connection String

Recommended:

```text
Host=shopixy-pgbouncer
Port=5432
Database=shopixy
Username=shopixy
Password=<password>
```

---

# 5. Security

## Database Credentials

Stored in Kubernetes Secret:

```text
shopixy-postgres-secret
```

Type:

```text
kubernetes.io/basic-auth
```

---

## TLS

CloudNativePG automatically generates:

```text
Server Certificates
Replication Certificates
CA Certificates
```

Secrets:

```text
shopixy-postgres-ca
shopixy-postgres-server
shopixy-postgres-replication
```

---

# 6. Monitoring

## Stack

Monitoring Components:

```text
Prometheus
Grafana
PodMonitor
CNPG Metrics Exporter
```

---

## Prometheus Discovery

Required Label:

```text
release=prometheus
```

Applied to:

```text
PodMonitor
```

Without this label:

```text
CNPG metrics are not collected.
```

---

## Important Metrics

```promql
cnpg_collector_up
```

```promql
cnpg_pg_database_size
```

```promql
cnpg_backends_total
```

```promql
cnpg_pg_replication_in_recovery
```

---

## Grafana Dashboard

CloudNativePG Dashboard:

```text
Dashboard ID: 20417
```

Additional PostgreSQL Dashboard:

```text
Dashboard ID: 9628
```

---

# 7. Backup Strategy

## Method

Logical Backups

Tool:

```text
pg_dump
```

---

## Storage Targets

### Local Storage

Backup Directory:

```text
backups/
```

---

### Offsite Storage

Provider:

```text
Google Drive
```

Tool:

```text
rclone
```

Remote:

```text
PostgressBackup
```

---

## Backup Workflow

```text
Find Current Primary
      ↓
Execute pg_dump
      ↓
Compress
      ↓
Upload to Google Drive
      ↓
Retention Cleanup
```

---

## Backup Validation

Verified Successfully.

Backup contains:

```text
Schema
Tables
Sequences
Data
```

---

# 8. Restore Strategy

Restore Type:

```text
Validation Restore
```

Process:

```text
Create Test Database
      ↓
Restore Backup
      ↓
Validate Tables
      ↓
Validate Data
```

Database:

```text
shopixy_restore_test
```

---

## Restore Verification

Successfully tested.

Verified:

```text
Schema Restore
Data Restore
Ownership Restore
Sequences Restore
```

---

# 9. Current Recovery Capabilities

Available:

```text
Full Backup Restore
Replica Failover
Google Drive Offsite Recovery
```

Not Yet Implemented:

```text
PITR (Point In Time Recovery)
WAL Archiving
```

Reason:

CloudNativePG native Barman integration is deprecated and replaced by the new Barman Plugin architecture.

PITR implementation intentionally postponed until migration to the new plugin model.

---

# 10. Bootstrap Automation

## Goal

Provision complete PostgreSQL infrastructure on a new VPS with minimal effort.

---

## Bootstrap Flow

```text
Generate Secrets
      ↓
Install CNPG Operator
      ↓
Create Namespace
      ↓
Create Secrets
      ↓
Deploy Cluster
      ↓
Wait For Readiness
      ↓
Deploy PgBouncer
      ↓
Apply Monitoring Labels
      ↓
Verify Health
```

---

## Environment Variables

File:

```text
.env
```

Example:

```env
POSTGRES_CLUSTER_NAME=shopixy-postgres

POSTGRES_DB=shopixy
POSTGRES_USER=shopixy
POSTGRES_PASSWORD=<password>

POSTGRES_INSTANCES=3
POSTGRES_STORAGE=20Gi

POSTGRES_CPU_REQUEST=500m
POSTGRES_MEMORY_REQUEST=1Gi

POSTGRES_CPU_LIMIT=2
POSTGRES_MEMORY_LIMIT=4Gi
```

---

# 11. Deployment Procedure

## Fresh Server

Install:

```text
K3s
kubectl
helm
```

---

## Bootstrap

```bash
cd postgresql

./bootstrap.sh
```

---

## Verification

```bash
kubectl get cluster -n postgresql

kubectl get pods -n postgresql

kubectl get svc -n postgresql

kubectl get pooler -n postgresql
```

Expected Result:

```text
Cluster in healthy state
3 Ready Instances
PgBouncer Ready
Metrics Available
```

---

# 12. Operational Commands

## Check Cluster

```bash
kubectl get cluster -n postgresql
```

---

## Check Pods

```bash
kubectl get pods -n postgresql
```

---

## Check Services

```bash
kubectl get svc -n postgresql
```

---

## Current Primary

```bash
kubectl get cluster shopixy-postgres \
-n postgresql \
-o jsonpath='{.status.currentPrimary}'
```

---

## Backup

```bash
./backup.sh
```

---

## Restore Validation

```bash
./restore.sh <backup-file>
```

---

# 13. Production Status

Current Status:

```text
CloudNativePG            ✓
PostgreSQL 17            ✓
3 Node HA Cluster        ✓
Streaming Replication    ✓
Automatic Failover       ✓
TLS                      ✓
PgBouncer                ✓
Prometheus               ✓
Grafana                  ✓
Backup                   ✓
Restore                  ✓
Google Drive Offsite     ✓
Bootstrap Automation     ✓
```

Overall Assessment:

```text
Production Ready
```

Infrastructure Maturity:

```text
Enterprise Grade
```
