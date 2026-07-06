# Edge Specification
## PASS 13.5 — Edge Infrastructure

Version: 1.0
Status: Draft
Related ADR: ADR-001

---

# Purpose

This document defines the functional specification of the Shopixy Edge Platform.

It describes what capabilities the Edge must provide.

Implementation details are intentionally excluded.

Those are implemented through Traefik configuration.

---

# Edge Responsibilities

The Edge Platform is responsible for:

- Receiving all external traffic.
- Routing HTTP traffic.
- Routing HTTPS traffic.
- Routing authorized TCP traffic.
- TLS termination where applicable.
- Middleware execution.
- Request forwarding.
- Traffic segmentation.

The Edge is NOT responsible for:

- Business logic.
- Authentication decisions.
- Authorization rules.
- Database permissions.
- Service discovery.

---

# EntryPoints

The platform shall expose the following logical entry points.

| Name | Protocol | Exposure |
|------|----------|----------|
| web | HTTP | Public |
| websecure | HTTPS | Public |
| postgres | TCP | Authorized Backend |
| redis | TCP | Authorized Backend |
| rabbitmq-amqp | TCP | Authorized Backend |
| rabbitmq-management | HTTPS | Restricted |
| opensearch-api | HTTPS | Authorized Backend |
| opensearch-dashboard | HTTPS | Restricted |
| minio-api | HTTPS | Authorized Backend |
| minio-console | HTTPS | Restricted |

---

# Exposure Classes

Every exposed endpoint belongs to exactly one class.

## Public

Accessible from the Internet.

Examples:

- Storefront
- Public API

---

## Restricted

Accessible only after administrative controls.

Examples:

- Grafana
- Dashboard
- RabbitMQ Management
- MinIO Console

---

## Authorized Backend

Accessible only from trusted backend infrastructure.

Examples:

- PostgreSQL
- Redis
- RabbitMQ AMQP
- OpenSearch API

---

## Internal

Never exposed through the Edge.

Examples:

- Prometheus
- Metrics
- Kubernetes APIs

---

# Backend Strategy

Phase 1

Backend services run outside Kubernetes.

The Edge forwards requests to external backend services.

---

Phase 2

Backend services move into Kubernetes.

No public URLs change.

No DNS changes.

No firewall redesign.

No client changes.

Only routing implementation changes.

---

# Compliance

PASS 13.5 is considered complete only if:

- One Edge Gateway exists.
- All public traffic enters through the Edge.
- Internal services remain ClusterIP.
- TCP routing supports authorized backend traffic.
- Future migration into Kubernetes requires no architectural redesign.
