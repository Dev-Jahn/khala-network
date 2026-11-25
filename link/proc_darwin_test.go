//go:build darwin

package main

import (
	"os"
	"os/exec"
	"strconv"
	"strings"
	"testing"
	"time"
)

func psValue(t *testing.T, keyword string, pid int) string {
	t.Helper()
	cmd := exec.Command("ps", "-o", keyword+"=", "-p", strconv.Itoa(pid))
	cmd.Env = append(os.Environ(), "LC_ALL=C", "LANG=C", "LC_TIME=C")
	data, err := cmd.Output()
	if err != nil {
		t.Fatalf("ps -o %s= -p %d: %v", keyword, pid, err)
	}
	return string(data)
}

// Registrations, leases and the notifier status written by earlier releases
// hold the start time as `LC_ALL=C ps -o lstart=` printed it, and a release
// that reads the kernel directly must produce the same bytes or every live
// session looks dead after the upgrade. The caller's locale must not matter.
func TestProcessFactsMatchPS(t *testing.T) {
	t.Setenv("LANG", "ko_KR.UTF-8")
	t.Setenv("LC_ALL", "ko_KR.UTF-8")
	child := exec.Command("sleep", "30")
	if err := child.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() {
		_ = child.Process.Kill()
		_ = child.Wait()
	}()
	for _, pid := range []int{os.Getpid(), os.Getppid(), child.Process.Pid} {
		got, err := processStartValue(pid)
		if err != nil {
			t.Fatalf("processStartValue(%d): %v", pid, err)
		}
		if want := strings.TrimSpace(psValue(t, "lstart", pid)); got != want {
			t.Fatalf("pid %d start=%q, ps lstart=%q", pid, got, want)
		}
		parent, err := processParent(pid)
		if err != nil {
			t.Fatalf("processParent(%d): %v", pid, err)
		}
		if want := strings.TrimSpace(psValue(t, "ppid", pid)); strconv.Itoa(parent) != want {
			t.Fatalf("pid %d parent=%d, ps ppid=%q", pid, parent, want)
		}
		got = strings.Join(processArgs(pid), "\x00")
		if want := strings.Join(strings.Fields(psValue(t, "command", pid)), "\x00"); got != want {
			t.Fatalf("pid %d args=%q, ps command=%q", pid, got, want)
		}
	}
	if _, err := processStartValue(child.Process.Pid + 1<<22); err == nil {
		t.Fatal("a pid that cannot exist has a start time")
	}
}

// ps pads a single-digit day of the month with a space, not a zero.
func TestProcessStartLayoutPadsDayWithSpace(t *testing.T) {
	got := time.Date(2026, time.November, 3, 4, 5, 6, 0, time.UTC).Format(cTimeLayout)
	if got != "Tue Nov  3 04:05:06 2026" {
		t.Fatalf("layout rendered %q", got)
	}
}

func TestBootSysctlMatchesSysctlCommand(t *testing.T) {
	for _, name := range []string{"kern.bootsessionuuid", "kern.boottime"} {
		want, err := exec.Command("sysctl", "-n", name).Output()
		if err != nil {
			t.Fatalf("sysctl -n %s: %v", name, err)
		}
		got, err := bootSysctl(name)
		if err != nil {
			t.Fatalf("bootSysctl(%s): %v", name, err)
		}
		if strings.TrimSpace(string(got)) != strings.TrimSpace(string(want)) {
			t.Fatalf("%s=%q, sysctl -n printed %q", name, got, want)
		}
	}
}
