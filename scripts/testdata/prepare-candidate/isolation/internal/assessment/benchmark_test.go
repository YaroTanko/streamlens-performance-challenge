package assessment

import "testing"

func BenchmarkAnalyze(b *testing.B) {
	b.Run("IsolationCanary", func(b *testing.B) {
		for range b.N {
		}
	})
	b.Run("Balanced", func(b *testing.B) {
		for range b.N {
		}
	})
}
