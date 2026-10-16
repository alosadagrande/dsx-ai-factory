---
title: "Deployment"
weight: 3
description: "Network setup, installing NICo and RMS, provisioning RHEL and OpenShift"
---

Deploying the Red Hat build of DSX AI Factory involves two distinct phases:

**Phase 1 — Management cluster setup** installs the NICo and RMS control plane
on an existing OpenShift cluster. NICo manages the full lifecycle of AI Factory
nodes from this cluster.

**Phase 2 — Workload provisioning** uses NICo to provision RHEL or OpenShift
on the bare-metal AI Factory compute nodes.

## Deployment sequence

| Step | What it does | Helm release / namespace |
|---|---|---|
| [Network prerequisites](./00-network-prerequisites/) | Configure VLANs, MetalLB VIPs, NMState subinterface | — |
| [Deploying DSX AI Factory](./01-dsx-ai-factory/) | Install OLM operators; configure MetalLB VIPs | `prereqs` → `nico-system` |
| [Deploying cloud infrastructure](./02-cloud-infra/) | Temporal, Keycloak RHBK, Crunchy PG | `cloud-infra` → `nico-rest` |
| [Deploying site infrastructure and Vault](./03-vault/) | Vault HA, NATS, Crunchy PG site | `site-infra` → `nico-system` |
| [Registering a site and deploying NICo](./04-site-registration/) | NICo Core, site-agent, RMS | `nico`, `rack-manager` → `nico-system` |
| [Deploying RHEL](./02-rhel/) | NICo provisions RHEL on AI Factory nodes | — |
| [Deploying OpenShift](./03-openshift/) | NICo provisions RHCOS workers | — |

All steps after network prerequisites are automated by the `Makefile` in this
repository. See `make help` for a full list of targets.
