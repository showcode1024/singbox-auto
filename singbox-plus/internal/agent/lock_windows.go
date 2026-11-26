//go:build windows

package agent

import (
	"context"
	"os"
	"time"

	"github.com/showcode1024/singbox-auto/singbox-plus/internal/store"
	"golang.org/x/sys/windows"
)

// AcquireFileLock acquires an exclusive Windows file lock on path, waiting up to timeout.
func AcquireFileLock(ctx context.Context, path string, timeout time.Duration) (func(), error) {
	if _, err := store.EnsurePrivateDir(path); err != nil {
		return nil, err
	}
	if err := store.RejectSymlink(path); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, err
	}
	h := windows.Handle(f.Fd())
	deadline := time.Now().Add(timeout)

	for {
		var ol windows.Overlapped
		err := windows.LockFileEx(h, windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &ol)
		if err == nil {
			return func() {
				var uol windows.Overlapped
				_ = windows.UnlockFileEx(h, 0, 1, 0, &uol)
				_ = f.Close()
			}, nil
		}
		if err != windows.ERROR_LOCK_VIOLATION {
			_ = f.Close()
			return nil, err
		}
		if time.Now().After(deadline) {
			_ = f.Close()
			return nil, &LockBusy{Msg: "another agent operation holds the local lock"}
		}
		select {
		case <-ctx.Done():
			_ = f.Close()
			return nil, ctx.Err()
		case <-time.After(25 * time.Millisecond):
		}
	}
}
