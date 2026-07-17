package analyzer

import "flag"

func implementationVersion() int {
	return flag.NArg()
}
