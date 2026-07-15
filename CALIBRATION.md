# Assessment calibration

Calibration is a maintainer-only release gate. It exercises the
`scripts/assess.sh` entry point that CI will use after the version 3 workflow
repin, retains raw evidence, and never modifies the supplied baseline, neutral
A/A, or optimized checkouts.

## Inputs and invocation

Prepare three separate, clean checkouts whose `HEAD` values are the exact full
SHAs passed on the command line. Also identify the candidate-scope base for each
candidate checkout; it may be a release/repin commit newer than the immutable
performance baseline:

1. the proposed immutable baseline;
2. a neutral candidate descended from that baseline, with source-equivalent
   executable code but a distinct commit accepted by the two-file scope guard;
3. a reviewed, known-valid optimized candidate descended from the baseline.

The neutral commit is necessary because the normal assessment correctly rejects
an empty candidate diff. The harness machine-verifies that both candidate scope
bases contain the exact immutable baseline `engine.go`. The neutral candidate
must equal that file byte-for-byte plus this single trailing line:

```go
// streamlens-calibration-neutral
```

Any other engine difference is rejected before controls or measurement.

Run from any directory, writing evidence to a new directory outside all three
checkouts. Its parent must be owned by the caller and must not be group- or
world-writable:

```sh
env -u BASH_ENV -u ENV \
  BENCH_SAMPLES=7 BENCH_TIME=300ms \
  ASSESSMENT_DOCKER_IMAGE='name@sha256:<digest>' \
  bash --noprofile --norc /path/to/repository/scripts/calibrate.sh \
    --baseline-dir /path/to/baseline --baseline-commit <40-sha> \
    --aa-dir /path/to/neutral \
      --aa-base-commit <40-sha> --aa-commit <40-sha> \
    --optimized-dir /path/to/optimized \
      --optimized-base-commit <40-sha> --optimized-commit <40-sha> \
    --optimized-min-tier Middle --optimized-max-tier Senior \
    --output-dir /private/path/to/new-calibration-output
```

The harness requires the real digest-pinned Docker runtime canary. It rejects
dirty or mismatched checkouts, mutable image inputs (through `assess.sh`), an
existing output path, output paths overlapping an input, fewer than five or more
than fifteen samples, and benchmark `GOMAXPROCS` values other than one.

A release-complete run requires at least seven samples and a duration-style
`BENCH_TIME` of at least `300ms`. Smaller accepted inputs such as five samples or
`1x` exist for harness smoke tests, but successful output is marked
`smoke-complete` and the summary says `smoke (not release evidence)`.

The provisional A/A guardrail is an absolute 10% change for every reported
scenario/metric median and geometric-mean result across `ns/op`, `B/op`, and
`allocs/op`. Override it explicitly with
`--aa-max-abs-percent` when investigating noise; a release threshold change must
be justified with retained evidence. `--max-wall-seconds` defaults to 3600 and
checks observed total duration after each bounded child phase. Container child
deadlines remain enforced by `scripts/run-isolated.sh`. The total wall value is
an acceptance bound, not a portable host-process watchdog; CI must also set a
job-level timeout for trusted Git, Go, and control-process failures.

## Implemented canaries

The harness first reuses the focused preparation, scope, and isolation suites,
then constructs private commits from data-only fixtures under
`internal/assessment/testdata/calibration` and submits them through `assess.sh`.
Fixture source is never sourced, compiled, or executed directly on the host.
The trusted source-audit process parses and type-checks policy fixtures on the
host; the wrong-result fixture is built and run only inside the restricted
container.

| Canary | Required result |
| --- | --- |
| Wrong aggregate result | Isolated functional tests reject it before sampling. |
| Independent snapshots | The protected reference aggregator recomputes all result hashes without calling `analyzer.Analyze`. |
| Fake benchmark output | Source policy rejects direct output before execution. |
| Filesystem mutation | Source policy rejects `os` access. |
| Process execution | Source policy rejects `os/exec` access. |
| Output close | Source policy rejects access to `os.Stdout`. |
| Protected path | Commit-based scope validation rejects the added path. |
| Extra symlink and FIFO | Reused preparation tests prove they never enter the synthetic tree. |
| Allowed-path symlink/special file | Reused preparation and scope tests reject them. |
| Hang and output overflow | Reused fake-Docker isolation tests prove deadline, bounded output, and CID-only cleanup. |
| Real container restrictions | Isolation suite requires the configured digest-pinned image and daemon. |

