---
title: "Troubleshooting"
weight: 5
---

This section covers common failure modes and their resolutions. Each entry
follows the pattern: symptom → likely cause → resolution.

## Node stuck in a provisioning state

### Stuck in `Discovered`

The node sent a DHCP DISCOVER but NICo has not advanced it past initial
discovery.

**Likely causes:**

- The BMC MAC address is not in NICo's `expected_machine` table — the node is
  unknown to NICo and will be ignored.
- The node's provisioning NIC is not on the correct L2 segment, or the MetalLB
  VIP for `nico-dhcp` (UDP port 67) is not reachable.
- The BMC is configured with a static IP and is not sending DHCP DISCOVERs.

**Resolution:**

```bash
# Verify the machine is registered
nico-admin-cli expected-machine list

# Check nico-dhcp received the DHCP DISCOVER
oc logs -n nico-system -l app=nico-dhcp --tail=200 | grep <bmc-mac>

# If no DHCP traffic, confirm the MetalLB VIP is reachable
oc get svc -n nico-system nico-dhcp
```

If the BMC has a static IP, provide it explicitly when registering:

```bash
nico-admin-cli expected-machine create \
  --bmc-mac <bmc-mac-address> \
  --bmc-ip <static-bmc-ip> \
  --segment <segment-name> \
  --sku <sku-name>
```

### Stuck in `Validating`

Hardware validation is running longer than expected (typically 5–15 minutes).

**Likely causes:**

- The GPU count, NIC model, or memory capacity does not match the registered SKU.
- Scout cannot call back to `nico-api` — network path from the provisioning
  segment to the management cluster API is blocked.

**Resolution:**

```bash
# Read the validation failure reason
nico-admin-cli machine get --machine-id <machine-id>

# Check nico-api for validation events
oc logs -n nico-system -l app=nico-api --tail=200 | grep -i "valid\|machine-id"
```

If the BOM does not match, update the SKU or re-register the machine with
the correct `--sku` value. Trigger a re-validation by power-cycling the node
after correcting the registration.

### `ValidationFailed`

NICo rejected the node because its hardware inventory does not match the SKU
bill of materials.

**Resolution:**

```bash
nico-admin-cli machine get --machine-id <machine-id>
```

The `validation_failure_reason` field lists each mismatched component. Correct
the hardware or update the SKU definition, then power-cycle the node to
restart the provisioning sequence.

### Stuck in `Provisioning`

The qcow-imager boot image is running but RHEL installation is not completing.

**Likely causes:**

- The RHEL qcow2 image URL is not reachable from the provisioning network.
- Insufficient disk space on the target device.
- Slow network path causing the image download to time out.

**Resolution:**

```bash
# Check nico-pxe serving the boot image
oc logs -n nico-system -l app=nico-pxe --tail=200 | grep <machine-ip>

# Verify the qcow2 image URL is reachable from inside the cluster
oc run -it --rm --image=registry.access.redhat.com/ubi10/ubi-minimal test \
  --restart=Never -- curl -I <qcow2-image-url>
```

---

## Network and DHCP issues

### Node does not get a DHCP address

```bash
# Confirm the nico-dhcp LoadBalancer VIP is assigned
oc get svc -n nico-system nico-dhcp

# Check for incoming DHCP traffic
oc logs -n nico-system -l app=nico-dhcp --tail=100

# If the provisioning network is routed (not flat L2), verify a DHCP relay
# is forwarding broadcasts from the node's VLAN to the nico-dhcp VIP
```

### Node cannot reach `nico-pxe` after getting an IP

The DHCP OFFER includes a boot URL pointing to the `nico-pxe` MetalLB VIP.
If the node cannot fetch `ipxe.efi`, it will not PXE boot.

```bash
# Confirm unbound resolves carbide-pxe.forge
oc run -it --rm --image=registry.access.redhat.com/ubi10/ubi-minimal dns-test \
  --restart=Never -- nslookup carbide-pxe.forge <nico-dns-vip>

# Confirm nico-pxe is serving artifacts
oc logs -n nico-system -l app=nico-pxe --tail=50
```

