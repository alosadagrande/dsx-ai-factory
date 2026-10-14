---
title: "Network prerequisites"
weight: 0
---

For hardware topology — switch models (SN5610 Spectrum-X, SN2201 OOB),
physical cabling, and scaling units — refer to the applicable
[NVIDIA Enterprise AI Factory Reference Architecture](https://docs.nvidia.com/reference-architectures/index.html)
for your platform. This page covers the **logical network configuration**
required before deploying NICo: VLANs, SVIs, management cluster subinterfaces,
and DHCP relay. Switch vendor documentation is required for non-Spectrum platforms.

Before deploying NICo and RMS, configure three network planes on the ToR
switch and the management cluster. NICo uses each plane at a different
lifecycle stage — understanding which plane is active when helps avoid the
most common provisioning failures.

## Three network planes

| Plane | Purpose | Lifecycle |
|---|---|---|
| **OOB / BMC** | Redfish API access to node BMCs and switches | Always active |
| **Provisioning** | DHCP, PXE boot, DNS during discovery and OS install | Active until tenant assignment |
| **Tenant (VNI)** | North-south traffic after instance allocation | NICo programs automatically |

**Key lifecycle point:** a node's provisioning NIC port is placed on the
provisioning VLAN at boot time. When NICo assigns a tenant instance, it
automatically re-programs the switch port to the tenant's VNI — the NIC
becomes a north-south NIC in the tenant's virtual network. Users do not
configure tenant VNIs manually; see [VNI propagation](#vni-propagation)
below.

![Network planes](/images/networking-planes.svg)

## ToR switch configuration

DSX AI Factory uses NVIDIA Spectrum switches. The NVUE
commands below apply to Cumulus Linux on Spectrum hardware. For other
vendors, the same logical operations (add VLAN, create SVI, assign ports)
are required — consult your switch vendor documentation.

> **Before making changes** on a Cumulus switch, open a BMC console session
> as a safety net, then checkpoint the current config:
> ```bash
> nv config save
> nv config checkpoint
> ```
> Always apply with `--timeout` so the switch auto-reverts if connectivity drops.

### Add the provisioning VLAN and SVI

Run on both ToR switches. Each switch gets a unique physical SVI address;
a shared virtual gateway address (VRR — Cumulus Virtual Router Redundancy)
provides a stable default gateway for nodes on the provisioning VLAN.

```bash
# Add provisioning VLAN to the bridge
nv set bridge domain br_default vlan <provisioning-vlan-id>

# SVI with VRR — run on switch 1
nv set interface vlan<provisioning-vlan-id> ip address <switch1-svi-ip>/<prefix>
nv set interface vlan<provisioning-vlan-id> ip vrr address <virtual-gateway-ip>/<prefix>
nv set interface vlan<provisioning-vlan-id> ip vrr mac-address <shared-vrr-mac>
nv set interface vlan<provisioning-vlan-id> ip vrr state up

# SVI with VRR — run on switch 2 (different physical IP, same virtual gateway)
nv set interface vlan<provisioning-vlan-id> ip address <switch2-svi-ip>/<prefix>
nv set interface vlan<provisioning-vlan-id> ip vrr address <virtual-gateway-ip>/<prefix>
nv set interface vlan<provisioning-vlan-id> ip vrr mac-address <shared-vrr-mac>
nv set interface vlan<provisioning-vlan-id> ip vrr state up
```

The VRR MAC must be identical on both switches so ARP is consistent across
failover. Choose a MAC in the `00:00:5e:00:01:xx` range (VRRP well-known range).

### Assign switch ports

**Management cluster uplink** — trunk VLAN so the cluster can place a
subinterface on the provisioning VLAN:

```bash
nv set interface <management-uplink-port> bridge domain br_default vlan <provisioning-vlan-id>
```

**AI Factory node provisioning ports** — access VLAN so nodes boot into
the provisioning broadcast domain:

```bash
# Repeat for each node's provisioning NIC uplink
nv set interface <node-provisioning-port> bridge domain br_default access <provisioning-vlan-id>
```

### Apply and save

```bash
nv config apply --timeout 120
# Verify connectivity, then confirm to keep:
nv config apply confirm
nv config save
```

> **After provisioning completes:** remove the access VLAN assignment from
> each node port and configure it for the north-south fabric. NICo's
> workflow automates the VNI re-programming; the underlying switch port
> assignment update is automated by NICo's spectrum-fabric provider
> via NVUE REST API on Spectrum switches.

## DHCP relay

DHCP is a broadcast protocol. The `nico-dhcp` service listens on a unicast
MetalLB VIP — broadcasts from AI Factory nodes will not reach it without a
relay.

**Relay is required** in the standard isolated topology where the
provisioning VLAN is L3-separated from the management cluster (different
subnets, routed through the SVI). Configure the relay on the provisioning
VLAN SVI to forward broadcasts to the `nico-dhcp` VIP:

```bash
# Cumulus NVUE — on the provisioning VLAN SVI (both switches)
nv set interface vlan<provisioning-vlan-id> ip dhcp-relay server-ip <nico-dhcp-vip>
nv set interface vlan<provisioning-vlan-id> ip dhcp-relay gateway-interface vlan<provisioning-vlan-id>
nv config apply --timeout 120
nv config apply confirm
nv config save
```

> **Relay is NOT needed** if the management cluster's provisioning
> subinterface is L2-adjacent to the AI Factory nodes — i.e., the
> management cluster has an interface directly on the provisioning VLAN
> and is in the same broadcast domain. In that case DHCP broadcasts reach
> the MetalLB VIP directly.

NICo matches DHCP DISCOVERs using the `giaddr` field set by the relay.
Without `giaddr`, NICo cannot associate the DISCOVER with the correct site
segment. The relay is also required on the **OOB/BMC VLAN SVI** if BMC
DHCP is served by NICo (not the case for sites where BMCs have static IPs).

## Management cluster — provisioning subinterface

The management cluster needs a VLAN subinterface to join the provisioning
broadcast domain. Apply a `NodeNetworkConfigurationPolicy` via NMState,
targeting the cluster node by hostname:

```yaml
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: nico-provisioning-vlan
spec:
  nodeSelector:
    kubernetes.io/hostname: <management-node-hostname>
  desiredState:
    interfaces:
      - name: <bond-or-nic>.<provisioning-vlan-id>
        type: vlan
        state: up
        vlan:
          base-iface: <bond-or-nic>
          id: <provisioning-vlan-id>
        ipv4:
          enabled: true
          dhcp: false
          address:
            - ip: <management-cluster-provisioning-ip>
              prefix-length: <prefix-length>
        ipv6:
          enabled: false
```

```bash
oc apply -f nico-provisioning-vlan-nncp.yaml
oc get nncp nico-provisioning-vlan -w   # wait for: Available
```

The MetalLB `L2Advertisement` must reference this subinterface so the NICo
VIP is announced on the provisioning VLAN only — not on the primary cluster
NIC. See [Deploying DSX AI Factory](../01-dsx-ai-factory/) for the
`IPAddressPool` and `L2Advertisement` configuration.

## VNI propagation

![Networking - VNI Propagation](/images/networking-vni-propagation.svg)

Once a tenant instance is allocated in NICo, NICo automatically programs
the switch fabric to assign the node's NIC to the tenant's VNI. The node
exits the provisioning VLAN and joins the tenant's virtual network as a
north-south NIC. This uses NICo's VPC and Subnet model — VPCs map to VNIs,
and NICo drives the data-plane update via NVUE REST API directly (spectrum-fabric provider).

Users do not configure VNIs manually. For details on the VPC and Subnet
model, see the
[NICo IP and network configuration](https://docs.nvidia.com/infra-controller/documentation/provisioning-day-0/ip-and-network-configuration)
documentation.
