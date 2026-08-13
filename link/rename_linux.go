//go:build linux

package main

import (
	"syscall"
	"unsafe"
)

const (
	renameNoReplaceFlag = 1
)

var atFDCWDLinux = ^uintptr(99)

func renameNoReplace(oldPath, newPath string) error {
	oldPtr, err := syscall.BytePtrFromString(oldPath)
	if err != nil {
		return err
	}
	newPtr, err := syscall.BytePtrFromString(newPath)
	if err != nil {
		return err
	}
	_, _, errno := syscall.Syscall6(
		sysRenameat2,
		atFDCWDLinux, uintptr(unsafe.Pointer(oldPtr)),
		atFDCWDLinux, uintptr(unsafe.Pointer(newPtr)),
		renameNoReplaceFlag, 0,
	)
	if errno != 0 {
		return errno
	}
	return nil
}
