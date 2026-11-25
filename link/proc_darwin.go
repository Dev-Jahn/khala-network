//go:build darwin

package main

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

// Process facts come from the kernel through sysctl(3) in this process. They
// used to be read by running ps(1) and sysctl(8), one fork+exec per value;
// the notifier asks for several per registered session on every scan, and
// macOS counts every one of those against a boot-wide counter.

// cTimeLayout is what ctime(3) and strftime("%c") in the C locale print: the
// day of the month is space-padded to two columns ("Mon Nov  3 ...").
const cTimeLayout = "Mon Jan _2 15:04:05 2006"

// processStartValue is the stored start identity of a process. Its bytes are
// those of `LC_ALL=C ps -o lstart= -p <pid>`, the form every registration
// written before this change holds: the kernel start time, whole seconds, in
// the local zone.
func processStartValue(pid int) (string, error) {
	info, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
	if err != nil {
		return "", err
	}
	// kern.proc.pid answers a missing pid with an empty record, not an error.
	if int(info.Proc.P_pid) != pid {
		return "", fmt.Errorf("no process %d", pid)
	}
	return time.Unix(info.Proc.P_starttime.Sec, 0).In(systemZone()).Format(cTimeLayout), nil
}

// systemZone is the zone a freshly started ps would print in. Go resolves
// time.Local once per process, but the notifier lives for months and the
// system zone can change under it (a laptop that travels); the commands that
// register sessions are new processes and would then disagree with it. With
// TZ set the zone is fixed for this process and its children alike; without
// it /etc/localtime is followed on every call, as libc does.
func systemZone() *time.Location {
	if _, set := os.LookupEnv("TZ"); set {
		return time.Local
	}
	target, err := os.Readlink("/etc/localtime")
	if err != nil {
		return time.Local
	}
	_, name, found := strings.Cut(target, "/zoneinfo/")
	if !found {
		return time.Local
	}
	zone, err := time.LoadLocation(name)
	if err != nil {
		return time.Local
	}
	return zone
}

func processParent(pid int) (int, error) {
	info, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
	if err != nil {
		return 0, err
	}
	if int(info.Proc.P_pid) != pid {
		return 0, fmt.Errorf("no process %d", pid)
	}
	return int(info.Eproc.Ppid), nil
}

// processArgs is the argument vector as the words of `ps -o command=`, which
// is how session kinds have always been matched: ps joins the arguments with
// spaces and escapes every other white-space byte, so the words are the
// space-separated pieces and an argument holding a space counts as several.
//
// The kernel only hands a process's arguments to its owner or to root. For
// any other process (a root-owned login or sshd above the session) ps, which
// is setuid root, is still asked, so the answer for those stays what it was.
// This runs once per ancestor when a session registers, never on a scan.
func processArgs(pid int) []string {
	if pid <= 1 {
		return nil
	}
	joined := ""
	if data, err := unix.SysctlRaw("kern.procargs2", pid); err != nil {
		out, err := exec.Command("ps", "-o", "command=", "-p", strconv.Itoa(pid)).Output()
		if err != nil {
			return nil
		}
		joined = strings.TrimRight(string(out), "\n")
	} else if argv, err := parseProcArgs2(data); err != nil {
		return nil
	} else {
		joined = strings.Join(argv, " ")
	}
	words := strings.Split(joined, " ")
	kept := words[:0]
	for _, word := range words {
		if word != "" {
			kept = append(kept, word)
		}
	}
	return kept
}

// parseProcArgs2 reads a kern.procargs2 buffer: argc, the executable path,
// NUL padding, then argc NUL-terminated arguments (the environment follows).
func parseProcArgs2(data []byte) ([]string, error) {
	if len(data) < 4 {
		return nil, errors.New("short procargs2")
	}
	argc := int(binary.LittleEndian.Uint32(data))
	rest := data[4:]
	end := bytes.IndexByte(rest, 0)
	if end < 0 {
		return nil, errors.New("procargs2 has no executable path")
	}
	rest = bytes.TrimLeft(rest[end:], "\x00")
	argv := make([]string, 0, argc)
	for len(argv) < argc {
		end = bytes.IndexByte(rest, 0)
		if end < 0 {
			return nil, errors.New("procargs2 ends inside the arguments")
		}
		argv = append(argv, string(rest[:end]))
		rest = rest[end+1:]
	}
	return argv, nil
}

// bootSysctl answers the two names currentBootID asks for with the bytes
// `sysctl -n <name>` printed.
func bootSysctl(name string) ([]byte, error) {
	switch name {
	case "kern.bootsessionuuid":
		value, err := unix.Sysctl(name)
		return []byte(value), err
	case "kern.boottime":
		tv, err := unix.SysctlTimeval(name)
		if err != nil {
			return nil, err
		}
		return []byte(fmt.Sprintf("{ sec = %d, usec = %d } %s\n", tv.Sec, tv.Usec,
			time.Unix(tv.Sec, 0).In(systemZone()).Format(cTimeLayout))), nil
	}
	return nil, fmt.Errorf("unsupported sysctl %s", name)
}
