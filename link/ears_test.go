package main

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const testGeneration = "3fa9c2d13fa9c2d13fa9c2d13fa9c2d13fa9c2d13fa9c2d13fa9c2d13fa9c2d1"

func validEarsFixture(node string, generation int64) string {
	return fmt.Sprintf("ears 1\nnode %s\ngeneration %d\nwritten-at 1788402001\ninterval 60\nstate running\ncomplete yes\ncomponent conduit release=0.9.1 adapter=1 ears=1\nmailbox mini\nlink 3\nidentity name=ink principal=session listening=yes route=socket phase=ready cc=2.1.258 reason=- pending-ring=1 pending-info=2 pending-operator=0 generation=%s first-seen=1788401950 oldest-pending=1788401900 written-rings=2 last-written=1788402000 last-drain=1788401800 last-drain-before=%s last-drain-after=- last-drain-status=ok future=value\n", node, generation, testGeneration, testGeneration)
}

func TestParseEarsR3CapsMandatoryFieldsAndCompatibility(t *testing.T) {
	valid := validEarsFixture("alpha", 9)
	identityLine := "identity " + strings.Split(valid, "identity ")[1]
	cases := []struct {
		name string
		data []byte
		file string
		ok   bool
	}{
		{name: "valid unknown identity key", data: []byte(valid), file: "conduit@alpha.ear", ok: true},
		{name: "too large", data: bytes.Repeat([]byte{'x'}, earsReaderMaxBytes+1), file: "conduit@alpha.ear"},
		{name: "too many lines", data: []byte("ears 1\n" + strings.Repeat("unknown x\n", earsReaderMaxLines)), file: "conduit@alpha.ear"},
		{name: "wrong basename prefix", data: []byte(valid), file: "foo@alpha.ear"},
		{name: "wrong suffix", data: []byte(valid), file: "conduit@alpha.ears"},
		{name: "wrong magic", data: []byte(strings.Replace(valid, "ears 1", "ears 2", 1)), file: "conduit@alpha.ear"},
		{name: "node mismatch", data: []byte(valid), file: "conduit@beta.ear"},
		{name: "missing written-at", data: []byte(strings.Replace(valid, "written-at 1788402001\n", "", 1)), file: "conduit@alpha.ear"},
		{name: "missing state", data: []byte(strings.Replace(valid, "state running\n", "", 1)), file: "conduit@alpha.ear"},
		{name: "missing complete", data: []byte(strings.Replace(valid, "complete yes\n", "", 1)), file: "conduit@alpha.ear"},
		{name: "missing component", data: []byte(strings.Replace(valid, "component conduit release=0.9.1 adapter=1 ears=1\n", "", 1)), file: "conduit@alpha.ear"},
		{name: "missing mailbox", data: []byte(strings.Replace(valid, "mailbox mini\n", "", 1)), file: "conduit@alpha.ear"},
		{name: "missing link", data: []byte(strings.Replace(valid, "link 3\n", "", 1)), file: "conduit@alpha.ear"},
		{name: "duplicate node", data: []byte(valid + "node alpha\n"), file: "conduit@alpha.ear"},
		{name: "identity mandatory key", data: []byte(strings.Replace(valid, " principal=session", "", 1)), file: "conduit@alpha.ear"},
		{name: "duplicate identity name", data: []byte(valid + identityLine), file: "conduit@alpha.ear"},
		{name: "record too long", data: []byte(valid + "unknown " + strings.Repeat("x", earsMaxRecordBytes) + "\n"), file: "conduit@alpha.ear"},
		{name: "truncated not last", data: []byte(strings.Replace(valid, "complete yes", "complete no", 1) + "truncated 1\nunknown later\n"), file: "conduit@alpha.ear"},
		{name: "truncated repeated", data: []byte(strings.Replace(valid, "complete yes", "complete no", 1) + "truncated 1\ntruncated 1\n"), file: "conduit@alpha.ear"},
		{name: "truncated with complete yes", data: []byte(valid + "truncated 1\n"), file: "conduit@alpha.ear"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			path := filepath.Join(dir, tc.file)
			if err := os.WriteFile(path, tc.data, 0600); err != nil {
				t.Fatal(err)
			}
			got, err := parseEars(path)
			if tc.ok && err != nil {
				t.Fatalf("parseEars: %v", err)
			}
			if !tc.ok && err == nil {
				t.Fatalf("accepted invalid file: %+v", got)
			}
			if tc.ok {
				if got.WrittenAt != 1788402001 || got.State != "running" || !got.Complete || len(got.Identities) != 1 {
					t.Fatalf("parsed snapshot=%+v", got)
				}
				identity := got.Identities[0]
				if identity.Name != "ink" || identity.Principal != "session" || !identity.Listening || identity.Generation != testGeneration || identity.LastDrainStatus != "ok" {
					t.Fatalf("parsed identity=%+v", identity)
				}
			}
		})
	}
}

