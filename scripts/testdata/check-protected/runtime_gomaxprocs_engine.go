package analyzer

import machine "runtime"

func implementationVersion() int {
	return machine.GOMAXPROCS(1)
}
