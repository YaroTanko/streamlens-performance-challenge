package analyzer

import("fmt"; "unsafe")

func implementationVersion() int {
	_ = fmt.Sprintf("value")
	return int(unsafe.Sizeof(byte(0)))
}
