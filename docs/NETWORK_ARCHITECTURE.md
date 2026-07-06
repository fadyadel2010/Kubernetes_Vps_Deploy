# ADR-001
# Network Architecture Baseline

**Document ID:** ADR-001

**Title:** Shopixy Network Architecture Baseline

**Version:** 3.0

**Status:** Approved

**Classification:** Architecture Decision Record

**Owner:** Platform Architecture

**Applies To:**

- Kubernetes Infrastructure
- Backend Services
- Databases
- Messaging
- Monitoring
- Storage
- Future Infrastructure Components

---

# Revision History

| Version | Status | Description |
|----------|--------|-------------|
| 1.0 | Initial | Initial baseline |
| 2.0 | Revised | Traffic classification introduced |
| 3.0 | Approved | Enterprise Architecture Baseline |

---

# Purpose

This document defines the permanent networking architecture of the Shopixy Platform.

It establishes architectural rules that every infrastructure component must follow regardless of deployment environment.

This document intentionally defines architectural principles rather than implementation-specific technologies.

Implementation details may evolve over time without changing this architecture.

---

# Architectural Philosophy

The Shopixy platform follows several long-term architectural values.

These values are intentionally independent of Kubernetes, Traefik, MetalLB, cloud providers or any particular technology.

Every future infrastructure decision should reinforce these principles.

---

## Philosophy 1

### Simplicity over Complexity

The platform prefers simple, predictable architectures over clever but difficult-to-maintain solutions.

Operational simplicity always has higher priority than architectural novelty.

---

## Philosophy 2

### Security by Default

No service should become publicly reachable simply because it was deployed.

Exposure must always be an explicit architectural decision.

---

## Philosophy 3

### Infrastructure as Code

Every infrastructure component must exist as version-controlled source code.

Manual production configuration is prohibited except during emergency recovery procedures.

Infrastructure must always be reproducible.

---

## Philosophy 4

### Explicit over Implicit

Network behavior must always be predictable.

Every communication path must be intentionally designed.

Hidden dependencies are unacceptable.

---

## Philosophy 5

### Environment Independence

The architecture must remain identical across:

- Development
- Office Lab
- VPS
- Dedicated Servers
- Multi-node Kubernetes

Infrastructure providers may change.

Architecture must not.

---

## Philosophy 6

### Evolution without Redesign

The architecture should support future services without requiring structural changes.

Examples include:

- Kafka
- ClickHouse
- AI Services
- Event Streaming
- Multi-region deployments

The addition of future services should extend the platform rather than redesign it.

---

# Scope

This ADR defines:

- Networking principles
- Service exposure philosophy
- Traffic categories
- Internal communication model
- Infrastructure boundaries
- Repository standards
- Future architectural constraints

---

# Non Goals

This document intentionally does NOT define:

- Firewall implementation
- VPN implementation
- Kubernetes Network Policies
- TLS implementation
- Secret Management
- Service Mesh
- Backup Strategy
- Disaster Recovery
- High Availability
- Cloud Provider Configuration

Those topics are covered by dedicated Architecture Decision Records and PASS certifications.

---

# Architecture Goals

The networking architecture is designed to achieve the following goals.

## Goal 1

Single and predictable entry point.

---

## Goal 2

Minimal attack surface.

---

## Goal 3

Zero accidental exposure.

---

## Goal 4

Consistent communication model.

---

## Goal 5

Infrastructure portability.

---

## Goal 6

Repeatable deployments.

---

## Goal 7

Operational simplicity.

---

## Goal 8

Long-term maintainability.

---

# Architectural Invariants

The following rules are permanent.

They may only be changed through a future Architecture Decision Record.

---

## Invariant 1

Exactly one official Edge Gateway exists.

---

## Invariant 2

Internal services communicate through Kubernetes Services.

Never Pod IPs.

---

## Invariant 3

Internal services are not directly exposed.

---

## Invariant 4

Infrastructure remains fully reproducible.

---

## Invariant 5

