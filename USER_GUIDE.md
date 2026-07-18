# StreamLens Go — User Guide

Use this page before choosing a command or opening a pull request. It separates
the public candidate workflow from the private evaluation workflow so that each
person uses only the repository and permissions they need.

## Choose your route

| You are… | Start here | Do not use |
| --- | --- | --- |
| A candidate completing the exercise | [Candidate route](#candidate-route) in this public repository | The private evaluator repository or maintainer-only commands |
| An interviewer reviewing a submission | [Interviewer route](#interviewer-route) in this public repository | Candidate files outside the committed pull-request revision |
| A maintainer operating the assessment | [Maintainer route](#maintainer-route) in this repository, then the private evaluator guide | Candidate workflows, tests, scripts, or local uncommitted changes as assessment input |
| An evaluator operator | The private repository's [`USER_GUIDE.md`](https://github.com/YaroTanko/streamlens-performance-evaluator/blob/main/USER_GUIDE.md) | Manual evaluation of an unrecorded or guessed revision |

The public challenge repository is
[`streamlens-performance-challenge`](https://github.com/YaroTanko/streamlens-performance-challenge).
The interviewer-owned evaluator is private; candidates neither need access to it
nor need to start it themselves.

This is a standalone Go exercise. Do not combine it with the separate Python
challenge or submit one solution to both.

## Candidate route

### 1. Prepare a clean branch

Before the session, the interviewer must send you a full 40-character
`STARTER_SHA`, normally the upstream `main` commit at the start of that session.
The Go release does not use `baseline-v3` as a candidate starter:
`baseline-v3` is the immutable evaluator baseline. The supplied SHA makes every
candidate in the session start from the same code even if `main` changes later.

Fork the public repository, then clone your fork and create one submission
branch from that exact commit:

```sh
git clone https://github.com/<your-user>/streamlens-performance-challenge.git
cd streamlens-performance-challenge
git remote add upstream https://github.com/YaroTanko/streamlens-performance-challenge.git
git fetch upstream
STARTER_SHA=<full-sha-sent-by-the-interviewer>
git switch -c optimize-analyzer "$STARTER_SHA"
go version
```

Use Go 1.26.5, selected by `go.mod`. The optional pre-push hook catches cheap
local errors, but does not replace CI:

```sh
git config core.hooksPath .githooks
```

If `go version` does not report Go 1.26.5, stop before the timer and ask the
interviewer to provision the required toolchain. Do not change `go.mod` or its
toolchain directive as a workaround.

The 30-minute timer starts only after the clean checkout and required Go
toolchain are ready. It stops at 30:00 or when you record your final local commit
SHA, whichever comes first. Pushing, opening the PR, CI queue time, and reading
the result are outside the timer.

### 2. Read the contract, then measure the baseline

Read these files in order:

1. [`TASK.md`](TASK.md) — scope, timing, and scoring.
2. [`PRD.md`](PRD.md) — observable behavior and source of truth.
3. [`DESIGN.md`](DESIGN.md) — invariants worth preserving.
4. [`AGENTS.md`](AGENTS.md) — instructions to give an AI coding assistant.
5. [`PROFILING.md`](PROFILING.md) — local profiling commands.

Run the starting checks before choosing an optimization:

```sh
make check
make benchmark
make profile-cpu
make profile-alloc
```

Use the profile to form a hypothesis. A benchmark tells you whether a change is
faster; a profile helps identify why it may be faster. You may use another
profiler, but record the actual observation in your notes.

### 3. Make the submission

Change exactly these two files:

```text
internal/analyzer/engine.go
OPTIMIZATION.md
```

For assessment version 3, `engine.go` must also remain inside the safe
standard-library subset described in `TASK.md`. In particular, do not add
filesystem, process, unsafe, benchmark-detection, direct-output, or
runtime-global controls to the submitted analyzer. Profiling tools remain allowed
outside that file.

Replace the optimization-note template with 5–10 concise bullets. Include a
truthful, non-empty `Profile evidence:` bullet naming the command or tool and the
hotspot you observed.

Before committing, rerun the checks and inspect the exact submission diff:

```sh
make check
make benchmark
make profile-cpu
git diff --check
git diff --name-only "$STARTER_SHA"...HEAD
```

The final command must print only the two allowed paths. Then commit, record the
full SHA before the timer ends, and push it:

```sh
git add internal/analyzer/engine.go OPTIMIZATION.md
git commit -m "Optimize event analysis"
git rev-parse HEAD
git push -u origin optimize-analyzer
```

Open a pull request from that branch to this repository's `main` branch. Keep the
PR as a draft while preparing it; mark it **Ready for review** only after the
recorded commit is pushed. Complete the pull-request template.

### 4. Read the result

For a ready PR, the public workflow automatically validates the committed scope
and source policy, runs correctness checks and comparative benchmarks, captures
diagnostic profiles, and dispatches the private evaluator. You do not start the
private evaluator yourself.

| What you see | Meaning | Your next action |
| --- | --- | --- |
| Protected scope or source policy failed | The submitted commit changed a forbidden path or uses a disallowed v3 construct | Fix only the two allowed files, commit a new revision, and push it before the timer if applicable |
| Functional tests failed | The observable contract changed | Fix the implementation and verify locally |
| A scored result is below target | The assessment ran correctly but did not reach the performance gate | Discuss the result with the interviewer; this is not an infrastructure error |
| Canary, image, evidence, or private-dispatch failure | Assessment infrastructure did not complete | Tell the interviewer; do not modify code merely to retry infrastructure |
| First-time fork workflow is awaiting approval | GitHub needs a maintainer action | Tell the interviewer; approval time is outside the timer |

CI is authoritative. It compares the immutable `baseline-v3` with your exact
committed revision. Local measurements are directional only.

## Interviewer route

### Prepare the session

Before starting a timer, fetch the public `main`, record its full commit SHA as
`STARTER_SHA`, and send that same SHA to every candidate:

```sh
git fetch origin main
git rev-parse origin/main
```

Confirm that Go 1.26.5 is available and that the candidate has a clean checkout.
The timer begins only after those checks; do not let a later `main` commit change
the candidate's starting point.

### One-time setup

Configure the public repository secret
`PRIVATE_EVALUATOR_DISPATCH_TOKEN`. It must be a fine-grained token scoped only
to `YaroTanko/streamlens-performance-evaluator` with **Actions: Read and write**.
It does not need Contents write permission.

```sh
gh secret set PRIVATE_EVALUATOR_DISPATCH_TOKEN \
  --repo YaroTanko/streamlens-performance-challenge
```

Do not give this token to candidates or place it in candidate-controlled files.

### For every candidate PR

1. Confirm that the candidate uses a fork and changes only
   `internal/analyzer/engine.go` and `OPTIMIZATION.md`.
2. Ask the candidate to mark the PR ready. A draft PR intentionally does not
   start the assessment.
3. If GitHub asks for first-time-contributor approval, approve the public
   workflow. This is an interviewer action, not candidate work.
4. Read the public job summary and artifact. Confirm the scope/source preflight,
   functional checks, isolation canary, and profile capture status before reading
   the performance tier.
5. Open the automatically dispatched private evaluator run only if you need its
   supplemental evidence. Do not request private-repository access from the
   candidate.
6. Review the exact diff, `OPTIMIZATION.md`, benchmark report, and profiles. The
   tier is evidence, not a hiring decision on its own.

If a reported metric is within two percentage points of a tier boundary, rerun
the same recorded candidate SHA once and use the lower inconsistent result, as
defined in `PRD.md`. Do not ask the candidate to alter code or notes for that
rerun.

## Maintainer route

Use this route only for assessment maintenance, not a candidate submission.

- The active assessment is version 3. `baseline-v3` is immutable; the workflow
  pins its full commit SHA and a digest-pinned Go container image.
- A change to the workload, source policy, tests, benchmark tooling, or runtime
  contract requires a new assessment version and a new immutable baseline. Do
  not edit those files in a candidate PR.
- For a local end-to-end assessment, use `make assess` with two clean exact Git
  checkouts and the required SHA inputs. See the **Maintainer assessment entry
  point** in [`README.md`](README.md); it requires Docker and the pinned image.
- Before activating a new version, run the calibration and real-runtime canary
  described in [`CALIBRATION.md`](CALIBRATION.md).
- Use the private evaluator's
  [`USER_GUIDE.md`](https://github.com/YaroTanko/streamlens-performance-evaluator/blob/main/USER_GUIDE.md)
  for manual re-evaluation and private evidence handling.

## Rules that apply to everyone

- Treat `PRD.md` as the product and assessment source of truth.
- Do not execute candidate-controlled workflows, tests, scripts, or generated
  files on a trusted host.
- Work from exact committed SHAs, never an uncommitted working tree.
- Keep candidate access public and minimal; keep evaluator evidence and tokens
  private.
