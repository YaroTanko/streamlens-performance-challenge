package analyzer

import "os"

func mutate(file *os.File) {
	_, _ = file.Write([]byte("forged output"))
}
