# Contributing

This public repository is designed for candidate optimization pull requests. Read
`TASK.md` before starting; candidate submissions have a deliberately narrow edit
scope.

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
