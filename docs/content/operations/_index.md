---
title: "Operations"
weight: 4
description: "Adding nodes, maintenance, monitoring, and upgrades"
---

This section covers day-2 management tasks for a running DSX AI Factory
deployment: adding nodes, reprovisioning, maintenance, monitoring, and upgrades.

## Adding a new node

To add a new AI Factory compute node after initial deployment:

1. **Install and cable** the node in the rack. Ensure the BMC NIC is on the
   provisioning network and the management (OOB) network is reachable from the
   management cluster.

2. **Register the node** in NICo before powering it on:

   ```bash
   nico-admin-cli expected-machine add \
     --bmc-username <bmc-username> \
     --bmc-password <bmc-password> \
     --chassis-serial-number <serial-number>
   # see: nico-admin-cli expected-machine add --help for full options (SKU, segment, interfaces)
   ```

3. **Power on** the node. NICo drives the full provisioning sequence
   automatically — BMC discovery, firmware pre-ingestion, hardware validation,
   and OS installation. See [Deploying RHEL](../../deployment/02-rhel/) for
   the complete provisioning flow.

4. **Monitor** until the machine reaches `Ready`:

   ```bash
   nico-admin-cli machine show
   ```

## Reprovisioning a node

To wipe and reprovision an existing node:

1. **Release the instance** to return the machine to the pool:

   ```bash
   nico-admin-cli instance release --instance <instance-id>
   # or by machine: nico-admin-cli instance release --machine <machine-id>
   ```

   NICo powers off the node, wipes it, and transitions it back to `Ready`.

2. **Assign a new instance** to trigger reprovisioning:

   ```bash
   nico-admin-cli instance allocate \
     --prefix-name <name> \
     --subnet <cidr>
   # see: nico-admin-cli instance allocate --help for full options
   ```

## Machine maintenance

To prevent new instance assignments (for hardware work, firmware updates, etc.):

```bash
# Enter maintenance mode (requires a reference ticket URL)
nico-admin-cli managed-host maintenance on \
  --host <managed-host-id> \
  --reference <ticket-url>

# Return to service
nico-admin-cli managed-host maintenance off \
  --host <managed-host-id>
```

Maintenance mode prevents NICo from assigning new instances to the node.
Existing instances are not automatically terminated — drain the node in
OpenShift before enabling maintenance if it is running workloads:

```bash
oc adm drain <node-name> --ignore-daemonsets --delete-emptydir-data
```

## Machine states reference

> Simplified state names — see the [NICo managed host state machine](https://docs.nvidia.com/infra-controller/documentation/architecture/state-machines/managed-host) for the full diagram.


| State | Description |
|---|---|
| `Discovered` | BMC seen via DHCP; pre-ingestion in progress |
| `Validating` | Hardware validation against SKU BOM |
| `ValidationFailed` | BOM mismatch — check hardware and re-register |
| `Ready` | Validated; available for instance assignment |
| `Assigned` | Instance assigned; OS install in progress or running |
| `Maintenance` | Excluded from new instance assignments |

## Monitoring NICo

### Machine states

```bash
# All machines and states
nico-admin-cli machine show

# Specific machine
nico-admin-cli machine show <machine-id>
```

### Logs

```bash
# NICo Core API (provisioning state machine)
oc logs -n nico-system -l app=nico-api --tail=100 -f

# NICo REST API (operator UI backend)
oc logs -n nico-system -l app=nico-rest-api --tail=100 -f
```

### Temporal workflow UI

NICo uses [Temporal](https://temporal.io) for durable workflow orchestration.
Access the Temporal UI to inspect in-progress and failed provisioning workflows:

```bash
oc port-forward -n nico-system svc/temporal-web 8080:8080
```

Then open `http://localhost:8080` in a browser. The namespace is `default`.
Workflows are named after the operation — for example, machine provisioning
workflows appear as `provision-machine-<machine-id>`.

## Updating DSX AI Factory

### Check release notes

Review the [GitHub releases page](https://github.com/rh-ecosystem-edge/dsx-ai-factory/releases)
for the target version before upgrading.

### Upgrade the umbrella chart

```bash
helm upgrade dsx-ai-factory \
  oci://ghcr.io/rh-ecosystem-edge/dsx-ai-factory/charts/dsx-ai-factory \
  --version <new-version> \
  --namespace nico-system \
  --reuse-values
```

`--reuse-values` preserves your site-specific configuration. Review the release
notes for any values that changed meaning or were renamed.

If the component charts (nico, nico-rest, rack-manager) were also updated,
ensure they have been published to GHCR before running `helm upgrade` — the
umbrella chart pulls them from OCI on `helm dependency update`.

### Verify after upgrade

```bash
# All pods should restart and reach Running
oc get pods -n nico-system -w

# NICo API health
oc port-forward -n nico-system svc/nico-rest-api 8388:8388 &
curl -k https://localhost:8388/api/v1/health
```

## RMS day-2 operations

The Rack Management Service (RMS) manages switch firmware, PDU power control,
and rack-level hardware inventory. For switch firmware updates, reprovisioning,
and other RMS-specific tasks, refer to the
[RMS operations documentation](https://docs.nvidia.com/rms/documentation/operations/overview).
