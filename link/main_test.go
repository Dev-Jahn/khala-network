package main

import (
	"io"
	"os"
	"regexp"
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
