# MongoDB Native Kubernetes Production Deployment Guide

## Shopixy Infrastructure Authority

### Version 1.0

---

# Overview

This document describes the complete deployment of the Shopixy MongoDB Native Kubernetes cluster on K3s.

The deployment provides:

* MongoDB Replica Set (3 Nodes)
* Internal Authentication (KeyFile)
* User Authentication
* Automated Bootstrap
* Backup & Restore
* Prometheus Monitoring
* Grafana Dashboard
* Production Ready Kubernetes Deployment

---

# Architecture

Replica Set:

* mongo-0 (Primary)
* mongo-1 (Secondary)
* mongo-2 (Secondary)

Namespace:

```text
mongo
```

Storage:

```text
local-path
```

Replica Set Name:

```text
rs0
```

---

# Project Structure

```text
mongo-native/

├── namespace.yaml
├── mongo-headless-service.yaml
├── mongo-statefulset.yaml
├── mongo-statefulset-bootstrap.yaml

├── jobs/
│   └── create-users.js

├── scripts/
│   ├── bootstrap.sh
│   ├── backup.sh
│   ├── restore.sh

├── secrets/
│   └── mongo-keyfile

├── monitoring/
│   ├── mongodb-exporter.yaml
│   ├── mongodb-service.yaml
│   ├── mongodb-servicemonitor.yaml
│   └── mongodb-dashboard.json

└── backups/
```

---

# Environment Configuration

File:

```text
.env
```

Contains:

* MONGO_REPLICA_SET
* MONGO_ADMIN_USER
* MONGO_ADMIN_PASSWORD
* SHOPIXY_DB
* SHOPIXY_USER
* SHOPIXY_PASSWORD
* BACKUP_RETENTION_DAYS
* BACKUP_REMOTE
* BACKUP_REMOTE_PATH

---

# Deployment Process

## Step 1

Create Namespace

```bash
kubectl apply -f namespace.yaml
```

---

## Step 2

Create Mongo KeyFile

```bash
openssl rand -base64 756 > secrets/mongo-keyfile
chmod 400 secrets/mongo-keyfile
```

---

## Step 3

Create Headless Service

```bash
kubectl apply -f mongo-headless-service.yaml
```

---

## Step 4

Deploy StatefulSet

Bootstrap Mode:

```bash
kubectl apply -f mongo-statefulset-bootstrap.yaml
```

Production Mode:

```bash
kubectl apply -f mongo-statefulset.yaml
```

---

# Automated Bootstrap

Bootstrap script:

```bash
./scripts/bootstrap.sh
```

Performs:

1. Create Namespace
2. Create Secret
3. Deploy Headless Service
4. Deploy Bootstrap StatefulSet
5. Wait For Pods
6. Initialize Replica Set
7. Wait For Primary Election
8. Create Admin User
9. Create Application User
10. Enable Authentication
11. Verify Deployment

---

# Authentication

Admin User:

```text
mongo-admin
```

Role:

```text
root
```

Database:

```text
admin
```

Application User:

```text
shopixy-app
```

Role:

```text
readWrite
```

Database:

```text
shopixy
```

---

# Backup

Script:

```bash
./scripts/backup.sh
```

Features:

* mongodump
* Archive Compression
* Manifest Generation
* Retention Cleanup
* Logging

Output:

```text
backups/mongodb/
```

---

# Restore

Script:

```bash
./scripts/restore.sh
```

Features:

* Archive Validation
* Confirmation Prompt
* Database Drop
* mongorestore
* Verification

Restore Target:

```text
shopixy
```

---

# Monitoring

Mongo Exporter:

```text
percona/mongodb_exporter:0.40.0
```

Port:

```text
9216
```

Namespace:

```text
mongo
```

---

# Prometheus Integration

Components:

* Deployment
* Service
* ServiceMonitor

Verification:

```bash
kubectl get servicemonitor -A
```

Prometheus Target:

```text
mongodb-exporter
```

Expected State:

```text
UP
```

---

# Grafana Dashboard

Dashboard Name:

```text
Shopixy MongoDB Production
```

Metrics:

* MongoDB Status
* Healthy Members
* Primary Nodes
* Secondary Nodes
* Connections
* Operations/sec
* Replica Set Health
* Database Size
* Storage Size
* Index Size

Datasource:

```text
Prometheus
```

---

# Validation Checklist

Replica Set:

```bash
rs.status()
```

Expected:

```text
1 PRIMARY
2 SECONDARY
```

Authentication:

```bash
db.runCommand({connectionStatus:1})
```

Expected:

```text
authenticatedUsers
```

Backup:

```bash
./scripts/backup.sh
```

Expected:

```text
Backup completed successfully
```

Restore:

```bash
./scripts/restore.sh
```

Expected:

```text
Restore completed successfully
```

Monitoring:

Prometheus Target:

```text
UP
```

Grafana:

```text
All Panels Returning Data
```

---

# Final Production Status

Completed:

PASS M1 Storage & StatefulSet
PASS M2 Replica Set
PASS M3 Authentication
PASS M4 Backup & Restore
PASS M5 Monitoring & Observability

Current Status:

MongoDB Native Kubernetes Production Authority Achieved
