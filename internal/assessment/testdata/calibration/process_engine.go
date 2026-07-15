package analyzer

import "os/exec"

func calibrationProcessExecution() error {
	return exec.Command("false").Run()
}
