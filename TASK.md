# Candidate Task

## Objective

You have up to 30 minutes to profile and improve StreamLens performance without
changing its observable behavior. You may use any AI assistant, profiler, editor,
or local analysis tool. Correctness is mandatory.

The timer starts after a clean checkout and the required Go toolchain are ready.
It stops at 30:00 or when you record your final local commit SHA. Clone/toolchain
setup, pushing that SHA, PR creation, CI runtime, and reading its report are not
timed. Do not change the submitted code or notes after recording the SHA.

## Allowed changes

Your pull request may modify exactly these files:

- `internal/analyzer/engine.go`
- `OPTIMIZATION.md`

Everything else is protected, including tests, benchmarks, fixtures, scripts,
module metadata, documentation, and GitHub Actions workflows. CI rejects a pull
request that changes a protected path. Do not move implementation into a new file.

## Required behavior

- Preserve the `Analyze(ctx, io.Reader, Config) ([]Group, error)` contract.
- Preserve parsing, validation, filtering, ordering, cancellation, and error
  behavior defined in `PRD.md`.
- Preserve deterministic sequential `float64` sums and exact counts, membership,
  and ordering; approximate aggregation is not allowed.
- Keep the project standard-library-only.
- Do not hard-code benchmark data or detect benchmark scenarios.

## Suggested workflow

1. Read `README.md` and this file; give `AGENTS.md`, `PRD.md`, and `DESIGN.md` to
   your AI assistant or consult them when behavior is unclear.
2. Run `make check`, `make benchmark`, and either a provided profiling target or
   another profiler. The provided targets are `make profile-cpu` and
   `make profile-alloc`; see `PROFILING.md`.
3. Use the observed hotspot to choose one or more measurable improvements.
4. Edit `internal/analyzer/engine.go`, then rerun correctness checks and benchmarks.
5. Replace the template in `OPTIMIZATION.md` with 5–10 concise bullets, including
   a non-empty `Profile evidence:` bullet that names the command or tool and the
   observed hotspot. Commit both deliverables and record the commit SHA before the
   timer ends.
6. After the timer, push that exact SHA, open an upstream pull request, and inspect
   its CI summary. A first-time fork workflow may wait for interviewer approval.

## Scoring

CI compares the immutable baseline and your revision on the same runner. It reports
the geometric-mean change across benchmark scenarios independently for execution
time (`ns/op`), allocated bytes (`B/op`), and allocation count (`allocs/op`).

| Improvement in a metric | Reported tier |
| --- | --- |
| Less than 20% | Below target |
| 20%–49.99% | Middle |
| 50%–74.99% | Senior |
| 75% or more | Staff |

The overall result is the highest tier reached by any metric. The performance gate
passes only when at least one metric improves by 20% or more, no metric's geometric
mean regresses by more than 20%, and no individual scenario/metric pair regresses
by more than 30%. Functional or protected-file failures always fail the assessment.

Benchmark noise and trade-offs are normal: improving CPU time, allocated bytes, or
allocation count are all legitimate approaches. Local results are directional;
the CI comparison is authoritative. If a result is within two percentage points of
a tier boundary, the interviewer may rerun the exact same commit and use the lower
of inconsistent outcomes. Tiers describe this optimization result only and must
not be interpreted as a candidate seniority or hiring decision.

Profiling is diagnostic and separate from scoring. CI creates its own CPU and
allocation pprof files and top summaries for interviewer review, but those
artifacts cannot prove which tool you used. Your `Profile evidence:` note must
truthfully describe your own observation; another profiler is as valid as the
provided Go pprof targets.

## Deliverables

- An implementation change in `internal/analyzer/engine.go`.
- A 5–10 bullet explanation in `OPTIMIZATION.md` covering profile evidence, the
  change, expected effect, trade-offs, and verification.
- A pull request from a branch in your public fork to the upstream repository.
