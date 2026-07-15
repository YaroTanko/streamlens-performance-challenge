# StreamLens Performance Challenge — Product Requirements Document

**Status:** Assessment version 2 is active; the version 3 integrity policy is
specified but remains inactive until the `baseline-v3` release
**Version:** 2.0 active; 3.0 activation requirements specified
**Language:** English
**Implementation language:** Go
**Source-of-truth rule:** The application, assessment instructions, tests, benchmarks, and CI workflow must conform to this document. If another repository document conflicts with this PRD, this PRD wins.

## 1. Product summary

StreamLens is a small command-line application with an exported in-repository Go analyzer component. It reads newline-delimited JSON (NDJSON) events, filters them, groups them into fixed time windows, and emits deterministic aggregate results.

The repository is also a 30-minute, AI-assisted Go performance exercise. The supplied implementation must be functionally correct and intentionally inefficient in realistic ways. A candidate forks the public repository, improves the implementation, documents the change, and opens a pull request. CI verifies correctness and reports the performance change against an immutable baseline.

## 2. Problem statement

Short Go interviews need an exercise that evaluates whether a candidate can:

1. orient themselves in an unfamiliar but documented codebase;
2. use profiling, benchmarks, source analysis, and an AI assistant responsibly;
3. preserve observable behavior while changing implementation details;
4. identify and improve CPU, memory, or allocation costs;
5. explain the optimization and its trade-offs concisely.

The result must be objectively measurable in CI and repeatable across candidate forks.

## 3. Users

### Candidate

A Go engineer completing the exercise in no more than 30 minutes. The candidate may use any AI assistant and any local analysis tools.

### Interviewer

An engineer reviewing the pull request, its CI report, the implementation choices, and `OPTIMIZATION.md`.

## 4. Goals

- Provide a complete, understandable Go project rather than an isolated algorithm puzzle.
- Keep the functional scope small enough to understand and modify in 30 minutes.
- Offer multiple legitimate optimization paths across execution time, bytes allocated, and allocation count.
- Produce deterministic functional results and low-noise comparative benchmarks.
- Require a concise, plausible profile observation before accepting an optimization.
- Provide repeatable local CPU and allocation profiling without requiring a
  particular profiler.
- Report the candidate result as Middle, Senior, or Staff optimization tier.
- Make the repository friendly to AI-assisted development through canonical project documentation.
- Keep the public-fork CI safe: no secrets, privileged tokens, or untrusted deployment steps.

## 5. Non-goals

- The exercise does not assess networking, databases, distributed systems, or cloud deployment.
- The optimization tier is not, by itself, a hiring or seniority decision.
- The baseline must not contain artificial delays, deliberate deadlocks, broken behavior, or misleading tests.
- Candidates are not expected to redesign the public API or output format.
- Approximate aggregation is out of scope: counts, membership, and ordering remain exact, while sums preserve the specified sequential `float64` semantics.

### 5.1 Public-repository integrity model

Benchmark fixtures and previous pull-request solutions are discoverable because the repository is public. Protected paths prevent accidental assessment changes; they do not make the exercise secret or adversarial. Interviewers must review the explanation and diff, not use the numeric tier as the sole hiring signal. Assessment versions should be rotated when solutions become common, and any material change to workloads or implementation receives a new pinned baseline.

### 5.2 Version 3 trust boundary and activation

Assessment version 3 adds a reviewable candidate source policy, a synthetic
baseline overlay, restricted container execution, and evidence manifests. These
layers reduce accidental or straightforward same-process interference; neither
the source guard nor the container is a complete security boundary for code that
runs inside the benchmark process. The public exercise remains non-adversarial,
and the interviewer must still review the candidate diff and explanation.

The version 3 policy applies only after all of the following are released as one
internally consistent assessment version: an immutable `baseline-v3` commit and
tag, a workflow pinned to that full commit SHA, and a successful real-runtime
canary using the exact digest-pinned container image. Merely merging the helper
tools or this policy does not activate version 3. Until that release, version 2
remains the active candidate contract and no document may claim that the version
3 isolation path is authoritative.

## 6. Candidate journey