Environment changes must never require architecture redesign.

---

## Invariant 6

Every permanent networking decision must be documented by an ADR.

---

# Decision Log

The following architectural decisions are permanently accepted.

| Decision | Status | Reason |
|----------|--------|--------|
| Single Edge Gateway | Accepted | Simplifies routing and security |
| ClusterIP Internal Services | Accepted | Reduces attack surface |
| Kubernetes DNS | Accepted | Stable service discovery |
| Infrastructure as Code | Accepted | Reproducibility |
| Environment Independence | Accepted | Future portability |
| Explicit Traffic Classification | Accepted | Predictable communication |
| ADR Governance | Accepted | Long-term maintainability |

---

# Architecture Governance

Architecture decisions are governed through ADRs.

An implementation may evolve.

An architectural principle may not.

Changing any architectural invariant requires:

1. New ADR
2. Technical justification
3. Risk assessment
4. Migration strategy
5. Approval

Implementation details never override architectural principles.

---

# Relationship with PASS Certifications

PASS certifications validate implementation.

Architecture Decision Records define design.

Relationship:

ADR

↓

PASS

↓

Implementation

↓

Validation

↓

Certification

Architecture always precedes implementation.

---

# Future ADR Roadmap

The following Architecture Decision Records are planned.

| ADR | Title | Status |
|------|-------|--------|
| ADR-001 | Network Architecture Baseline | Approved |
| ADR-002 | Edge Architecture | Planned |
| ADR-003 | Network Security | Planned |
| ADR-004 | Secrets Management | Planned |
| ADR-005 | High Availability | Planned |
| ADR-006 | Disaster Recovery | Planned |

---

# End of Part 1


# Part 2
# Network Model & Traffic Architecture

---

# Network Architecture Overview

The Shopixy Platform follows a layered networking architecture.

Each layer has a single responsibility.

No component is allowed to bypass layer boundaries.

```
                    Internet
                         │
                Public Requests
                         │
──────────────────────────────────────────
                 Edge Layer
──────────────────────────────────────────
                 Edge Gateway
            HTTP • HTTPS • TCP
──────────────────────────────────────────
          Kubernetes Service Layer
──────────────────────────────────────────
             ClusterIP Services
──────────────────────────────────────────
          Platform Infrastructure
──────────────────────────────────────────
Databases • Messaging • Storage • Monitoring
```

---

# Layer Responsibilities

## Layer 1

Internet

Responsibilities:

- Public Clients
- Mobile Applications
- Browsers
- External APIs

No direct communication with internal services is permitted.

---

## Layer 2

Edge Layer

Responsibilities:

- Traffic entry
- Request routing
- TLS termination (where applicable)
- Authentication integration
- Rate limiting
- Traffic forwarding

The Edge Layer is the only layer allowed to receive external traffic.

---

## Layer 3

Service Layer

Responsibilities:

- Business APIs
- Internal APIs
- Application Services
- Admin Services

All communication occurs through Kubernetes Services.

---

## Layer 4

Infrastructure Layer

Responsibilities:

- PostgreSQL
- MongoDB
- Redis
- RabbitMQ
- OpenSearch
- MinIO

Infrastructure services never receive arbitrary public traffic.

---

# Traffic Classification

Every network request belongs to exactly one traffic category.

---

## Category A

Public Traffic

Origin:

- Browsers
- Mobile Apps
- Public APIs

Protocols:

- HTTP
- HTTPS

Flow:

```
Internet
      │
Edge Gateway
      │
Application Service
```

Characteristics:

- Public
- User-facing
- Internet accessible
- Authentication required where applicable

---

## Category B

Authorized Backend Traffic

Origin:

- ERP Backend
- Background Workers
- Trusted Internal Services
- Integration Servers

Protocols:

- TCP
- HTTPS

Flow:

```
Authorized Backend
         │
    Edge Gateway
         │
Infrastructure Services
```

Characteristics:

