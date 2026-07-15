# StreamLens Assessment Hardening - Implementation Plan

**Goal:** Make correctness and performance assessment failures explicit, reproducible, and difficult to trigger accidentally, while preserving the candidate contract and the 30-minute exercise.
**Estimate:** Five to seven maintainer sessions plus local and CI calibration runs.
**Dependencies:** A clean maintainer branch based on assessment v2, access to GitHub Actions for calibration, and the immutable v2 baseline commit `6b25bcaca101b840db27a5bfabbfadb7a523a6d6`.

Patterns adapted from OpenClaw are fail-closed lifecycle checks, explicit protocol boundaries, deterministic fixtures, layered verification, and cheap checks before expensive execution. This plan does not treat hooks or same-process benchmark output as a complete security boundary.

## Current status

- Implemented and verified locally: complete-result verification for every protected benchmark scenario.
- Implemented and verified locally: strict begin/end framing, output grammar, and retained failure diagnostics for every benchmark sample.
- Implemented and verified locally: transactional evidence-manifest generations with a schema-v1 golden hash.
- Implemented and verified locally: opt-in check-only pre-push preflight, including branch-refspec integration tests.
- Implemented and verified with construction, fake-runtime, and exact-image real canaries: synthetic candidate trees; bounded test, benchmark, and profile execution; proxy clearing; cleanup-before-publication; and an AST/type-aware candidate source policy.
- Implemented and self-tested locally: the six-revision-boundary assessment entry point, isolated diagnostic profiles, explicit source-policy documentation, and the calibration/adversarial harness.
- Observed exact-image gate: `golang:1.26.5-bookworm@sha256:1ecb7edf62a0408027bd5729dfd6b1b8766e578e8df93995b225dfd0944eb651` passed functional, `1x` benchmark, profile extraction, network/host-write/proxy restrictions, and validated-CID cleanup on Linux/arm64 Docker Desktop.
- Released locally: immutable baseline commit `770e8cb4e206b697c63d18d119dcb6d97d07884b` and annotated `baseline-v3` tag.
- Measured and retained against that exact SHA: seven-sample A/A stayed within 3.57%, the known-optimized canary reached Middle (`+22.70% ns/op`, `+31.06% B/op`, `+17.23% allocs/op`), all six adversarial canaries failed before scoring, and the complete harness finished in 641 seconds.
- Pending before remote activation: commit and push the trusted-base `pull_request_target` workflow repin, then repeat the runtime canary and release calibration on the pinned GitHub Actions runner and analyze repeated-run noise.

**Current trust boundary:** The local implementation catches correctness regressions, malformed logs, protected-tree changes, host-hook configuration, and common process/filesystem/output tampering. It does not cryptographically authenticate code running in the benchmark process: same-process behavior remains review-based under the PRD's non-adversarial public-repository model. The restricted lifecycle has passed an exact-image local canary but is not authoritative until the complete baseline is tagged, the workflow is repinned, and retained release calibration passes on the pinned runner.

### Step 1: Lock benchmark scenarios to complete expected results

**What:** Verify the deterministic serialization hash of every full scenario result in both functional tests and after each timed benchmark invocation. Keep hashing outside the measured region and avoid an untimed warm-up of the measured input. Independently recompute the three snapshots with an opt-in protected reference aggregator that does not call `analyzer.Analyze`.
**Files:** `internal/assessment/benchmark_test.go`, `internal/assessment/reference_test.go`
**Commands:** `go test ./internal/assessment -count=1`; `go test -tags reference -run '^TestReferenceScenarioResults$' ./internal/assessment`; `GOMAXPROCS=1 go test -run '^$' -bench '^BenchmarkAnalyze$' -benchmem -benchtime=1x -count=1 -cpu=1 ./internal/assessment`
**Check:** Every scenario rejects changed values, ordering, missing groups, or changed top users; benchmark metrics remain non-zero; the independent reference aggregator produces the same three hashes.
**Result:** A fast benchmark result cannot be accepted merely because it is non-empty.

### Step 2: Make benchmark sample parsing fail closed

**What:** Wrap every child run in sequential begin/end markers, prefix untrusted child output, require the expected Go benchmark header/row/trailer grammar, and reject missing, duplicate, reordered, inconsistent, or cross-run samples. Require ordered `goos`, `goarch`, and `pkg`; accept `cpu` only as a unique, consistent optional header because Go omits it on some platforms.
**Files:** `scripts/run-benchmarks.sh`, `cmd/benchcompare/main.go`, `cmd/benchcompare/main_test.go`
**Commands:** `go test ./cmd/benchcompare -count=1`; `BENCH_SAMPLES=5 BENCH_TIME=1x bash scripts/run-benchmarks.sh . . /tmp/streamlens-aa`; `go run ./cmd/benchcompare -baseline /tmp/streamlens-aa/baseline.txt -candidate /tmp/streamlens-aa/candidate.txt -min-samples 5`
**Check:** A valid A/A run parses and reports Below target with the expected non-zero performance-gate exit; malformed markers, forged extra rows, hidden rows, unequal sample sets, and failed child commands are rejected with useful diagnostics.
**Result:** The comparator consumes only complete, attributable samples instead of scanning arbitrary log text.

### Step 3: Build and run candidates in an isolated synthetic tree

