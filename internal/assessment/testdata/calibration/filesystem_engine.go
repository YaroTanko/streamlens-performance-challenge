package analyzer

import "os"

func calibrationFilesystemMutation() error {
	return os.WriteFile("host-write", []byte("must not run"), 0o600)
}
