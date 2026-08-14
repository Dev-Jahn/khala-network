package main

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestProtocolMajorMismatchSendsFatalErrorAndBye(t *testing.T) {
	local, remote := net.Pipe()
	defer local.Close()
	defer remote.Close()
	p := &pump{
		self: "alpha", role: "dial", maxObject: 1 << 20,
		reader: bufio.NewReader(local), writer: newFrameWriter(local),
		logger: log.New(io.Discard, "", 0),
	}
	peerResult := make(chan []frame, 1)
	go func() {
		r := bufio.NewReader(remote)
		_, _ = readFrame(r, 1<<20)
		_ = newFrameWriter(remote).write(helloFrame(hello{
			Magic: protocolMagic, Major: protocolMajor + 1, Minor: 0,
			Node: "b200", Role: "serve", Impl: "future",
		}))
		first, _ := readFrame(r, 1<<20)
		second, _ := readFrame(r, 1<<20)
		peerResult <- []frame{first, second}
	}()
	if _, err := p.handshake(); err == nil {
		t.Fatal("major mismatch succeeded")
	}
	frames := <-peerResult
	if len(frames) != 2 || frames[0].typ != frameError || frames[1].typ != frameBye {
		t.Fatalf("got frame types %d, %d", frames[0].typ, frames[1].typ)
	}
	pe, err := decodeError(frames[0])
	if err != nil {
		t.Fatal(err)
	}
	if pe.Recoverable || pe.Code != "MAJOR_MISMATCH" {
		t.Fatalf("unexpected error %#v", pe)
	}
}

func TestNegotiatedMinorIsMinimum(t *testing.T) {
	for _, tc := range []struct {
		local, remote, want uint64
	}{
		{1, 0, 0},
		{1, 1, 1},
		{1, 9, 1},
		{2, 1, 1},
		{2, 2, 2},
	} {
		if got := minimumMinor(tc.local, tc.remote); got != tc.want {
			t.Errorf("minimumMinor(%d, %d)=%d want %d", tc.local, tc.remote, got, tc.want)
		}
	}
}

func TestMindOfferRequiresMinorTwo(t *testing.T) {
	home := testKhalaHome(t)
	path := filepath.Join(home, "minds", "alpha", "worker", "1.0")
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("mind"), 0600); err != nil {
		t.Fatal(err)
	}
	var wire bytes.Buffer
	p := &pump{
		role: "dial", minor: 1, retainDays: 30, maxObject: 1 << 20,
		logger: log.New(io.Discard, "", 0), writer: newFrameWriter(&wire),
		origins: newOriginSet(), known: make(map[string]string), rejected: make(map[string]string),
	}
	c := candidate{class: "mind", node: "alpha", session: "worker", basename: "1.0", path: path}
	if err := p.sendCandidate(context.Background(), c); err != nil {
		t.Fatal(err)
	}
	if wire.Len() != 0 {
		t.Fatalf("minor 1 wrote %d mind OFFER bytes", wire.Len())
	}
}

func TestMindInstallTriggersBrainWithoutTouchingFreshMarker(t *testing.T) {
	home := testKhalaHome(t)
	fresh := filepath.Join(home, "run", "link.fresh")
	if err := os.MkdirAll(filepath.Dir(fresh), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(fresh, nil, 0600); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-time.Hour)
	if err := os.Chtimes(fresh, old, old); err != nil {
		t.Fatal(err)
	}
	data := []byte("mind bytes")
	o := testMindOffer("alpha", "worker", fmt.Sprintf("%d.0", time.Now().Unix()), data)
	var wire bytes.Buffer
	p := &pump{
		home: home, role: "dial", writer: newFrameWriter(&wire), logger: log.New(io.Discard, "", 0),
		origins: newOriginSet(), brain: &brain{dirty: make(chan struct{}, 1)}, asyncErr: make(chan error, 1),
	}
	ins := &installer{home: home, role: "dial", peer: "beta", retainDays: 30, logger: p.logger}
	var active atomic.Bool
	active.Store(true)
	p.installIncoming(ins, o, data, &active)
	select {
	case <-p.brain.dirty:
	default:
		t.Fatal("mind install did not trigger brain reconcile")
	}
	info, err := os.Stat(fresh)
	if err != nil {
		t.Fatal(err)
	}
	if info.ModTime().After(old.Add(time.Second)) {
		t.Fatalf("mind install refreshed link marker: got %s want %s", info.ModTime(), old)
	}
}

