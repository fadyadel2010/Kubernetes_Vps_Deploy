# Shopixy Redis Production Stack

## Final Infrastructure Documentation

Version: 1.0
Status: Production Ready
Date: June 2026

---

# Overview

تم بناء Redis Production Stack كاملة على Kubernetes باستخدام Redis Operator من Opstree بهدف توفير:

* High Availability
* Automatic Failover
* Persistent Storage
* Authentication
* Monitoring
* Backup & Restore
* Disaster Recovery
* Fully Automated Bootstrap

المنظومة مصممة لتشغيل Redis كخدمة Production ضمن بنية Shopixy Infrastructure.

---

# Architecture

## Redis Replication

Cluster Size:

```text
redis-0  -> Master
redis-1  -> Replica
redis-2  -> Replica
```

تم استخدام:

```text
RedisReplication
```

من Redis Operator.

خصائص التصميم:

* 3 Nodes
* Persistent Volumes
* Automatic Replica Re-Sync
* Exporter Enabled

---

## Authentication

تم تفعيل Password Authentication الرسمية الخاصة بالـ Operator.

Secret:

```text
redis-auth
```

Key:

```text
password
```

الـ Redis لا تسمح بأي اتصال غير موثق.

اختبار:

```bash
redis-cli ping
```

Expected:

```text
NOAUTH Authentication required
```

ثم:

```bash
redis-cli -a PASSWORD ping
```

Expected:

```text
PONG
```

---

## Sentinel High Availability

تم تشغيل:

```text
RedisSentinel
```

بعدد:

```text
3 Sentinel Nodes
```

Topology:

```text
sentinel-0
sentinel-1
sentinel-2
```

Master Group:

```text
mymaster
```

Quorum:

```text
2
```

---

## Automatic Failover

تم اختبار Failover فعليًا.

تم حذف:

```bash
kubectl delete pod redis-0
```

وقامت Sentinel تلقائيًا بـ:

* اكتشاف سقوط الـ Master
* انتخاب Replica جديدة
* تحويلها إلى Master
* إعادة توصيل بقية Replicas

نجح الاختبار بالكامل.

---

# Monitoring

تم تشغيل:

```text
redis-exporter
```

داخل جميع Pods.

Metrics Source:

```text
Prometheus
```

تم إنشاء:

```text
ServiceMonitor
```

ليتم اكتشاف Redis تلقائيًا.

---

# Grafana Dashboard

تم بناء Dashboard مخصصة لـ Redis.

تشمل:

## Availability

* Redis Up
* Sentinel Status

## Memory

* Used Memory
* Max Memory
* Fragmentation Ratio

## Performance

* Commands/sec
* Ops/sec
* Network Traffic

## Persistence

* RDB Status
* AOF Status
* Last Save

## Replication

* Master Status
* Replica Count
* Replication Health

## Sentinel

* Sentinel Count
* Replica Discovery
* Quorum Status

---

# Backup Strategy

تم تصميم Backup Production Script.

File:

```text
scripts/backup.sh
```

---

## Backup Source

لا يتم أخذ Backup من الـ Master.

يتم اكتشاف Replica تلقائيًا.

مثال:

```text
redis-1
```

أو:

```text
redis-2
```

---

## Backup Contents

يتم نسخ:

```text
dump.rdb
```

و:

```text
appendonlydir/
```

ويشمل:

```text
appendonly.aof.base.rdb
appendonly.aof.incr.aof
appendonly.aof.manifest
```

---

## Validation

يتم التحقق من:

* وجود الملفات
* صحة dump.rdb
* حجم الأرشيف

---

## Compression

ينتج:

```text
redis_backup_TIMESTAMP.tar.gz
```

---

# Google Drive Backup

تم دمج:

```text
rclone
```

مع:

```text
Google Drive
```

Remote:

```text
RedisBackup
```

Path:

```text
shopixy-backups/redis
```

---

# Restore Strategy

ملف:

```text
scripts/restore.sh
```

