---
title: "Deploying OpenShift"
weight: 3
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

NICo uses its **InlineIpxe** OS variant to boot the RHCOS live installer.
Ignition is delivered via kernel arguments — not through NICo's `user_data`
field (which is cloud-init only and ignored by RHCOS).

The provisioning sequence:

1. NICo boots the node to the RHCOS live environment via iPXE
2. The live environment runs `coreos-installer` using the `coreos.inst.*`
   kernel arguments, writing RHCOS to the node's primary disk
3. The node reboots from disk; RHCOS first-boot fetches the worker ignition
   from the MCS (`ignition.config.url`) and applies it
4. The node registers with the workload cluster as a new worker

## Step 1 — Register the RHCOS OS definition

Create an OS record in NICo that describes how to boot the RHCOS installer.
Replace the URLs with the actual paths to your RHCOS live artifacts, either
served by `nico-pxe`'s artifact cache or from an internal HTTP server.

```bash
nico-admin-cli operating-system create \
  --name "openshift-coreos" \
  --ipxe-template-id <coreos-ipxe-template-id> \
  --site-id <site-id> \
  --kernel-params "rd.neednet=1 \
    coreos.inst.install_dev=/dev/sda \
    coreos.live.rootfs_url=http://<nico-pxe-vip>/public/blobs/internal/x86_64/rhcos-live-rootfs.x86_64.img \
    coreos.inst.ignition_url=https://api-int.<cluster-domain>:22623/config/worker" \
  --kernel-url "http://<nico-pxe-vip>/public/blobs/internal/x86_64/rhcos-live-kernel-x86_64" \
  --initrd-url "http://<nico-pxe-vip>/public/blobs/internal/x86_64/rhcos-live-initramfs.x86_64.img"
```

> **Note:** `coreos.inst.install_dev` must match the target node's primary
> disk device name (typically `/dev/sda` for SATA/SAS or `/dev/nvme0n1` for
> NVMe). Verify with the hardware inventory from the Scout discovery phase.

Wait for the OS record to reach `Ready` status before proceeding:

```bash
nico-admin-cli operating-system get <os-id>
```

## Step 2 — Create an instance type for OpenShift workers

Create an instance type that references the RHCOS OS definition and binds it
to the machines you want to provision:

```bash
nico-admin-cli instance-type create \
  --name "openshift-worker" \
  --operating-system-id <os-id> \
  --segment <provisioning-segment-name>
```

Associate the validated machines with this instance type:

```bash
nico-admin-cli instance-type machine-association create \
  --instance-type-id <instance-type-id> \
  --machine-id <machine-id>
```

## Step 3 — Allocate instances

Allocate an instance for each machine to trigger RHCOS installation:

```bash
nico-admin-cli instance create \
  --instance-type-id <instance-type-id> \
  --machine-id <machine-id> \
  --tenant-id <tenant-id>
```

NICo will power-cycle the node, boot it to the RHCOS live installer via iPXE,
and run `coreos-installer`. Monitor progress:

```bash
# Watch machine state transitions
oc get machines -n nico-system -w

# View provisioning events
oc logs -n nico-system -l app=nico-api --tail=100 -f
```

The machine transitions through `Assigned` → `Provisioning` → `Ready` once
RHCOS is installed and the node has rebooted.

## Step 4 — Approve worker CSRs

New worker nodes generate two certificate signing requests — one for the node
bootstrapper and one for the kubelet serving certificate. Approve them on the
workload cluster:

```bash
# Approve all pending CSRs (run twice — once for each certificate)
oc get csr -o name | xargs oc adm certificate approve
```

The node should appear in the workload cluster within a few minutes:

```bash
oc get nodes
```

For production deployments, configure the cluster's **Machine Approver** to
approve CSRs automatically based on machine inventory.

## Step 5 — Verify GPU and Network Operator

Once workers are `Ready`, the GPU Operator and Network Operator — installed
via OLM by the `dsx-ai-factory-prereqs` chart — automatically detect the
new nodes and install the required drivers:

```bash
# GPU Operator daemonset rolls out to new workers
oc get daemonset -n gpu-operator

# Network Operator configures SR-IOV and RDMA
oc get sriovnetworknodestates -n sriov-network-operator
```

Allow several minutes for driver installation and device plugin registration
to complete before scheduling GPU workloads.

## Next steps

With OpenShift worker nodes running on AI Factory hardware, proceed to
[Operations](../../operations/) for day-2 management tasks including
node maintenance, reprovisioning, and monitoring.
