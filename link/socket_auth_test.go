package main

import (
	"io"
	"io/fs"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

const testMessagingToken = "0123456789abcdef0123456789abcdef"

// listenWhole records everything each connection wrote, not just its first line.
func listenWhole(t *testing.T, path string) <-chan string {
	t.Helper()
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	got := make(chan string, 4)
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			data, _ := io.ReadAll(conn)
			_ = conn.Close()
			got <- string(data)
		}
	}()
	return got
}

func TestRegisterKeepsTokenOnlyBesideItsSocket(t *testing.T) {
	f := newNotifierFixture(t)
	own := filepath.Join(f.runtime, "own.sock")
	t.Setenv("CLAUDE_CODE_MESSAGING_SOCKET", own)
	t.Setenv("CLAUDE_CODE_MESSAGING_TOKEN", testMessagingToken)
	pid := strconv.Itoa(os.Getpid())
	register := func(identity string, extra ...string) sessionRegistration {
		t.Helper()
		args := append([]string{"--identity", identity, "--instance", identity, "--session-id", identity + "-session",
			"--pid", pid, "--kind", "interactive"}, extra...)
		if err := registerForTest(t, args...); err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(f.runtime, "sessions", identity+".json")
		if info, err := os.Stat(path); err != nil || info.Mode().Perm() != 0600 {
			t.Fatalf("registration mode: %v %v", info, err)
		}
		var reg sessionRegistration
		if err := readJSON(path, &reg); err != nil {
			t.Fatal(err)
		}
		return reg
	}

	reg := register("hooked", "--socket", own)
	if reg.MessagingToken != testMessagingToken || reg.TokenSocket != own || sessionToken(reg) != testMessagingToken {
		t.Fatalf("SessionStart registration did not keep its socket's token: %+v", reg)
	}
	reg = register("hooked", "--socket", filepath.Join(f.runtime, "other.sock"))
	if reg.TokenSocket != own || sessionToken(reg) != "" {
		t.Fatalf("a token followed another socket: %+v", reg)
	}
	if reg = register("inherited"); reg.SocketPath != own || reg.MessagingToken != "" {
		t.Fatalf("a socket taken from the environment stored a token: %+v", reg)
	}
	t.Setenv("CLAUDE_CODE_MESSAGING_TOKEN", "")
	if reg = register("hooked", "--socket", own); reg.MessagingToken != "" || reg.TokenSocket != "" {
		t.Fatalf("a session without a token kept the old one: %+v", reg)
	}
}

func TestConduitRingSendsAuthLineOnlyForItsSocket(t *testing.T) {
	for _, test := range []struct {
		name        string
		tokenSocket string
		auth        bool
	}{{"own socket", "", true}, {"another socket", "/elsewhere.sock", false}} {
		t.Run(test.name, func(t *testing.T) {
			f := newNotifierFixture(t)
			reg := f.addRegistration("ink", "ink-owner", "interactive", false, time.Now(), 1)
			_ = f.listeners[len(f.listeners)-1].Close()
			rings := listenWhole(t, reg.SocketPath)
			reg.MessagingToken = testMessagingToken
			reg.TokenSocket = firstNonempty(test.tokenSocket, reg.SocketPath)
			writeRegistrationForTest(t, f.runtime, reg)
			f.writeLease("ink", &reg, "owned", 1)
			f.stageMessage("ink")
			f.notifier.scan()
			var got string
			select {
			case got = <-rings:
			case <-time.After(2 * time.Second):
				t.Fatalf("not rung; log:\n%s", f.logs.String())
			}
			lines := strings.SplitAfter(got, "\n")
			want := 2
			if test.auth {
				want = 3
				if lines[0] != `{"type":"auth","token":"`+testMessagingToken+`"}`+"\n" {
					t.Fatalf("auth line = %q", lines[0])
				}
			}
			if len(lines) != want || lines[want-1] != "" || !strings.Contains(lines[want-2], "KHALA-CONDUIT/1") {
				t.Fatalf("connection carried %q", got)
			}
			registration := filepath.Join(f.runtime, "sessions", reg.InstanceID+".json")
			_ = filepath.WalkDir(filepath.Dir(f.home), func(path string, entry fs.DirEntry, err error) error {
				if err != nil || entry.IsDir() || path == registration {
					return nil
				}
				if data, _ := os.ReadFile(path); strings.Contains(string(data), testMessagingToken) {
					t.Errorf("token leaked into %s", path)
				}
				return nil
			})
			if strings.Contains(f.logs.String(), testMessagingToken) {
				t.Error("token leaked into the conduit log")
			}
		})
	}
}
