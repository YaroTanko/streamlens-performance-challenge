# StreamLens Design

## Purpose

StreamLens transforms a UTF-8 NDJSON event stream into deterministic
aggregates. It is deliberately small enough to understand during a short exercise,
while its supplied implementation leaves multiple realistic performance trade-offs
for a candidate to investigate.

`PRD.md` defines all observable behavior. This document describes the current
component boundaries and the invariants an implementation must preserve.

## Components

- `cmd/streamlens` owns flags, file or standard-input selection, JSON output,
  diagnostics, and process exit status.
- `internal/analyzer` owns event decoding, validation, filtering, windowing,
  aggregation, and deterministic result ordering.
- `internal/assessment` owns deterministic benchmark workloads. Its input is built
  outside the timed region and covers balanced, high-cardinality, and mostly
  filtered streams.
- The profiling script runs the same analyzer workloads outside the authoritative
  sample loop and writes CPU and allocation pprof data plus top summaries.
- `scripts` and `.github/workflows` own protected-path validation and comparative
  reporting against the immutable baseline.

The analyzer entry point is:

```go
Analyze(ctx context.Context, input io.Reader, cfg Config) ([]Group, error)
```

`Config` supports optional inclusive `From`, optional exclusive `To`, an optional
event-type allow-list, a positive fixed `Window`, and a positive `TopK`. A zero
window defaults to one minute and a zero top-K defaults to three.

## Processing model

```text
io.Reader
  -> for each non-empty NDJSON line, in input order:
       decode and validate the event
       apply time and type filters
       assign a UTC-aligned window and aggregation key
       update exact counts and sequential float64 sums
  -> order groups and top users
  -> return []Group
  -> CLI encodes deterministic JSON
```

An invalid event stops processing. The returned error includes its one-based input
line number. An earlier aggregation error takes precedence over a later input
error. Unknown JSON fields and empty lines are ignored. Input lines may exceed the
default `bufio.Scanner` token size.

## Behavioral invariants

- Filtering occurs before aggregation.
- `From` is inclusive and `To` is exclusive.
- Window start is exactly `timestamp.UTC().Truncate(window)`.
- A group key is window start, tenant ID, and event type.
- Counts and unique-user results are exact. Value sums use sequential IEEE-754
  `float64` addition in input order; overflow returns an error.
- Top users sort by descending summed value, then ascending user ID.
- Groups sort by ascending window start, tenant ID, then event type.
- Identical input and configuration produce byte-for-byte identical CLI JSON.
- Malformed or invalid input returns an error with the correct line number.
- Unknown fields are syntax-checked but not converted; only the last occurrence of
  an exact field name is interpreted.
- Errors follow input order, so an earlier aggregation failure wins over a later
  malformed event.
- Cancellation is observed before processing and between completed reads and
  aggregation steps; an arbitrary reader blocked in `Read` is not interruptible.
- Empty output is a non-nil slice and CLI JSON is `[]`.
- The implementation uses only the Go standard library.

## Performance assessment

Benchmarks report `ns/op`, `B/op`, and `allocs/op` for three different workload
shapes. CI alternates baseline and candidate samples on the same hosted runner,
uses each scenario's median, and then calculates a geometric mean across scenarios.
Aggregate and per-scenario regression guards keep one large loss from being hidden
by gains elsewhere. This makes more than one optimization strategy viable without
making any single benchmark the entire exercise.

Tests and benchmark tooling are intentionally outside the candidate-editable area.
Candidates change only `internal/analyzer/engine.go` and `OPTIMIZATION.md`; all
behavioral boundaries above remain fixed.

## Profiling and scoring separation

`make profile-cpu` and `make profile-alloc` create
`.bench/profiles/cpu.pprof`, `.bench/profiles/alloc.pprof`,
`.bench/profiles/cpu-top.txt`, and `.bench/profiles/alloc-top.txt`. The targets are
repeatable entry points for Go pprof; they do not constrain the candidate to
pprof. A candidate may instead use another profiler or analysis tool and records
the actual observation in `OPTIMIZATION.md`.

CI profiles the candidate revision in a dedicated diagnostic step and includes
the top summaries in its job report. Authoritative scoring still comes only from
the alternating baseline-versus-candidate benchmark samples. Running a profiler
changes execution conditions, so profile measurements are never mixed into the
scored sample set.
