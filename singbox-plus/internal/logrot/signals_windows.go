//go:build windows

package logrot

import (
	"os"
	"os/exec"
	"os/signal"
)

func forwardSignals(proc *os.Process) func() {
	ch := make(chan os.Signal, 4)
	signal.Notify(ch, os.Interrupt)
	done := make(chan struct{})
	go func() {
		for {
			select {
			case sig := <-ch:
				if proc != nil {
					_ = proc.Signal(sig)
				}
			case <-done:
				return
			}
		}
	}()
	return func() {
		signal.Stop(ch)
		close(done)
	}
}

func exitCodeFromError(exitErr *exec.ExitError) int {
	return exitErr.ExitCode()
}
