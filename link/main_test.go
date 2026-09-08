package main

import (
	"io"
	"os"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// The version subcommand must print exactly linkVersion, and linkVersion must be a plain release triple.
var semverPattern = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+$`)

func TestVersionSubcommandUsesLinkVersion(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stdout
	os.Stdout = w
	status := run([]string{"version"})
	_ = w.Close()
	os.Stdout = old
	data, err := io.ReadAll(r)
	_ = r.Close()
	if err != nil {
		t.Fatal(err)
	}
	if status != 0 || string(data) != linkVersion+"\n" || !semverPattern.MatchString(linkVersion) {
		t.Fatalf("status=%d output=%q linkVersion=%q", status, data, linkVersion)
	}
	if implVersion != "0.5.0" {
		t.Fatalf("implVersion changed to %q", implVersion)
	}
}

func TestProcessStartCommandPinsLocale(t *testing.T) {
	t.Setenv("LANG", "ko_KR.UTF-8")
	t.Setenv("LC_ALL", "ko_KR.UTF-8")
	cmd := processStartCommand(os.Getpid())
	var lcAll, lang string
	for _, kv := range cmd.Env {
		switch {
		case strings.HasPrefix(kv, "LC_ALL="):
			lcAll = kv
		case strings.HasPrefix(kv, "LANG="):
			lang = kv
		}
	}
	if lcAll != "LC_ALL=C" || lang != "LANG=C" {
		t.Fatalf("process start command does not pin the C locale (last LC_ALL=%q LANG=%q)", lcAll, lang)
	}
	if cmd.Args[0] != "ps" || cmd.Args[len(cmd.Args)-1] != strconv.Itoa(os.Getpid()) {
		t.Fatalf("unexpected ps invocation %v", cmd.Args)
	}
}