func TestFutureMindQuarantineDoesNotTriggerBrainOrTouchFreshMarker(t *testing.T) {
	home := testKhalaHome(t)
	fresh := filepath.Join(home, "run", "link.fresh")
	if err := os.MkdirAll(filepath.Dir(fresh), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(fresh, nil, 0600); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-time.Hour)
	if err := os.Chtimes(fresh, old, old); err != nil {
		t.Fatal(err)
	}
	data := []byte("future mind bytes")
	generation := fmt.Sprintf("%d.0", time.Now().Unix()+86401)
	o := testMindOffer("alpha", "worker", generation, data)
	var wire bytes.Buffer
	p := &pump{
		home: home, role: "dial", writer: newFrameWriter(&wire), logger: log.New(io.Discard, "", 0),
		origins: newOriginSet(), brain: &brain{dirty: make(chan struct{}, 1)}, asyncErr: make(chan error, 1),
	}
	ins := &installer{home: home, role: "dial", peer: "beta", retainDays: 30, logger: p.logger}
	var active atomic.Bool
	active.Store(true)
	p.installIncoming(ins, o, data, &active)
	select {
	case <-p.brain.dirty:
		t.Fatal("future mind quarantine triggered brain reconcile")
	default:
	}
	info, err := os.Stat(fresh)
	if err != nil {
		t.Fatal(err)
	}
	if info.ModTime().After(old.Add(time.Second)) {
		t.Fatalf("future mind quarantine refreshed link marker: got %s want %s", info.ModTime(), old)
	}
	want := filepath.Join(home, "spool", "dead", "mind.alpha.worker."+generation)
	if _, err := os.Stat(want); err != nil {
		t.Fatalf("future mind quarantine missing: %v", err)
	}
}

func TestServeDefaultQuietTimeout(t *testing.T) {
	if os.Getenv("KHALA_LINK_LONG_TEST") != "1" {
		t.Skip("set KHALA_LINK_LONG_TEST=1 for the 60s serve liveness test")
	}
	t.Setenv("KHALA_LINK_TEST_QUIET_TIMEOUT", "")
	home := testKhalaHome(t)
	local, remote := net.Pipe()
	defer local.Close()
	defer remote.Close()
	result := make(chan error, 1)
	go func() {
		_, err := runPump(context.Background(), readWriter{Reader: local, Writer: local},
			home, "serve", "b200", "", "/bin/true", 1<<20, 30, time.Hour, newLogOnceSet(),
			log.New(io.Discard, "", 0))
		result <- err
	}()
	remoteReader := bufio.NewReader(remote)
	if _, err := readFrame(remoteReader, 1<<20); err != nil {
		t.Fatal(err)
	}
	if err := newFrameWriter(remote).write(helloFrame(hello{
		Magic: protocolMagic, Major: protocolMajor, Minor: protocolMinor,
		Node: "alpha", Role: "dial", Impl: "silent-test-double",
	})); err != nil {
		t.Fatal(err)
	}
	started := time.Now()
	select {
	case err := <-result:
		elapsed := time.Since(started)
		if err == nil || !strings.Contains(err.Error(), "no inbound protocol frame for 1m0s") {
			t.Fatalf("unexpected serve result after %s: %v", elapsed, err)
		}
		if elapsed < 60*time.Second || elapsed > 62*time.Second {
			t.Fatalf("serve quiet timeout elapsed=%s", elapsed)
		}
	case <-time.After(63 * time.Second):
		t.Fatal("serve did not stop after its 60s quiet timeout")
	}
}

