# ADR 001: Cell source as a duck type

- Status: Accepted
- Date: 2026-09-23

## Context

Furud must be usable independently from any workbook, grid UI, or persistence
structure. Depending on a concrete sheet implementation would prevent isolated
calculation tests and force applications to adopt Furud's storage model.

## Decision

The engine reads individual cells through `value_at(reference)` and ranges
through optional `each_in(area)`. Furud owns formula and recalculation state,
but does not own or mutate the caller's source object.

## Consequences

Storage implementations can optimize sparse range traversal and remain
replaceable. Callers applying row or column edits must update their source in
step with Furud's formula adjustment methods.
