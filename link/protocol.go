package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
)

const (
	frameHello byte = iota + 1
	frameOffer
	frameHave
	frameNeed
	frameData
	frameStored
	framePing
	framePong
	frameError
	frameBye
)

const (
	protocolMagic  = "KHALA1"
	protocolMajor  = uint64(1)
	protocolMinor  = uint64(0)
	maxControlSize = 64 << 10
)

type frame struct {
	typ     byte
	payload []byte
}

type frameWriter struct {
	w  io.Writer
	mu chan struct{}
}

func newFrameWriter(w io.Writer) *frameWriter {
	fw := &frameWriter{w: w, mu: make(chan struct{}, 1)}
	fw.mu <- struct{}{}
	return fw
}

func (w *frameWriter) write(f frame) error {
	<-w.mu
	defer func() { w.mu <- struct{}{} }()
	if len(f.payload) > int(^uint32(0)) {
		return errors.New("frame payload is too large")
	}
	header := [5]byte{f.typ}
	binary.BigEndian.PutUint32(header[1:], uint32(len(f.payload)))
	if err := writeFull(w.w, header[:]); err != nil {
		return err
	}
	return writeFull(w.w, f.payload)
}

func writeFull(w io.Writer, p []byte) error {
	for len(p) > 0 {
		n, err := w.Write(p)
		if err != nil {
			return err
		}
		if n == 0 {
			return io.ErrShortWrite
		}
		p = p[n:]
	}
	return nil
}

func readFrame(r *bufio.Reader, maxObject int64) (frame, error) {
	header := make([]byte, 5)
	if _, err := io.ReadFull(r, header); err != nil {
		return frame{}, err
	}
	n := int64(binary.BigEndian.Uint32(header[1:]))
	limit := int64(maxControlSize)
	if header[0] == frameData {
		limit = maxObject + 4096
	}
	if n < 0 || n > limit {
		return frame{}, fmt.Errorf("frame type %d length %d exceeds limit %d", header[0], n, limit)
	}
	payload := make([]byte, n)
	if _, err := io.ReadFull(r, payload); err != nil {
		return frame{}, err
	}
	return frame{typ: header[0], payload: payload}, nil
}

type encoder struct{ b []byte }

func (e *encoder) str(s string) {
	e.u64(uint64(len(s)))
	e.b = append(e.b, s...)
}

func (e *encoder) u64(n uint64) {
	var b [8]byte
	binary.BigEndian.PutUint64(b[:], n)
	e.b = append(e.b, b[:]...)
}

type decoder struct {
	b []byte
	i int
}

func (d *decoder) u64() (uint64, error) {
	if len(d.b)-d.i < 8 {
		return 0, io.ErrUnexpectedEOF
	}
	n := binary.BigEndian.Uint64(d.b[d.i : d.i+8])
	d.i += 8
	return n, nil
}

func (d *decoder) str() (string, error) {
	n, err := d.u64()
	if err != nil {
		return "", err
	}
	if n > uint64(len(d.b)-d.i) {
		return "", io.ErrUnexpectedEOF
	}
	s := string(d.b[d.i : d.i+int(n)])
	d.i += int(n)
	return s, nil
}

func (d *decoder) done() error {
	if d.i != len(d.b) {
		return fmt.Errorf("%d trailing payload bytes", len(d.b)-d.i)
	}
	return nil
}

type hello struct {
	Magic string
	Major uint64
	Minor uint64
	Node  string
	Role  string
	Impl  string
}

func helloFrame(h hello) frame {
	var e encoder
	e.str(h.Magic)
	e.u64(h.Major)
	e.u64(h.Minor)
	e.str(h.Node)
	e.str(h.Role)
	e.str(h.Impl)
	return frame{typ: frameHello, payload: e.b}
}

func decodeHello(f frame) (hello, error) {
	if f.typ != frameHello {
		return hello{}, fmt.Errorf("first frame is type %d, not HELLO", f.typ)
	}
	d := decoder{b: f.payload}
	var h hello
	var err error
	if h.Magic, err = d.str(); err != nil {
		return h, err
	}
	if h.Major, err = d.u64(); err != nil {
		return h, err
	}
	if h.Minor, err = d.u64(); err != nil {
		return h, err
	}
	if h.Node, err = d.str(); err != nil {
		return h, err
	}
	if h.Role, err = d.str(); err != nil {
		return h, err
	}
	if h.Impl, err = d.str(); err != nil {
		return h, err
	}
	return h, d.done()
}

