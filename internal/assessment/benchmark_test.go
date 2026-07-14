package assessment_test

import (
	"bytes"
	"context"
	"testing"

	"github.com/YaroTanko/streamlens-performance-challenge/internal/analyzer"
	"github.com/YaroTanko/streamlens-performance-challenge/internal/benchfixture"
)

var benchmarkResult []analyzer.Group

func BenchmarkAnalyze(b *testing.B) {
	for _, scenario := range benchfixture.Scenarios() {
		scenario := scenario
		b.Run(scenario.Name, func(b *testing.B) {
			b.ReportAllocs()
			b.ResetTimer()

			for i := 0; i < b.N; i++ {
				groups, err := analyzer.Analyze(
					context.Background(),
					bytes.NewReader(scenario.Input),
					scenario.Config,
				)
				if err != nil {
					b.Fatalf("Analyze() error: %v", err)
				}
				if len(groups) == 0 {
					b.Fatal("Analyze() returned no groups")
				}
				benchmarkResult = groups
			}
		})
	}
}
