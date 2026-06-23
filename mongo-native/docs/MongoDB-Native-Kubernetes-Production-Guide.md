# MongoDB-Native-Kubernetes-Production-Guide.md

# MongoDB Native Kubernetes Production Guide

## Shopixy Infrastructure Authority

### Version 1.0

---

# Purpose

This document describes the complete deployment of a production-grade MongoDB Replica Set running natively on Kubernetes (K3s).

The goal is to allow a full rebuild of the MongoDB environment on a new VPS without relying on undocumented knowledge.

At the end of this guide the cluster will provide:

* MongoDB Replica Set (3 Nodes)
* Internal Replica Authentication
* User Authentication
* Automated Bootstrap
* Backup & Restore
* Prometheus Monitoring
* Grafana Dashboard
* Production Ready Deployment

---

# Prerequisites

Server Requirements

Recommended:

* 8 vCPU+
* 16 GB RAM+
* SSD Storage

Installed Software:

* Ubuntu Server 24.04 LTS
* K3s
* kubectl
* Helm
* Git

Verify K3s:

```bash
kubectl get nodes
```

Expected:

```text
STATUS: Ready
```

---

# Repository Layout

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

├── monitoring/
│   ├── mongodb-exporter.yaml
│   ├── mongodb-service.yaml
│   ├── mongodb-servicemonitor.yaml
│   └── mongodb-dashboard.json

├── backups/
├── logs/
└── secrets/
```

---

# Step 1 - Create Namespace

File:

namespace.yaml

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: mongo
```

Apply:

```bash
kubectl apply -f namespace.yaml
```

Verify:

```bash
kubectl get ns mongo
```

Expected:

```text
Active
```

---

# Step 2 - Generate Mongo KeyFile

Mongo Replica Set members must authenticate with each other.

Generate:

```bash
openssl rand -base64 756 > secrets/mongo-keyfile
```

Secure:

```bash
chmod 400 secrets/mongo-keyfile
```

Verify:

```bash
ls -l secrets/mongo-keyfile
```

Expected:

```text
-r--------
```

---

# Step 3 - Create Headless Service

File:

mongo-headless-service.yaml

Purpose:

* Stable DNS names
* StatefulSet communication
* Replica Set member discovery

Apply:

```bash
kubectl apply -f mongo-headless-service.yaml
```

Verify:

```bash
kubectl get svc -n mongo
```

Expected:

```text
mongo-headless
```

---

# Step 4 - Bootstrap StatefulSet

Purpose:

Start MongoDB without authentication so bootstrap operations can run.

File:

mongo-statefulset-bootstrap.yaml

Important:

Bootstrap StatefulSet DOES NOT contain:

```yaml
--auth
```

Deploy:

```bash
kubectl apply -f mongo-statefulset-bootstrap.yaml
```

Wait:

```bash
kubectl rollout status statefulset/mongo -n mongo
```

Verify:

```bash
kubectl get pods -n mongo
```

Expected:

```text
mongo-0 Running
mongo-1 Running
mongo-2 Running
```

---

# Step 5 - Initialize Replica Set

Connect:

```bash
kubectl exec -it -n mongo mongo-0 -- mongo
```

Run:

```javascript
rs.initiate({
  _id: "rs0",
  members: [
    {
      _id: 0,
      host: "mongo-0.mongo-headless.mongo.svc.cluster.local:27017"
    },
    {
      _id: 1,
      host: "mongo-1.mongo-headless.mongo.svc.cluster.local:27017"
    },
    {
      _id: 2,
      host: "mongo-2.mongo-headless.mongo.svc.cluster.local:27017"
    }
  ]
})
```

Verify:

```javascript
rs.status()
```

Expected:

```text
PRIMARY
SECONDARY
SECONDARY
```

---

# Step 6 - Create Admin User

Run:

```javascript
use admin

db.createUser({
  user: "mongo-admin",
  pwd: "YOUR_PASSWORD",
  roles: [
    {
      role: "root",
      db: "admin"
    }
  ]
})
```

Verify:

```javascript
db.getUsers()
```

---

# Step 7 - Create Application User

Run:

```javascript
use shopixy

db.createUser({
  user: "shopixy-app",
  pwd: "YOUR_PASSWORD",
  roles: [
    {
      role: "readWrite",
      db: "shopixy"
    }
  ]
})
```

Verify:

```javascript
db.getUsers()
```

---

# Step 8 - Enable Authentication

Replace bootstrap StatefulSet:

```bash
kubectl apply -f mongo-statefulset.yaml
```

Production StatefulSet contains:

```yaml
- --auth
- --keyFile=/workdir/keyfile
```

Restart:

```bash
kubectl rollout status statefulset/mongo -n mongo
```

Verify:

```bash
mongo admin \
-u mongo-admin \
-p PASSWORD \
--authenticationDatabase admin
```

Expected:

Successful login

---

# Step 9 - Automated Bootstrap

Production deployment uses:

```bash
./scripts/bootstrap.sh
```

Bootstrap performs:

1. Namespace Creation
2. Secret Creation
3. Service Deployment
4. Bootstrap StatefulSet Deployment
5. ReplicaSet Initialization
6. Primary Election Verification
7. Admin User Creation
8. Application User Creation
9. Production StatefulSet Deployment
10. Final Validation

Expected Final Output:

```text
BOOTSTRAP COMPLETED SUCCESSFULLY
```

---

# Step 10 - Backup System

Run:

```bash
./scripts/backup.sh
```

Process:

* mongodump
* compression
* manifest generation
* retention cleanup

Output:

```text
backups/mongodb/
```

Verify:

```bash
ls backups/mongodb
```

Expected:

```text
mongodb_backup_*.tar.gz
```

---

# Step 11 - Restore System

Run:

```bash
./scripts/restore.sh \
backups/mongodb/backup.tar.gz
```

Process:

1. Validate Archive
2. Confirmation Prompt
3. Drop Database
4. Restore Database
5. Verify Documents

Expected:

```text
Restore completed successfully
```

---

# Step 12 - MongoDB Exporter

Deploy:

```bash
kubectl apply -f monitoring/mongodb-exporter.yaml
```

Verify:

```bash
kubectl get pods -n mongo
```

Expected:

```text
mongodb-exporter Running
```

Metrics:

```bash
curl http://EXPORTER_IP:9216/metrics
```

Expected:

```text
mongodb_up
mongodb_members_health
mongodb_ss_connections
```

---

# Step 13 - Prometheus Integration

Deploy:

```bash
kubectl apply -f monitoring/mongodb-servicemonitor.yaml
```

Verify:

Prometheus:

```text
Status -> Targets
```

Expected:

```text
mongodb-exporter UP
```

---

# Step 14 - Grafana Dashboard

Import:

```text
monitoring/mongodb-dashboard.json
```

Dashboard:

```text
Shopixy MongoDB Production
```

Panels:

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

Expected:

No "No Data" panels.

---

# Production Validation

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
db.runCommand({
 connectionStatus:1
})
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

Prometheus:

```text
mongodb-exporter UP
```

Grafana:

```text
All Panels Returning Data
```

---

# Final Status

PASS M1 Storage & StatefulSet

PASS M2 Replica Set

PASS M3 Authentication

PASS M4 Backup & Restore

PASS M5 Monitoring & Observability

Result:

MongoDB Native Kubernetes Production Authority Achieved
Version 1.0
