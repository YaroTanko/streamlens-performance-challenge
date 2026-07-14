# Profiling StreamLens

Profiling should guide the optimization, but it is not itself a scoring metric.
The comparative CI benchmark remains authoritative for `ns/op`, `B/op`, and
`allocs/op`. Use the profiler that helps you reason clearly; Go pprof is provided
only as a repeatable default.

## Provided commands

Capture a CPU profile and its top summary:

```sh
make profile-cpu
```

Capture an allocation profile and its top summary:

```sh
make profile-alloc
```

Both targets profile the `Balanced` scenario by default. Select another workload
when its shape is more relevant to your hypothesis:

```sh
PROFILE_SCENARIO=HighCardinality make profile-cpu
PROFILE_SCENARIO=MostlyFiltered make profile-alloc
```

Valid scenario names are `Balanced`, `HighCardinality`, and `MostlyFiltered`.

The commands write:

- `.bench/profiles/cpu.pprof`
- `.bench/profiles/alloc.pprof`
- `.bench/profiles/cpu-top.txt`
- `.bench/profiles/alloc-top.txt`

The files are local diagnostics and are ignored by Git. Each command replaces the
corresponding previous output, so save a copy elsewhere if you need before/after
profiles.

## Inspecting pprof data

The generated text files provide a quick flat view. The retained
`.bench/profiles/assessment.test` binary lets you inspect the raw profiles
directly:

```sh
go tool pprof -top .bench/profiles/assessment.test .bench/profiles/cpu.pprof
go tool pprof -top -sample_index=alloc_space \
  .bench/profiles/assessment.test .bench/profiles/alloc.pprof
go tool pprof -top -sample_index=alloc_objects \
  .bench/profiles/assessment.test .bench/profiles/alloc.pprof
```

CPU samples point to code consuming processor time. `alloc_space` highlights the
total bytes allocated during the run, while `alloc_objects` emphasizes allocation
count. Allocation profiles use Go's normal statistical sampling; use benchmark
`B/op` and `allocs/op` for quantitative before/after comparisons. A hot function
is evidence to investigate, not automatic proof that it should be rewritten;
confirm the relevant call path and preserve the PRD contract.

## Other profilers are allowed

You may use another profiler, including an IDE profiler, Go execution tracing, or
operating-system performance tooling. Benchmark inspection, compiler diagnostics,
and source analysis may supplement the result, but do not replace a measured
profile. Application dependencies must remain standard-library-only, but a local
development tool does not become an application dependency merely because you use
it during the exercise.

In `OPTIMIZATION.md`, keep the `Profile evidence:` label and name the actual
command or tool plus the hotspot you observed. For example, describe which parser,
aggregation, sorting, or allocation path dominated; do not claim a finding that
was not measured.

## CI diagnostics

CI independently profiles the submitted candidate revision's `Balanced` scenario
and publishes `profiles/cpu.pprof`, `profiles/alloc.pprof`,
`profiles/cpu-top.txt`, and `profiles/alloc-top.txt` in the workflow artifact. It
also places top summaries in the job report. This independent capture helps the
interviewer judge whether the written explanation is plausible, but it cannot
prove which tool the candidate used during the timed session.

Profile collection runs outside the alternating baseline-versus-candidate samples.
It therefore does not contribute to the optimization percentage or tier. Treat a
profile as guidance and the CI benchmark comparison as the final performance
measurement.