1. Fork the public repository.
2. Create a branch in the fork.
3. Read `README.md` and `TASK.md`; use `PRD.md` and `DESIGN.md` as reference material and provide `AGENTS.md` to the AI assistant.
4. Run the functional tests, local benchmark, and at least one profiling tool.
5. Use the profile evidence, source analysis, and any AI assistant to choose an
   optimization.
6. Optimize permitted implementation files without changing observable behavior.
7. Add a 5–10 bullet explanation to `OPTIMIZATION.md`, including the profiling
   command or tool and an observed hotspot.
8. Push the branch and open a pull request to the upstream repository.
9. Inspect the CI correctness and performance report.

For a first-time fork contributor, GitHub may hold the workflow pending maintainer approval. The interviewer reviews the diff and approves the run; this wait is outside the candidate timer.

### 6.1 Timing boundary

Timed work starts after the interviewer provides a clean checkout and confirms that the required Go toolchain is available. It ends at 30:00 or when the candidate records the final local commit SHA, whichever comes first. Clone and toolchain setup, pushing the recorded commit, pull-request creation, GitHub Actions queue/runtime, and reading the final CI report are untimed. The submitted pull request must contain the recorded SHA; post-timer implementation or documentation changes are not allowed except an interviewer-approved rerun of the same SHA after infrastructure failure.

## 7. Event input

The application accepts UTF-8 NDJSON. Each non-empty line contains one event:

```json
{"timestamp":"2026-01-15T12:34:56.123Z","tenant_id":"acme","user_id":"user-42","type":"purchase","value":19.95}
```

### 7.1 Event fields

| Field | Type | Requirements |
| --- | --- | --- |
| `timestamp` | string | Valid RFC3339Nano timestamp with an explicit offset |
| `tenant_id` | string | Non-empty |
| `user_id` | string | Non-empty |
| `type` | string | Non-empty |
| `value` | number | Representable as a finite Go `float64` and greater than or equal to zero |

Required field names use the exact lowercase spellings in the schema. Differently cased names are treated as unknown fields. Unknown fields must contain syntactically valid JSON but are otherwise ignored without application-level type or numeric-range conversion. When the same exact JSON field occurs more than once, only its last value is interpreted. Empty and whitespace-only lines are ignored. A malformed or invalid event stops processing and returns an error containing the one-based input line number.

Processing is ordered by input line. Each accepted event is aggregated before the
next line is processed, so when an input contains multiple independent failures,
the error encountered on the earliest line takes precedence.

## 8. Analysis configuration

The analyzer and CLI support:

- optional inclusive `from` timestamp;
- optional exclusive `to` timestamp;
- optional allow-list of event types;
- fixed window size, defaulting to one minute and required to be positive;
- top-K user count, defaulting to three and required to be positive.

Filtering happens before aggregation. Events outside the time interval or type allow-list do not contribute to output.

## 9. Aggregation behavior

Events are grouped by:

1. UTC-aligned fixed window start;
2. `tenant_id`;
3. event `type`.

Window start is defined exactly as `timestamp.UTC().Truncate(window)`, using Go's `time.Time.Truncate` semantics.

For every group, StreamLens returns:

- total event count;
- deterministic sequential `float64` sum of `value` in input order;
- exact count of unique users;
- up to K users with the highest summed value in the group.

Top users are ordered by descending summed value and then ascending `user_id` to break ties.

Group and per-user sums use ordinary IEEE-754 `float64` addition in input order. Implementations must not reorder additions or substitute an approximate aggregate. If an addition overflows to infinity, analysis returns a processing error instead of returning a non-finite result.

Aggregate groups are ordered by ascending window start, then ascending `tenant_id`, then ascending event type. JSON output must be byte-for-byte deterministic for identical input and configuration.

No matching events produce the JSON array `[]`, not `null`. A canonical single-group output is:

```json
[{"window_start":"2026-01-15T12:34:00Z","tenant_id":"acme","type":"purchase","count":2,"sum":30,"unique_users":2,"top_users":[{"user_id":"user-42","value":19.95},{"user_id":"user-7","value":10.05}]}]
```

## 10. Public API and CLI

