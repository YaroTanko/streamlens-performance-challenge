package analyzer

import "un\u0073afe"

func implementationVersion() int {
	return int(unsafe.Sizeof(byte(0)))
}
