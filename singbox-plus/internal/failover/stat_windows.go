//go:build windows

package failover

import "os"

type fileStatKey struct {
	mtimeNS int64
	size    int64
}

func makeFileStatKey(fi os.FileInfo) fileStatKey {
	return fileStatKey{
		mtimeNS: fi.ModTime().UnixNano(),
		size:    fi.Size(),
	}
}
