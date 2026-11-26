//go:build unix

package failover

import (
	"os"
	"syscall"
)

type fileStatKey struct {
	dev     uint64
	ino     uint64
	mtimeNS int64
	size    int64
}

func makeFileStatKey(fi os.FileInfo) fileStatKey {
	key := fileStatKey{
		mtimeNS: fi.ModTime().UnixNano(),
		size:    fi.Size(),
	}
	if st, ok := fi.Sys().(*syscall.Stat_t); ok && st != nil {
		key.dev = uint64(st.Dev)
		key.ino = uint64(st.Ino)
	}
	return key
}
