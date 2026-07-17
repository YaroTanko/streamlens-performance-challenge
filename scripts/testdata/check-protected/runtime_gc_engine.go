package analyzer

import "runtime"

func implementationVersion() int {
	runtime.GC()
	return 2
}
