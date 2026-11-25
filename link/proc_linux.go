//go:build linux

package main

import (
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// procStatFields returns the fields of /proc/<pid>/stat after the command
// name, so index 0 is the state (field 3 of proc(5)).
func procStatFields(pid int) ([]string, error) {
	data, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "stat"))
	if err != nil {
		return nil, err
	}
	line := string(data)
	end := strings.LastIndex(line, ")")
	if end < 0 {
		return nil, errors.New("malformed /proc stat")
	}
	return strings.Fields(line[end+1:]), nil
}

// processStartValue is the stored start identity of a process: its start time
// in clock ticks since boot (field 22 of proc(5)).
func processStartValue(pid int) (string, error) {
	fields, err := procStatFields(pid)
	if err != nil {
		return "", err
	}
	if len(fields) <= 19 {
		return "", errors.New("short /proc stat")
	}
	return fields[19], nil
}

func processParent(pid int) (int, error) {
	fields, err := procStatFields(pid)
	if err != nil {
		return 0, err
	}
	if len(fields) < 2 {
		return 0, errors.New("short /proc stat")
	}
	return strconv.Atoi(fields[1])
}

func processArgs(pid int) []string {
	if pid <= 1 {
		return nil
	}
	data, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "cmdline"))
	if err != nil {
		return nil
	}
	return strings.Split(strings.TrimRight(string(data), "\x00"), "\x00")
}

// bootSysctl exists for darwin; a linux boot id comes from /proc.
func bootSysctl(name string) ([]byte, error) {
	return nil, errors.New("sysctl " + name + " is not read on linux")
}
