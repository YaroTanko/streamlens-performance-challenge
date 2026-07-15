package analyzer

import (
	"io"
	"os"
)

func mutate(file *os.File) {
	var writer io.Writer = file
	_, _ = writer.Write([]byte("forged output"))
}
