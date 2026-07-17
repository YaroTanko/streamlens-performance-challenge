package analyzer

import "fmt"

// Comments may discuss BenchmarkAnalyze, fmt.Println, or import "os" without
// turning those words into executable tampering behavior.
func implementationVersion() int {
	counts := map[string]int{"events": 2}
	_ = fmt.Sprintf("%s=%d", "events", counts["events"])
	_ = "fmt.Println is text here, not a call"
	return counts["events"]
}
