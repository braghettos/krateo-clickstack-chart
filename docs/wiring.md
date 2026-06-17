# clickstack — composition wiring & operations (chart repo)

The per-chart `values.yaml` surface, how the installer pins and wires the observability stack, the
dependencies, and the real operational gotchas. Everything is traced to the charts; where a stale
comment disagrees with the rendered chart, the chart wins.

## `charts/krateo-clickstack` — the wrapper surface

The heavy upstream values live under `clickstack:` and are passed through verbatim; Helm's top-level
`global` propagates into clickstack and all its subcharts (clickhouse / otel / hyperdx / mongodb).

### Global / exposure

- `global.storageClassName: "standard-rwo"` (`values.yaml`) — overrides the upstream default
  (`local-path`) for GKE.
- **HyperDX exposure:** `hyperdxLoadBalancer.enabled: true`, `name: krateo-clickstack-app-lb`,
  `port: 3000`. Renders an ADDITIONAL `LoadBalancer` Service (upstream only emits the ClusterIP
  `krateo-clickstack-app`); selector mirrors the upstream app pods, no hardcoded `loadBalancerIP`.
  Expose HyperDX through the installer CR / this flag, not by hand-patching the upstream Service.
- `clickstack.hyperdx.ingress.enabled: false`, `clickstack.fullnameOverride: krateo-clickstack`
  (keeps ClickHouse/Keeper/Mongo Service names stable under `core-provider`'s random release name).

### Krateo additions (this chart's own templates)

- `httpHandlers.enabled: true` → the `clickhouse-http-handlers` ConfigMap (the `/events` handler),
  mounted into ClickHouse via `clickstack.clickhouse.extraVolumes` /`extraVolumeMounts` at
  `/etc/clickhouse-server/config.d/http-handlers.xml`.
- `otelCredentials` → the `otel-clickhouse-credentials` Secret: `secretName`,
  `username: otelcollector`, `password: otelcollectorpass`. **These MUST match the ClickStack
  ClickHouse `otelcollector` user** (clickstack provisions it via `extraUsersConfig` with the same
  password). Created in `krateo-system` (the collectors' namespace), so no cross-namespace replication.

### ClickHouse resources (the load-bearing path)

- `clickstack.clickhouse.cluster.spec.containerTemplate.resources`: limits `cpu 4 / memory 8Gi`,
  requests `cpu 1 / memory 2Gi`. **This is the ONLY path upstream `clickstack` 3.0.0 honours** — it
  renders only `clickhouse.cluster.spec` into the `ClickHouseCluster` CR.
- `clickstack.clickhouse.image: clickhouse/clickhouse-server:26.3-alpine` and
  `clickstack.clickhouse.persistence.size: 50Gi` are **INERT** (top-level keys upstream ignores). They
  are kept un-moved on purpose: realizing them = a ClickHouse version upgrade (25.7→26.3) + PVC resize
  (10Gi→50Gi), a deliberate change that must not ride along with the memory fix. To realize later,
  move `image` → `cluster.spec.containerTemplate.image` and `size` →
  `cluster.spec.dataVolumeClaimSpec.resources.requests.storage`.
- `clickstack.otel.resources`: limits `cpu 1 / memory 512Mi`, requests `cpu 100m / memory 256Mi`.
- `clickstack.otel-collector.enabled: false` — the bundled OpAMP otel-collector subchart is DISABLED:
  it crashlooped (exit 2, OpAMP supervisor mode ignoring the chart `--config`) and is redundant here
  (Krateo's own collectors do the real ClickHouse ingestion with `krateo.io/composition-id`).
- `clickstack.mongodb.enabled: true`, `mongodb.persistence.size: 10Gi`.

## `charts/otel-collector-deployment` — cluster-level collector

All under `opentelemetry-collector:` (the upstream dep):

- `mode: deployment`, `replicaCount: 1`, image `ghcr.io/braghettos/krateo-otel-collector:1.0.0`,
  `command.name: otelcol-krateo` (image repo renamed; binary name unchanged).
- `clusterRole.create: true` with read rules on core/apps/batch/autoscaling K8s resources plus `get`
  on the Krateo CR groups (`composition.krateo.io`, `templates.krateo.io`,
  `widgets.templates.krateo.io`, `deployment.krateo.io`, `core.krateo.io`) — needed so the
  `compositionresolver` can resolve an involvedObject to its owning composition.
- `presets` all disabled (the chart hand-rolls `config` instead).
- `config`: `receivers` `k8sobjects` (watch Events) + `k8s_cluster` (60s metrics); `processors`
  `memory_limiter` (75% / 20% spike), `k8sattributes`, `resource` (`telemetry.source: k8s-events`),
  `compositionresolver` (`cache_ttl 5m`, `negative_cache_ttl 30s`,
  `label_key: krateo.io/composition-id`), `batch`; `exporters` `clickhouse` →
  `tcp://krateo-clickstack-clickhouse-clickhouse-headless.krateo-system.svc:9000`, db `default`,
  tables `otel_logs`/`otel_traces`/`otel_metrics`, `create_schema: true`. Two pipelines: `logs`
  (k8sobjects → … → clickhouse) and `metrics` (k8s_cluster → memory_limiter, batch → clickhouse);
  `traces: null`.
- `extraEnvs` `CH_USERNAME`/`CH_PASSWORD` from the `otel-clickhouse-credentials` Secret.
- `resources`: limits `cpu 500m / memory 512Mi`, requests `cpu 100m / memory 256Mi`.

## `charts/otel-collector-daemonset` — node-level collector

Wraps the same upstream `opentelemetry-collector` `0.158.1` in daemonset mode for pod logs, host and
kubelet metrics → ClickHouse.

## `charts/krateo-sse-proxy`

- **`replicaCount: 1` is deliberate.** sse-proxy is a STATEFUL in-memory SSE hub (each pod runs its
  own ClickHouse poller + client hub). Behind an L4 LoadBalancer with `sessionAffinity: None`, GCP
  hashes each client to one backend, so a degraded replica deterministically 503s a fixed subset of
  users on `/notifications` — exactly what broke the portal bell. A single hub eliminates the split;
  the poller resumes from `lastSeenUnix` on restart. (To scale >1: gate readiness on poller health +
  add `sessionAffinity`, or move to a shared event store.)
- `image: ghcr.io/braghettos/krateo-sse-proxy:1.0.0`; `service.type: ClusterIP`, `service.port: 8080`;
  container port 8080, `/health` liveness+readiness.
- `clickhouse.url: http://krateo-clickstack-clickhouse-clickhouse-headless.krateo-system.svc:8123`,
  `clickhouse.user: default`, password from the `clickhouse-credentials` Secret
  (`passwordSecret.optional: true`). Env: `CLICKHOUSE_URL/USER/PASSWORD`, `LISTEN_ADDR :8080`.
- `resources`: limits `cpu 200m / memory 128Mi`, requests `cpu 50m / memory 32Mi`. Hardened
  securityContext (`runAsNonRoot`, `readOnlyRootFilesystem`, drop ALL caps).

## Dependencies (what must exist around the stack)

- **The ClickHouse operator** (provides the `ClickHouseCluster` CRD) — must be installed; the wrapper
  renders a `ClickHouseCluster` CR but does not ship its CRD (see [crds.md](crds.md)).
- **Upstream chart deps** vendored under each chart's `charts/`: `clickstack 3.0.0`,
  `opentelemetry-collector 0.158.1`.
- **The `otel-clickhouse-credentials` Secret** (rendered by the wrapper) — both collectors `extraEnvs`
  reference it; its `username`/`password` must match the ClickHouse `otelcollector` user.
- **The `clickhouse-http-handlers` ConfigMap** (rendered by the wrapper) — the `/events` handler the
  sse-proxy / bell depend on.
- **Stable Service names** via `clickstack.fullnameOverride` — every collector/sse-proxy ClickHouse
  reference hardcodes `krateo-clickstack-clickhouse-clickhouse-headless`.

## How the installer wires it

The [krateo-installer](https://github.com/braghettos/krateo-installer) umbrella owns the
CompositionDefinitions for the wrapper and the collectors (`README.md`). It pins each
`spec.chart.version` to a released chart tag and points `core-provider` at the OCI artifacts;
`core-provider` reads `charts/krateo-clickstack/values.schema.json`, generates the `KrateoClickstack`
CRD, and reconciles one Composition per instance. The collectors depend on the `krateo-clickstack`
composition (for the credentials Secret), and `krateo-sse-proxy` is exposed so the portal events bell
can reach it. The deployed chart version is readable from `CompositionDefinition.spec.chart.version`
(the tag at which to fetch THIS repo's docs).

## Gotchas

- **A behavioral fix MUST ride a version bump.** `core-provider`/helm cache a chart by version tag and
  never re-pull an *unchanged* version. `0.1.2` was once mutably overwritten with the 8Gi ClickHouse
  change, but live clusters kept the cached 0.1.2 (old 1Gi) and ClickHouse OOMed the bell
  `/notifications` query — so the fix was re-shipped as a new version (`Chart.yaml` comment, the
  `0.1.5` history). Never overwrite a published version; bump it.
- **ClickHouse resources only count under `cluster.spec`.** Upstream `clickstack` 3.0.0 ignores
  top-level `clickhouse.resources` / `clickhouse.image` / `clickhouse.persistence`. Put resources at
  `clickstack.clickhouse.cluster.spec.containerTemplate.resources`; a top-level `resources:` is INERT
  and silently leaves ClickHouse at the operator default (~1Gi) → OOM.
- **sse-proxy is single-replica on purpose.** Don't bump `replicaCount` without gating readiness on
  poller health and adding session affinity, or a subset of users gets stuck 503s on the bell.
- **otel credentials must match the ClickHouse user.** `otelCredentials.username/password` must equal
  the `otelcollector` user clickstack provisions; a mismatch silently fails ClickHouse writes.
- **Keep the bundled otel-collector disabled.** Re-enabling `clickstack.otel-collector` brings back the
  crashlooping OpAMP collector and duplicates ingestion without `krateo.io/composition-id`.
- **`KrateoClickstack` is generated, not authored.** Don't look for a CRD YAML to edit — change the
  chart values surface and let `core-provider` re-derive the type (see [crds.md](crds.md)).

## See also

- [overview.md](overview.md) — chart layout, the CompositionDefinitions, what gets deployed.
- [crds.md](crds.md) — why this component owns no hand-authored CRD; the generated composition type.
- Code repo runtime view: `braghettos/krateo-clickstack`
  [`docs/llms.txt`](https://github.com/braghettos/krateo-clickstack/blob/main/docs/llms.txt)
  (the custom OTel collector, the `compositionresolver` processor, the sse-proxy poller/hub).
