## Summary

<!-- Briefly describe the implementation change. -->

## Local verification

<!-- Include relevant `make check` and `make benchmark` results. CI is authoritative. -->

## Checklist

- [ ] I changed only `internal/analyzer/engine.go` and `OPTIMIZATION.md`.
- [ ] I preserved exact behavior, deterministic ordering, and the public API.
- [ ] `make check` passes locally.
- [ ] I ran `make benchmark` before and after the change.
- [ ] `OPTIMIZATION.md` contains a concise 5–10 line explanation and trade-offs.
- [ ] I did not special-case tests or benchmark workloads.