The internal package exposes an in-repository analyzer API that accepts `context.Context`, an `io.Reader`, and a configuration value. It is not a library API for external Go modules. A nil context or input returns an error. Cancellation is observed before processing and between completed input reads and aggregation steps; the analyzer is not required to interrupt an arbitrary `io.Reader` blocked inside its `Read` method.

The `streamlens` CLI supports input from a file or standard input and writes the aggregate result as JSON to standard output. Diagnostics go to standard error. A processing error exits non-zero.

The project must depend only on the Go standard library unless this PRD is amended.
Starting with assessment version 3, candidate code in
`internal/analyzer/engine.go` uses the narrower safe-standard-library subset in
Section 15.1. That restriction applies to the submitted analyzer implementation,
not to profiling commands or analysis tools run outside `engine.go`.

## 11. Baseline implementation requirements

- The baseline is correct and passes all tests.
- Its inefficiencies must arise from plausible data-processing choices.
- It must contain several independent optimization opportunities.
- Removing only one bottleneck should be capable of producing a meaningful but not necessarily maximum score.
- Combining implementation and algorithmic improvements should make higher tiers reachable.
- The code must not label individual lines as deliberate bottlenecks or prescribe the solution.
- CI pins the baseline by its full 40-character upstream commit SHA. A
  `baseline-v2` tag is a human-readable alias and is not the source of truth.
- Any change to the implementation, tests, fixtures, benchmark tooling, or pinned Go toolchain creates a new assessment version and baseline commit.
- Version 3 must not become active until `baseline-v3`, the pinned workflow, the
  documented source policy, the synthetic overlay, the restricted runner, and
  its real digest-pinned runtime canary are released together.

## 12. Functional verification

Tests must cover:

- parsing valid events and ignoring unknown fields;
- empty-line behavior;
- validation failures with line numbers;
- inclusive `from` and exclusive `to` filtering;
- event-type filtering;
- UTC window alignment, including non-UTC input offsets;
- count, sum, unique-user, and top-K correctness;
- deterministic group and top-user ordering;
- context cancellation;
- inputs larger than the default `bufio.Scanner` token size;
- CLI success and failure behavior.

All functional tests must pass before a performance result is accepted.

## 13. Benchmark design

The benchmark workload is deterministic and generated in memory outside the timed region. It includes at least these scenarios:

1. **Balanced:** representative tenants, event types, users, and windows.
2. **High cardinality:** many grouping keys and users.
3. **Mostly filtered:** most valid input events are excluded by configuration.

Each scenario reports:

- `ns/op` for execution time;
- `B/op` for bytes allocated;
- `allocs/op` for allocation count.

CI runs the immutable baseline and the pull-request revision on the same GitHub-hosted runner with Go 1.26.5 and normally seven alternating samples per scenario (never fewer than five). The report uses each scenario's median and shows per-scenario results plus a geometric-mean improvement for every metric.

Starting with assessment version 3, each retained sample is strictly framed and
contains the ordered Go benchmark headers `goos`, `goarch`, and `pkg`, followed
by the exact protected benchmark rows and normal `PASS`/`ok` trailer. A single
`cpu` header is accepted only after `pkg` and must be consistent when present; it
is optional because the Go tool legitimately omits it on some platforms,
including the pinned Linux/arm64 image.

If an aggregate result is within two percentage points of the 20%, 50%, or 75% boundaries, the interviewer should rerun the exact same candidate SHA once. When the two runs produce different tiers or pass/fail outcomes, use the lower result and retain both reports. No code or documentation change is allowed for that rerun.

## 14. Scoring and CI policy

Correctness is mandatory. CI fails when functional tests fail or protected assessment files change.
CI also fails when `OPTIMIZATION.md` does not contain 5–10 bullets or its
`Profile evidence:` bullet is missing, empty, or still contains template prompts.
This validation establishes that evidence was reported, not that a particular
tool was used; plausibility remains a human-review decision.

For each metric, improvement is calculated relative to the immutable baseline:

```text
improvement = (baseline - candidate) / baseline * 100
```

The report assigns an optimization tier independently to execution time, bytes allocated, and allocation count:

| Improvement | Tier |
| --- | --- |
| less than 20% | Below target |
| 20%–49.99% | Middle |
| 50%–74.99% | Senior |
| 75% or more | Staff |

