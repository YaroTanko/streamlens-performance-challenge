package analyzer

import host "os"

func mutate(file *host.File) {
	_ = file.Close()
}
