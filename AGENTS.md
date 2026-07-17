# Instructions for AI Coding Agents

This repository is a timed Go performance assessment. Help the candidate analyze
and improve the existing implementation while preserving the contract. AI use is
explicitly allowed; do not conceal uncertainty or claim benchmark gains that were
not measured.

## Authority and scope

1. `PRD.md` is the product and assessment source of truth.
2. `TASK.md` defines the candidate-editable scope and scoring policy.
3. `DESIGN.md` summarizes architecture and invariants.

Assessment version 3 is active and anchored by the immutable `baseline-v3`
package and workflow pin. Older recorded submissions retain their original
assessment-version contract.

For a candidate pull request, edit exactly:

- `internal/analyzer/engine.go`
- `OPTIMIZATION.md`

Do not edit or generate tests, fixtures, benchmark code, scripts, module metadata,
other documentation, workflows, or additional implementation files. If a requested
change requires a protected path, explain the conflict instead of making the edit.

## Version 3 candidate source policy

For `baseline-v3`, keep candidate `engine.go` within the documented
safe-standard-library subset. Do not import `C`, `os`, `os/exec`, `unsafe`,
`syscall`, `testing`, `flag`, `log`, `log/slog`, `log/syslog`, `runtime/debug`,
`runtime/pprof`, or `runtime/trace`. Do not use package-level `runtime` functions
or variables, `print`/`println`, `fmt.Print*`, unsafe cgo/compiler directives, or
source markers intended to recognize the protected benchmark.

These restrictions apply only to the submitted `internal/analyzer/engine.go`.
Profiling and analysis tools outside that file remain unrestricted: help the
candidate use pprof, system profilers, debuggers, shell tools, and AI assistance
as appropriate. Do not move profiling or process-control behavior into the
analyzer to evade the boundary.

The version 3 guard parses and type-checks exact committed source, but it is a
workflow aid rather than a complete security boundary. Keep every optimization
ordinary, small, and human-reviewable within the 30-minute task; never imply that
passing the source audit proves benign behavior.

At version 3 activation, assessment construction starts from the immutable
baseline and overlays exactly `internal/analyzer/engine.go` and
`OPTIMIZATION.md`. Candidate tests, scripts, module metadata, generated files,
submodules, and workflows are not copied or executed. Fixed trusted commands run
in a restricted digest-pinned container with bounded deadline and output, and the
trusted parent performs validated CID cleanup and writes evidence manifests. A
real canary using that exact image is required before activation; fake-runtime
tests do not satisfy that requirement.

## Working rules

- Inspect and profile the implementation before selecting an optimization. The
  repository provides `make profile-cpu` and `make profile-alloc`, but another
  profiler is equally acceptable.
- Preserve the specified parsing, validation, filtering, aggregation, ordering, error, and
  cancellation behavior.
- Do not convert ignored fields, interpret only the last exact duplicate field,
  and preserve earliest-line error precedence.
- Preserve input-order `float64` sum semantics and overflow errors; do not reorder
  additions or substitute approximate arithmetic.
- Use only the Go standard library and preserve the exported in-repository API and JSON format.
- For an active version 3 assessment, also preserve the safe-standard-library
  subset above; do not propose a prohibited package or sensitive
  runtime/process/output API as an optimization.
- Never weaken, bypass, special-case, or detect tests and benchmark workloads.
- Never replace specified results with approximations or skip valid input work.
- Keep the change reviewable within a 30-minute exercise.
- Record the measured or expected effect and any trade-off in `OPTIMIZATION.md`.
- Include a non-empty `Profile evidence:` bullet naming the command or tool and an
  observed hotspot. Do not claim profile evidence that was not observed.

## Verification

Run:

```sh
make check
make benchmark
# Run at least one profiling target (or use another profiler):
make profile-cpu    # CPU hotspots
make profile-alloc  # allocation hotspots
```

If `make` is unavailable, run:

```sh
go vet ./...
go test ./...
go build ./...
GOMAXPROCS=1 go test -run '^$' -bench . -benchmem -cpu=1 ./internal/assessment
```

Treat local benchmark changes as directional because CI performs the authoritative
same-run baseline comparison. Before finishing, inspect the diff and confirm that
only the two allowed files changed and that `OPTIMIZATION.md` contains 5–10 concise
bullets explaining the profile evidence, approach, expected effect, trade-offs,
and verification. Profiling is diagnostic and remains separate from scoring.
