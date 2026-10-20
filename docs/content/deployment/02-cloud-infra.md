---
title: "Deploying cloud infrastructure"
weight: 3
---

![NICo cloud tier architecture](/images/nico-cloud-architecture.png)

NICo has **two tiers**, by design, so one central API can manage many
datacenters. The **site** tier is the controller that runs next to the hardware
(covered later); the **cloud** tier is the shared, central layer which includes the REST API,
identity, workflow engine, and their databases. The cloud tier can sit far away and
serve many sites at once.

This page covers `deploy-cloud-infra` — the **backing
services** NICo depends on, laid down *before* NICo itself; the `deploy-cloud`
step then puts the app on top. Everything lands in the `nico-rest` namespace:
Crunchy PostgreSQL, RHBK Keycloak, Temporal, OpenShift Routes, and ESO
ExternalSecrets.

> **This step must complete — including the post-install steps — before
> deploying NICo Core.** NICo Core connects to these services at startup and
> will crash-loop if they are absent.

## Step 1 — Deploy cloud infrastructure

```bash
make deploy-cloud-infra
```

This runs:
```bash
helm upgrade --install -n nico-rest nico-rest-infra \
  charts/cloud-infra/ \
  --create-namespace --wait --timeout 10m \
  --post-renderer kustomize-post-renderer \
  --post-renderer-args scripts/kustomize/infra-cloud
```

The chart creates:

| Resource | Namespace | Purpose |
|---|---|---|
| Crunchy PG cluster | `nico-rest` | Persistent state — one instance, four databases: `nico`, `keycloak`, and Temporal's `temporal` + `temporal_visibility` |
| RHBK Keycloak instance | `rhbk-operator` | Identity provider for the NICo REST API and UI |
| RHBK Keycloak realm | `rhbk-operator` | The `nico` realm, imported automatically so auth is ready out of the box |
| Temporal server | `nico-rest` | Workflow engine that drives NICo's long-running operations (e.g. provisioning a machine) |
| OpenShift Routes | `nico-rest` | External HTTPS entry point to Keycloak and the API (OpenShift-specific) |
| ESO ExternalSecrets | `nico-rest` | Copies the root CA created earlier into this namespace and wires up the database credentials |

Verify all pods are running before proceeding:

```bash
oc get pods -n nico-rest
oc get pods -n rhbk-operator
oc get postgrescluster -n nico-rest
```

## Step 2 — Deploy the NICo REST plane

![Deploying the NICo cloud REST plane](/images/deploy-nico-cloud.png)

The previous step laid the plumbing; this step installs the actual NICo cloud
**application** on top — the **REST API** that operators and orchestrators talk
to. Deploy it before bootstrapping the organization, which calls this API:

```bash
make deploy-cloud
```

This installs the **upstream NVIDIA `nico-rest` chart in the `nico-rest`namespace, unmodified.
Instead, a **Kustomize post-renderer** patches the rendered output to
fit OpenShift, with `charts/values/nico-rest.yaml` as the image override file.

The REST API does not run alone: it stores its state in **PostgreSQL**,
authenticates against **Keycloak**, and drives long-running operations through
**Temporal**. All deployed in the infra step above.

Verify the pods and the external API route:

```bash
oc get pods -n nico-rest
oc get route nico-rest-api -n nico-rest
oc port-forward -n nico-rest svc/nico-rest-api 8388:8388 &
curl -sk https://localhost:8388/api/v1/health
```

The next two steps: patching the Keycloak route and bootstrapping the
organization turn this empty API into one you can onboard hardware into.

## Step 3 — Patch the Keycloak route

The Keycloak Route is backed by the RHBK operator's self-signed certificate.
OpenShift's router cannot verify it without the CA. The route returns HTTP 503
until the CA is injected:

```bash
make patch-keycloak-route
```

This reads the `nico-root-ca-secret` from the `cert-manager` namespace and
patches the Keycloak Route's `destinationCACertificate` field. Verify:

```bash
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster \
  -o jsonpath='{.spec.domain}')
curl -sk https://keycloak-rhbk-operator.${CLUSTER_DOMAIN}/realms/nico \
  | python3 -m json.tool | grep realm
```

You should see `"realm": "nico"`.

## Step 4 — Bootstrap the organization

NICo requires an **Infrastructure Provider** and a default **Tenant** to be
created before any machines can be onboarded. This is a one-time bootstrap:

```bash
make bootstrap-org
```

This fetches a Keycloak admin token, retrieves the `ncx-service` OIDC client
secret, obtains a client-credentials Bearer token for the NICo REST API, and
calls `/v2/org/ncx/nico/infrastructure-provider/current` and
`/v2/org/ncx/nico/tenant/current`, which lazily create the Infrastructure
Provider and the default Tenant if they do not already exist.

> **If `bootstrap-org` fails with a token error**, check that `patch-keycloak-route`
> completed successfully. A 503 from the Keycloak route is the most common cause.

Or run all four steps in sequence:

```bash
make deploy-all-cloud
```

## Next steps

Proceed to [Deploying site infrastructure and Vault](../03-vault/) to set up
the site-plane dependencies before deploying NICo Core.