package main

import (
	"bufio"
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

type readWriter struct {
	io.Reader
	io.Writer
}

type pump struct {
	home             string
	role             string
	self             string
	peer             string
	localMinor       uint64
	minor            uint64
	maxObject        int64
	retainDays       uint64
	scanEvery        time.Duration
	logger           *log.Logger
	reader           *bufio.Reader
	writer           *frameWriter
	brain            *brain
	origins          *originSet
	responses        chan frame
	lastInput        atomic.Int64
	activeOut        atomic.Bool
	asyncErr         chan error
	knownMu          sync.Mutex
	known            map[string]string
	rejected         map[string]string
	expiredOfferLogs *logOnceSet
}

func runPump(ctx context.Context, rw readWriter, home, role, self, expectedPeer, brainPath string, maxObject int64, retainDays uint64, scanEvery time.Duration, expiredOfferLogs *logOnceSet, logger *log.Logger) (hello, error) {
	localMinor, err := advertisedMinor(role)
	if err != nil {
		return hello{}, err
	}
	p := &pump{
		home: home, role: role, self: self, peer: expectedPeer,
		localMinor: localMinor,
		maxObject:  maxObject, retainDays: retainDays, scanEvery: scanEvery, logger: logger,
		reader: bufio.NewReader(rw.Reader), writer: newFrameWriter(rw.Writer),
		origins: newOriginSet(), responses: make(chan frame, 8), asyncErr: make(chan error, 4),
		known: make(map[string]string), rejected: make(map[string]string), expiredOfferLogs: expiredOfferLogs,
	}
	remote, err := p.handshake()
	if err != nil {
		return remote, err
	}
	if role == "serve" {
		p.peer = remote.Node
	}
	p.minor = minimumMinor(p.localMinor, remote.Minor)
	if p.minor < streamMinor {
		logger.Printf("negotiated protocol %d.%d; stream offers disabled", protocolMajor, p.minor)
	}
	if role == "dial" && expectedPeer != "" && remote.Node != expectedPeer {
		p.fatal("PEER_MISMATCH", fmt.Sprintf("expected peer %q, got %q", expectedPeer, remote.Node))
		return remote, fmt.Errorf("peer mismatch")
	}
	if err := p.touchFresh(); err != nil {
		logger.Printf("touch link.fresh after HELLO failed: %v", err)
	}
	p.lastInput.Store(time.Now().UnixNano())

	sessionCtx, cancel := context.WithCancel(ctx)
	p.brain = newBrain(brainPath, home, logger)
	brainDone := make(chan struct{})
	go func() {
		p.brain.run(sessionCtx)
		close(brainDone)
	}()
	candidates := make(chan candidate, 256)
	watcher := newTreeWatcher(home, role, self, p.peer, logger, p.brain, p.origins, candidates, scanEvery)
	errs := make(chan error, 4)
	watcherDone := make(chan struct{})
	go func() {
		errs <- watcher.run(sessionCtx)
		close(watcherDone)
	}()
	defer func() {
		cancel()
		// A scan-gate reconcile can own brain.lock.d. Let the watcher finish it
		// before this process exits, otherwise the child dies with a live lock.
		<-watcherDone
		select {
		case <-brainDone:
		case <-time.After(10 * time.Second):
			logger.Printf("brain reconcile still running after link shutdown; leaving it alive to release brain.lock.d")
		}
	}()
	go func() { errs <- p.sendLoop(sessionCtx, candidates) }()
	go func() { errs <- p.readLoop(sessionCtx) }()
	go func() { errs <- p.keepalive(sessionCtx) }()

	select {
	case <-ctx.Done():
		_ = p.writer.write(frame{typ: frameBye})
		return remote, ctx.Err()
	case err := <-errs:
		if err == nil {
			err = errors.New("protocol worker stopped")
		}
		return remote, err
	case err := <-p.asyncErr:
		return remote, err
	}
}

func (p *pump) handshake() (hello, error) {
	local := hello{Magic: protocolMagic, Major: protocolMajor, Minor: p.localMinor, Node: p.self, Role: p.role, Impl: implVersion}
	if err := p.writer.write(helloFrame(local)); err != nil {
		return hello{}, fmt.Errorf("write HELLO: %w", err)
	}
	f, err := readFrame(p.reader, p.maxObject)
	if err != nil {
		return hello{}, fmt.Errorf("read HELLO: %w", err)
	}
	remote, err := decodeHello(f)
	if err != nil {
		p.fatal("BAD_HELLO", err.Error())
		return hello{}, err
	}
	if remote.Magic != protocolMagic {
		p.fatal("BAD_MAGIC", fmt.Sprintf("unsupported magic %q", remote.Magic))
		return remote, fmt.Errorf("protocol magic mismatch")
	}
	if remote.Major != protocolMajor {
		p.fatal("MAJOR_MISMATCH", fmt.Sprintf("protocol major %d is incompatible with %d", remote.Major, protocolMajor))
		return remote, fmt.Errorf("protocol major mismatch")
	}
	if !validNode(remote.Node) {
		p.fatal("BAD_NODE", fmt.Sprintf("invalid remote node alias %q", remote.Node))
		return remote, fmt.Errorf("invalid remote node")
	}
	wantRole := "serve"
	if p.role == "serve" {
		wantRole = "dial"
	}
	if remote.Role != wantRole {
		p.fatal("BAD_ROLE", fmt.Sprintf("expected role %q, got %q", wantRole, remote.Role))
		return remote, fmt.Errorf("remote role mismatch")
	}
	return remote, nil
}

func minimumMinor(local, remote uint64) uint64 {
	if remote < local {
		return remote
	}
	return local
}

func advertisedMinor(role string) (uint64, error) {
	value, set := os.LookupEnv("KHALA_LINK_TEST_SERVE_MINOR")
	if role != "serve" || !set {
		return protocolMinor, nil
	}
	minor, err := strconv.ParseUint(value, 10, 64)
	if err != nil || minor > protocolMinor {
		return 0, fmt.Errorf("KHALA_LINK_TEST_SERVE_MINOR must be between 0 and %d", protocolMinor)
	}
	return minor, nil
}

func (p *pump) fatal(code, text string) {
	p.logger.Printf("fatal protocol error %s: %s", code, text)
	_ = p.writer.write(errorFrame(code, false, text))
	_ = p.writer.write(frame{typ: frameBye})
}

func (p *pump) readLoop(ctx context.Context) error {
	installPeer := p.peer
	if p.role == "dial" {
		installPeer = p.self
	}
	ins := &installer{home: p.home, role: p.role, peer: installPeer, retainDays: p.retainDays, logger: p.logger}
	var incoming *offer
	var installing atomic.Bool
	for {
		f, err := readFrame(p.reader, p.maxObject)
		if err != nil {
			return fmt.Errorf("read frame: %w", err)
		}
		p.lastInput.Store(time.Now().UnixNano())
		switch f.typ {
		case frameOffer:
			if incoming != nil || installing.Load() {
				p.fatal("INFLIGHT_LIMIT", "received OFFER while prior inbound object awaits DATA")
				return errors.New("multiple inbound objects")
			}
			o, err := decodeOffer(f)
			if err != nil {
				p.fatal("BAD_OFFER", err.Error())
				return err
			}
			if o.Class == "stream" && p.minor < streamMinor {
				text := fmt.Sprintf("stream OFFER requires protocol minor %d", streamMinor)
				p.logger.Printf("refused unnegotiated OFFER: %s", text)
				if err := p.writer.write(errorFrame("UNNEGOTIATED_CLASS", true, text)); err != nil {
					return err
				}
				continue
			}
			if o.Size > uint64(p.maxObject) {
				text := fmt.Sprintf("%s is %d bytes; max-object-bytes is %d", o.Basename, o.Size, p.maxObject)
				p.logger.Printf("refused oversized OFFER: %s", text)
				if err := p.writer.write(errorFrame("OBJECT_TOO_LARGE", true, text)); err != nil {
					return err
				}
				continue
			}
			if _, err := ins.destination(o); err != nil {
				text := fmt.Sprintf("invalid OFFER %s/%s: %v", o.Node, o.Basename, err)
				p.logger.Printf("%s", text)
				if err := p.writer.write(errorFrame("INVALID_OFFER", true, text)); err != nil {
					return err
				}
				continue
			}
			if o.Class == "stream" {
				expired, err := streamExpiredAt(o.Basename, p.retainDays, 1, time.Now())
				if err != nil {
					text := fmt.Sprintf("invalid stream epoch %s: %v", o.Basename, err)
					p.logger.Printf("%s", text)
					if err := p.writer.write(errorFrame("INVALID_OFFER", true, text)); err != nil {
						return err
					}
					continue
				}
				if expired {
					text := fmt.Sprintf("expired stream skipped without install or quarantine: %s", o.Basename)
					p.logger.Printf("%s", text)
					if err := p.writer.write(errorFrame("STREAM_EXPIRED", true, text)); err != nil {
						return err
					}
					continue
				}
			}
			_, equal, inspectErr := ins.inspect(o)
			if inspectErr == nil && equal {
				p.origins.add(offerKey(o), o.ID)
				if err := p.writer.write(idFrame(frameHave, o.ID)); err != nil {
					return err
				}
				if delay := durationEnv("KHALA_LINK_TEST_STORED_DELAY", 0); delay > 0 {
					time.Sleep(delay)
				}
				if err := p.writer.write(idFrame(frameStored, o.ID)); err != nil {
					return err
				}
				if err := p.touchFresh(); err != nil {
					p.logger.Printf("touch link.fresh after STORED failed: %v", err)
				}
				continue
			}
			if inspectErr != nil && !os.IsNotExist(inspectErr) {
				p.logger.Printf("destination inspection for %s: %v; requesting DATA for quarantine", o.Basename, inspectErr)
			}
			incoming = &o
			if err := p.writer.write(idFrame(frameNeed, o.ID)); err != nil {
				return err
			}
		case frameData:
			if incoming == nil {
				p.fatal("UNEXPECTED_DATA", "DATA arrived without an accepted OFFER")
				return errors.New("unexpected DATA")
			}
			id, data, err := decodeData(f)
			if err != nil || id != incoming.ID {
				p.fatal("BAD_DATA", "DATA transfer id does not match OFFER")
				return errors.New("bad DATA transfer id")
			}
			o := *incoming
			incoming = nil
			installing.Store(true)
			go p.installIncoming(ins, o, data, &installing)
		case frameHave, frameNeed, frameStored:
			if !p.activeOut.Load() {
				p.fatal("UNEXPECTED_RESPONSE", fmt.Sprintf("frame %d without outbound transfer", f.typ))
				return errors.New("unexpected transfer response")
			}
			select {
			case p.responses <- f:
			case <-ctx.Done():
				return ctx.Err()
			}
		case framePing:
			epoch, err := decodeEpoch(f)
			if err != nil {
				p.fatal("BAD_PING", err.Error())
				return err
			}
			if os.Getenv("KHALA_LINK_TEST_SUPPRESS_PONG") != "1" {
				if err := p.writer.write(epochFrame(framePong, epoch)); err != nil {
					return err
				}
				if err := p.touchFresh(); err != nil {
					p.logger.Printf("touch link.fresh after sent PONG failed: %v", err)
				}
			}
		case framePong:
			if _, err := decodeEpoch(f); err != nil {
				p.fatal("BAD_PONG", err.Error())
				return err
			}
			if err := p.touchFresh(); err != nil {
				p.logger.Printf("touch link.fresh after PONG failed: %v", err)
			}
		case frameError:
			pe, err := decodeError(f)
			if err != nil {
				p.fatal("BAD_ERROR", err.Error())
				return err
			}
			p.logger.Printf("remote ERROR %s recoverable=%t: %s", pe.Code, pe.Recoverable, pe.Text)
			if !pe.Recoverable {
				return fmt.Errorf("remote fatal ERROR %s: %s", pe.Code, pe.Text)
			}
			if p.activeOut.Load() {
				select {
				case p.responses <- f:
				case <-ctx.Done():
					return ctx.Err()
				}
			}
		case frameBye:
			if len(f.payload) != 0 {
				p.fatal("BAD_BYE", "BYE payload must be empty")
				return errors.New("bad BYE")
			}
			return io.EOF
		case frameHello:
			p.fatal("DUPLICATE_HELLO", "HELLO is only valid as the first frame")
			return errors.New("duplicate HELLO")
		default:
			p.fatal("UNKNOWN_FRAME", fmt.Sprintf("unknown frame type %d", f.typ))
			return fmt.Errorf("unknown frame type %d", f.typ)
		}
	}
}

// installIncoming keeps disk durability latency out of the sole protocol
// reader. The sender cannot start a second inbound object until this goroutine
// replies with STORED or ERROR, so the per-direction in-flight limit stays one.
func (p *pump) installIncoming(ins *installer, o offer, data []byte, active *atomic.Bool) {
	result, path, installErr := ins.receive(o, data)
	if result == expiredSkipped && installErr == nil {
		active.Store(false)
		text := fmt.Sprintf("expired stream skipped without install or quarantine: %s", o.Basename)
		if err := p.writer.write(errorFrame("STREAM_EXPIRED", true, text)); err != nil {
			p.reportAsyncError(err)
		}
		return
	}
	if installErr != nil || result == quarantined {
		text := fmt.Sprintf("%s/%s refused: %v", o.Node, o.Basename, installErr)
		p.logger.Printf("%s", text)
		active.Store(false)
		if err := p.writer.write(errorFrame("IMMUTABLE_CONFLICT", true, text)); err != nil {
			p.reportAsyncError(err)
		}
		return
	}
	p.origins.add(offerKey(o), o.ID)
	if delay := durationEnv("KHALA_LINK_TEST_STORED_DELAY", 0); delay > 0 {
		time.Sleep(delay)
	}
	active.Store(false)
	if err := p.writer.write(idFrame(frameStored, o.ID)); err != nil {
		p.reportAsyncError(err)
		return
	}
	if err := p.touchFresh(); err != nil {
		p.logger.Printf("touch link.fresh after STORED failed: %v", err)
	}
	p.logger.Printf("stored %s/%s at %s", o.Node, o.Basename, path)
	p.brain.trigger()
}

func (p *pump) reportAsyncError(err error) {
	select {
	case p.asyncErr <- err:
	default:
	}
}

func (p *pump) sendLoop(ctx context.Context, candidates <-chan candidate) error {
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case c := <-candidates:
			if err := p.sendCandidate(ctx, c); err != nil {
				return err
			}
		}
	}
}

