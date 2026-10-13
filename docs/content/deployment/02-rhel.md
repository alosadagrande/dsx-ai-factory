---
title: "Deploying RHEL"
weight: 2
---

NICo provisions RHEL on AI Factory bare-metal compute nodes automatically.
Once you register a node with NICo, the system drives it from power-on through
hardware validation to a running RHEL installation without manual intervention.

## How NICo provisions RHEL

The provisioning sequence proceeds in four phases:

### 1. Node registration

Before powering on a node, register its expected configuration in NICo using
the `nico-admin-cli` tool:

```bash
nico-admin-cli expected-machine create \
  --bmc-mac <bmc-mac-address> \
  --segment <provisioning-segment-name> \
  --sku <sku-name>
```

This tells NICo to expect a machine with that BMC MAC address, which network
segment it will boot on, and which hardware SKU (bill of materials) it must
match before being admitted to the pool.

### 2. Discovery — Scout OS

When the node powers on, NICo's DHCP server (`nico-dhcp`) assigns it an IP
address and provides a boot URL pointing to the `nico-pxe` service. The node
UEFI HTTP-boots `ipxe.efi`, which chainloads a per-node boot script from
`nico-pxe`.

NICo dispatches the **Scout discovery OS** — a two-stage boot image:

| Boot blob | Role |
|---|---|
| `ipxe.efi` | iPXE UEFI loader with embedded chainload script |
| `scout.efi` | Minimal UKI loader; downloads and measures Scout rootfs |
| `scout.squashfs` | Scout rootfs containing the `forge-scout` hardware agent |

The loader (`scout.efi`) downloads `scout.squashfs`, measures it into TPM PCR 16
for integrity verification, mounts it as an overlay, and boots into it. The
`forge-scout` agent then enumerates the node's hardware — CPUs, memory, NICs,
GPUs, storage — and reports the inventory to NICo over mTLS gRPC.

All three boot blobs are served by the `infra-controller-pxe` container image
running in the management cluster.

### 3. Hardware validation

NICo validates the reported inventory against the expected SKU bill of
materials. If the hardware matches, the node advances to the validation phase
where it boots Scout a second time to collect runtime measurements (GPU health,
NIC link status).

If validation fails, the node enters `ValidationFailed` state. Check the
hardware against the expected SKU and verify that all components are seated
and recognized.

### 4. RHEL installation

Once validated, NICo marks the node `Ready` in its inventory pool. When an
instance is assigned to the node (either automatically or by an operator), NICo:

1. Configures the node's network segment and storage via `nico-site-agent`
2. Triggers a PXE boot to the **qcow-imager** boot image (`qcow-imager.efi`)
3. `qcow-imager` writes a RHEL qcow2 image to the node's primary disk using
   `disk_imaging.sh`
4. The node reboots from disk into RHEL
5. NICo clears the PXE boot flag; the node will boot from disk on all
   subsequent power-ons

## Machine states reference

| State | Description |
|---|---|
| `Discovered` | NICo received a DHCP DISCOVER from this node's BMC; initial Scout boot pending |
| `Validating` | Hardware validation in progress; Scout is collecting measurements |
| `ValidationFailed` | BOM mismatch; check hardware against expected SKU |
| `Ready` | Node passed validation; available for instance assignment |
| `Assigned` | Instance assigned; network/storage config in progress or RHEL install running |
| `Maintenance` | Node in maintenance mode; not available for new instances |

## Monitoring provisioning

Watch machine state transitions:

```bash
# List all machines and their current state
oc get machines -n nico-system

# Watch a specific machine
oc get machine <machine-name> -n nico-system -w

# View NICo API logs for provisioning events
oc logs -n nico-system -l app=nico-api --tail=100 -f
```

The NICo UI also provides a real-time view of machine state and provisioning
progress, accessible via the `nico-rest-api` service.

## RHEL image configuration

The RHEL qcow2 image used by `qcow-imager` is referenced in the NICo
configuration as an OS image record. Configure the image URL in the NICo
deployment values:

```yaml
nico:
  nico-pxe:
    config:
      osImages:
        - name: rhel-10
          url: https://<your-artifact-store>/rhel-10-x86_64.qcow2
          sha256: <sha256-of-image>
```

The image can be served from an internal HTTP server, an S3-compatible store,
or proxied through `nico-pxe`'s artifact cache. Set the caching strategy
to `CacheAsNeeded` to have `nico-pxe` download and cache the image locally
on first use.

## Next steps

With RHEL running on the AI Factory compute nodes, proceed to
[Deploying OpenShift](../03-openshift/).