### OVN blocking DHCP UDP traffic

If the provisioning NIC is behind an OVN network, DHCP relay traffic (UDP
port 67) may be blocked by the default OVN allow-from-router policy.

```bash
# Check that the OVN local-gateway mode is enabled
oc get network.operator cluster -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig}'
```

Enable local-gateway mode per the MetalLB VIP configuration in
[Deploying DSX AI Factory](../../deployment/01-dsx-ai-factory/).

---

## Helm chart installation issues

### Prerequisite operator CRDs not ready after `prereqs` chart install

The MetalLB webhook can cause the post-install hook to time out before CRDs
are fully established.

```bash
# Check which CRDs are still missing
oc get crd | grep -E "metallb|nmstate|externalsecret|issuer"

# Re-run the hook manually for the affected operator
oc wait --for=condition=Established crd/metallbs.metallb.io --timeout=10m
oc wait --for=condition=Established crd/nmstates.nmstate.io --timeout=10m
```

If the hook job is still running, wait for it to complete or delete and
re-install the chart with `--no-hooks` and apply the singleton resources
manually.

### `helm upgrade` fails after a values change

Before upgrading, compare the current and new default values:

```bash
helm diff upgrade dsx-ai-factory \
  oci://ghcr.io/rh-ecosystem-edge/dsx-ai-factory/charts/dsx-ai-factory \
  --version <new-version> \
  --reuse-values
```

The `helm-diff` plugin highlights value renames and schema changes before
they affect a running cluster.

---

## Certificate and mTLS issues

### NICo Core cannot reach site services

NICo uses mTLS for all internal gRPC communication. If `nico-api` logs show
connection refused or certificate errors to site services, check cert-manager.

```bash
# Verify ClusterIssuers are Ready
oc get clusterissuer -n nico-system

# Check that nico-api and nico-dhcp certificates were issued
oc get certificate -n nico-system

# If a certificate is not Ready, describe it for the failure reason
oc describe certificate <cert-name> -n nico-system
```

If ClusterIssuers are not Ready, the post-install hook for the `prereqs`
chart may not have run. Apply them manually:

```bash
helm upgrade dsx-ai-factory-prereqs \
  oci://ghcr.io/rh-ecosystem-edge/dsx-ai-factory/charts/dsx-ai-factory-prereqs \
  --reuse-values --namespace nico-system
```

---

## Temporal workflow failures

### Finding a failed workflow

```bash
# Port-forward the Temporal UI
oc port-forward -n nico-system svc/temporal-web 8080:8080
```

Open `http://localhost:8080`. Select namespace `default`. Filter by status
**Failed** or **Timed Out**. Click a workflow to see the event history and
the point of failure.

### Retrying a stuck or failed workflow

Most NICo provisioning workflows are safe to reset from the Temporal UI
(Action → Reset → Reset to last workflow task). The state machine will
re-enter the last checkpoint and retry the failed activity.

For workflows stuck in a running state with no activity, use the **Terminate**
action, then power-cycle the affected node to restart provisioning.

---

## Useful diagnostic commands

```bash
# All machine states
nico-admin-cli machine list

# All active instances
nico-admin-cli instance list

# NICo Core logs (provisioning state machine)
oc logs -n nico-system -l app=nico-api --tail=200 -f

# NICo DHCP logs
oc logs -n nico-system -l app=nico-dhcp --tail=200 -f

# NICo PXE logs
oc logs -n nico-system -l app=nico-pxe --tail=200 -f

# NICo REST API logs
oc logs -n nico-system -l app=nico-rest-api --tail=200 -f

# All pods in nico-system
oc get pods -n nico-system

# MetalLB VIP assignments
oc get svc -n nico-system

# cert-manager certificate status
oc get certificate -n nico-system
```
