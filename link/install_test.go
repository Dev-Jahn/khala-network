package main

import (
	"crypto/sha256"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

type testLogger struct{ t *testing.T }

func (l testLogger) Printf(format string, args ...any) { l.t.Logf(format, args...) }

func testKhalaHome(t *testing.T) string {
	t.Helper()
	base := os.Getenv("HOME")
	if base == "" {
		t.Fatal("HOME is required for no-/tmp test rigs")
	}
	home, err := os.MkdirTemp(base, ".khala-link-go-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := os.RemoveAll(home); err != nil {
			t.Errorf("cleanup: %v", err)
		}
	})
	for _, dir := range []string{"tmp", "spool/for/alpha", "spool/for/beta", "presence"} {
		if err := os.MkdirAll(filepath.Join(home, dir), 0700); err != nil {
			t.Fatal(err)
		}
	}
	return home
}

func testOffer(class, node, name string, data []byte) offer {
	digest := sha256.Sum256(data)
	return offer{ID: transferID(class, node, name, digest), Class: class, Node: node, Basename: name, Size: uint64(len(data)), Digest: digest}
}

func TestInstallFsyncRenameAndNoClobber(t *testing.T) {
	home := testKhalaHome(t)
	data := []byte("immutable bytes")
	o := testOffer("spool", "alpha", "123.sender@beta", data)
	i := installer{home: home, role: "dial", peer: "alpha", logger: testLogger{t}}
	result, path, err := i.receive(o, data)
	if err != nil {
		t.Fatal(err)
	}
	if result != installed {
		t.Fatalf("result=%v", result)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(data) {
		t.Fatalf("installed %q", got)
	}
	if _, equal, err := i.inspect(o); err != nil || !equal {
		t.Fatalf("HAVE inspection equal=%t err=%v", equal, err)
	}
}

func TestDifferentDigestQuarantinesAndPreservesOriginal(t *testing.T) {
	home := testKhalaHome(t)
	dest := filepath.Join(home, "spool", "for", "alpha", "same.sender@beta")
	original := []byte("original")
	if err := os.WriteFile(dest, original, 0600); err != nil {
		t.Fatal(err)
	}
	incoming := []byte("different")
	o := testOffer("spool", "alpha", filepath.Base(dest), incoming)
	i := installer{home: home, role: "dial", peer: "alpha", logger: testLogger{t}}
	result, quarantine, err := i.receive(o, incoming)
	if err == nil || result != quarantined {
		t.Fatalf("result=%v err=%v", result, err)
	}
	got, readErr := os.ReadFile(dest)
	if readErr != nil || string(got) != string(original) {
		t.Fatalf("original changed: %q err=%v", got, readErr)
	}
	q, readErr := os.ReadFile(quarantine)
	if readErr != nil || string(q) != string(incoming) {
		t.Fatalf("quarantine=%q err=%v", q, readErr)
	}
}

func TestMutablePresenceLeaseReplacesAtomically(t *testing.T) {
	home := testKhalaHome(t)
	dest := filepath.Join(home, "presence", "ear@alpha.watching")
	if err := os.WriteFile(dest, []byte("1\n30\n"), 0600); err != nil {
		t.Fatal(err)
	}
	updated := []byte("2\n30\n")
	o := testOffer("presence", "alpha", filepath.Base(dest), updated)
	i := installer{home: home, role: "serve", peer: "alpha", logger: testLogger{t}}
	result, _, err := i.receive(o, updated)
	if err != nil || result != installed {
		t.Fatalf("result=%v err=%v", result, err)
	}
	got, err := os.ReadFile(dest)
	if err != nil || string(got) != string(updated) {
		t.Fatalf("presence=%q err=%v", got, err)
	}
}

func TestRoleOwnershipRejectsReflectionAndTraversal(t *testing.T) {
	home := testKhalaHome(t)
	i := installer{home: home, role: "serve", peer: "alpha", logger: testLogger{t}}
	for _, o := range []offer{
		testOffer("spool", "alpha", "1.sender@alpha", []byte("x")),
		testOffer("spool", "beta", "../escape", []byte("x")),
		testOffer("presence", "beta", "ear@beta.watching", []byte("x")),
	} {
		if _, err := i.destination(o); err == nil {
			t.Errorf("accepted forbidden offer %#v", o)
		}
	}
}

func TestInspectRejectsExistingSymlink(t *testing.T) {
	home := testKhalaHome(t)
	data := []byte("outside bytes")
	outside := filepath.Join(home, "tmp", "outside")
	if err := os.WriteFile(outside, data, 0600); err != nil {
		t.Fatal(err)
	}
	name := "symlink.sender@beta"
	dest := filepath.Join(home, "spool", "for", "alpha", name)
	if err := os.Symlink(outside, dest); err != nil {
		t.Fatal(err)
	}
	i := installer{home: home, role: "dial", peer: "alpha", logger: testLogger{t}}
	if _, equal, err := i.inspect(testOffer("spool", "alpha", name, data)); err == nil || equal {
		t.Fatalf("symlink satisfied HAVE: equal=%t err=%v", equal, err)
	}
}

func TestConcurrentDifferentBytesNeverClobber(t *testing.T) {
	home := testKhalaHome(t)
	i := installer{home: home, role: "dial", peer: "alpha", logger: testLogger{t}}
	name := "race.sender@beta"
	objects := [][]byte{[]byte("first immutable bytes"), []byte("second immutable bytes")}
	results := make(chan installResult, len(objects))
	errs := make(chan error, len(objects))
	var wg sync.WaitGroup
	for _, data := range objects {
		data := data
		wg.Add(1)
		go func() {
			defer wg.Done()
			result, _, err := i.receive(testOffer("spool", "alpha", name, data), data)
			results <- result
			errs <- err
		}()
	}
	wg.Wait()
	close(results)
	close(errs)
	installedCount := 0
	quarantinedCount := 0
	for result := range results {
		switch result {
		case installed:
			installedCount++
		case quarantined:
			quarantinedCount++
		}
	}
	if installedCount != 1 || quarantinedCount != 1 {
		t.Fatalf("installed=%d quarantined=%d", installedCount, quarantinedCount)
	}
	for err := range errs {
		if err == nil {
			continue
		}
		t.Logf("expected losing writer error: %v", err)
	}
	got, err := os.ReadFile(filepath.Join(home, "spool", "for", "alpha", name))
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(objects[0]) && string(got) != string(objects[1]) {
		t.Fatalf("destination contains partial/unknown bytes: %q", got)
	}
}

func TestRecoverStaleTmpMovesWithoutUnlink(t *testing.T) {
	home := testKhalaHome(t)
	path := filepath.Join(home, "tmp", "link.stale.123")
	if err := os.WriteFile(path, []byte("interrupted"), 0600); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-25 * time.Hour)
	if err := os.Chtimes(path, old, old); err != nil {
		t.Fatal(err)
	}
	if err := recoverStaleTemps(home, testLogger{t}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("stale tmp still present: %v", err)
	}
	matches, err := filepath.Glob(filepath.Join(home, "spool", "quarantine", "recovered-tmp.link.stale.123.*"))
	if err != nil || len(matches) != 1 {
		t.Fatalf("recovered matches=%v err=%v", matches, err)
	}
}
