package main

import (
	"context"
	"errors"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type autoTrustFixture struct {
	t        *testing.T
	a        *autoTrust
	clock    time.Time
	cache    string
	runs     string
	installs int
}

// The fake khala-codex appends a line to the runs file, rewrites
// $CODEX_HOME/config.toml the way recording trust does, and then prints and
// exits as $KHALA_HOME/fake says.
func newAutoTrustFixture(t *testing.T) *autoTrustFixture {
	t.Helper()
	root := t.TempDir()
	f := &autoTrustFixture{t: t, clock: time.Unix(1_800_000_000, 0), runs: filepath.Join(root, "runs")}
	home, codexHome := filepath.Join(root, "khala"), filepath.Join(root, "codex")
	f.cache = filepath.Join(codexHome, "plugins", "cache")
	bin := filepath.Join(root, "khala-codex")
	script := "#!/bin/sh\necho \"$* PATH=$PATH\" >> '" + f.runs + "'\necho run > \"$CODEX_HOME/config.toml\"\n. \"$KHALA_HOME/fake\"\n"
	for path, content := range map[string]string{bin: script, filepath.Join(home, "fake"): "exit 0\n"} {
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0700); err != nil {
			t.Fatal(err)
		}
	}
	f.a = &autoTrust{
		home: home, codexHome: codexHome, logger: log.New(io.Discard, "", 0),
		now:      func() time.Time { return f.clock },
		locate:   func(string) (string, error) { return bin, nil },
		deadline: 10 * time.Second, backoff: autoTrustBackoff, results: make(chan autoTrustResult, 1),
	}
	f.install("market", "khala-network-codex", "0.4.1")
	f.write("codex-auto-trust.path", "/usr/bin:/bin\n")
	return f
}

func (f *autoTrustFixture) write(name, content string) {
	f.t.Helper()
	if err := os.WriteFile(filepath.Join(f.a.home, name), []byte(content), 0600); err != nil {
		f.t.Fatal(err)
	}
}

// install re-creates a plugin directory, as a marketplace refresh does. The
// mtimes are set explicitly so that two installs never share one.
func (f *autoTrustFixture) install(marketplace, plugin, version string) {
	f.t.Helper()
	dir := filepath.Join(f.cache, marketplace, plugin)
	if err := os.RemoveAll(dir); err != nil {
		f.t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(dir, version), 0700); err != nil {
		f.t.Fatal(err)
	}
	f.installs++
	stamp := time.Unix(1_700_000_000+int64(f.installs), 0)
	for _, path := range []string{dir, filepath.Join(dir, version)} {
		if err := os.Chtimes(path, stamp, stamp); err != nil {
			f.t.Fatal(err)
		}
	}
}

func (f *autoTrustFixture) last() string {
	data, _ := os.ReadFile(f.a.lastPath())
	return string(data)
}

// tick advances the clock by one tick and waits for the run it started, if any.
func (f *autoTrustFixture) tick() {
	f.t.Helper()
	f.clock = f.clock.Add(autoTrustTick)
	f.a.tick(context.Background())
	if f.a.running {
		f.a.finish(<-f.a.results)
	}
}

func (f *autoTrustFixture) expectRuns(want int, when string) {
	f.t.Helper()
	data, _ := os.ReadFile(f.runs)
	if got := strings.Count(string(data), "auto-trust --run PATH="); got != want {
		f.t.Fatalf("%s: %d runs, want %d", when, got, want)
	}
}

func TestAutoTrustOffWithoutOptIn(t *testing.T) {
	f := newAutoTrustFixture(t)
	for _, list := range []string{"absent", "", "\n  \n"} {
		if list != "absent" {
			f.write("codex-auto-trust", list)
		}
		for i := 0; i < 3; i++ {
			f.tick()
			f.tick()
			f.install("market", "khala-network-codex", "0.4.1")
		}
	}
	f.expectRuns(0, "opt-in list empty or absent")
	if _, err := os.Stat(f.a.lastPath()); !os.IsNotExist(err) {
		t.Fatalf("last-result file exists with the feature off: %v", err)
	}
}

