## Summary

<!-- Briefly describe the implementation change. -->

## Local verification

<!-- Include relevant checks, benchmarks, and the profiler/tool used. CI is authoritative. -->

## Checklist

- [ ] I changed only `internal/analyzer/engine.go` and `OPTIMIZATION.md`.
- [ ] I preserved exact behavior, deterministic ordering, and the public API.
- [ ] `make check` passes locally.
- [ ] I ran `make benchmark` before and after the change.
- [ ] I profiled the analyzer with a provided target or another profiling tool.
- [ ] `OPTIMIZATION.md` contains 5–10 concise bullets, including a non-empty
      `Profile evidence:` bullet that names the command/tool and observed hotspot.
- [ ] I did not special-case tests or benchmark workloads.
