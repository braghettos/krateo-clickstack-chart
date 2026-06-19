# krateo-clickstack-chart

Krateo PlatformOps **observability** blueprint repo. Groups the ClickStack wrapper with the
collectors and event proxy that feed and surface it. All charts publish to the consolidated
registry `oci://ghcr.io/braghettos/krateo`.

Part of the [krateo-installer](https://github.com/braghettos/krateo-installer) ecosystem.

## Charts

| Path | Chart | OCI artifact | Purpose |
|------|-------|--------------|---------|
| `charts/krateo-observability` | `krateo-observability` | `oci://ghcr.io/braghettos/krateo/krateo-observability` | ClickStack (ClickHouse + OTel gateway + HyperDX + MongoDB) wrapper: `values.schema.json`, the ClickHouse http-handlers ConfigMap, the otel-clickhouse credentials Secret and a HyperDX LoadBalancer Service. The composition the installer uses (Kind `KrateoObservability`) |
| `charts/otel-collector-deployment` | `otel-collector-deployment` | `oci://ghcr.io/braghettos/krateo/otel-collector-deployment` | Cluster-level OTel collector that enriches K8s events with `krateo.io/composition-id` and exports to ClickHouse |
| `charts/otel-collector-daemonset` | `otel-collector-daemonset` | `oci://ghcr.io/braghettos/krateo/otel-collector-daemonset` | Node-level OTel collector for pod logs, host and kubelet metrics |
| `charts/krateo-sse-proxy` | `krateo-sse-proxy` | `oci://ghcr.io/braghettos/krateo/krateo-sse-proxy` | Polls ClickHouse and pushes new K8s events to the portal via Server-Sent Events |

## How the installer consumes it

The installer umbrella emits a `CompositionDefinition` per chart, pointing `core-provider` at the
OCI artifacts above; `core-provider` generates the typed CRDs and reconciles one Composition per
instance. The collectors depend on the `krateo-observability` composition (for the ClickHouse
credentials Secret), and `krateo-sse-proxy` is exposed so the portal's events bell can reach it.

## Local validation

```sh
helm lint charts/krateo-observability
helm template smoke charts/krateo-observability
```

## Release

Push a semver tag (`X.Y.Z`) — CI packages every chart under `charts/*` at its declared version
and publishes to `oci://ghcr.io/braghettos/krateo`. Charts that still carry the `CHART_VERSION`
placeholder (e.g. `clickstack`) track the tag; independently-pinned charts keep their own version.

## Links

- Installer umbrella: https://github.com/braghettos/krateo-installer
- ClickStack: https://github.com/ClickHouse/ClickStack-helm-charts
