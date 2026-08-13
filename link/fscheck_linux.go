//go:build linux

package main

import (
	"fmt"
	"syscall"
)

func networkFilesystem(path string) (bool, string, error) {
	var stat syscall.Statfs_t
	if err := syscall.Statfs(path, &stat); err != nil {
		return false, "", err
	}
	switch uint64(stat.Type) {
	case 0x6969:
		return true, "NFS", nil
	case 0x0BD00BD0:
		return true, "Lustre", nil
	default:
		return false, fmt.Sprintf("magic=0x%x", uint64(stat.Type)), nil
	}
}