func (p *pump) sendCandidate(ctx context.Context, c candidate) error {
	if c.class == "stream" && p.minor < streamMinor {
		return nil
	}
	if c.class == "stream" {
		expired, err := streamExpiredAt(c.basename, p.retainDays, 1, time.Now())
		if err != nil {
			p.logger.Printf("invalid stream epoch skipped: %s: %v", c.basename, err)
			return nil
		}
		if expired {
			if p.expiredOfferLogs == nil || p.expiredOfferLogs.first(c.key()) {
				p.logger.Printf("expired stream offer skipped: %s", c.basename)
			}
			return nil
		}
	}
	info, err := os.Lstat(c.path)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		p.logger.Printf("stat offer source %s failed: %v", c.path, err)
		return nil
	}
	if !info.Mode().IsRegular() || !validBasename(c.basename) {
		return nil
	}
	f, err := openRegular(c.path)
	if err != nil {
		p.logger.Printf("read offer source %s failed: %v", c.path, err)
		return nil
	}
	data, readErr := io.ReadAll(f)
	closeErr := f.Close()
	if readErr != nil {
		p.logger.Printf("read offer source %s failed: %v", c.path, readErr)
		return nil
	}
	if closeErr != nil {
		p.logger.Printf("close offer source %s failed: %v", c.path, closeErr)
		return nil
	}
	if int64(len(data)) > p.maxObject {
		text := fmt.Sprintf("%s is %d bytes; max-object-bytes is %d; rsync remains available", c.path, len(data), p.maxObject)
		p.logger.Printf("%s", text)
		if err := p.writer.write(errorFrame("OBJECT_TOO_LARGE", true, text)); err != nil {
			return err
		}
		return nil
	}
	digest := sha256.Sum256(data)
	id := transferID(c.class, c.stream, c.node, c.basename, digest)
	if p.origins.has(c.key(), id) {
		return nil
	}
	if p.isRejected(c.key(), id) {
		return nil
	}
	if p.isKnown(c.key(), id) {
		if p.role == "serve" && c.deleteAfterStored {
			if err := removeTransit(c.path, digest); err != nil && !os.IsNotExist(err) {
				p.logger.Printf("refused reappeared transit unlink %s: %v", c.path, err)
			} else {
				p.logger.Printf("removed reappeared C3-identical transit %s; peer already STORED it", c.path)
			}
		}
		return nil
	}
	o := offer{ID: id, Class: c.class, Stream: c.stream, Node: c.node, Basename: c.basename, Size: uint64(len(data)), Digest: digest}
	p.activeOut.Store(true)
	defer p.activeOut.Store(false)
	if err := p.writer.write(offerFrame(o)); err != nil {
		return err
	}
	first, err := p.waitResponse(ctx, id)
	if err != nil {
		return err
	}
	if first.typ == frameError {
		p.markRejected(c.key(), id)
		return nil
	}
	if first.typ == frameHave {
		p.logger.Printf("peer HAVE %s/%s; DATA skipped", c.node, c.basename)
	}
	if first.typ == frameNeed {
		if err := p.writer.write(dataFrame(id, data)); err != nil {
			return err
		}
	} else if first.typ != frameHave {
		return fmt.Errorf("unexpected first transfer response type %d", first.typ)
	}
	stored, err := p.waitResponse(ctx, id)
	if err != nil {
		return err
	}
	if stored.typ == frameError {
		p.markRejected(c.key(), id)
		return nil
	}
	if stored.typ != frameStored {
		return fmt.Errorf("expected STORED, got frame %d", stored.typ)
	}
	p.markKnown(c.key(), id)
	if err := p.touchFresh(); err != nil {
		p.logger.Printf("touch link.fresh after received STORED failed: %v", err)
	}
	if c.deleteAfterStored {
		if p.role != "serve" {
			return errors.New("internal ownership error: dial reached transit unlink")
		}
		if err := removeTransit(c.path, digest); err != nil && !os.IsNotExist(err) {
			p.logger.Printf("refused transit unlink %s after STORED: %v", c.path, err)
		} else {
			p.logger.Printf("removed hub transit %s after peer STORED (C1 depends on C3)", c.path)
		}
	}
	return nil
}

