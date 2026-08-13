//go:build darwin

package main

import (
	"syscall"
	"unsafe"
)

// Darwin's renameatx_np(RENAME_EXCL) is the no-clobber counterpart of
// Linux renameat2(RENAME_NOREPLACE). These values are stable Darwin ABI.
const (
	sysRenameatxNPDarwin = 488
	renameExclDarwin     = 0x4
)

var atFDCWDDarwin = ^uintptr(1)

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
		sysRenameatxNPDarwin,
		atFDCWDDarwin, uintptr(unsafe.Pointer(oldPtr)),
		atFDCWDDarwin, uintptr(unsafe.Pointer(newPtr)),
		renameExclDarwin, 0,
	)
	if errno != 0 {
		return errno
	}
	return nil
}
