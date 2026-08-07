---
type: ExampleIndex
title: clickstack-chart — examples
description: Runnable examples under examples/, each paired with a README stating preconditions and the one apply command.
resource: oci://ghcr.io/krateo-platformops/charts/krateo-observability
tags: [examples, composition]
timestamp: 2026-08-07T00:00:00Z
---

# Examples

Each example is a runnable manifest + a README with preconditions and the one apply command.

- [observability-composition](../examples/observability-composition/README.md) — deploy the
  ClickStack wrapper as a Krateo composition: register the
  [`CompositionDefinition`](../compositiondefinition.yaml), then create a
  `KrateoObservability` CR with a minimal block-style values override.

The reference manifests under [`ops/`](../ops/README.md) (ClickHouse config, HA policies,
alert bootstrap) are operational material, not examples — the live artifacts are the charts.
