//go:build windows

package agent

import (
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"time"

	"github.com/showcode1024/singbox-auto/singbox-plus/internal/store"
)

// RunProcess executes args and terminates the child on timeout or context cancellation.
func RunProcess(ctx context.Context, args []string, timeout, _ time.Duration, cfg map[string]any) ([]byte, error) {
	if len(args) == 0 {
		return nil, agentErr("empty command")
	}
	outFile, err := os.CreateTemp("", ".ysq-out-*")
	if err != nil {
		return nil, err
	}
	defer func() {
		name := outFile.Name()
		_ = outFile.Close()
		_ = os.Remove(name)
	}()

	errFile, err := os.CreateTemp("", ".ysq-err-*")
	if err != nil {
		return nil, err
	}
	defer func() {
		name := errFile.Name()
		_ = errFile.Close()
		_ = os.Remove(name)
	}()

	runCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	cmd := exec.CommandContext(runCtx, args[0], args[1:]...)
	cmd.Stdin = nil
	cmd.Stdout = outFile
	cmd.Stderr = errFile

	waitErr := cmd.Run()
	if errors.Is(runCtx.Err(), context.DeadlineExceeded) && ctx.Err() == nil {
		return nil, agentErr("local helper timed out; its process group was terminated; configuration must be checked on the next sync")
	}
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}

	if _, err := outFile.Seek(0, io.SeekStart); err != nil {
		return nil, err
	}
	output, err := io.ReadAll(io.LimitReader(outFile, store.MaxBody+1))
	if err != nil {
		return nil, err
	}

	errTail := readTail(errFile, 8192)
	if waitErr != nil {
		code := 1
		var exitErr *exec.ExitError
		if errors.As(waitErr, &exitErr) {
			code = exitErr.ExitCode()
		}
		return nil, agentErr("local command failed (%d): %s", code, Redact(errTail, cfg))
	}
	if len(output) > store.MaxBody {
		return nil, agentErr("local helper output exceeds 2 MiB")
	}
	return output, nil
}

func readTail(f *os.File, maxBytes int64) string {
	size, err := f.Seek(0, io.SeekEnd)
	if err != nil || size <= 0 {
		return ""
	}
	start := size - maxBytes
	if start < 0 {
		start = 0
	}
	if _, err := f.Seek(start, io.SeekStart); err != nil {
		return ""
	}
	b, _ := io.ReadAll(io.LimitReader(f, maxBytes))
	return string(b)
}
