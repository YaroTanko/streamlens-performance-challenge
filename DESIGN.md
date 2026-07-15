# StreamLens Design

## Purpose

StreamLens transforms a UTF-8 NDJSON event stream into deterministic
aggregates. It is deliberately small enough to understand during a short exercise,
while its supplied implementation leaves multiple realistic performance trade-offs
for a candidate to investigate.

`PRD.md` defines all observable behavior. This document describes the current
component boundaries and the invariants an implementation must preserve.

Assessment version 2 remains active. The version 3 boundaries in this document
are a pending release design and become authoritative only when an immutable
`baseline-v3` commit, its workflow pin, and the exact-image real runtime canary
are released together.

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

Version 3 adds four maintainer-owned integrity components without expanding the
candidate-editable area:

- the protected scope/source guard reads exact committed blobs, enforces the
  two-file allowlist, and parses and type-checks `engine.go` without running it;
- the candidate preparer copies the immutable baseline into a fresh synthetic
  tree and overlays only `internal/analyzer/engine.go` and `OPTIMIZATION.md`;
- the isolated runner invokes fixed trusted test or benchmark commands inside an
  immutable digest-pinned restricted container; and
- the evidence-manifest writer records revisions, parameters, and artifact
  digests in a deterministic core, with timestamps and runner identity in a
  separate volatile envelope.

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

Starting with assessment version 3, the framed parser requires ordered `goos`,
`goarch`, and `pkg` headers in every sample. Go's `cpu` header is optional for
platform portability, but when emitted it may appear only once after `pkg` and
must remain identical across samples and between baseline and candidate.

Tests and benchmark tooling are intentionally outside the candidate-editable area.
Candidates change only `internal/analyzer/engine.go` and `OPTIMIZATION.md`; all
behavioral boundaries above remain fixed.

## Version 3 source-policy boundary

The version 3 analyzer is standard-library-only and additionally uses a safe,
reviewable subset appropriate for same-process assessment integrity. Candidate
`engine.go` cannot import `C`, `os`, `os/exec`, `unsafe`, `syscall`, `testing`,
`flag`, `log`, `log/slog`, `log/syslog`, `runtime/debug`, `runtime/pprof`, or
`runtime/trace`. A type-aware audit also rejects package-level `runtime` functions
and variables, direct output through `print`, `println`, and `fmt.Print*`, unsafe
cgo/compiler directives, and protected-benchmark detection markers.

The restriction is intentionally local to candidate `engine.go`. Trusted
repository code and candidate profiling tools outside that file may use runtime,
process, output, tracing, and profiling APIs as needed. This preserves unrestricted
diagnostic choice while keeping the submitted implementation small and directly
reviewable within the 30-minute exercise.

The audit catches common filesystem, process, runtime-global, and output
interference, including aliases resolved by Go type checking. It cannot prove all
possible program behavior and is not a language sandbox. It remains one workflow
aid inside the PRD's non-adversarial, human-reviewed trust model.

## Version 3 construction and isolated execution

The authoritative flow is:

```text
immutable baseline tree + candidate engine.go + candidate OPTIMIZATION.md
  -> validate regular files and exact committed source policy
  -> create fresh baseline-owned synthetic tree with only those two overlays
  -> run fixed trusted test/benchmark command in digest-pinned container
  -> trusted parent bounds deadline/output and captures framed evidence
  -> remove the invocation's validated container ID
  -> hash artifacts into deterministic core + volatile manifest envelope
```

The preparer never traverses candidate paths beyond the two deliverables. Tests,
benchmarks, scripts, module metadata, generated files, submodules, and workflows
therefore come from the immutable baseline and candidate versions of them are not
executed. The container uses a read-only root and workspace, no network or IPC,
dropped capabilities, no privilege escalation, a non-root user, and explicit CPU,
memory, process, and file bounds. The parent process owns benchmark framing and
artifact storage rather than mounting a writable results directory into the
container.

GitHub Actions uses `pull_request_target` so the workflow definition is loaded
from the trusted base branch instead of the pull request merge commit. The token
is explicitly read-only and no secrets are referenced. Checkout v7's explicit
unsafe-PR opt-out is used only to materialize the exact fork commit as data;
trusted baseline code reads its committed blobs, and no host step runs a command
from that checkout. Candidate analyzer execution begins only after the two-file
overlay enters the restricted no-network container.

Wall-clock and combined-output limits fail closed. Cleanup uses only the validated
container ID produced for that invocation and is itself bounded. These controls
reduce host-side effects but do not authenticate output produced by analyzer code
inside the trusted benchmark process. A real canary against the exact
digest-pinned image must demonstrate host-write and network restrictions,
fixed-command execution, and normal CID cleanup before `baseline-v3` activation.
Separate bounded canaries cover deadline, output-limit, and cleanup-failure
handling; fake-runtime and command-construction tests alone are insufficient for
the image-specific release gate.

`manifest-core.json` contains stable, sorted revision identifiers, assessment
parameters, and SHA-256 plus size for retained artifacts. `manifest.json` wraps
that evidence with generation time and available runner metadata. Unchanged core
inputs must serialize identically, while volatile environment facts do not change
the core digest.

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

The version 3 source restriction does not limit this diagnostic workflow: pprof,
other profilers, debuggers, and process-level tools remain available outside
candidate `engine.go`.
