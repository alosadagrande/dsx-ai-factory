---
title: "Deploying DSX AI Factory"
weight: 2
---

This section guides you through deploying the Red Hat build of DSX AI Factory
on an OpenShift management cluster. The deployment follows a fixed sequence of
Helm releases across three namespaces:

| Namespace | What runs there |
|---|---|
| `nico-rest` | NICo REST plane, Temporal, Keycloak RHBK, Crunchy PG (cloud) |
| `nico-system` | NICo Core, Vault, NATS, Crunchy PG (site), RMS |
| `rhbk-operator` | Keycloak operator |

The full sequence is automated by the `Makefile` included in this repository.
The steps below walk through each phase in order.

## Step 1 — Install prerequisite operators

The `prereqs` chart installs the OLM operators that all subsequent releases
depend on.

```bash
make deploy-prereqs
```

Or directly with Helm:

```bash
helm install dsx-ai-factory-prereqs \
  oci://ghcr.io/rh-ecosystem-edge/dsx-ai-factory/charts/dsx-ai-factory-prereqs \
  --version 0.1.0 \
  --namespace nico-system \
  --create-namespace \
  --wait --timeout 15m
```

This installs cert-manager, Crunchy PostgreSQL, RHBK (Keycloak), MetalLB,
External Secrets Operator, and NMState via OLM subscriptions, then waits for
each operator's CRDs to be established.

> **If post-install hooks time out** (MetalLB webhook race): reinstall with
> `--no-hooks` then run manually:
> ```bash
> oc wait --for=condition=Established crd/metallbs.metallb.io --timeout=10m
> oc wait --for=condition=Established crd/nmstates.nmstate.io --timeout=10m
> ```

## Step 2 — Configure MetalLB VIPs for provisioning services

NICo's provisioning services must be reachable by AI Factory nodes over the
provisioning network via MetalLB LoadBalancer IPs. OpenShift Routes cannot
carry UDP traffic, so DHCP (port 67) and DNS (port 53) require LoadBalancer
services.

| Service | Port | Protocol | Purpose |
|---|---|---|---|
| `nico-api` | 443 | TCP | Core gRPC API; IP SAN in the TLS certificate |
| `nico-pxe` | 8080 | TCP | iPXE server and boot artifact serving |
| `unbound` | 53 | UDP+TCP | DNS for the `.forge` provisioning zone |
| `nico-dhcp` | 67 | UDP | DHCP for AI Factory nodes |
| `nico-ssh-console-rs` | 2222 | TCP | SSH console access |

All services share a single VIP. Create an `IPAddressPool` and
`L2Advertisement` in the `metallb-system` namespace:

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: nico-provisioning
  namespace: metallb-system
spec:
  addresses:
    - <provisioning-network-vip>/32
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: nico-provisioning
  namespace: metallb-system
spec:
  ipAddressPools:
    - nico-provisioning
  interfaces:
    - <provisioning-nic>
```

```bash
oc apply -f metallb-provisioning.yaml
```

> **OVN gateway requirement:** Enable local-gateway mode if not already set:
> ```bash
> oc patch network.operator cluster --type merge \
>   -p '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"routingViaHost":true,"ipForwarding":"Global"}}}}}'
> oc rollout status daemonset/ovnkube-node -n openshift-ovn-kubernetes
> ```

> **DHCP relay:** Required when the provisioning VLAN is L3-separated from the
> management cluster. See
> [Network prerequisites](../00-network-prerequisites/).

Or use the Makefile:

```bash
make deploy-dataplane-vip SITE=<name>
```

## Next steps

**Management cluster deployment** — continue in this order:

1. [Deploying cloud infrastructure](../02-cloud-infra/) — Temporal, Keycloak, Crunchy PG cloud
2. [Deploying site infrastructure and Vault](../03-vault/) — Vault HA, NATS, Crunchy PG site
3. [Registering a site and deploying NICo](../04-site-registration/) — NICo Core, site-agent, RMS

Once the management cluster is fully operational, provision AI Factory compute nodes:

- [Deploying RHEL](../02-rhel/)
- [Deploying OpenShift](../03-openshift/)
