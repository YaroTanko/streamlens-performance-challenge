package analyzer

import "unsafe"

func implementationVersion() int {
	return int(unsafe.Sizeof(byte(0)))
}
