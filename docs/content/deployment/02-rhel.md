---
title: "Deploying RHEL"
weight: 6
---

NICo provisions RHEL on AI Factory bare-metal compute nodes automatically.
Once you register a node with NICo, the system drives it from power-on through
hardware validation to a running RHEL installation without manual intervention.

## How NICo provisions RHEL

NICo drives RHEL installation automatically once a node is registered.
The discovery, Scout boot, and hardware validation phases are identical
for all operating systems — see the
[provisioning flow](../../overview/#provisioning-flow) in
the Architecture section. This page covers the RHEL-specific steps.

### Step 1 — Register the node

Before powering on a node, register its expected configuration in NICo:

```bash
nico-admin-cli expected-machine add \
  --bmc-username <bmc-username> \
  --bmc-password <bmc-password> \
  --chassis-serial-number <serial-number>
# see: nico-admin-cli expected-machine add --help for full options (SKU, segment, interfaces)
```

Power on the node. NICo drives discovery, Scout boot, and BOM validation
automatically. Once validated, the node enters the `Ready` pool.

### Step 2 — Assign an instance (RHEL)

When an instance is assigned, NICo:

1. Configures the node's network segment and storage via `nico-site-agent`
2. Triggers a PXE boot to the **qcow-imager** boot image (`qcow-imager.efi`)
3. `qcow-imager` writes a RHEL qcow2 image to the node's primary disk
4. The node reboots from disk into RHEL; PXE override cleared

## Machine states reference

> These are simplified state names for documentation purposes. The internal NICo state machine is more granular — see the [NICo managed host state machine](https://docs.nvidia.com/infra-controller/documentation/architecture/state-machines/managed-host) for the full state diagram.


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
nico-admin-cli machine show

# Show a specific machine
nico-admin-cli machine show <machine-id>

# View NICo API logs for provisioning events
oc logs -n nico-system -l app=nico-api --tail=100 -f
```

The NICo UI also provides a real-time view of machine state and provisioning
progress, accessible via the `nico-rest-api` service.

## Cloud-init

> **Developer Preview limitation:** Cloud-init first-boot customization
> (user accounts, SSH keys, network config via `user_data`) is not
> supported in this release. `qcow-imager` writes the RHEL image as-is;
> no cloud-init datasource is injected. Bake any required configuration
> into the qcow2 image before provisioning.

## RHEL image configuration

Register the RHEL qcow2 image as an OS record in NICo using `nico-admin-cli`:

```bash
nico-admin-cli operating-system create --name rhel-10
# see: nico-admin-cli operating-system create --help for artifact/iPXE template options
```

The image URL must be reachable from the management cluster at provisioning
time. It can be served from an internal HTTP server, an S3-compatible object
store, or proxied through `nico-pxe`'s artifact cache.

## Further reading

- [NICo — Ingesting hosts](https://docs.nvidia.com/infra-controller/documentation/provisioning-day-0/ingesting-hosts) — full reference for machine registration options
- [NICo — IP and network configuration](https://docs.nvidia.com/infra-controller/documentation/provisioning-day-0/ip-and-network-configuration)
- [NICo — Discovery OS / Scout](https://docs.nvidia.com/infra-controller/documentation/provisioning-day-0/discovery-os-cloud-init-scout)

## Next steps

With RHEL running on the AI Factory compute nodes, proceed to
[Deploying OpenShift](../03-openshift/).