func TestAutoTrustRunsOnceTheCacheHoldsStill(t *testing.T) {
	f := newAutoTrustFixture(t)
	f.write("codex-auto-trust", "khala-network-codex\n")
	f.write("fake", "printf 'khala-network-codex\\tstop\\tuntrusted\\ttrusted\\n'\n"+
		"printf 'khala-network-codex\\tinterrupt\\ttrusted\\ttrusted\\n'\n")
	f.tick()
	f.expectRuns(0, "first sight at service start")
	f.tick()
	f.expectRuns(1, "unchanged for one further tick")
	// The run rewrote config.toml; that must not look like a cache change.
	for i := 0; i < 5; i++ {
		f.tick()
	}
	f.expectRuns(1, "after the run's own config.toml write")

	// Codex is still writing: every tick sees another change, so nothing runs.
	for i := 0; i < 3; i++ {
		f.install("market", "khala-network-codex", "0.4.2")
		f.tick()
		f.expectRuns(1, "cache still changing")
	}
	f.tick()
	f.expectRuns(2, "cache settled")

	// A plugin that is not listed does not count; listing it does.
	f.install("market", "hippo", "1.0.0")
	f.tick()
	f.tick()
	f.expectRuns(2, "unlisted plugin re-created")
	f.write("codex-auto-trust", "khala-network-codex\nhippo\n")
	f.tick()
	f.tick()
	f.expectRuns(3, "opt-in list changed")
	// Enabling again records a PATH; that is a change, and the run gets it.
	f.write("codex-auto-trust.path", "/opt/recorded/bin:/usr/bin:/bin\n")
	f.tick()
	f.tick()
	f.expectRuns(4, "recorded PATH changed")
	if runs, _ := os.ReadFile(f.runs); !strings.HasSuffix(string(runs), "auto-trust --run PATH=/opt/recorded/bin:/usr/bin:/bin\n") {
		t.Fatalf("the run did not get the recorded PATH:\n%s", runs)
	}

	last := f.last()
	for _, want := range []string{
		"\nexit\t0\n", "changed\tkhala-network-codex\tstop\tuntrusted\ttrusted\n",
		"\tkhala-network-codex\n",
	} {
		if !strings.Contains(last, want) {
			t.Fatalf("last-result file lacks %q:\n%s", want, last)
		}
	}
	if strings.Contains(last, "interrupt") {
		t.Fatalf("an unchanged hook was recorded as changed:\n%s", last)
	}

	// The recorded line outlives a later run that had nothing to do, also
	// across a service restart, and goes 24 h after its run.
	f.write("fake", "exit 0\n")
	f.install("market", "hippo", "1.0.1")
	restarted := *f.a
	restarted.on, restarted.seen, restarted.handled = false, "", ""
	restarted.lastBody, restarted.recorded, restarted.recordedAt = "", "", time.Time{}
	f.a = &restarted
	f.tick()
	f.tick()
	f.expectRuns(5, "later change")
	if last = f.last(); !strings.Contains(last, "\nrecorded\t") || strings.Contains(last, "changed\t") {
		t.Fatalf("recorded line not kept beside the newer result:\n%s", last)
	}
	f.clock = f.clock.Add(autoTrustAnnounce)
	f.tick()
	if last = f.last(); strings.Contains(last, "recorded\t") || !strings.Contains(last, "\nexit\t0\n") {
		t.Fatalf("recorded line kept past 24 h, or the result lost with it:\n%s", last)
	}
}

func TestAutoTrustBacksOffAfterFailure(t *testing.T) {
	f := newAutoTrustFixture(t)
	f.write("codex-auto-trust", "khala-network-codex\n")
	f.write("fake", "echo 'khala-codex: installed copy is not the published release' >&2\nexit 5\n")
	f.tick()
	f.tick()
	f.expectRuns(1, "first run")
	if last := f.last(); !strings.Contains(last, "\nexit\t5\nerror\tinstalled copy is not the published release\n") {
		t.Fatalf("failure not recorded:\n%s", last)
	}
	// Retries come 1, 2, 5, 15 and then every 30 minutes after the previous run.
	for attempt, wait := range []time.Duration{time.Minute, 2 * time.Minute, 5 * time.Minute, 15 * time.Minute, 30 * time.Minute, 30 * time.Minute} {
		for elapsed := autoTrustTick; elapsed < wait; elapsed += autoTrustTick {
			f.tick()
		}
		f.expectRuns(attempt+1, "inside the backoff")
		f.tick()
		f.expectRuns(attempt+2, "backoff over")
	}
	// A new cache change starts over without waiting for the backoff.
	f.install("market", "khala-network-codex", "0.4.2")
	f.tick()
	f.tick()
	f.expectRuns(8, "cache changed during the backoff")
	// Success ends the retries.
	f.write("fake", "exit 0\n")
	f.clock = f.clock.Add(time.Minute)
	f.tick()
	f.expectRuns(9, "retry that succeeds")
	f.clock = f.clock.Add(12 * time.Hour)
	f.tick()
	f.expectRuns(9, "after success")
}

func TestAutoTrustMissingAdapterAndDeadline(t *testing.T) {
	f := newAutoTrustFixture(t)
	var logged strings.Builder
	f.a.logger = log.New(&logged, "", 0)
	found := f.a.locate
	f.a.locate = func(string) (string, error) { return "", errors.New("khala-codex not found") }
	f.write("codex-auto-trust", "khala-network-codex\n")
	// Without a recorded PATH nothing is run, and that is said once.
	for _, path := range []string{"absent", "\n"} {
		if path == "absent" {
			if err := os.Remove(filepath.Join(f.a.home, "codex-auto-trust.path")); err != nil {
				t.Fatal(err)
			}
		} else {
			f.write("codex-auto-trust.path", path)
		}
		for i := 0; i < 400; i++ {
			f.tick()
		}
	}
	f.expectRuns(0, "no recorded PATH")
	if got := strings.Count(logged.String(), "khala-codex auto-trust <plugins>"); got != 1 {
		t.Fatalf("missing PATH logged %d times, want 1:\n%s", got, logged.String())
	}
	if last := f.last(); !strings.Contains(last, "\nexit\t127\nerror\tno PATH recorded") {
		t.Fatalf("missing PATH not recorded:\n%s", last)
	}
	f.write("codex-auto-trust.path", "/usr/bin:/bin\n")
	for i := 0; i < 400; i++ {
		f.tick()
	}
	if got := strings.Count(logged.String(), "not found"); got != 1 {
		t.Fatalf("missing adapter logged %d times, want 1:\n%s", got, logged.String())
	}
	if last := f.last(); !strings.Contains(last, "\nexit\t127\nerror\tkhala-codex not found\n") {
		t.Fatalf("missing adapter not recorded:\n%s", last)
	}

	// A run past its deadline is killed and recorded; the loop is not held.
	f.a.locate, f.a.deadline = found, 200*time.Millisecond
	f.write("fake", "sleep 30\n")
	f.install("market", "khala-network-codex", "0.4.2")
	f.tick()
	started := time.Now()
	f.tick()
	if waited := time.Since(started); waited > 5*time.Second {
		t.Fatalf("a run past its deadline took %s to end", waited)
	}
	if last := f.last(); !strings.Contains(last, "\nexit\t124\nerror\t") {
		t.Fatalf("deadline not recorded:\n%s", last)
	}
}
