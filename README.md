# StreamLens Performance Challenge

[![StreamLens assessment](https://github.com/YaroTanko/streamlens-performance-challenge/actions/workflows/assessment.yml/badge.svg)](https://github.com/YaroTanko/streamlens-performance-challenge/actions/workflows/assessment.yml)

StreamLens is a small Go CLI and in-repository analyzer component that reads NDJSON events, filters them,
groups them into fixed UTC-aligned windows, and produces deterministic aggregate
results. This repository is also a 30-minute, AI-assisted performance exercise:
preserve the behavior, improve the implementation, and let CI measure the result.

`PRD.md` is the source of truth for product behavior and assessment policy. Read
`TASK.md` before making a candidate change.

**Start here:** [`USER_GUIDE.md`](USER_GUIDE.md) tells candidates, interviewers,
and maintainers which repository to use, which commands to run, and what each CI
result means.

## Quick start

Use the Go version declared in `go.mod`.

```sh
make check
make benchmark
make profile-cpu
make profile-alloc
```

Roughly equivalent raw commands are:

```sh
go test ./...
GOMAXPROCS=1 go test -run '^$' -bench . -benchmem -cpu=1 ./internal/assessment
```

## Maintainer assessment entry point (v3)

Maintainers can run the hardened local flow against two clean, exact Git
checkouts. All inputs are required; the output path must not exist, and the
output parent must be owned by the caller without group/world write permission.
The container image must be pinned by digest.

```sh
BASELINE_CHECKOUT=/path/to/clean/base \
CANDIDATE_CHECKOUT=/path/to/clean/candidate \
BASELINE_SHA=<full-40-character-pinned-baseline-sha> \
CANDIDATE_BASE_SHA=<full-40-character-pr-base-sha> \
CANDIDATE_SHA=<full-40-character-candidate-sha> \
ASSESS_OUTPUT=/path/to/new-results \
ASSESSMENT_DOCKER_IMAGE='golang:1.26.5-bookworm@sha256:1ecb7edf62a0408027bd5729dfd6b1b8766e578e8df93995b225dfd0944eb651' \
make assess
```

The pinned benchmark baseline and the candidate's PR base are separate inputs,
so a later workflow-repin commit does not become part of candidate scope. The
command validates committed scope first, constructs symmetric synthetic
trees, runs candidate correctness and alternating benchmark samples through the
restricted container runner, compares them with trusted baseline tooling, then
captures a separate isolated CPU/allocation profile and writes `functional.txt`,
`benchmarks/`, `profiles/`, `profile.txt`, and a transactional `evidence/`
manifest generation.
Comparator exits remain `0` for pass, `1` for a valid result below the gate, and
`2` for comparison or infrastructure errors. Profiles remain diagnostic and are
never mixed into scored samples. A real local run requires an available Docker
daemon and the pinned image to be present because the runner uses `--pull=never`.

### Automatic private evaluator dispatch

Each ready candidate pull request that passes the trusted scope/source preflight
automatically dispatches the private evaluator with the exact head repository,
unique PR merge-base SHA, head SHA, PR number, and public-run URL derived from
the trusted `pull_request_target` event. No interviewer input is required per
run. Draft PRs wait until they are marked ready. Once a newer head is
successfully dispatched, it cancels the obsolete private run for the same PR.

One Actions secret is required on this public repository:

- `PRIVATE_EVALUATOR_DISPATCH_TOKEN`: a fine-grained token limited to
  `YaroTanko/streamlens-performance-evaluator` with **Actions: Read and write**.
  It does not need Contents write permission.

Configure it once under **Settings → Secrets and variables → Actions**, or with:

```sh
gh secret set PRIVATE_EVALUATOR_DISPATCH_TOKEN \
  --repo YaroTanko/streamlens-performance-challenge
```

The secret is used only by code checked out at the exact trusted workflow
revision to call the private workflow dispatch API. It is never exposed to
candidate files, tests, build commands, or the isolated analyzer process. The
public assessment records the dispatch and fails as an infrastructure error if
it cannot be created, while its own assessment and evidence capture still
complete. The private evidence records a deterministic
`repository#PR@head-SHA` correlation identifier and the public-run URL.

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
`OPTIMIZATION.md`. Keep the output and observable behavior unchanged, write a 5–10
bullet optimization note with a concrete profile observation, and open a pull
request to the upstream repository.

CI first verifies tests and protected paths. It then compares the immutable
baseline and pull-request revision on the same runner, reporting time, bytes, and
allocations. Passing requires at least 20% improvement in one metric with no more
than 20% aggregate regression in another metric and no more than 30% regression
in any scenario/metric pair. See `TASK.md` for the complete rules.

Local benchmark values help guide development, but only the comparative CI run is
authoritative. A reported Middle, Senior, or Staff optimization tier describes the
measured result, not the candidate's job level or hiring outcome.

The provided profiling targets write CPU and allocation pprof data and top
summaries to `.bench/profiles/`. They are a convenient starting point, not a tool
restriction: any profiler may be used. CI captures fresh candidate profiles for
review, but profiles are diagnostic and do not contribute to the score. See
`PROFILING.md` for commands and interpretation guidance.

## Documentation

- `PRD.md`: product requirements and assessment source of truth
- `USER_GUIDE.md`: role-based candidate, interviewer, and maintainer workflow
- `TASK.md`: candidate scope, scoring, and deliverables
- `DESIGN.md`: architecture and behavioral invariants
- `PROFILING.md`: profiler-agnostic workflow and local pprof commands
- `AGENTS.md`: instructions for AI coding agents
- `CONTRIBUTING.md`: fork and pull-request workflow
- `OPTIMIZATION.md`: candidate explanation template
