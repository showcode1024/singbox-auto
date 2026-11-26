//go:build unix

package agent

import (
	"context"
	"errors"
	"syscall"
	"time"

	"github.com/showcode1024/singbox-auto/singbox-plus/internal/store"
)

// AcquireFileLock acquires an exclusive advisory flock on path, waiting up to timeout.
func AcquireFileLock(ctx context.Context, path string, timeout time.Duration) (func(), error) {
	if _, err := store.EnsurePrivateDir(path); err != nil {
		return nil, err
	}
	if err := store.RejectSymlink(path); err != nil {
		return nil, err
	}
	fd, err := syscall.Open(path, syscall.O_RDWR|syscall.O_CREAT|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return nil, err
	}
	_ = syscall.Fchmod(fd, 0o600)

	deadline := time.Now().Add(timeout)
	for {
		err := syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			return func() {
				_ = syscall.Flock(fd, syscall.LOCK_UN)
				_ = syscall.Close(fd)
			}, nil
		}
		if !errors.Is(err, syscall.EWOULDBLOCK) && !errors.Is(err, syscall.EAGAIN) {
			_ = syscall.Close(fd)
			return nil, err
		}
		if time.Now().After(deadline) {
			_ = syscall.Close(fd)
			return nil, &LockBusy{Msg: "another agent operation holds the local lock"}
		}
		select {
		case <-ctx.Done():
			_ = syscall.Close(fd)
			return nil, ctx.Err()
		case <-time.After(25 * time.Millisecond):
		}
	}
}