Every adversarial assessment must fail in its expected stage and must not create
non-empty benchmark sample files. A generic non-zero status is insufficient.

### Measured runtime canary

On 2026-07-15, the real runtime canary passed locally with:

```sh
ASSESSMENT_DOCKER_IMAGE='golang:1.26.5-bookworm@sha256:1ecb7edf62a0408027bd5729dfd6b1b8766e578e8df93995b225dfd0944eb651' \
  REQUIRE_DOCKER_RUNTIME=1 bash scripts/isolation-test.sh
```

The Docker server reported `linux/aarch64`; the digest-pinned image reported
`go1.26.5 linux/arm64`. The functional container check, isolated `1x` benchmark,
and isolated CPU/allocation profile extraction all passed. The real canary also
confirmed empty proxy variables, no host writes or external network access, and
cleanup before profile publication. This is evidence for the local container
lifecycle and restrictions only. It is not A/A noise evidence,
optimized-canary evidence, or proof of behavior on the GitHub-hosted runner. The
console result was observed during implementation but has not yet been retained
as a release artifact; the release run must retain its
`controls/isolation.log`.

### Measured local release calibration

On 2026-07-15, a complete local release run used the immutable baseline commit
`770e8cb4e206b697c63d18d119dcb6d97d07884b`, seven alternating samples at
`300ms`, and the exact image above. It retained
`.bench/calibration-baseline-v3/status.txt=complete` and reported:

- maximum absolute A/A change: 3.57% against the provisional 10% guardrail;
- A/A geometric means: -1.03% `ns/op`, +0.02% `B/op`, and 0.00%
  `allocs/op`;
- known-optimized geometric means: +22.70% `ns/op`, +31.06% `B/op`, and
  +17.23% `allocs/op`, for an overall Middle tier;
- all six adversarial canaries rejected before benchmark scoring; and
- 641 seconds total wall time against the 3600-second acceptance bound.

The A/A and optimized `manifest-core.json` SHA-256 values were respectively
`c1d441b68aceea4972a975e8e960d111b7bd64b8f6af61b948198fefb2da8f48` and
`d60ec72a371948904a0d742a53ebd044804b860f5514aa1d15bfac4315eca2ee`.
This is retained local evidence for the exact tagged baseline, not evidence for
the GitHub-hosted runner. Profiles and test binaries remain in ignored local
evidence storage rather than Git history.

## Evidence layout

The explicit output directory contains:

- `controls/*.log` for preparation, source/scope, independent-reference, and isolation suites;
- `adversarial/results.tsv` and one retained log per adversarial candidate;
- `measurements/aa/` and `measurements/optimized/`, each using the normal
  assessment evidence layout;
- `measurements/aa-improvements.tsv` and `measurements/aa-geomean.tsv`, the
  parsed scenario and aggregate noise values;
- `calibration-summary.md` and `status.txt`.

`status.txt` remains `failed exit=N` for an incomplete run. It changes to
`complete` only after input immutability is rechecked, A/A is within its bound,
the optimized result falls inside the explicitly requested tier range, and
release measurement parameters were used. A successful smaller run is labeled
`smoke-complete` and cannot be mistaken for release evidence.

## Evidence status

Implemented and locally construction-tested: input validation, non-overlapping
explicit output, reuse of existing guard suites, creation of temporary canary
commits, exact neutral-source equivalence, independent snapshot recomputation,
expected-stage enforcement, exact three-scenario A/A report parsing,
optimized-tier-range parsing, release/smoke separation, wall-time accounting,
and incomplete-run retention.

Pending before remote assessment v3 activation:

- the same release calibration on the pinned GitHub Actions runner;
- repetition of the passed digest-pinned runtime canary on the pinned CI runner;
- repeated-run noise analysis and any resulting guardrail adjustment.

The measured values above are exact-final-baseline local observations; they are
not claims about the GitHub-hosted runner.
