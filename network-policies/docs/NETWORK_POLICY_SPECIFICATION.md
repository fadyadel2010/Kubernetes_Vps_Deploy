# Network Policy Specification
## PASS 14.1 — East-West Traffic Isolation

Version: 1.0

Status: Draft

Related ADR: ADR-001

---

# Purpose

This document defines the network isolation model for the Shopixy Kubernetes Platform.

It specifies which workloads are allowed to communicate with each other.

Implementation details are intentionally excluded.

Those are implemented through Kubernetes NetworkPolicy resources.

---

# Objectives

The platform shall:

- Isolate workloads by namespace.
- Prevent unrestricted pod-to-pod communication.
- Allow only explicitly authorized traffic.
- Preserve all existing public ingress through Traefik.
- Preserve all existing TCP routing through Traefik.

---

# Security Model

The platform follows a Zero Trust model.

Communication is denied unless explicitly allowed.

---

# Traffic Classes

Traffic belongs to one of four categories.

## Public Ingress

Traffic entering through Traefik.

Examples:

- Storefront
- Public APIs
- Grafana
- Prometheus
- Dashboard

---

## East-West

Communication between workloads inside Kubernetes.

Examples:

- API → PostgreSQL
- API → Redis
- API → RabbitMQ
- API → OpenSearch
- API → MinIO

---

## Infrastructure

Communication required for cluster operation.

Examples:

- DNS
- Metrics
- Health checks

---

## External

Traffic leaving the cluster.

Examples:

- SMTP
- Payment gateways
- Amazon SP-API
- Google APIs

---

# Isolation Rules

Namespaces are isolated.

Cross-namespace communication must be explicitly authorized.

Database workloads never accept unrestricted traffic.

Messaging systems never accept unrestricted traffic.

Storage services never accept unrestricted traffic.

---

# Default Behavior

The final state of the platform shall use Default Deny.

Allow rules are added incrementally.

Deployment follows:

Phase 1

Create all allow policies.

Phase 2

Validate connectivity.

Phase 3

Enable namespace Default Deny.

---

# Non Goals

Network Policies do NOT replace:

- Authentication
- Authorization
- TLS
- Secrets
- RBAC

---

# Compliance

PASS 14.1 is complete only if:

- Every production namespace is protected.
- Cross-namespace traffic is explicitly defined.
- Infrastructure traffic remains operational.
- Public ingress continues to function.
- TCP routing through Traefik continues to function.
