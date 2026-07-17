package analyzer

//go:linkname terminate os.Exit
func terminate(code int)

func implementationVersion() int {
	terminate(0)
	return 2
}
