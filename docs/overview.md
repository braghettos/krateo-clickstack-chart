# clickstack — deployment overview (chart repo)

What the Krateo **ClickStack observability blueprint** is, and **how it deploys** as a set of Krateo
compositions. This is the deployment view; the internals/runtime view (the custom OTel collector, the
`compositionresolver` processor, the sse-proxy binary) lives in the code repo
`braghettos/krateo-clickstack` (`docs/`). Every claim below is traced to a file in this repo — if a
comment disagrees with what the chart actually renders, the rendered chart wins.

## What clickstack is

The Krateo portal's **observability stack**. It ingests Kubernetes telemetry (pod logs, K8s Events,
host/kubelet/cluster metrics) into ClickHouse, enriches each event with a
`krateo.io/composition-id` so telemetry can be sliced per Krateo composition, lets operators explore
it through HyperDX, and feeds two consumers:

- the **portal events bell**, via a ClickHouse `GET /events?composition_id=<uid>` http-handler and
  the `krateo-sse-proxy` that streams new events to the browser over Server-Sent Events;
- the **`krateo-clickstack-agent`** (this repo's `kagent/chart`), which troubleshoots Krateo/K8s
  issues by querying the same ClickHouse tables.

This repo is the **braghettos packaging as a Krateo blueprint**: it wraps the upstream ClickStack
Helm chart and the upstream OpenTelemetry collector chart, folds in the Krateo-specific glue, and
ships a `values.schema.json` so `core-provider` can generate a typed CompositionDefinition CRD. It
replaces the old imperative `obs-stack` `install.sh` phases (no hand-run `kubectl patch`,
`README.md`).

## Repo layout — four deployable charts + the agent

| Path | Chart name | OCI artifact | Versioning |
|------|------------|--------------|------------|
| `charts/krateo-clickstack` | `krateo-clickstack` | `oci://ghcr.io/braghettos/krateo/krateo-clickstack` | tracks the git tag (`Chart.yaml` `version: CHART_VERSION`); current literal `0.1.5`, `appVersion 3.0.0` |
| `charts/otel-collector-deployment` | `otel-collector-deployment` | `oci://ghcr.io/braghettos/krateo/otel-collector-deployment` | pinned `0.2.0`, independent |
| `charts/otel-collector-daemonset` | `otel-collector-daemonset` | `oci://ghcr.io/braghettos/krateo/otel-collector-daemonset` | pinned `0.1.1`, independent |
| `charts/krateo-sse-proxy` | `krateo-sse-proxy` | `oci://ghcr.io/braghettos/krateo/krateo-sse-proxy` | pinned `0.1.3`, independent |
| `kagent/chart` | `krateo-clickstack-agent` | `oci://ghcr.io/braghettos/krateo/krateo-clickstack-agent` | `0.1.x`, independent (`kagent/chart/Chart.yaml`) |

They version **independently**:

- **The ClickStack wrapper** (`charts/krateo-clickstack`) is the heaviest piece. `version` is the
  `CHART_VERSION` placeholder substituted to the git tag at release; `appVersion` is `3.0.0` (the
  upstream `clickstack` dependency version, `Chart.yaml`). It vendors the upstream `clickstack`
  `3.0.0` chart as a dependency and passes most values through under the `clickstack:` key. The
  `KrateoClickstack` composition the installer creates is this chart.
  > **Version bumps are load-bearing for re-pull.** `core-provider`/helm cache a chart by its version
  > tag and never re-pull an *unchanged* version, so a behavioral fix MUST ride a version bump or live
  > clusters keep the old artifact (`Chart.yaml` comment, the `0.1.5` history) — see
  > [wiring.md](wiring.md).
- **The two OTel collector charts** (`otel-collector-deployment`, `otel-collector-daemonset`) each
  wrap the upstream `opentelemetry-collector` `0.158.1` chart and are pinned independently of the
  wrapper. The deployment-mode one runs the custom `krateo-otel-collector` image (the
  `compositionresolver` processor); the daemonset-mode one runs node-level log/metric collection.
- **The SSE proxy** (`krateo-sse-proxy`) is a small Krateo-built Go service (image
  `ghcr.io/braghettos/krateo-sse-proxy`); pinned `0.1.3`, single replica by design (it is a stateful
  in-memory SSE hub — see [wiring.md](wiring.md)).
- **The agent chart** (`kagent/chart`) is the federated specialist agent (`krateo-clickstack-agent`)
  registered on `krateo-autopilot`; it versions on its own `0.1.x` line and is **not** any
  observability workload. `kagent/compositiondefinition.yaml` ships its CompositionDefinition (pinned
  `0.1.0`).

## The CompositionDefinition

The repo-root `compositiondefinition.yaml` registers the wrapper with Krateo: `core.krateo.io/v1alpha1`,
name `krateo-clickstack`, namespace `krateo-system`, `spec.chart.url` =
`oci://ghcr.io/braghettos/krateo/krateo-clickstack`, `spec.chart.version` pinned (currently `"0.1.2"`
in this file). In a real install the [krateo-installer](https://github.com/braghettos/krateo-installer)
umbrella owns this and the per-collector CompositionDefinitions (`README.md`). `core-provider` reads
the wrapper chart's `values.schema.json`, generates the typed `KrateoClickstack` CRD, and reconciles
one Composition per instance. The deployed chart version is cluster-observable from
`CompositionDefinition.spec.chart.version` (the tag at which an agent should fetch THIS repo's docs —
see [llms.txt](llms.txt)).

> The pinned version in `compositiondefinition.yaml` (`0.1.2`) is the *registered* version, not
> necessarily the latest chart tag in the repo (`Chart.yaml` is `0.1.5`). Always read the cluster's
> live `CompositionDefinition.spec.chart.version` to know what is actually deployed.

The CompositionDefinition that also lives here is the agent's
(`kagent/compositiondefinition.yaml`): `core.krateo.io/v1alpha1`, name `krateo-clickstack-agent`,
namespace `krateo-system`, `spec.chart.version: "0.1.0"`.

## What each chart deploys

### `charts/krateo-clickstack` (the wrapper)

The vendored upstream `clickstack` subchart renders ClickHouse (via the ClickHouse operator's
`ClickHouseCluster` CR), the OTel gateway, HyperDX, and MongoDB. Krateo additions rendered by THIS
chart's own templates (`charts/krateo-clickstack/templates/`):

- **`clickhouse-http-handlers` ConfigMap** (`http-handlers-configmap.yaml`, gated on
  `httpHandlers.enabled`) — the `GET /events?composition_id=<uid>` predefined-query handler XML from
  `files/http-handlers.xml`, mounted into the ClickHouse pods at
  `/etc/clickhouse-server/config.d/http-handlers.xml` via `clickstack.clickhouse.extraVolumes`.
- **`otel-clickhouse-credentials` Secret** (`otel-credentials-secret.yaml`, gated on
  `otelCredentials.enabled`) — `username`/`password` for the collectors' ClickHouse `otelcollector`
  user, created in the release namespace (`krateo-system`).
- **`krateo-clickstack-app-lb` LoadBalancer Service** (`hyperdx-loadbalancer.yaml`, gated on
  `hyperdxLoadBalancer.enabled`) — an ADDITIONAL Service exposing the HyperDX UI on port 3000
  externally (upstream only emits a ClusterIP), with no hardcoded `loadBalancerIP`.

`clickstack.fullnameOverride: krateo-clickstack` keeps the ClickHouse/Keeper/Mongo Service names
stable regardless of the random release name `core-provider` assigns, so the collectors and sse-proxy
can resolve `krateo-clickstack-clickhouse-clickhouse-headless`.

### `charts/otel-collector-deployment` (cluster-level)

A single-replica `opentelemetry-collector` in `deployment` mode running the custom
`krateo-otel-collector` image (binary `otelcol-krateo`). Pipelines: a `logs` pipeline
(`k8sobjects` events → `memory_limiter, k8sattributes, resource, compositionresolver, batch` →
ClickHouse) and a `metrics` pipeline (`k8s_cluster` → ClickHouse). The `compositionresolver` processor
stamps `krateo.io/composition-id`. It ships its own `clusterRole` (read on K8s + Krateo CR groups) and
pulls ClickHouse creds from the `otel-clickhouse-credentials` Secret via `extraEnvs`.

### `charts/otel-collector-daemonset` (node-level)

A daemonset-mode `opentelemetry-collector` collecting pod logs, host metrics and kubelet metrics and
exporting them to ClickHouse.

### `charts/krateo-sse-proxy`

A Deployment + ClusterIP Service (`templates/`). One container, port 8080, `/health` probes, polls
ClickHouse (`clickhouse.url` → `krateo-clickstack-clickhouse-clickhouse-headless:8123`) and pushes new
K8s events to connected browsers over SSE. `replicaCount: 1` is deliberate (stateful in-memory hub).

For the full per-chart `values.yaml` surface, the installer wiring, and the operational gotchas, see
[wiring.md](wiring.md). For what CRDs this component does (and does not) own, see [crds.md](crds.md).

## Cross-references

- **Code repo (internals & runtime):** `braghettos/krateo-clickstack` —
  [`docs/llms.txt`](https://github.com/braghettos/krateo-clickstack/blob/main/docs/llms.txt). That set
  is versioned at the **image** tag (the collector/sse-proxy image tags); this set is versioned at the
  **chart** tag.
- **Installer umbrella:** `braghettos/krateo-installer` (owns the CompositionDefinitions).
- **Upstream:** `ClickHouse/ClickStack-helm-charts`, `open-telemetry/opentelemetry-helm-charts`.
