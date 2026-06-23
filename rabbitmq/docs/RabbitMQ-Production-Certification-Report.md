# RabbitMQ Production Certification Report

## Overview

تم بناء وتشغيل RabbitMQ Production Cluster على Kubernetes (K3s) كجزء من البنية التحتية الأساسية لمنصة Shopixy.

الهدف من المشروع كان إنشاء RabbitMQ Enterprise-Grade Deployment يحقق:

* High Availability
* Persistent Storage
* Topology as Code
* Infrastructure as Code
* TLS Encryption
* Monitoring
* Backup & Restore
* Disaster Recovery
* Automated Bootstrap

---

# Infrastructure

## Kubernetes Platform

* K3s
* Single Node Production Deployment
* Local Path Storage

## RabbitMQ Version

* RabbitMQ 4.2.6
* Erlang 27.3.4.11

## Cluster Topology

RabbitMQ Cluster consists of:

* rabbitmq-server-0
* rabbitmq-server-1
* rabbitmq-server-2

Replica Count:

3 Nodes

Cluster Type:

Quorum-based RabbitMQ Cluster

---

# Resource Allocation

Requests:

* CPU: 500m
* Memory: 4Gi

Limits:

* CPU: 2 Core
* Memory: 4Gi

Cluster Total Reserved Memory:

12Gi

---

# Storage

Persistent Volumes:

* 50Gi per node

Total Allocated Storage:

150Gi

Storage Class:

local-path

Persistence:

StatefulSet + PVC

---

# RabbitMQ Configuration

cluster_partition_handling = autoheal

vm_memory_high_watermark.relative = 0.6

disk_free_limit.relative = 1.0

collect_statistics_interval = 10000

---

# Topology as Code

VHost:

shopixy

Application User:

shopixy-app

Permissions:

Configure: .*
Write: .*
Read: .*

Exchange:

shopixy.events

Type:

topic

Queues:

* orders
* products
* notifications

Queue Type:

quorum

Bindings:

orders.* -> orders

products.* -> products

notifications.* -> notifications

---

# Monitoring

Prometheus Integration:

Enabled

Metrics Endpoint:

HTTPS

Port:

15691

ServiceMonitor:

rabbitmq-servicemonitor

Grafana Dashboard:

Operational

Monitoring Status:

Healthy

---

# TLS Implementation

Certificate Manager:

Installed

Root CA:

rabbitmq-ca

Server Certificate:

rabbitmq-server-cert

Management HTTPS:

15671

AMQPS:

5671

Prometheus TLS:

15691

TLS Status:

Operational

---

# Backup Strategy

Script:

scripts/backup.sh

Backed Up Data:

* Definitions
* Cluster Metadata
* RabbitMQ Node Data

Storage:

Local Archive

Cloud Copy:

Google Drive (Rclone)

Retention:

7 Days

---

# Restore Strategy

Script:

scripts/restore.sh

Capabilities:

* Full Cluster Recovery
* StatefulSet Recovery
* PVC Data Recovery
* Definitions Import

Recovery Type:

Disaster Recovery

---

# Automation

Bootstrap Script:

bootstrap.sh

Capabilities:

* Namespace Creation
* Operator Validation
* Cluster Deployment
* Topology Deployment
* Monitoring Deployment
* Validation Checks

---

# Validation Results

Cluster Status:

PASS

Quorum Queues:

PASS

TLS:

PASS

Monitoring:

PASS

Backup:

PASS

Restore:

PASS

Bootstrap:

PASS

Production Readiness:

CERTIFIED