- Explicitly authorized
- Infrastructure-controlled
- Never considered anonymous internet traffic
- Subject to dedicated authorization policies

---

## Category C

Internal Kubernetes Traffic

Origin:

Pods inside Kubernetes.

Flow:

```
Pod
 │
ClusterIP
 │
Pod
```

Characteristics:

- Internal only
- Never routed through the Edge
- Uses Kubernetes DNS
- Lowest latency path

---

# Traffic Separation

Traffic categories are intentionally isolated.

Public traffic must never become internal traffic without passing through application logic.

Infrastructure traffic must never be reachable directly by public clients.

Internal cluster traffic must never traverse the Edge Layer.

---

# Access Matrix

| Client | Destination | Path |
|---------|-------------|------|
| Browser | API | Edge Gateway |
| Browser | Storefront | Edge Gateway |
| Browser | Admin Portal | Edge Gateway |
| Browser | Grafana | Edge Gateway (environment-dependent) |
| Browser | Prometheus | Not Allowed |
| Authorized Backend | PostgreSQL | Edge Gateway |
| Authorized Backend | MongoDB | Edge Gateway |
| Authorized Backend | Redis | Edge Gateway |
| Authorized Backend | RabbitMQ | Edge Gateway |
| Authorized Backend | OpenSearch API | Edge Gateway |
| Kubernetes API | PostgreSQL | ClusterIP |
| Kubernetes API | Redis | ClusterIP |
| Kubernetes API | RabbitMQ | ClusterIP |
| Kubernetes API | MongoDB | ClusterIP |
| Kubernetes API | OpenSearch | ClusterIP |
| Kubernetes Jobs | Platform Services | ClusterIP |
| Monitoring Components | Platform Services | ClusterIP |

---

# Service Exposure Policy

The following table defines the permanent exposure rules.

| Service | Service Type | Public | Authorized Backend | Internal Cluster |
|----------|--------------|--------|--------------------|------------------|
| API | ClusterIP | ✔ | ✔ | ✔ |
| Storefront | ClusterIP | ✔ | ✔ | ✔ |
| Admin Portal | ClusterIP | ✔ | ✔ | ✔ |
| PostgreSQL | ClusterIP | ✖ | ✔ | ✔ |
| MongoDB | ClusterIP | ✖ | ✔ | ✔ |
| Redis | ClusterIP | ✖ | ✔ | ✔ |
| RabbitMQ AMQP | ClusterIP | ✖ | ✔ | ✔ |
| RabbitMQ Management | ClusterIP | ✔ (restricted) | ✔ | ✔ |
| OpenSearch Dashboard | ClusterIP | ✔ (restricted) | ✔ | ✔ |
| OpenSearch API | ClusterIP | ✖ | ✔ | ✔ |
| MinIO Console | ClusterIP | ✔ (restricted) | ✔ | ✔ |
| MinIO API | ClusterIP | ✖ | ✔ | ✔ |
| Grafana | ClusterIP | ✔ (restricted) | ✔ | ✔ |
| Prometheus | ClusterIP | ✖ | ✖ | ✔ |

---

# Internal Communication Rules

Every workload inside Kubernetes communicates directly using ClusterIP Services.

Example:

```
API
 │
 ▼
Redis
```

Never:

```
API
 │
 ▼
Edge Gateway
 │
 ▼
Redis
```

The Edge Gateway is reserved for traffic originating outside Kubernetes.

---

# Service Discovery Policy

Every service must use Kubernetes DNS.

Example:

```
postgres-rw.postgresql.svc.cluster.local
```

Never:

- Pod IP
- Cluster IP literals
- Static IP configuration

The platform relies entirely on Kubernetes-native service discovery.

---

# Infrastructure Exposure Rules

Infrastructure components are classified as protected services.

Protected services include:

- PostgreSQL
- MongoDB
- Redis
- RabbitMQ
- OpenSearch
- MinIO

These services:

- Never accept anonymous public traffic.
- Never expose permanent NodePorts.
- Never rely on Pod IPs.
- Are only reachable through approved communication paths.

