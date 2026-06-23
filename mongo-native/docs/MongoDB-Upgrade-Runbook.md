# MongoDB Upgrade Runbook

## Shopixy Infrastructure Authority

### MongoDB 4.4 → MongoDB 8.x Migration Guide

---

# Purpose

This document describes the safe migration path from the current Shopixy MongoDB cluster:

```text
Percona Server for MongoDB 4.4.29
```

to a modern MongoDB release.

The objective is:

* Zero Data Loss
* Minimal Downtime
* Rollback Capability
* Production Safe Upgrade

---

# Current State

Current Version:

```text
MongoDB 4.4.29
```

Replica Set:

```text
rs0
```

Members:

```text
mongo-0
mongo-1
mongo-2
```

Authentication:

```text
Enabled
```

Monitoring:

```text
Prometheus
Grafana
Mongo Exporter
```

---

# Critical Rule

MongoDB does NOT support:

```text
4.4 → 7.0
```

or

```text
4.4 → 8.0
```

directly.

Upgrade path must be:

```text
4.4
 ↓
5.0
 ↓
6.0
 ↓
7.0
 ↓
8.0
```

---

# Recommended Strategy

DO NOT perform in-place upgrades on production.

Instead:

```text
Build New Cluster
Migrate Data
Switch Traffic
Retire Old Cluster
```

This is significantly safer.

---

# Option A (Recommended)

Fresh Cluster Migration

---

# Step 1

Create New VPS

Install:

* Ubuntu 24.04
* K3s
* Helm
* kubectl

Deploy:

```text
MongoDB 8.x
```

using the latest version of:

```text
mongo-statefulset.yaml
```

---

# Step 2

Deploy Fresh MongoDB Cluster

Verify:

```javascript
rs.status()
```

Expected:

```text
1 PRIMARY
2 SECONDARY
```

---

# Step 3

Create Users

Create:

```text
mongo-admin
shopixy-app
```

Verify authentication.

---

# Step 4

Take Final Backup From Old Cluster

Run:

```bash
./scripts/backup.sh
```

Verify archive exists.

Expected:

```text
mongodb_backup_xxx.tar.gz
```

---

# Step 5

Transfer Backup

Copy archive:

```bash
scp backup.tar.gz new-server:/tmp/
```

or

```bash
rclone copy
```

from backup storage.

---

# Step 6

Restore Into New Cluster

Run:

```bash
./scripts/restore.sh
```

Verify:

```javascript
db.products.count()
db.orders.count()
```

Document counts must match old cluster.

---

# Step 7

Validation

Application Validation:

* Login
* Products
* Orders
* Checkout
* Background Jobs

Monitoring Validation:

* Grafana
* Prometheus
* Mongo Exporter

---

# Step 8

Cutover

Update:

```text
MongoDB Connection String
```

in:

```text
CommerceHub
Shopixy
POS
Workers
```

Restart applications.

---

# Step 9

Observe

Monitor:

```text
24-48 Hours
```

Watch:

* CPU
* Memory
* Queries
* Replica Health

---

# Step 10

Decommission Old Cluster

After successful validation:

Stop:

```text
MongoDB 4.4 Cluster
```

Archive:

```text
Final Backup
```

Keep for:

```text
30 Days Minimum
```

---

# Option B

In-Place Upgrade

NOT Recommended.

Use only if migration is impossible.

---

# Phase 1

4.4 → 5.0

Upgrade image:

```text
percona/percona-server-mongodb:5.0
```

Rolling restart:

```text
SECONDARY
SECONDARY
PRIMARY
```

Verify:

```javascript
db.version()
```

Expected:

```text
5.0.x
```

---

# Phase 2

Upgrade Feature Compatibility Version

Verify:

```javascript
db.adminCommand({
 getParameter:1,
 featureCompatibilityVersion:1
})
```

Set:

```javascript
db.adminCommand({
 setFeatureCompatibilityVersion:"5.0"
})
```

---

# Phase 3

5.0 → 6.0

Repeat process.

---

# Phase 4

Set FCV 6.0

```javascript
db.adminCommand({
 setFeatureCompatibilityVersion:"6.0"
})
```

---

# Phase 5

6.0 → 7.0

Repeat process.

---

# Phase 6

Set FCV 7.0

```javascript
db.adminCommand({
 setFeatureCompatibilityVersion:"7.0"
})
```

---

# Phase 7

7.0 → 8.0

Repeat process.

---

# Phase 8

Set FCV 8.0

```javascript
db.adminCommand({
 setFeatureCompatibilityVersion:"8.0"
})
```

---

# Rollback Plan

Before EVERY upgrade:

Create:

```bash
./scripts/backup.sh
```

Store:

```text
Local
Remote
```

If failure occurs:

1. Stop Upgrade
2. Restore Backup
3. Roll Back StatefulSet Image
4. Verify Replica Set

---

# Recommended Future State

Target Version:

```text
MongoDB 8.x
```

Replica Set:

```text
3 Members
```

Monitoring:

```text
Prometheus
Grafana
Mongo Exporter
```

Authentication:

```text
Enabled
```

Backup:

```text
Daily Automated
```

Disaster Recovery:

```text
Remote Backup Storage
```

---

# Final Recommendation

For Shopixy:

Recommended Migration Method:

```text
Fresh VPS
Fresh Cluster
Backup
Restore
Traffic Cutover
```

Avoid:

```text
In-Place Multi-Version Upgrade
```

unless absolutely necessary.

This provides the lowest risk and the fastest recovery path.
