//go:build unix

package main

import (
	"os"
	"syscall"
)

func shutdownSignals() []os.Signal {
	return []os.Signal{syscall.SIGTERM, syscall.SIGINT}
}

func setPrivateUmask() {
	syscall.Umask(0o077)
}
