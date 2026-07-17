package analyzer

import "os"

func calibrationOutputClose() error {
	return os.Stdout.Close()
}
