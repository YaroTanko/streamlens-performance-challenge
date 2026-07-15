# Contributing

This public repository is designed for candidate optimization pull requests. Read
`TASK.md` before starting; candidate submissions have a deliberately narrow edit
scope.

Assessment version 2 remains active. The version 3 policy described below becomes
authoritative only when maintainers release an immutable `baseline-v3` commit and
tag, pin the workflow to that full SHA, and pass a real runtime canary with the
exact digest-pinned container image. Landing documentation or helper tooling by
itself does not activate version 3.

## Fork and branch workflow

1. Fork the repository on GitHub.
2. Clone your fork and create a short-lived branch:

   ```sh
   git clone https://github.com/<your-user>/streamlens-performance-challenge.git
   cd streamlens-performance-challenge
   git switch -c optimize-analyzer
   ```

3. Run the starting checks:

   ```sh
   make check
   make benchmark
   make profile-cpu  # or make profile-alloc
   ```

4. Modify only `internal/analyzer/engine.go` and `OPTIMIZATION.md`.
5. Rerun the checks, commit, and push your branch:

   ```sh
   git add internal/analyzer/engine.go OPTIMIZATION.md
   git commit -m "Optimize event analysis"
   git push -u origin optimize-analyzer
   ```

6. Open a pull request from the fork branch to the upstream repository's default
   branch. Complete the pull-request template and inspect the GitHub Actions summary.

## Version 3 candidate integrity policy

Version 3 keeps the same candidate scope: modify only
`internal/analyzer/engine.go` and `OPTIMIZATION.md`. In that version,
`engine.go` must use a safe, reviewable subset of the Go standard library and may
not import `C`, `os`, `os/exec`, `unsafe`, `syscall`, `testing`, `flag`, `log`,
`log/slog`, `log/syslog`, `runtime/debug`, `runtime/pprof`, or `runtime/trace`.
Sensitive package-level `runtime` functions and variables, direct output through
`print`/`println` or `fmt.Print*`, unsafe cgo/compiler directives, and protected
benchmark detection are also rejected.

This restriction applies only inside candidate `engine.go`; profiling tools and
analysis commands outside the submitted implementation remain unrestricted. The
source guard is deliberately a workflow aid, not a complete security boundary.
Candidates should keep optimizations directly reviewable, and interviewers must
still inspect the exact diff and explanation.

The version 3 assessor creates a fresh synthetic tree from the immutable baseline
and overlays only the two regular-file deliverables. Candidate tests, scripts,
module metadata, generated files, submodules, and workflows are neither copied nor
executed. Fixed trusted commands run in a restricted digest-pinned container with
a read-only root and workspace, no network, bounded resources, deadline, and
output, followed by validated container-ID cleanup. The artifact set records
stable revisions, parameters, hashes, and sizes in `manifest-core.json`; volatile
time and runner metadata are isolated in `manifest.json`.

Maintainers must verify these restrictions with a real canary against the exact
pinned image before activating `baseline-v3`. Fake-runtime and
command-construction tests are useful prechecks but do not satisfy that release
gate.

## Optional push preflight

The repository includes an opt-in pre-push hook for inexpensive checks. Enable it
once in the clone before starting the timed exercise:

```sh
git config core.hooksPath .githooks
```

Before each push, the hook requires a clean worktree, checks the complete branch
diff against `origin/main`, verifies the two-file candidate scope and
`OPTIMIZATION.md`, checks `engine.go` formatting, and runs focused vet and
correctness tests. It deliberately skips comparative benchmarks.

If the assessment base is available under another ref, configure it for the
push or run the script directly:

```sh
STREAMLENS_BASE_REF=upstream/main git push
bash scripts/preflight.sh upstream/main
```

The hook fails closed when its base ref or required tools are unavailable. It is
only a local convenience; GitHub Actions remains authoritative.

GitHub may require a maintainer to approve Actions for a first-time fork
contributor. The interviewer should review the diff and approve the run; queue and
approval time are outside the candidate's 30-minute timer.

CI is authoritative: it verifies correctness and protected paths before comparing
the pull request with the immutable baseline on the same runner. Raw benchmark
outputs and diagnostic CPU/allocation profiles are attached as workflow artifacts.
The profiles support human review; only the comparative benchmark determines the
numeric result.

## Submission expectations

- Keep all observable behavior consistent with the deterministic PRD contract.
- Keep the implementation standard-library-only.
- Provide 5–10 concise bullets in `OPTIMIZATION.md`, including a truthful,
  non-empty `Profile evidence:` bullet naming the command or tool and hotspot.
- Do not modify or attempt to bypass protected assessment files.
- Treat the reported optimization tier as a performance result, not a statement of
  job seniority.

For repository-maintenance changes outside the candidate exercise, open a separate
issue or pull request clearly marked as maintenance rather than an assessment
submission.
