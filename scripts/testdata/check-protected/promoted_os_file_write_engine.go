package analyzer

import "os"

type fileWrapper struct {
	*os.File
}

func mutate(file fileWrapper) {
	_, _ = file.Write([]byte("forged output"))
}