---

# Edge Gateway Responsibilities

The Edge Gateway is responsible for:

- HTTP Routing
- HTTPS Routing
- TCP Routing
- TLS Management
- Request Forwarding
- Middleware Execution
- Traffic Segmentation
- Connection Entry

The Edge Gateway is NOT responsible for:

- Business Logic
- Database Authentication
- Authorization Decisions
- Secret Management
- Service Discovery
- Data Validation

---

# Authorization Boundary

The Edge Gateway forwards authorized infrastructure traffic.

The mechanism establishing trust between an Authorized Backend and the platform is intentionally defined outside this ADR.

Acceptable implementation examples include:

- Private Networks
- VPN
- Mutual TLS
- IP Allowlisting
- Identity-aware proxies

The architecture intentionally remains implementation independent.

---

# Network Constraints

The following are prohibited:

- Permanent NodePort deployments
- Pod-to-Pod communication via Pod IP
- Multiple Edge Gateways
- Direct public database exposure
- Manual service discovery
- Hardcoded service addresses

---

# Future Evolution

Future infrastructure components inherit this architecture automatically.

Example:

Kafka

↓

ClusterIP

↓

Authorized Backend
OR

↓

Internal Kubernetes

No architectural redesign is required.

The same applies to:

- ClickHouse
- AI Services
- Event Streaming
- Analytics
- Machine Learning workloads

---

# End of Part 2



# Part 3
# Security Governance, Evolution & Certification

---

# Security Philosophy

Security is considered a foundational architectural concern rather than an implementation feature.

Every infrastructure component must assume that all network communication is untrusted until explicitly authorized.

The platform follows the principle of "Security by Design" rather than "Security after Deployment".

---

# Security Principles

## Principle 1

Least Privilege

Every workload shall receive only the permissions required to perform its responsibilities.

No service receives broader access for convenience.

---

## Principle 2

Default Deny

Network communication is denied unless explicitly allowed.

Access must always be intentionally granted.

---

## Principle 3

Zero Trust

Network location never implies trust.

Every communication path must be authenticated and authorized according to the platform security architecture.

---

## Principle 4

Defense in Depth

Security shall be implemented through multiple independent layers including:

- Edge Security
- Firewall
- Kubernetes Network Policies
- Authentication
- Authorization
- Secret Management
- Transport Encryption

Failure of one security layer must not expose the platform.

---

## Principle 5

Single Responsibility

Every security mechanism has one responsibility.

Examples:

Firewall
    Infrastructure boundary

Edge Gateway
    Traffic entry

Network Policy
    Pod communication

Secrets Management
    Credential protection

Authentication
    Identity verification

Authorization
    Permission enforcement

No component replaces another.

---

# Communication Contracts

The following communication rules are permanent architectural contracts.

---

## Rule 1

Application services may communicate directly with infrastructure services only when required by business responsibility.

Example

API

↓

PostgreSQL

Allowed

---

## Rule 2

Application services shall never communicate with infrastructure components they do not own.

Example

Affiliate Service

↓

Inventory Database

Not Allowed
(unless explicitly designed)

---

## Rule 3

Frontend applications never communicate directly with infrastructure services.

Forbidden:

Browser

↓

PostgreSQL

Browser

↓

Redis

Browser

↓

RabbitMQ

---

## Rule 4

Monitoring systems observe infrastructure.

They never participate in business workflows.

---

## Rule 5

Infrastructure services never initiate business requests.

Infrastructure responds.

Applications initiate.

---

## Rule 6

Every new service must explicitly declare:

- What it exposes
- What it consumes
- What it is allowed to reach

No implicit connectivity exists.

---

# Authorization Policy

The architecture distinguishes between:

Public Access

and

Authorized Infrastructure Access.

The mechanism used to establish trust is intentionally implementation-independent.

Approved implementation mechanisms include:

- Private Networking
- VPN
- Mutual TLS
- Identity-aware Proxies
- IP Allowlisting

