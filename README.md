# StreamLens Performance Challenge

[![StreamLens assessment](https://github.com/YaroTanko/streamlens-performance-challenge/actions/workflows/assessment.yml/badge.svg)](https://github.com/YaroTanko/streamlens-performance-challenge/actions/workflows/assessment.yml)

StreamLens is a small Go CLI and in-repository analyzer component that reads NDJSON events, filters them,
groups them into fixed UTC-aligned windows, and produces deterministic aggregate
results. This repository is also a 30-minute, AI-assisted performance exercise:
preserve the behavior, improve the implementation, and let CI measure the result.

`PRD.md` is the source of truth for product behavior and assessment policy. Read
`TASK.md` before making a candidate change.

## Quick start

Use the Go version declared in `go.mod`.

```sh
make check
make benchmark
```

Roughly equivalent raw commands are:

```sh
go test ./...
GOMAXPROCS=1 go test -run '^$' -bench . -benchmem -cpu=1 ./internal/assessment
```

Run the CLI against an NDJSON file:

```sh
go run ./cmd/streamlens \
  -input examples/events.ndjson \
  -from 2026-01-15T12:00:00Z \
  -to 2026-01-15T13:00:00Z \
  -types purchase,click \
  -window 1m \
  -top-k 3
```

Omit `-input` to read from standard input. Use `go run ./cmd/streamlens -h`
for all options.

A canonical input/output pair is available in `examples/events.ndjson` and
`examples/expected.json`.

## The challenge

Fork the repository, create a branch, and use any AI assistant or profiling tools
you find useful. You may change only `internal/analyzer/engine.go` and
`OPTIMIZATION.md`. Keep the output and observable behavior unchanged, write a 5–10 line
optimization note, and open a pull request to the upstream repository.

CI first verifies tests and protected paths. It then compares the immutable
baseline and pull-request revision on the same runner, reporting time, bytes, and
allocations. Passing requires at least 20% improvement in one metric with no more
than 20% aggregate regression in another metric and no more than 30% regression
in any scenario/metric pair. See `TASK.md` for the complete rules.

Local benchmark values help guide development, but only the comparative CI run is
authoritative. A reported Middle, Senior, or Staff optimization tier describes the
measured result, not the candidate's job level or hiring outcome.

## Documentation

- `PRD.md`: product requirements and assessment source of truth
- `TASK.md`: candidate scope, scoring, and deliverables
- `DESIGN.md`: architecture and behavioral invariants
- `AGENTS.md`: instructions for AI coding agents
- `CONTRIBUTING.md`: fork and pull-request workflow
- `OPTIMIZATION.md`: candidate explanation template