The overall reported tier is the highest tier reached by any metric. To pass the performance gate:

- at least one metric must improve by 20% or more; and
- no metric's geometric mean may regress by more than 20%; and
- no individual scenario/metric pair may regress by more than 30%.

An improvement of exactly -20.00% for a metric geometric mean or -30.00% for a scenario/metric pair is allowed; only a larger regression fails the gate.

The percentages describe the optimization result, not the candidate's job level.

### 14.1 Profiling evidence

Profiling guides the candidate's choice; it is separate from authoritative
benchmark scoring. The repository provides `make profile-cpu` and
`make profile-alloc`, but candidates may use another profiler.
`OPTIMIZATION.md` must name the command or tool used and the observed hotspot.

CI independently captures CPU and allocation profiles for the submitted revision's
`Balanced` scenario and publishes both machine-readable pprof files and
human-readable top summaries. These artifacts help the interviewer evaluate
whether the explanation is plausible; they do not prove which tool the candidate
used during the timed work. The interviewer reviews that evidence and the
implementation rather than treating the presence of a CI profile as proof of
candidate process.

## 15. Protected assessment files

Candidate pull requests may change only:

- the analyzer implementation paths explicitly listed in `TASK.md`;
- `OPTIMIZATION.md`.

Tests, benchmark fixtures, benchmark comparison tooling, module metadata, documentation other than `OPTIMIZATION.md`, and GitHub Actions workflows are protected. CI must reject accidental protected-file changes. This guard is a workflow aid, not a security boundary; the interviewer still reviews the diff.

### 15.1 Candidate analyzer source policy for version 3

This subsection is inactive for version 2 and becomes part of the candidate
contract only at the `baseline-v3` activation described in Section 5.2. Candidate
pull requests still edit exactly `internal/analyzer/engine.go` and
`OPTIMIZATION.md`; the source policy does not expand that scope.

The submitted `engine.go` must remain a straightforward, reviewable analyzer
implementation using a safe subset of the Go standard library. It must not:

- import `C`, `os`, `os/exec`, `unsafe`, `syscall`, `testing`, `flag`, `log`,
  `log/slog`, `log/syslog`, `runtime/debug`, `runtime/pprof`, or
  `runtime/trace`;
- use package-level functions or variables resolved from `runtime` to inspect or
  mutate process-wide runtime state;
- write diagnostics through the `print` or `println` built-ins or
  `fmt.Print`, `fmt.Printf`, or `fmt.Println`;
- use cgo or unsafe compiler directives such as `//go:linkname`, `//go:cgo_*`,
  or `#cgo`; or
- detect the protected benchmark package, benchmark function, or test benchmark
  flags through source strings or equivalent source-level markers.

The prohibited imports cover filesystem and process access, subprocesses,
unsafe/system calls, test hooks, flag and logging side effects, and runtime
debugging, profiling, or tracing from inside the measured analyzer. Other
standard-library packages remain available when they preserve the PRD contract.
Profilers, debuggers, shell commands, and other tools used outside `engine.go`
remain unrestricted and may be used to gather the required profile evidence.

The guard parses and type-checks the exact committed analyzer source so aliases
and shadowed names are distinguished. It is intended to produce specific,
reviewable failures for common integrity violations. It is a workflow aid rather
than a complete language sandbox or proof of benign behavior; human review is
still required.

### 15.2 Candidate construction and execution for version 3

At version 3 activation, the authoritative assessment must construct a fresh
synthetic tree from the immutable baseline and overlay exactly the candidate's
regular-file versions of `internal/analyzer/engine.go` and `OPTIMIZATION.md`.
All tests, benchmark workloads, scripts, module metadata, generated files, and
workflow definitions come from the baseline. Candidate-provided tests, scripts,
module files, workflow files, symlinks, submodules, and other paths must not be
copied into or executed from the synthetic tree.

Trusted correctness and benchmark commands must run from that tree in an
immutable digest-pinned container image with a read-only root and workspace, no
network or IPC access, dropped capabilities, no privilege escalation, a non-root
user, and bounded CPU, memory, process, and file resources. The trusted parent
owns benchmark framing and artifacts, enforces a finite wall-clock deadline and
combined-output limit, and removes only the validated container ID recorded for
that invocation. Deadline, output-limit, and container-ID cleanup failures must
fail closed.

