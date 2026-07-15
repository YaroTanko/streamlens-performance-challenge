package assessment_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"testing"

	"github.com/YaroTanko/streamlens-performance-challenge/internal/analyzer"
	"github.com/YaroTanko/streamlens-performance-challenge/internal/benchfixture"
)

var benchmarkResult []analyzer.Group

// scenarioResultSHA256 snapshots the deterministic encoding/json serialization
// of each fixture's complete result from immutable v2 baseline
// 6b25bcaca101b840db27a5bfabbfadb7a523a6d6, independently checked by the
// reference-tagged aggregator. It detects changes to values, ordering, and the
// complete TopUsers lists.
var scenarioResultSHA256 = map[string]string{
	"Balanced":        "c97917c47448f0ab9c0acaeb395ae0c60486e6fe88cbcd80b2dce0d162938589",
	"HighCardinality": "5a15bb2bb03fb6fe281632d86acff025cf4df6d55852ee3d95bb30783ba0b9b1",
	"MostlyFiltered":  "4d9c9675e6c83a0cd78645654f5f0375825b3d786b332c83955e2f302745716c",
}

func TestBenchmarkScenarioResults(t *testing.T) {
	for _, scenario := range benchfixture.Scenarios() {
		scenario := scenario
		t.Run(scenario.Name, func(t *testing.T) {
			// Repeated calls catch accidental state leakage between analyses.
			for run := 0; run < 3; run++ {
				assertScenarioResult(t, scenario, analyzeScenario(t, scenario))
			}
		})
	}
}

func BenchmarkAnalyze(b *testing.B) {
	for _, scenario := range benchfixture.Scenarios() {
		scenario := scenario
		b.Run(scenario.Name, func(b *testing.B) {
			b.ReportAllocs()
			b.ResetTimer()

			var groups []analyzer.Group
			for i := 0; i < b.N; i++ {
				var err error
				groups, err = analyzer.Analyze(
					context.Background(),
					bytes.NewReader(scenario.Input),
					scenario.Config,
				)
				if err != nil {
					b.Fatalf("Analyze() error: %v", err)
				}
				benchmarkResult = groups
			}
			b.StopTimer()
			assertScenarioResult(b, scenario, groups)
		})
	}
}

func analyzeScenario(tb testing.TB, scenario benchfixture.Scenario) []analyzer.Group {
	tb.Helper()

	groups, err := analyzer.Analyze(
		context.Background(),
		bytes.NewReader(scenario.Input),
		scenario.Config,
	)
	if err != nil {
		tb.Fatalf("Analyze() error: %v", err)
	}
	return groups
}

func assertScenarioResult(tb testing.TB, scenario benchfixture.Scenario, groups []analyzer.Group) {
	tb.Helper()

	encoded, err := json.Marshal(groups)
	if err != nil {
		tb.Fatalf("marshal complete result: %v", err)
	}
	digest := sha256.Sum256(encoded)
	got := hex.EncodeToString(digest[:])
	if want, ok := scenarioResultSHA256[scenario.Name]; !ok {
		tb.Fatalf("no expected result evidence for scenario %q", scenario.Name)
	} else if got != want {
		tb.Fatalf("deterministic result SHA-256 = %s, want %s", got, want)
	}
}