func TestFormatEarsR3SanitizesSortsDeduplicatesAndCaps(t *testing.T) {
	identities := make([]earsIdentity, 0, earsWriterMaxIdentities+2)
	identities = append(identities,
		earsIdentity{Name: "zeta", Principal: "session", Listening: true, Route: "channel+socket", Phase: "ready", CCVersion: "2.1.0", Reason: "-", Generation: testGeneration, LastDrainStatus: "partial", LastDrainBefore: testGeneration, LastDrainAfter: "-"},
		earsIdentity{Name: "bad/name\nleak", Principal: "session", Route: "none", Phase: "ready", CCVersion: strings.Repeat("x", 200) + "/leak", Reason: "lease", Generation: "-", LastDrainStatus: "-", LastDrainBefore: "-", LastDrainAfter: "-"},
	)
	for n := 0; n < earsWriterMaxIdentities; n++ {
		identities = append(identities, earsIdentity{Name: fmt.Sprintf("id-%03d", n), Principal: "session", Route: "none", Phase: "-", CCVersion: "-", Reason: "noreg", Generation: "-", LastDrainStatus: "-", LastDrainBefore: "-", LastDrainAfter: "-"})
	}
	snapshot := earsSnapshot{Node: "alpha", Generation: 1700000001, WrittenAt: 1700000000, Interval: 60, State: "running", Components: []earsComponent{{Name: "conduit", Release: linkVersion, Adapter: "1", Ears: "1"}}, Mailboxes: []string{"mini", "alpha", "mini"}, LinkAge: -1, Identities: identities}
	data, err := formatEars(snapshot)
	if err != nil {
		t.Fatal(err)
	}
	text := string(data)
	if len(data) > earsWriterMaxBytes {
		t.Fatalf("snapshot is %d bytes, cap %d", len(data), earsWriterMaxBytes)
	}
	for _, leak := range []string{"bad/name", "leak", strings.Repeat("x", 65)} {
		if strings.Contains(text, leak) {
			t.Fatalf("unsafe token %q leaked:\n%s", leak, text)
		}
	}
	if !strings.Contains(text, "identity name=- principal=session listening=no route=none phase=ready cc=- reason=lease ") {
		t.Fatalf("adversarial values were not replaced by '-':\n%s", text)
	}
	if !strings.Contains(text, "complete no\n") || !strings.HasSuffix(text, "truncated 2\n") {
		t.Fatalf("256-row cap/trailer missing:\n%s", text)
	}
	if strings.Count(text, "mailbox alpha mini\n") != 1 {
		t.Fatalf("mailboxes not sorted/deduplicated: %s", text)
	}
	for _, line := range strings.Split(strings.TrimSuffix(text, "\n"), "\n") {
		if len(line) > earsMaxRecordBytes {
			t.Fatalf("record is %d bytes: %q", len(line), line)
		}
	}
}

func TestFormatEarsRejectsAnOversizeHeaderRecord(t *testing.T) {
	mailboxes := make([]string, 0, 200)
	for index := 0; index < 200; index++ {
		mailboxes = append(mailboxes, fmt.Sprintf("mailbox-%03d", index))
	}
	_, err := formatEars(earsSnapshot{Node: "alpha", Generation: 1, WrittenAt: 1, Interval: 60, State: "running", Components: []earsComponent{{Name: "conduit", Release: linkVersion, Adapter: "1", Ears: "1"}}, Mailboxes: mailboxes, LinkAge: -1})
	if err == nil {
		t.Fatal("formatter emitted a header record longer than 1024 bytes")
	}
}