type offer struct {
	ID       string
	Class    string
	Node     string
	Basename string
	Size     uint64
	Digest   [sha256.Size]byte
}

func offerFrame(o offer) frame {
	var e encoder
	e.str(o.ID)
	e.str(o.Class)
	e.str(o.Node)
	e.str(o.Basename)
	e.u64(o.Size)
	e.str(hex.EncodeToString(o.Digest[:]))
	return frame{typ: frameOffer, payload: e.b}
}

func decodeOffer(f frame) (offer, error) {
	d := decoder{b: f.payload}
	var o offer
	var digest string
	var err error
	if o.ID, err = d.str(); err != nil {
		return o, err
	}
	if o.Class, err = d.str(); err != nil {
		return o, err
	}
	if o.Node, err = d.str(); err != nil {
		return o, err
	}
	if o.Basename, err = d.str(); err != nil {
		return o, err
	}
	if o.Size, err = d.u64(); err != nil {
		return o, err
	}
	if digest, err = d.str(); err != nil {
		return o, err
	}
	decoded, err := hex.DecodeString(digest)
	if err != nil || len(decoded) != sha256.Size {
		return o, errors.New("invalid OFFER sha256")
	}
	copy(o.Digest[:], decoded)
	if err := d.done(); err != nil {
		return o, err
	}
	if o.ID != transferID(o.Class, o.Node, o.Basename, o.Digest) {
		return o, errors.New("OFFER transfer id does not match its object identity")
	}
	return o, nil
}

func idFrame(typ byte, id string) frame {
	var e encoder
	e.str(id)
	return frame{typ: typ, payload: e.b}
}

func decodeID(f frame) (string, error) {
	d := decoder{b: f.payload}
	id, err := d.str()
	if err != nil {
		return "", err
	}
	return id, d.done()
}

func dataFrame(id string, data []byte) frame {
	var e encoder
	e.str(id)
	e.b = append(e.b, data...)
	return frame{typ: frameData, payload: e.b}
}

func decodeData(f frame) (string, []byte, error) {
	d := decoder{b: f.payload}
	id, err := d.str()
	if err != nil {
		return "", nil, err
	}
	return id, d.b[d.i:], nil
}

func epochFrame(typ byte, epoch uint64) frame {
	var e encoder
	e.u64(epoch)
	return frame{typ: typ, payload: e.b}
}

func decodeEpoch(f frame) (uint64, error) {
	d := decoder{b: f.payload}
	n, err := d.u64()
	if err != nil {
		return 0, err
	}
	return n, d.done()
}

type protocolError struct {
	Code        string
	Recoverable bool
	Text        string
}

func errorFrame(code string, recoverable bool, text string) frame {
	var e encoder
	e.str(code)
	if recoverable {
		e.u64(1)
	} else {
		e.u64(0)
	}
	e.str(text)
	return frame{typ: frameError, payload: e.b}
}

func decodeError(f frame) (protocolError, error) {
	d := decoder{b: f.payload}
	var p protocolError
	var recoverable uint64
	var err error
	if p.Code, err = d.str(); err != nil {
		return p, err
	}
	if recoverable, err = d.u64(); err != nil {
		return p, err
	}
	if recoverable > 1 {
		return p, errors.New("invalid ERROR recoverable flag")
	}
	p.Recoverable = recoverable == 1
	if p.Text, err = d.str(); err != nil {
		return p, err
	}
	return p, d.done()
}

func transferID(class, node, basename string, digest [sha256.Size]byte) string {
	h := sha256.New()
	_, _ = io.WriteString(h, class)
	_, _ = io.WriteString(h, "\x00")
	_, _ = io.WriteString(h, node)
	_, _ = io.WriteString(h, "\x00")
	_, _ = io.WriteString(h, basename)
	_, _ = h.Write(digest[:])
	return hex.EncodeToString(h.Sum(nil))
}