func TestPumpShutdownWaitsForAgeScanReconcile(t *testing.T) {
	home := testKhalaHome(t)
	brainPath := filepath.Join(home, "fake-brain")
	brainScript := `#!/bin/sh
if [ "${KHALA_LINK_SCAN_GATE-}" = 1 ]; then
    mkdir "$KHALA_HOME/run/brain.lock.d" || exit 1
    printf '%s\n' "$$" > "$KHALA_HOME/run/brain.lock.d/owner"
    : > "$KHALA_HOME/gate.started"
    sleep 1
    rm -f "$KHALA_HOME/run/brain.lock.d/owner"
    rmdir "$KHALA_HOME/run/brain.lock.d"
    : > "$KHALA_HOME/gate.done"
fi
`
	if err := os.WriteFile(brainPath, []byte(brainScript), 0700); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	local, remote := net.Pipe()
	defer local.Close()
	defer remote.Close()
	result := make(chan error, 1)
	go func() {
		_, err := runPump(ctx, readWriter{Reader: local, Writer: local}, home, "serve", "b200", "",
			brainPath, 1<<20, 30, time.Hour, newLogOnceSet(), log.New(io.Discard, "", 0))
		result <- err
	}()
	remoteReader := bufio.NewReader(remote)
	if _, err := readFrame(remoteReader, 1<<20); err != nil {
		t.Fatal(err)
	}
	if err := newFrameWriter(remote).write(helloFrame(hello{
		Magic: protocolMagic, Major: protocolMajor, Minor: protocolMinor,
		Node: "alpha", Role: "dial", Impl: "shutdown-test-double",
	})); err != nil {
		t.Fatal(err)
	}
	started := filepath.Join(home, "gate.started")
	deadline := time.Now().Add(time.Second)
	for {
		if _, err := os.Stat(started); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("age-scan reconcile did not start")
		}
		time.Sleep(10 * time.Millisecond)
	}
	_ = remote.Close()
	select {
	case <-result:
	case <-time.After(2 * time.Second):
		t.Fatal("pump did not stop after age-scan reconcile completed")
	}
	if _, err := os.Stat(filepath.Join(home, "gate.done")); err != nil {
		t.Fatalf("pump returned before age-scan reconcile finished: %v", err)
	}
	if _, err := os.Stat(filepath.Join(home, "run", "brain.lock.d")); !os.IsNotExist(err) {
		t.Fatalf("pump stranded brain lock on shutdown: %v", err)
	}
}

func TestInboundInstallDoesNotBlockOppositeDirectionResponses(t *testing.T) {
	t.Setenv("KHALA_LINK_TEST_DATA_INSTALL_DELAY", "500ms")
	home := testKhalaHome(t)
	local, remote := net.Pipe()
	defer local.Close()
	defer remote.Close()
	p := &pump{
		home: home, role: "dial", self: "alpha", maxObject: 1 << 20,
		reader: bufio.NewReader(local), writer: newFrameWriter(local),
		logger: log.New(io.Discard, "", 0), responses: make(chan frame, 1),
		origins: newOriginSet(), asyncErr: make(chan error, 1),
		brain: &brain{dirty: make(chan struct{}, 1)},
	}
	p.activeOut.Store(true)
	result := make(chan error, 1)
	go func() { result <- p.readLoop(context.Background()) }()

	data := []byte("durable inbound")
	o := testOffer("spool", "alpha", "async.sender@beta", data)
	remoteWriter := newFrameWriter(remote)
	remoteReader := bufio.NewReader(remote)
	if err := remoteWriter.write(offerFrame(o)); err != nil {
		t.Fatal(err)
	}
	if f, err := readFrame(remoteReader, 1<<20); err != nil || f.typ != frameNeed {
		t.Fatalf("NEED frame=%v err=%v", f.typ, err)
	}
	if err := remoteWriter.write(dataFrame(o.ID, data)); err != nil {
		t.Fatal(err)
	}
	writeResult := make(chan error, 1)
	go func() { writeResult <- remoteWriter.write(idFrame(frameHave, "concurrent-outbound")) }()
	select {
	case f := <-p.responses:
		if f.typ != frameHave {
			t.Fatalf("response type=%d", f.typ)
		}
	case <-time.After(200 * time.Millisecond):
		t.Fatal("opposite-direction HAVE was blocked by inbound install")
	}
	if err := <-writeResult; err != nil {
		t.Fatal(err)
	}
	if f, err := readFrame(remoteReader, 1<<20); err != nil || f.typ != frameStored {
		t.Fatalf("STORED frame=%v err=%v", f.typ, err)
	}
	select {
	case <-p.brain.dirty:
	case <-time.After(time.Second):
		t.Fatal("install completion did not trigger the brain")
	}
	_ = remote.Close()
	select {
	case <-result:
	case <-time.After(time.Second):
		t.Fatal("reader did not stop after pipe close")
	}
}

