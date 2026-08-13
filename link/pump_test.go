package main

import (
	"bufio"
	"context"
	"io"
	"log"
	"net"
	"os"
	"strings"
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
	} {
		if got := minimumMinor(tc.local, tc.remote); got != tc.want {
			t.Errorf("minimumMinor(%d, %d)=%d want %d", tc.local, tc.remote, got, tc.want)
		}
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
			home, "serve", "b200", "", "/bin/true", 1<<20, time.Hour,
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
