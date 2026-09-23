# ADR 002: Incremental recalculation over a dependency graph

- Status: Accepted
- Date: 2026-09-23

## Context

Recalculating every formula after every cell edit makes interactive workbook
updates scale with the whole workbook. Formula dependencies also need to be
visible for tracing and cycle detection.

## Decision

Track cell precedents and dependents when formulas are set. Edits mark the
changed cell and reachable dependents dirty; recalculation evaluates that
subset in dependency order and runs Tarjan's strongly connected component
algorithm to identify cycles.

## Consequences

Local edits avoid unrelated formulas and cycle reporting follows the same graph
used for dependency tracing. Dynamic references cannot always be known before
evaluation, so volatile reference functions are refreshed on recalculation;
literal `INDIRECT` and `OFFSET` references are also tracked directly.