**What:** Create a fresh tree from the assessment baseline, copy only `internal/analyzer/engine.go` and `OPTIMIZATION.md` from the candidate, and build trusted test binaries from that tree. Run them in a restricted container with a read-only root, no network, dropped capabilities, cleared proxy variables, and no benchmark-results mount; the trusted parent captures and frames output. Extract five fixed, size-bounded profile files through the validated live CID and publish them only after successful CID cleanup. Do not execute candidate scripts, workflows, tests, or module metadata.
**Files:** `scripts/prepare-candidate.sh`, `scripts/prepare-candidate-test.sh`, `scripts/run-isolated.sh`, `scripts/isolation-test.sh`, `scripts/testdata/prepare-candidate/`, `.github/workflows/assessment.yml`
**Commands:** `bash scripts/prepare-candidate-test.sh`; `bash scripts/isolation-test.sh`; `git diff --no-index baseline-tree prepared-candidate`
**Check:** Synthetic candidates containing changed tests, scripts, symlinks, submodules, generated files, or renamed paths cannot influence the prepared tree; fake-runtime canaries prove deadline, output-cap, and CID cleanup failure handling; `REQUIRE_DOCKER_RUNTIME=1` must prove host-write/network restrictions against the pinned image in CI.
**Result:** CI evaluates only the allowed implementation and prevents it from directly rewriting trusted host artifacts, while retaining the documented same-process output limitation.

### Step 4: Harden the candidate scope guard

**What:** Parse NUL-delimited Git name/status and mode changes, reject renames, copies, symlinks, submodules, and non-regular allowed files, and apply an AST/type-aware source policy to exact committed blobs for process access, filesystem APIs, stdout/stderr manipulation, runtime mutation, benchmark detection, and unsafe/system calls in `engine.go`.
**Files:** `scripts/check-protected.sh`, `scripts/check-protected-test.sh`, `scripts/testdata/check-protected/`, `cmd/sourceaudit/main.go`, `cmd/sourceaudit/main_test.go`
**Commands:** `go test ./cmd/sourceaudit -count=1`; `bash scripts/check-protected-test.sh`
**Check:** Every malicious fixture fails with the exact offending path or construct, while representative legitimate optimizations pass.
**Result:** The two-file candidate allowlist becomes deterministic and catches common same-process benchmark tampering.

### Step 5: Use one assessment entry point locally and in CI

**What:** Add one trusted orchestration script for protected checks, correctness, alternating samples, comparison, and profile capture; call the same entry point from `Makefile` and GitHub Actions.
**Files:** `scripts/assess.sh`, `scripts/assess-test.sh`, `Makefile`, `.github/workflows/assessment.yml`, `README.md`
**Commands:** `make assess`; `bash scripts/assess-test.sh`
**Check:** Local and CI invocations produce the same directory layout, exit codes, report, and failure ordering for the same revisions.
**Result:** Fewer discrepancies between a candidate's local preflight and the authoritative workflow.

### Step 6: Stabilize execution inputs and emit an evidence manifest

**What:** Fix the GitHub-hosted OS label to `ubuntu-24.04`, retain SHA-pinned Actions and Go toolchain inputs, and capture the available runner image/version metadata. Write deterministic revisions, parameters, and artifact SHA-256 values to `manifest-core.json`; put timestamps and runner metadata in a separate `manifest.json` envelope.
**Files:** `.github/workflows/assessment.yml`, `scripts/assess.sh`, `cmd/evidencemanifest/main.go`, `cmd/evidencemanifest/main_test.go`
**Commands:** `go test ./cmd/evidencemanifest -count=1`; `make assess`; `sha256sum .bench/assessment/manifest-core.json`
**Check:** Re-running the manifest command over unchanged artifacts produces the same `manifest-core.json`; volatile timestamps and runner metadata are isolated in the envelope.
**Result:** Every report states exactly what code and environment produced it.

### Step 7: Add calibration and adversarial canaries

**What:** Run A/A noise calibration, a known valid optimized implementation, and synthetic candidates that return wrong data, print fake benchmark rows, close output, mutate files, or alter protected paths.
**Files:** `internal/assessment/testdata/calibration/`, `scripts/calibrate.sh`, `CALIBRATION.md`
**Commands:** `BENCH_SAMPLES=7 BENCH_TIME=300ms bash scripts/calibrate.sh`; `go test ./...`
**Check:** A/A stays inside documented noise and wall-clock bounds, the optimized canary reaches its expected range, the independent result oracle matches all snapshots, and every adversarial canary fails before scoring.
**Result:** Thresholds and guards have measured evidence instead of relying only on unit tests.

### Step 8: Add a cheap check-only preflight hook

**What:** Provide an opt-in repository hook that runs formatting, protected-scope validation, focused correctness tests, and documentation checks without running the full benchmark suite.
**Files:** `.githooks/pre-push`, `scripts/preflight.sh`, `scripts/preflight-test.sh`, `CONTRIBUTING.md`
**Commands:** `bash scripts/preflight-test.sh`; `bash scripts/preflight.sh`; `git config core.hooksPath .githooks`
**Check:** The hook fails closed on missing tools or failed checks, remains opt-in, and never modifies candidate files.
**Result:** Candidates catch inexpensive failures before pushing while authoritative scoring remains in CI.

### Step 9: Release the complete package as assessment v3

**What:** Update the specification and design for correctness hashes, framed samples, trust boundaries, evidence, and calibration; create a v3 baseline commit and tag; then repin the workflow to that full commit SHA in a follow-up commit.
**Files:** `PRD.md`, `TASK.md`, `DESIGN.md`, `AGENTS.md`, `README.md`, `.github/workflows/assessment.yml`
**Commands:** `make check`; `make benchmark`; `make profile-cpu`; `BENCH_SAMPLES=7 BENCH_TIME=300ms bash scripts/calibrate.sh`; `git rev-parse HEAD`
**Check:** All checks pass, the full A/A and optimized-canary runs are retained, `baseline-v3` points to the immutable baseline commit, and the workflow references the same 40-character SHA.
**Result:** The new tooling actually runs in CI as one internally consistent assessment version.
