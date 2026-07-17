# Optimization notes

- Profile evidence: `go test -cpuprofile` showed map-key construction as the largest sampled hotspot.
- Replaced repeated linear lookups with an in-memory map.
- Preserved input-order additions and deterministic output sorting.
- Expected effect: fewer comparisons for high-cardinality inputs.
- Trade-off: the map retains a small amount of extra capacity.
- Verification: functional tests and the local benchmark passed.