func TestEarGenerationUsesNowOwnFileAndRuntimeState(t *testing.T) {
	f := newConduitFixture(t)
	for _, dir := range []string{"presence", "tmp", "run/drained"} {
		if err := os.MkdirAll(filepath.Join(f.home, dir), 0700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.MkdirAll(filepath.Join(f.runtime, "ears"), 0700); err != nil {
		t.Fatal(err)
	}
	future := int64(4102444800)
	if err := os.WriteFile(filepath.Join(f.home, "presence", "conduit@alpha.ear"), []byte(strings.Replace(validEarsFixture("alpha", future), "state running", "state stopping", 1)), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(f.runtime, "ears", "generation"), []byte(fmt.Sprintf("%d\n", future+10)), 0600); err != nil {
		t.Fatal(err)
	}
	if err := f.conduit.writeEars(earsModel{Now: time.Unix(1700000000, 0), State: "stopping"}); err != nil {
		t.Fatal(err)
	}
	parsed, err := parseEars(filepath.Join(f.home, "presence", "conduit@alpha.ear"))
	if err != nil {
		t.Fatal(err)
	}
	if parsed.Generation != future+11 || parsed.State != "stopping" || len(parsed.Identities) != 0 {
		t.Fatalf("snapshot=%+v", parsed)
	}
	state, err := os.ReadFile(filepath.Join(f.runtime, "ears", "generation"))
	if err != nil || string(state) != fmt.Sprintf("%d\n", future+11) {
		t.Fatalf("generation state=%q err=%v", state, err)
	}
}

func TestBuildEarModelUsesLeaseSelectionRouteDrainAndOldestPending(t *testing.T) {
	f := newConduitFixture(t)
	for _, dir := range []string{"run/drained", "presence", "tmp", "inbox/shared/new"} {
		if err := os.MkdirAll(filepath.Join(f.home, dir), 0700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.MkdirAll(filepath.Join(f.runtime, "ears"), 0700); err != nil {
		t.Fatal(err)
	}
	older := f.addRegistration("shared", "older", "interactive", false, time.Now().Add(-2*time.Hour), 7)
	newer := f.addRegistration("shared", "newer", "interactive", false, time.Now().Add(-time.Hour), 7)
	_ = f.addChannel(&older)
	regs := map[string]sessionRegistration{"older": older, "newer": newer}
	lease := identityLease{BootID: f.bootID, Identity: "shared", InstanceID: older.InstanceID, Epoch: older.LeaseEpoch, PID: older.PID, PIDStart: older.PIDStart, ClaudeSessionID: older.ClaudeSessionID, State: "owned"}
	letter := f.stageEnvelope("shared", "1700000000.1.1.sender@alpha", "From: sender@alpha\nType: message\nSubject: private-sentinel\n\nbody-sentinel\n")
	oldest := time.Unix(1700000000, 0)
	if err := os.Chtimes(letter, oldest, oldest); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(f.home, "run", "drained", "shared"), []byte("drain 1 1700000010 "+testGeneration+" - 1 0 0 partial\n"), 0600); err != nil {
		t.Fatal(err)
	}
	f.conduit.observeGeneration("shared", older.InstanceID, f.conduit.pending("shared"))
	model, err := f.conduit.buildEarsModel(regs, map[string]identityLease{"shared": lease, "orphan": {BootID: f.bootID, Identity: "orphan", State: "released"}}, time.Unix(1700000100, 0), "running")
	if err != nil {
		t.Fatal(err)
	}
	row := model.Identities[0]
	if len(model.Identities) != 1 || row.Name != "shared" || !row.Listening || row.Route != "channel+socket" || row.OldestPending != oldest.Unix() || row.LastDrain != 1700000010 || row.LastDrainBefore != testGeneration || row.LastDrainAfter != "-" || row.LastDrainStatus != "partial" {
		t.Fatalf("rows=%+v", model.Identities)
	}
	lease.Epoch++
	model, err = f.conduit.buildEarsModel(regs, map[string]identityLease{"shared": lease}, time.Now(), "running")
	if err != nil || model.Identities[0].Listening || model.Identities[0].Reason != "lease" {
		t.Fatalf("mismatched lease=%+v err=%v", model.Identities, err)
	}
	delete(regs, "older")
	lease.InstanceID = "missing"
	model, err = f.conduit.buildEarsModel(regs, map[string]identityLease{"shared": lease}, time.Now(), "running")
	if err != nil || model.Identities[0].CCVersion != newer.CCVersion || model.Identities[0].Reason != "lease" {
		t.Fatalf("reclaim order=%+v err=%v", model.Identities, err)
	}
}

func TestEarSidecarSurvivesRestartAndCountsOnlyWritten(t *testing.T) {
	f := newConduitFixture(t)
	if err := os.MkdirAll(filepath.Join(f.runtime, "ears"), 0700); err != nil {
		t.Fatal(err)
	}
	reg := f.addRegistration("ink", "owner", "interactive", false, time.Now().Add(-time.Hour), 3)
	f.writeLease("ink", &reg, "owned", 3)
	f.stageLetter("ink")
	letters := f.conduit.pending("ink")
	f.conduit.observeGeneration("ink", reg.InstanceID, letters)
	before, err := f.conduit.readEarSidecar("ink")
	if err != nil || before.Generation == "" || before.FirstSeen == 0 {
		t.Fatalf("initial sidecar=%+v err=%v", before, err)
	}
	lease := readLeaseForTest(t, filepath.Join(f.runtime, "identities", "ink.lease"))
	f.conduit.maybeRing("ink", lease, reg, letters)
	if !waitForTest(time.Second, func() bool { return f.deliveries[reg.InstanceID].Load() == 1 }) {
		t.Fatal("doorbell not written")
	}
	after, err := f.conduit.readEarSidecar("ink")
	if err != nil || after.WrittenRings != 1 || after.LastWritten == 0 || after.FirstSeen != before.FirstSeen {
		t.Fatalf("written sidecar=%+v err=%v", after, err)
	}
	restarted := &conduit{runtime: f.runtime, bootID: f.bootID, backoff: f.conduit.backoff, logger: f.conduit.logger, states: make(map[string]*conduitState)}
	restored := restarted.restoreState("ink", reg.InstanceID, after.Generation)
	if restored.firstSeen.Unix() != before.FirstSeen || restored.writtenRings != 1 {
		t.Fatalf("restart state=%+v sidecar=%+v", restored, after)
	}
}

func TestConduitEarLifecycleIgnoresPendingOnlyTransitionsAndStops(t *testing.T) {
	f := newConduitFixture(t)
	for _, dir := range []string{"presence", "tmp", "run/drained"} {
		if err := os.MkdirAll(filepath.Join(f.home, dir), 0700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.MkdirAll(filepath.Join(f.runtime, "ears"), 0700); err != nil {
		t.Fatal(err)
	}
	f.conduit.scanEvery = 25 * time.Millisecond
	f.conduit.earInterval = time.Hour
	f.conduit.earMailboxes = []string{"alpha"}
	reg := f.addRegistration("ink", "owner", "interactive", false, time.Now().Add(-time.Hour), 3)
	f.writeLease("ink", &reg, "owned", 3)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- f.conduit.run(ctx) }()
	path := filepath.Join(f.home, "presence", "conduit@alpha.ear")
	waitGeneration := func(after int64, limit time.Duration) earsSnapshot {
		deadline := time.Now().Add(limit)
		for time.Now().Before(deadline) {
			if snapshot, err := parseEars(path); err == nil && snapshot.Generation > after {
				return snapshot
			}
			time.Sleep(20 * time.Millisecond)
		}
		t.Fatalf("snapshot generation did not advance past %d", after)
		return earsSnapshot{}
	}
	initial := waitGeneration(0, 2*time.Second)
	initialBytes, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("real conduit snapshot bytes (%d):\n%s", len(initialBytes), initialBytes)
	f.stageLetter("ink")
	time.Sleep(500 * time.Millisecond)
	unchanged, err := parseEars(path)
	if err != nil || unchanged.Generation != initial.Generation {
		t.Fatalf("pending-only generation=%d initial=%d err=%v", unchanged.Generation, initial.Generation, err)
	}
	if err := mutateRegistration(f.runtime, f.bootID, reg.InstanceID, func(current *sessionRegistration) error { current.Phase = "starting"; return nil }); err != nil {
		t.Fatal(err)
	}
	transitioned := waitGeneration(initial.Generation, 3*time.Second)
	if transitioned.Identities[0].Listening || transitioned.Identities[0].Reason != "phase" {
		t.Fatalf("transition=%+v", transitioned)
	}
	cancel()
	if err := <-done; err != context.Canceled {
		t.Fatalf("run err=%v", err)
	}
	final := waitGeneration(transitioned.Generation, 2*time.Second)
	if final.State != "stopping" || len(final.Identities) != 0 {
		t.Fatalf("final=%+v", final)
	}
}

func TestEarsOffWritesOneStoppingSnapshotAndOnResumes(t *testing.T) {
	f := newConduitFixture(t)
	for _, dir := range []string{"presence", "tmp", "run/drained", "inbox/ink/new", "ears"} {
		root := f.home
		if dir == "ears" {
			root = f.runtime
		}
		if err := os.MkdirAll(filepath.Join(root, dir), 0700); err != nil {
			t.Fatal(err)
		}
	}
	path := filepath.Join(f.home, "presence", "conduit@alpha.ear")
	if err := f.conduit.writeEars(earsModel{Now: time.Unix(1700000000, 0), State: "running"}); err != nil {
		t.Fatal(err)
	}
	first, _ := parseEars(path)
	if err := os.WriteFile(filepath.Join(f.home, "config"), []byte("self alpha\nears off\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := f.conduit.writeEars(earsModel{Now: time.Unix(1700000001, 0), State: "running", Identities: []earsIdentity{{Name: "ink"}}}); err != nil {
		t.Fatal(err)
	}
	stopped, err := parseEars(path)
	if err != nil || stopped.State != "stopping" || len(stopped.Identities) != 0 || stopped.Generation <= first.Generation {
		t.Fatalf("stopping snapshot=%+v err=%v", stopped, err)
	}
	if err := f.conduit.writeEars(earsModel{Now: time.Unix(1700000002, 0), State: "running"}); err != nil {
		t.Fatal(err)
	}
	silent, _ := parseEars(path)
	if silent.Generation != stopped.Generation {
		t.Fatalf("ears off wrote twice: %d then %d", stopped.Generation, silent.Generation)
	}
	if err := os.WriteFile(filepath.Join(f.home, "config"), []byte("self alpha\nears on\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := f.conduit.writeEars(earsModel{Now: time.Unix(1700000003, 0), State: "running"}); err != nil {
		t.Fatal(err)
	}
	resumed, err := parseEars(path)
	if err != nil || resumed.State != "running" || resumed.Generation <= stopped.Generation {
		t.Fatalf("resumed snapshot=%+v err=%v", resumed, err)
	}
}

func TestEarSixtyIdentitySize(t *testing.T) {
	identities := make([]earsIdentity, 0, 60)
	for index := 0; index < 60; index++ {
		identities = append(identities, earsIdentity{Name: fmt.Sprintf("session-%02d", index), Principal: "session", Listening: true, Route: "socket", Phase: "ready", CCVersion: "2.1.258", PendingRing: 2, PendingInfo: 1, Generation: testGeneration, FirstSeen: 1788401000, OldestPending: 1788400900, WrittenRings: 2, LastWritten: 1788401900, LastDrain: 1788401800, LastDrainBefore: testGeneration, LastDrainAfter: "-", LastDrainStatus: "ok", Reason: "-"})
	}
	data, err := formatEars(earsSnapshot{Node: "alpha", Generation: 1788402001, WrittenAt: 1788402001, Interval: 60, State: "running", Components: []earsComponent{{Name: "conduit", Release: linkVersion, Adapter: "1", Ears: "1"}}, Mailboxes: []string{"mini"}, LinkAge: 3, Identities: identities})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "truncated ") || len(data) > earsWriterMaxBytes {
		t.Fatalf("60-identity snapshot bytes=%d", len(data))
	}
	t.Logf("60-identity snapshot bytes=%d", len(data))
}

func TestMeasureEarIdleFiveMinutes(t *testing.T) {
	if os.Getenv("KHALA_RUN_FIVE_MINUTE_MEASUREMENT") != "1" {
		t.Skip("set KHALA_RUN_FIVE_MINUTE_MEASUREMENT=1 for the release measurement")
	}
	f := newConduitFixture(t)
	for _, dir := range []string{"presence", "tmp", "run/drained"} {
		if err := os.MkdirAll(filepath.Join(f.home, dir), 0700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.MkdirAll(filepath.Join(f.runtime, "ears"), 0700); err != nil {
		t.Fatal(err)
	}
	for index := 0; index < 3; index++ {
		identity := fmt.Sprintf("idle-%d", index)
		instance := fmt.Sprintf("owner-%d", index)
		reg := f.addRegistration(identity, instance, "interactive", false, time.Now().Add(-time.Hour), uint64(index+1))
		f.writeLease(identity, &reg, "owned", uint64(index+1))
	}
	f.conduit.scanEvery = 500 * time.Millisecond
	f.conduit.earInterval = 60 * time.Second
	f.conduit.earMailboxes = []string{"alpha"}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- f.conduit.run(ctx) }()
	path := filepath.Join(f.home, "presence", "conduit@alpha.ear")
	deadline := time.Now().Add(5 * time.Minute)
	var lastGeneration int64
	runningSnapshots := 0
	for time.Now().Before(deadline) {
		if snapshot, err := parseEars(path); err == nil && snapshot.State == "running" && snapshot.Generation != lastGeneration {
			if len(snapshot.Identities) != 3 {
				cancel()
				<-done
				t.Fatalf("snapshot identities=%d, want 3", len(snapshot.Identities))
			}
			lastGeneration = snapshot.Generation
			runningSnapshots++
		}
		time.Sleep(200 * time.Millisecond)
	}
	cancel()
	if err := <-done; err != context.Canceled {
		t.Fatalf("run err=%v", err)
	}
	if runningSnapshots > 6 {
		t.Fatalf("5-minute idle running snapshots=%d, want <= 6", runningSnapshots)
	}
	t.Logf("5-minute idle running snapshots=%d", runningSnapshots)
}

func TestMalformedDrainWarnsOnce(t *testing.T) {
	f := newConduitFixture(t)
	if err := os.MkdirAll(filepath.Join(f.home, "run", "drained"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(f.home, "run", "drained", "ink"), []byte("broken\n"), 0600); err != nil {
		t.Fatal(err)
	}
	for n := 0; n < 2; n++ {
		if got := f.conduit.readDrainStamp("ink"); got.LastDrain != 0 || got.LastDrainStatus != "-" {
			t.Fatalf("drain defaults=%+v", got)
		}
	}
	if strings.Count(f.logs.String(), "malformed drained stamp ignored: ink") != 1 {
		t.Fatalf("logs=%s", f.logs.String())
	}
}

// The reader's grammar must accept everything the writer emits (eddy merge
// gate B1: `route=channel+socket` was rejected by the reader).
func TestEarsRoundTripAcceptsEveryWriterValue(t *testing.T) {
	for _, route := range []string{"socket", "channel", "channel+socket", "none"} {
		listening := route != "none"
		reason := "-"
		if !listening {
			reason = "lease"
		}
		snapshot := earsSnapshot{Node: "alpha", Generation: 7, WrittenAt: 1788400000, Interval: 60, State: "running", Complete: true,
			Components: []earsComponent{{Name: "conduit", Release: "0.9.1", Adapter: "1", Ears: "1"}},
			Identities: []earsIdentity{{Name: "zeta", Principal: "session", Listening: listening, Route: route, Phase: "ready", CCVersion: "2.1.0", Reason: reason, Generation: "-", LastDrainStatus: "-", LastDrainBefore: "-", LastDrainAfter: "-"}}}
		data, err := formatEars(snapshot)
		if err != nil {
			t.Fatalf("format route %s: %v", route, err)
		}
		parsed, err := parseEarsBytes(data, "alpha")
		if err != nil {
			t.Fatalf("round trip rejected writer output for route %s: %v\n%s", route, err, data)
		}
		if len(parsed.Identities) != 1 || parsed.Identities[0].Route != route {
			t.Fatalf("round trip lost route %s: %+v", route, parsed.Identities)
		}
	}
}
