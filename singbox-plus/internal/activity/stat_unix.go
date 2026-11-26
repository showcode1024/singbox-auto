//go:build unix

package activity

import (
	"os"
	"syscall"
)

type fileStat struct {
	Dev     uint64
	Ino     uint64
	Size    int64
	MtimeNS int64
	IsReg   bool
}

func statPath(path string) (fileStat, error) {
	fi, err := os.Stat(path)
	if err != nil {
		return fileStat{}, err
	}
	return statFromInfo(fi), nil
}

func statFile(f *os.File) (fileStat, error) {
	fi, err := f.Stat()
	if err != nil {
		return fileStat{}, err
	}
	return statFromInfo(fi), nil
}

func statFromInfo(fi os.FileInfo) fileStat {
	st := fileStat{
		Size:    fi.Size(),
		MtimeNS: fi.ModTime().UnixNano(),
		IsReg:   fi.Mode().IsRegular(),
	}
	if sys, ok := fi.Sys().(*syscall.Stat_t); ok && sys != nil {
		st.Dev = uint64(sys.Dev)
		st.Ino = uint64(sys.Ino)
	}
	return st
}
