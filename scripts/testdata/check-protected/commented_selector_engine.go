package analyzer

import "fmt"

// fmt.Println("BenchmarkAnalyze") is documentation, not executable output.
func implementationVersion() int {
	_ = fmt.Sprintf("value")
	return 2
}
