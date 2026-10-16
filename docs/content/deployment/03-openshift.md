---
title: "Deploying OpenShift"
weight: 7
---

NICo provisions OpenShift worker nodes on AI Factory bare-metal compute nodes
by installing RHCOS and delivering the worker ignition from an existing
OpenShift workload cluster. The management cluster runs NICo; the workload
cluster is built on AI Factory nodes.

This follows the same discovery and hardware validation flow as RHEL
provisioning — the difference is that NICo boots the RHCOS live installer via
iPXE and passes the worker ignition URL in kernel arguments.

## Prerequisites

- Management cluster with NICo and RMS running (see [Deploying DSX AI Factory](../01-dsx-ai-factory/))
- AI Factory compute nodes validated by NICo (`Ready` state)
- A target OpenShift workload cluster with control plane already bootstrapped
- The workload cluster's Machine Config Server (MCS) reachable from the provisioning network (`https://api-int.<cluster-domain>:22623`)
- RHCOS live boot artifacts accessible via `nico-pxe` (kernel, initramfs, rootfs)

## How NICo provisions RHCOS workers

The discovery, Scout boot, and hardware validation phases are identical
to RHEL provisioning — see the
[provisioning flow](../../overview/#provisioning-flow) in
the Architecture section. After validation, the node enters `Ready` state.

NICo then uses its **InlineIpxe** OS variant to boot the RHCOS live
installer. Ignition is delivered via kernel arguments — not through
NICo's `user_data` field (which is cloud-init only and ignored by RHCOS).

The provisioning sequence:

1. NICo boots the node to the RHCOS live environment via iPXE
2. The live environment runs `coreos-installer` using the `coreos.inst.*`
   kernel arguments, writing RHCOS to the node's primary disk
3. The node reboots from disk; RHCOS first-boot fetches the worker ignition
   from the MCS (`ignition.config.url`) and applies it
4. The node registers with the workload cluster as a new worker

## Step 1 — Register the RHCOS OS definition

RHCOS OS definition configuration uses iPXE templates with kernel arguments
for coreos-installer. This requires additional iPXE template parameters
beyond the basic OS record. See:

```bash
nico-admin-cli operating-system create --help
nico-admin-cli ipxe-template --help
```

Refer to the [NICo ingesting hosts documentation](https://docs.nvidia.com/infra-controller/documentation/provisioning-day-0/ingesting-hosts) for the full InlineIpxe workflow.

Once created, verify the OS record:

```bash
nico-admin-cli operating-system show
nico-admin-cli operating-system show <os-id>
```

## Step 2 — Create an instance type for OpenShift workers

Create an instance type for RHCOS workers:

```bash
nico-admin-cli instance-type create --name "openshift-worker"
# see: nico-admin-cli instance-type create --help for full options
```

Associate validated machines with this instance type:

```bash
nico-admin-cli instance-type associate <instance-type-id> <machine-id>
# Multiple machines (comma-separated, no spaces):
nico-admin-cli instance-type associate <instance-type-id> <id1>,<id2>
```

## Step 3 — Allocate instances

Allocate an instance for each machine to trigger RHCOS installation:

```bash
nico-admin-cli instance allocate \
  --prefix-name <name> \
  --subnet <cidr>
# see: nico-admin-cli instance allocate --help for full options
```

NICo will power-cycle the node, boot it to the RHCOS live installer via iPXE,
and run `coreos-installer`. Monitor progress:

```bash
# Show machine state
nico-admin-cli machine show

# View provisioning events
oc logs -n nico-system -l app=nico-api --tail=100 -f
```

The machine transitions through `Assigned` → `Provisioning` → `Ready` once
RHCOS is installed and the node has rebooted.

## Step 4 — Install GPU and Network Operator on the workload cluster

Install the GPU Operator and Network Operator on the workload cluster via
OperatorHub before scheduling GPU workloads:

- [NVIDIA GPU Operator on OpenShift](https://docs.nvidia.com/datacenter/cloud-native/openshift/latest/openshift-container-platform.html)
- [NVIDIA Network Operator](https://docs.nvidia.com/networking/display/kubernetes2641/index.html)

## Next steps

With OpenShift worker nodes running on AI Factory hardware, proceed to
[Operations](../../operations/) for day-2 management tasks including
node maintenance, reprovisioning, and monitoring.
