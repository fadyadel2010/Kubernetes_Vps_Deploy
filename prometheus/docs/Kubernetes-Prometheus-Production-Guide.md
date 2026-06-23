Kubernetes Prometheus Production Guide
# Kubernetes Prometheus Production Guide

## Overview

This guide documents the deployment of a production-ready Prometheus monitoring stack on a K3s Kubernetes cluster.

The stack includes:

- Prometheus Operator
- Prometheus Server
- Node Exporter
- kube-state-metrics
- Persistent Storage
- Traefik Ingress
- Grafana Integration

The deployment uses Helm and follows Kubernetes best practices.

---

# Environment

## Server Specifications

| Resource | Value |
|-----------|--------|
| CPU | 24 vCPU |
| Memory | 94 GB |
| Storage | 548 GB |
| OS | Ubuntu Server |
| Kubernetes | K3s |
| StorageClass | local-path |

---

# Architecture

Server
│
├── K3s
│
├── Prometheus Operator
│
├── Prometheus
│
├── Node Exporter
│
├── kube-state-metrics
│
└── Grafana

Prometheus collects:

- Kubernetes metrics
- Node metrics
- Pod metrics
- Container metrics

Grafana visualizes all collected metrics.

---

# Install Helm

Install Helm:

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

Verify installation:

helm version
Configure Kubectl Access

Create kubeconfig:

mkdir -p ~/.kube

sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config

sudo chown $(id -u):$(id -g) ~/.kube/config

chmod 600 ~/.kube/config

Verify:

kubectl --kubeconfig ~/.kube/config get nodes

Expected:

NAME            STATUS   ROLES           AGE
shopixyserver   Ready    control-plane
Add Helm Repository
helm repo add prometheus-community \
https://prometheus-community.github.io/helm-charts

helm repo update

Verify:

helm search repo prometheus
Create Namespace
kubectl create namespace prometheus

Verify:

kubectl get ns
Custom Helm Values

Create:

custom-values.yaml

grafana:
  enabled: false

alertmanager:
  enabled: false

prometheus:
  prometheusSpec:
    retention: 15d

    resources:
      requests:
        cpu: 200m
        memory: 1Gi

      limits:
        cpu: 1000m
        memory: 2Gi

    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes:
            - ReadWriteOnce

          resources:
            requests:
              storage: 20Gi

Install Prometheus Stack
KUBECONFIG=~/.kube/config helm install prometheus \
prometheus-community/kube-prometheus-stack \
-n prometheus \
-f custom-values.yaml

Verify:

helm list -n prometheus

Expected:

STATUS: deployed
Verify Pods
kubectl get pods -n prometheus

Expected components:

Prometheus Operator
Prometheus Server
Node Exporter
kube-state-metrics

All pods should be:

Running
Verify Persistent Storage

Check PVC:

kubectl get pvc -n prometheus

Expected:

STATUS: Bound

Check PV:

kubectl get pv
Troubleshooting
Node Exporter CrashLoopBackOff

Problem:

listen tcp 0.0.0.0:9100:
bind: address already in use

Cause:

Existing Docker Node Exporter was already using port 9100.

Check:

docker ps

Fix:

docker stop infra-node-exporter

docker rm infra-node-exporter

Delete failed pod:

kubectl delete pod <node-exporter-pod> -n prometheus

Verify:

kubectl get pods -n prometheus

Expected:

1/1 Running
Prometheus Targets

Access:

http://prometheus.local/targets

All targets should show:

UP

Key targets:

apiserver
kubelet
coredns
kube-state-metrics
node-exporter
prometheus
Create Prometheus Ingress

File:

prometheus-ingress.yaml

apiVersion: networking.k8s.io/v1
kind: Ingress

metadata:
  name: prometheus
  namespace: prometheus

spec:
  ingressClassName: traefik

  rules:
    - host: prometheus.local

      http:
        paths:
          - path: /
            pathType: Prefix

            backend:
              service:
                name: prometheus-kube-prometheus-prometheus

                port:
                  number: 9090

Apply:

kubectl apply -f prometheus-ingress.yaml

Verify:

kubectl get ingress -A

Expected:

prometheus.local
Windows Hosts File

Edit:

C:\Windows\System32\drivers\etc\hosts

Add:

192.168.1.50 prometheus.local

Access:

http://prometheus.local
Verify Metrics Collection

Example PromQL queries:

up
node_memory_MemAvailable_bytes
node_cpu_seconds_total
rate(node_cpu_seconds_total[5m])
Grafana Integration

Prometheus datasource URL:

http://prometheus-kube-prometheus-prometheus.prometheus.svc.cluster.local:9090

Verify datasource:

Data source is working
Dashboard

Recommended Dashboard:

Node Exporter Full

Dashboard ID:

1860

Metrics Included:

CPU Usage
Memory Usage
Disk Usage
Filesystem Usage
Network Traffic
System Load
Uptime
Production Notes

Current Production Features:

Persistent Storage
Resource Requests
Resource Limits
15 Day Retention
Prometheus Operator
Traefik Ingress
Kubernetes Service Discovery

Future Improvements:

Alertmanager
Email Alerts
Slack Alerts
TLS / HTTPS
Authentication
Backup Strategy
Long-Term Storage
Remote Write
Repository Structure
prometheus/
│
├── docs/
│   └── Kubernetes-Prometheus-Production-Guide.md
│
├── custom-values.yaml
│
└── prometheus-ingress.yaml
Deployment Status

Status: Production v1

Components:

Prometheus Operator
Prometheus Server
Node Exporter
kube-state-metrics
Persistent Storage
Traefik Ingress
Grafana Integration

Deployment completed successfully.
