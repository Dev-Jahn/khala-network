package main

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"testing"
)

func TestProtocolFramesRoundTrip(t *testing.T) {
	digest := sha256.Sum256([]byte("payload"))
	want := offer{Class: "spool", Node: "beta", Basename: "1.sender@alpha", Size: 7, Digest: digest}
	want.ID = transferID(want.Class, want.Stream, want.Node, want.Session, want.Basename, want.Digest)
	var wire bytes.Buffer
	if err := newFrameWriter(&wire).write(offerFrame(want)); err != nil {
		t.Fatal(err)
	}
	f, err := readFrame(bufio.NewReader(&wire), 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	got, err := decodeOffer(f)
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("offer mismatch: got %#v want %#v", got, want)
	}
}

func TestOfferRejectsForgedTransferID(t *testing.T) {
	digest := sha256.Sum256([]byte("payload"))
	o := offer{ID: "../../tmp", Class: "spool", Node: "beta", Basename: "1.sender@alpha", Size: 7, Digest: digest}
	if _, err := decodeOffer(offerFrame(o)); err == nil {
		t.Fatal("forged transfer id was accepted")
	}
}

func TestStreamOfferRoundTripAndBindsStreamToTransferID(t *testing.T) {
	digest := sha256.Sum256([]byte("stream payload"))
	want := offer{Class: "stream", Stream: "khala", Node: "alpha", Basename: "1.2.3.ear@alpha", Size: 14, Digest: digest}
	want.ID = transferID(want.Class, want.Stream, want.Node, want.Session, want.Basename, want.Digest)
	otherID := transferID(want.Class, "other", want.Node, want.Session, want.Basename, want.Digest)
	if want.ID == otherID {
		t.Fatal("stream name is absent from transfer identity")
	}
	got, err := decodeOffer(offerFrame(want))
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("stream offer mismatch: got %#v want %#v", got, want)
	}
}

func TestMindOfferRoundTripAndBindsSessionToTransferID(t *testing.T) {
	digest := sha256.Sum256([]byte("mind payload"))
	want := offer{Class: "mind", Node: "alpha", Session: "worker", Basename: "123.4", Size: 12, Digest: digest}
	want.ID = transferID(want.Class, want.Stream, want.Node, want.Session, want.Basename, want.Digest)
	otherID := transferID(want.Class, want.Stream, want.Node, "other", want.Basename, want.Digest)
	if want.ID == otherID {
		t.Fatal("mind session is absent from transfer identity")
	}
	got, err := decodeOffer(offerFrame(want))
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("mind offer mismatch: got %#v want %#v", got, want)
	}
}

func TestLegacyOfferEncodingRemainsByteIdentical(t *testing.T) {
	digest := sha256.Sum256([]byte("legacy payload"))
	for _, class := range []string{"spool", "presence"} {
		o := offer{Class: class, Node: "alpha", Basename: "1.2.3.ear@alpha", Size: 14, Digest: digest}
		o.ID = transferID(o.Class, o.Stream, o.Node, o.Session, o.Basename, o.Digest)
		legacyIDHash := sha256.New()
		_, _ = io.WriteString(legacyIDHash, o.Class)
		_, _ = io.WriteString(legacyIDHash, "\x00")
		_, _ = io.WriteString(legacyIDHash, o.Node)
		_, _ = io.WriteString(legacyIDHash, "\x00")
		_, _ = io.WriteString(legacyIDHash, o.Basename)
		_, _ = legacyIDHash.Write(o.Digest[:])
		legacyID := hex.EncodeToString(legacyIDHash.Sum(nil))
		if o.ID != legacyID {
			t.Fatalf("%s transfer ID changed from v1.0: got %s want %s", class, o.ID, legacyID)
		}
		var legacy encoder
		legacy.str(o.ID)
		legacy.str(o.Class)
		legacy.str(o.Node)
		legacy.str(o.Basename)
		legacy.u64(o.Size)
		legacy.str(hex.EncodeToString(o.Digest[:]))
		if got := offerFrame(o).payload; !bytes.Equal(got, legacy.b) {
			t.Fatalf("%s OFFER changed from v1.0: got %x want %x", class, got, legacy.b)
		}
	}
	stream := offer{Class: "stream", Stream: "commons", Node: "alpha", Basename: "1.2.3.ear@alpha", Size: 14, Digest: digest}
	stream.ID = transferID(stream.Class, stream.Stream, stream.Node, stream.Session, stream.Basename, stream.Digest)
	var legacyStream encoder
	legacyStream.str(stream.ID)
	legacyStream.str(stream.Class)
	legacyStream.str(stream.Stream)
	legacyStream.str(stream.Node)
	legacyStream.str(stream.Basename)
	legacyStream.u64(stream.Size)
	legacyStream.str(hex.EncodeToString(stream.Digest[:]))
	if got := offerFrame(stream).payload; !bytes.Equal(got, legacyStream.b) {
		t.Fatalf("stream OFFER changed from v1.1: got %x want %x", got, legacyStream.b)
	}
}

func TestDataCarriesExactlyOfferedBytes(t *testing.T) {
	want := []byte{0, 1, 2, 0xff}
	f := dataFrame("xfer", want)
	id, got, err := decodeData(f)
	if err != nil {
		t.Fatal(err)
	}
	if id != "xfer" || !bytes.Equal(got, want) {
		t.Fatalf("got id=%q data=%v", id, got)
	}
}

func TestUnknownFrameRemainsVisibleToProtocolLoop(t *testing.T) {
	var wire bytes.Buffer
	if err := newFrameWriter(&wire).write(frame{typ: 0xff}); err != nil {
		t.Fatal(err)
	}
	f, err := readFrame(bufio.NewReader(&wire), 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	if f.typ != 0xff {
		t.Fatalf("unknown type changed to %d", f.typ)
	}
}

func TestBasenameValidation(t *testing.T) {
	valid := []string{"123.sender@alpha", "ear@alpha.watching", "A-1.z"}
	invalid := []string{"", ".hidden", "../escape", "/absolute", "has_underbar"}
	for _, name := range valid {
		if !validBasename(name) {
			t.Errorf("valid name rejected: %q", name)
		}
	}
	for _, name := range invalid {
		if validBasename(name) {
			t.Errorf("invalid name accepted: %q", name)
		}
	}
}