func TestExpiredOutboundStreamProducesNoOfferAndLogsOnce(t *testing.T) {
	home := testKhalaHome(t)
	name := fmt.Sprintf("%d.1.1.speaker@alpha", time.Now().Unix()-32*86400)
	path := filepath.Join(home, "streams", "commons", "alpha", name)
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("expired"), 0600); err != nil {
		t.Fatal(err)
	}
	var wire bytes.Buffer
	var logs bytes.Buffer
	p := &pump{
		role: "dial", minor: streamMinor, retainDays: 30, maxObject: 1 << 20,
		logger: log.New(&logs, "", 0), writer: newFrameWriter(&wire),
		expiredOfferLogs: newLogOnceSet(), origins: newOriginSet(),
		known: make(map[string]string), rejected: make(map[string]string),
	}
	c := candidate{class: "stream", stream: "commons", node: "alpha", basename: name, path: path}
	for cycle := 0; cycle < 2; cycle++ {
		if err := p.sendCandidate(context.Background(), c); err != nil {
			t.Fatal(err)
		}
	}
	if wire.Len() != 0 {
		t.Fatalf("expired stream wrote %d wire bytes", wire.Len())
	}
	if count := strings.Count(logs.String(), name); count != 1 {
		t.Fatalf("expired skip log count=%d logs=%q", count, logs.String())
	}
}

func TestInboundExpiredOfferIsRecoverableWithoutDataOrBrainTrigger(t *testing.T) {
	home := testKhalaHome(t)
	local, remote := net.Pipe()
	defer local.Close()
	defer remote.Close()
	p := &pump{
		home: home, role: "serve", self: "b200", peer: "alpha", minor: streamMinor,
		retainDays: 30, maxObject: 1 << 20,
		reader: bufio.NewReader(local), writer: newFrameWriter(local),
		logger: log.New(io.Discard, "", 0), responses: make(chan frame, 1),
		origins: newOriginSet(), asyncErr: make(chan error, 1),
		brain: &brain{dirty: make(chan struct{}, 1)},
	}
	result := make(chan error, 1)
	go func() { result <- p.readLoop(context.Background()) }()

	name := fmt.Sprintf("%d.1.1.speaker@alpha", time.Now().Unix()-32*86400)
	data := []byte("expired in flight")
	o := testStreamOffer("commons", "alpha", name, data)
	if err := newFrameWriter(remote).write(offerFrame(o)); err != nil {
		t.Fatal(err)
	}
	f, err := readFrame(bufio.NewReader(remote), 1<<20)
	if err != nil || f.typ != frameError {
		t.Fatalf("response type=%d err=%v", f.typ, err)
	}
	protocolErr, err := decodeError(f)
	if err != nil || protocolErr.Code != "STREAM_EXPIRED" || !protocolErr.Recoverable {
		t.Fatalf("response=%+v err=%v", protocolErr, err)
	}
	if _, err := os.Stat(filepath.Join(home, "streams", "commons", "alpha", name)); !os.IsNotExist(err) {
		t.Fatalf("expired offer installed: %v", err)
	}
	select {
	case <-p.brain.dirty:
		t.Fatal("expired offer triggered the brain")
	default:
	}
	_ = remote.Close()
	select {
	case <-result:
	case <-time.After(time.Second):
		t.Fatal("reader did not stop after pipe close")
	}
}

func TestUnknownFrameSendsFatalErrorAndBye(t *testing.T) {
	local, remote := net.Pipe()
	defer local.Close()
	defer remote.Close()
	p := &pump{
		role: "dial", self: "alpha", maxObject: 1 << 20,
		reader: bufio.NewReader(local), writer: newFrameWriter(local),
		logger: log.New(io.Discard, "", 0), responses: make(chan frame, 1),
	}
	result := make(chan error, 1)
	go func() { result <- p.readLoop(context.Background()) }()
	if err := newFrameWriter(remote).write(frame{typ: 0xff}); err != nil {
		t.Fatal(err)
	}
	r := bufio.NewReader(remote)
	first, err := readFrame(r, 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	second, err := readFrame(r, 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	if first.typ != frameError || second.typ != frameBye {
		t.Fatalf("got frame types %d, %d", first.typ, second.typ)
	}
	if err := <-result; err == nil {
		t.Fatal("unknown frame did not fail")
	}
}