Before this path may become authoritative, a real runtime canary must exercise
the exact pinned image and demonstrate the required host-write and network
restrictions, fixed test and benchmark commands, and normal validated-CID cleanup.
Separate bounded canaries must cover deadline, output-limit, and cleanup-failure
handling. Construction tests or a fake runtime alone do not satisfy the activation
requirement.

## 16. CI output

Every pull request produces a GitHub Actions job summary containing:

- functional-test status;
- protected-file status;
- baseline and candidate values for every benchmark and metric;
- percentage change per scenario;
- geometric-mean improvement for time, bytes, and allocations;
- tier for each metric and the overall optimization tier;
- top CPU and allocation profile summaries for the candidate revision;
- the final pass/fail reason.

Raw benchmark outputs are retained as workflow artifacts. The same artifact
contains `profiles/cpu.pprof`, `profiles/alloc.pprof`,
`profiles/cpu-top.txt`, and `profiles/alloc-top.txt` for the candidate revision.
Profile capture is diagnostic and runs separately from the alternating benchmark
samples used for scoring. The workflow uses the `pull_request` event with
read-only permissions and does not use secrets.

When version 3 is activated, each authoritative assessment artifact set also
contains `manifest-core.json`, with sorted revisions, fixed assessment parameters,
and SHA-256 plus size for every recorded artifact, and `manifest.json`, which
adds volatile generation time and runner metadata. Re-creating the core manifest
over identical inputs must produce identical bytes. The manifest records the
evidence chain; it does not turn the source guard or same-process benchmark into a
cryptographic security boundary.

## 17. Repository documentation

All repository documentation and user-facing text are written exclusively in English.

The repository contains:

- `PRD.md` — product and assessment source of truth;
- `README.md` — short orientation and quick start;
- `TASK.md` — candidate rules and deliverables;
- `DESIGN.md` — current architecture and invariants;
- `PROFILING.md` — local profiling commands and interpretation guidance;
- `AGENTS.md` — canonical instructions for AI coding agents;
- `OPTIMIZATION.md` — candidate response template;
- `CONTRIBUTING.md` — fork and pull-request workflow;
- a pull-request template;
- a license appropriate for a public assessment repository.

## 18. Acceptance criteria

The repository is ready when:

1. a clean checkout builds with the documented Go version;
2. all functional tests pass;
3. the local benchmark command is deterministic and documented;
4. the supplied baseline is measurably inefficient across multiple metrics;
5. at least one validated implementation can reach each optimization tier;
6. CI fetches the full pinned baseline commit SHA from the upstream repository, compares a fork pull request with it, and emits the required summary;
7. CI rejects a pull request that changes protected files;
8. no workflow exposes secrets or grants write permission to forked code;
9. all documentation is in English and internally consistent;
10. `make profile-cpu` and `make profile-alloc` produce valid local pprof files
    and readable top summaries without affecting benchmark scoring;
11. CI publishes candidate CPU and allocation profiles plus top summaries as
    diagnostic artifacts;
12. CI validates the 5–10 bullet response and requires a completed
    `Profile evidence:` bullet without treating it as proof of tool use;
13. a reviewer can understand the optimization and its profile rationale from the
    pull request and a 5–10 bullet `OPTIMIZATION.md`.
14. version 3 is not advertised as active before an immutable `baseline-v3`
    release and workflow repin;
15. version 3 source-policy failures identify a reviewable offending construct
    while legitimate analyzer optimizations within the safe subset pass;
16. version 3 evaluates only the two candidate deliverables overlaid onto the
    immutable baseline and never executes candidate tests, scripts, module
    metadata, or workflows;
17. the exact digest-pinned version 3 container image passes a real runtime canary
    for host-write, network, fixed-command, and normal CID-cleanup behavior, while
    bounded canaries cover deadline, output-limit, and cleanup failures; and
18. version 3 evidence manifests reproduce byte-for-byte for unchanged core
    inputs and keep volatile runner metadata outside the deterministic core.
