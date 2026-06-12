# `krateo-clickstack-agent` — federated specialist agent

The Krateo observability expert: troubleshoots Krateo/K8s issues by querying the ClickStack telemetry backend (ClickHouse+OTel+HyperDX). Knows braghettos/krateo-clickstack-chart.

Per the [/kagent standard](https://github.com/braghettos/krateo-autopilot/blob/main/AGENTS-VERSIONING.md)
it is **component-scoped** and knows its component from this chart's `Chart.yaml` `sources`
(`braghettos/krateo-clickstack-chart`), read via github MCP tools.
Reachable only through the `krateo-autopilot` orchestrator (registered via `extraAgents`). Published
to `oci://ghcr.io/braghettos/krateo/krateo-clickstack-agent` (pinned `0.1.0`).