---

## Restore Process

الخطوات:

1. Extract Backup
2. Stop Redis
3. Restore Master PVC
4. Clean Replica PVCs
5. Start Redis
6. Replica Re-Sync
7. Validate Replication
8. Restart Sentinel
9. Sentinel Rediscovery

---

## Disaster Recovery

تم اختبار Restore فعليًا.

النتيجة:

* البيانات عادت بنجاح
* Replication عادت
* Sentinel أعادت اكتشاف الـ Master
* Failover استمر بالعمل

---

# Bootstrap Automation

ملف:

```text
scripts/bootstrap.sh
```

---

## Purpose

تشغيل كامل Redis Stack من الصفر.

---

## What Bootstrap Does

1. Validate Environment
2. Create Namespace
3. Validate Operator
4. Validate Secret
5. Deploy Redis
6. Wait Redis Ready
7. Deploy Sentinel
8. Wait Sentinel Ready
9. Deploy Monitoring
10. Run Production Validation

---

## Production Validation

يتحقق من:

### Authentication

```text
NOAUTH
```

ثم:

```text
PONG
```

---

### Replication

```text
role:master
connected_slaves:2
```

---

### Sentinel

```text
num-slaves:2
num-other-sentinels:2
```

---

### Monitoring

يتحقق من:

```text
ServiceMonitor
```

---

# Directory Structure

```text
redis/
│
├── namespace.yaml
├── redis-replication.yaml
├── redis-sentinel.yaml
│
├── monitoring/
│   └── redis-servicemonitor.yaml
│
├── scripts/
│   ├── bootstrap.sh
│   ├── backup.sh
│   └── restore.sh
│
├── backups/
├── logs/
│
├── redis-operator/
│
└── .env
```

---

# New VPS Deployment Procedure

عند شراء VPS جديد:

## Step 1

Install:

```text
Ubuntu
Docker
K3s
Helm
kubectl
rclone
```

---

## Step 2

Clone Repository

```bash
git clone <repository>
cd redis
```

---

## Step 3

Configure Google Drive

```bash
rclone config
```

Verify:

```bash
rclone lsd RedisBackup:
```

---

## Step 4

Create .env

Example:

```bash
REDIS_PASSWORD=<PASSWORD>

BACKUP_RETENTION_DAYS=7

BACKUP_REMOTE=RedisBackup
BACKUP_REMOTE_PATH=shopixy-backups/redis
```

---

## Step 5

Bootstrap Stack

```bash
chmod +x scripts/bootstrap.sh

./scripts/bootstrap.sh
```

Expected:

```text
Redis Production Stack Ready
```

---

## Step 6 (Optional)

Restore Latest Backup

```bash
./scripts/restore.sh \
backups/redis/latest_backup.tar.gz
```

---

## Step 7

Validate

```bash
kubectl get pods -n redis
```

Expected:

```text
redis-0
redis-1
redis-2

sentinel-0
sentinel-1
sentinel-2
```

All Running.

---

# Operational Runbooks

## Test Redis

```bash
kubectl exec -it -n redis redis-0 -- \
redis-cli -a PASSWORD ping
```

Expected:

```text
PONG
```

---

## Test Failover

```bash
kubectl delete pod redis-0 -n redis
```

Verify Sentinel elects a new Master.

---

## Run Backup

```bash
./scripts/backup.sh
```

---

## Restore Backup

```bash
./scripts/restore.sh archive.tar.gz
```

---

# Final Status

Infrastructure Components:

```text
R1 Operator                  COMPLETE
R2 Replication               COMPLETE
R3 Monitoring                COMPLETE
R4 Authentication            COMPLETE
R4.5 Sentinel HA             COMPLETE
R5.1 Backup                  COMPLETE
R5.2 Restore                 COMPLETE
R5.3 Google Drive Backup     COMPLETE
R6 Bootstrap Automation      COMPLETE
```

Production Readiness:

```text
READY FOR PRODUCTION
```