func (p *pump) waitResponse(ctx context.Context, id string) (frame, error) {
	for {
		select {
		case <-ctx.Done():
			return frame{}, ctx.Err()
		case f := <-p.responses:
			if f.typ == frameError {
				if _, err := decodeError(f); err != nil {
					return frame{}, err
				}
				return f, nil
			}
			got, err := decodeID(f)
			if err != nil {
				return frame{}, err
			}
			if got != id {
				return frame{}, fmt.Errorf("response transfer id %q does not match %q", got, id)
			}
			return f, nil
		}
	}
}

func (p *pump) keepalive(ctx context.Context) error {
	pingEvery := durationEnv("KHALA_LINK_TEST_PING_INTERVAL", 5*time.Second)
	quiet := 60 * time.Second
	if p.role == "dial" {
		quiet = 20 * time.Second
	}
	quiet = durationEnv("KHALA_LINK_TEST_QUIET_TIMEOUT", quiet)
	tick := time.NewTicker(time.Second)
	defer tick.Stop()
	var ping *time.Ticker
	var pingC <-chan time.Time
	if p.role == "dial" {
		ping = time.NewTicker(pingEvery)
		defer ping.Stop()
		pingC = ping.C
	}
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case now := <-pingC:
			if err := p.writer.write(epochFrame(framePing, uint64(now.Unix()))); err != nil {
				return err
			}
		case <-tick.C:
			last := time.Unix(0, p.lastInput.Load())
			if time.Since(last) > quiet {
				return fmt.Errorf("no inbound protocol frame for %s", quiet)
			}
		}
	}
}

func (p *pump) isKnown(key, id string) bool {
	p.knownMu.Lock()
	got, ok := p.known[key]
	p.knownMu.Unlock()
	return ok && got == id
}
func (p *pump) markKnown(key, id string) {
	p.knownMu.Lock()
	p.known[key] = id
	delete(p.rejected, key)
	p.knownMu.Unlock()
}

func (p *pump) isRejected(key, id string) bool {
	p.knownMu.Lock()
	got, ok := p.rejected[key]
	p.knownMu.Unlock()
	return ok && got == id
}

func (p *pump) markRejected(key, id string) {
	p.knownMu.Lock()
	p.rejected[key] = id
	p.knownMu.Unlock()
}

func offerKey(o offer) string {
	return o.Class + "\x00" + o.Stream + "\x00" + o.Node + "\x00" + o.Basename
}

func (p *pump) touchFresh() error {
	dir := filepath.Join(p.home, "run")
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	path := filepath.Join(dir, "link.fresh")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	now := time.Now()
	return os.Chtimes(path, now, now)
}

func durationEnv(name string, fallback time.Duration) time.Duration {
	if s := os.Getenv(name); s != "" {
		if d, err := time.ParseDuration(s); err == nil && d > 0 {
			return d
		}
	}
	return fallback
}
