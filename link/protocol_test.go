package main

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"testing"
)

func TestProtocolFramesRoundTrip(t *testing.T) {
	digest := sha256.Sum256([]byte("payload"))
	want := offer{Class: "spool", Node: "beta", Basename: "1.sender@alpha", Size: 7, Digest: digest}
	want.ID = transferID(want.Class, want.Node, want.Basename, want.Digest)
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
