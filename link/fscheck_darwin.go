//go:build darwin

package main

import (
	"bytes"
	"syscall"
)

func networkFilesystem(path string) (bool, string, error) {
	var stat syscall.Statfs_t
	if err := syscall.Statfs(path, &stat); err != nil {
		return false, "", err
	}
	raw := make([]byte, len(stat.Fstypename))
	for n, c := range stat.Fstypename {
		raw[n] = byte(c)
	}
	name := string(bytes.TrimRight(raw, "\x00"))
	return name == "nfs" || name == "lustre", name, nil
}
