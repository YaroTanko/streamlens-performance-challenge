package analyzer

type localPrinter struct{}

func (localPrinter) Println(string) {}

func implementationVersion() int {
	fmt := localPrinter{}
	fmt.Println("local method")
	print := func(string) {}
	print("local function")
	return 2
}