Future implementations may adopt different technologies without modifying this ADR.

---

# Repository Governance

Infrastructure repositories follow one consistent standard.

Each infrastructure component must contain:

base/

overlays/

docs/

bootstrap.sh

validate.sh

tests/

Every deployment must be reproducible.

Manual configuration is considered temporary unless codified.

---

# Architectural Constraints

The following constraints are mandatory.

---

Constraint 1

Pod IP dependencies are prohibited.

---

Constraint 2

Permanent NodePort exposure is prohibited.

---

Constraint 3

Multiple independent Edge Gateways are prohibited.

---

Constraint 4

Direct anonymous database exposure is prohibited.

---

Constraint 5

Manual infrastructure drift is prohibited.

---

Constraint 6

Architecture principles may only change through an approved ADR.

---

# Implementation Roadmap

The following PASS certifications implement this architecture.

PASS 13.5

Edge Infrastructure

Objectives

- Edge deployment
- External IP strategy
- Edge bootstrap

---

PASS 13.6

Edge Routing

Objectives

- HTTP
- HTTPS
- TCP
- Routing validation

---

PASS 13.7

Infrastructure Firewall

Objectives

- SSH hardening
- Edge exposure
- Authorized backend connectivity
- Production firewall rules

---

PASS 14

Network Security

Objectives

- Kubernetes NetworkPolicy
- Default Deny
- Namespace Isolation
- Service Isolation
- Zero Trust enforcement

Mandatory before Production.

---

PASS 15

Platform High Availability

Objectives

- Edge High Availability
- Pod Disruption Budgets
- Anti-affinity
- Failure tolerance

---

PASS 16

Secrets Management

Objectives

- External Secrets
- Secret Rotation
- Certificate Management
- Secure Secret Distribution

---

PASS 17

Disaster Recovery

Objectives

- Backup validation
- Recovery procedures
- Platform restoration
- Infrastructure recovery testing

---

# Production Readiness Model

The platform reaches Production Certification only when:

ADR-001 Approved

↓

PASS 13 Complete

↓

PASS 14 Complete

↓

PASS 15 Complete

↓

PASS 16 Complete

↓

PASS 17 Complete

↓

Production Certification

---

# Compliance Checklist

The platform must satisfy the following requirements.

Networking

✓ Single Edge Gateway

✓ ClusterIP internal services

✓ Kubernetes DNS

✓ Infrastructure as Code

✓ Explicit traffic classification

Security

✓ Default Deny

✓ Least Privilege

✓ Zero Trust

✓ Defense in Depth

✓ Protected infrastructure

Operations

✓ Reproducible deployments

✓ Repository standardization

✓ Environment independence

✓ Architecture governance

---

# Architecture Decision

Decision

The Shopixy Platform adopts a unified network architecture centered around a single Edge Gateway, protected internal services, Infrastructure as Code, explicit traffic classification, and long-term architectural governance through ADRs.

Consequences

Positive

- Consistent deployments
- Predictable networking
- Easier operations
- Lower attack surface
- Future scalability
- Simplified onboarding
- Easier auditing

Trade-offs

- Requires disciplined governance
- Requires dedicated security implementation
- Initial setup is more structured
- Future changes require ADR review

These trade-offs are intentionally accepted in exchange for long-term platform stability.

---

# ADR Approval

Document

ADR-001

Title

Network Architecture Baseline

Status

Approved

Supersedes

None

Related PASS

PASS 13.4

Related ADRs

ADR-002 Edge Architecture

ADR-003 Network Security

ADR-004 Secrets Management

ADR-005 High Availability

ADR-006 Disaster Recovery

---

# Final Statement

This Architecture Decision Record establishes the permanent networking foundation of the Shopixy Platform.

Future infrastructure may extend this architecture but shall not violate the architectural principles defined herein without a formally approved successor ADR.

Implementation technologies are expected to evolve.

Architectural principles are expected to remain stable.

---

# End of ADR-001
