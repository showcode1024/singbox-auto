//go:build windows

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
	f, err := os.Open(path)
	if err != nil {
		return fileStat{}, err
	}
	defer f.Close()
	return statFile(f)
}

func statFile(f *os.File) (fileStat, error) {
	fi, err := f.Stat()
	if err != nil {
		return fileStat{}, err
	}
	st := fileStat{
		Size:    fi.Size(),
		MtimeNS: fi.ModTime().UnixNano(),
		IsReg:   fi.Mode().IsRegular(),
	}
	var info syscall.ByHandleFileInformation
	if err := syscall.GetFileInformationByHandle(syscall.Handle(f.Fd()), &info); err == nil {
		st.Dev = uint64(info.VolumeSerialNumber)
		st.Ino = (uint64(info.FileIndexHigh) << 32) | uint64(info.FileIndexLow)
	}
	return st, nil
}
