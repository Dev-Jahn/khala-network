package main

import (
	"bytes"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

type installer struct {
	home           string
	role           string
	peer           string
	logger         loggerLike
	linkInstallLog sync.Once
}

type loggerLike interface{ Printf(string, ...any) }

type installResult int

const (
	installed installResult = iota
	alreadyStored
	quarantined
)

func (i *installer) destination(o offer) (string, error) {
	if !validNode(o.Node) || !validBasename(o.Basename) {
		return "", fmt.Errorf("invalid node or basename")
	}
	switch o.Class {
	case "spool":
		if i.role == "dial" && o.Node != i.peer {
			return "", fmt.Errorf("dial accepts spool only for self %q, got %q", i.peer, o.Node)
		}
		if i.role == "serve" && o.Node == i.peer {
			return "", fmt.Errorf("serve refuses reflected spool for connected spoke %q", i.peer)
		}
		return filepath.Join(i.home, "spool", "for", o.Node, o.Basename), nil
	case "presence":
		node, ok := presenceNode(o.Basename)
		if !ok || node != o.Node {
			return "", fmt.Errorf("presence basename owner does not match node")
		}
		if i.role == "serve" && node != i.peer {
			return "", fmt.Errorf("serve accepts presence only from connected spoke %q", i.peer)
		}
		return filepath.Join(i.home, "presence", o.Basename), nil
	case "stream":
		if !validNode(o.Stream) || !validMessageID(o.Basename) {
			return "", fmt.Errorf("invalid stream or Id")
		}
		if i.role == "dial" && o.Node == i.peer {
			return "", fmt.Errorf("dial refuses reflected stream shard for self %q", i.peer)
		}
		if i.role == "serve" && o.Node != i.peer {
			return "", fmt.Errorf("serve accepts stream only from connected spoke %q", i.peer)
		}
		return filepath.Join(i.home, "streams", o.Stream, o.Node, o.Basename), nil
	default:
		return "", fmt.Errorf("unknown object class %q", o.Class)
	}
}

func digestFile(path string) ([sha256.Size]byte, error) {
	var zero [sha256.Size]byte
	f, err := openRegular(path)
	if err != nil {
		return zero, err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return zero, err
	}
	copy(zero[:], h.Sum(nil))
	return zero, nil
}

func openRegular(path string) (*os.File, error) {
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_CLOEXEC|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, err
	}
	f := os.NewFile(uintptr(fd), path)
	if f == nil {
		_ = syscall.Close(fd)
		return nil, fmt.Errorf("open regular file %s", path)
	}
	info, err := f.Stat()
	if err != nil {
		_ = f.Close()
		return nil, err
	}
	if !info.Mode().IsRegular() {
		_ = f.Close()
		return nil, fmt.Errorf("not a regular file")
	}
	return f, nil
}

func sameDigest(path string, want [sha256.Size]byte) (bool, error) {
	got, err := digestFile(path)
	if err != nil {
		return false, err
	}
	return bytes.Equal(got[:], want[:]), nil
}

func (i *installer) inspect(o offer) (string, bool, error) {
	dest, err := i.destination(o)
	if err != nil {
		return "", false, err
	}
	_, err = os.Lstat(dest)
	if os.IsNotExist(err) {
		return dest, false, nil
	}
	if err != nil {
		return "", false, err
	}
	equal, err := sameDigest(dest, o.Digest)
	return dest, equal, err
}

func (i *installer) receive(o offer, data []byte) (installResult, string, error) {
	if uint64(len(data)) != o.Size {
		return quarantined, "", fmt.Errorf("DATA size %d does not match OFFER size %d", len(data), o.Size)
	}
	digest := sha256.Sum256(data)
	if !bytes.Equal(digest[:], o.Digest[:]) {
		return quarantined, "", fmt.Errorf("DATA sha256 does not match OFFER")
	}
	if err := os.MkdirAll(filepath.Join(i.home, "tmp"), 0700); err != nil {
		return quarantined, "", err
	}
	tmp := filepath.Join(i.home, "tmp", fmt.Sprintf("link.%s.%d", o.ID, os.Getpid()))
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if os.IsExist(err) {
		stale := fmt.Sprintf("%s.stale.%d", tmp, time.Now().UnixNano())
		if renameErr := os.Rename(tmp, stale); renameErr != nil {
			return quarantined, tmp, fmt.Errorf("move stale transfer tmp: %w", renameErr)
		}
		i.logger.Printf("moved stale transfer tmp aside for whole-object retry: %s", stale)
		f, err = os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	}
	if err != nil {
		return quarantined, "", fmt.Errorf("create transfer tmp: %w", err)
	}
	writeOK := false
	defer func() {
		if !writeOK {
			_ = f.Close()
		}
	}()
	if err := writeFull(f, data); err != nil {
		return quarantined, tmp, fmt.Errorf("write transfer tmp: %w", err)
	}
	if err := f.Sync(); err != nil {
		return quarantined, tmp, fmt.Errorf("fsync transfer tmp: %w", err)
	}
	if err := f.Close(); err != nil {
		return quarantined, tmp, fmt.Errorf("close transfer tmp: %w", err)
	}
	writeOK = true
	if delay := durationEnv("KHALA_LINK_TEST_DATA_INSTALL_DELAY", 0); delay > 0 {
		time.Sleep(delay)
	}

	dest, err := i.destination(o)
	if err != nil {
		return quarantined, tmp, err
	}
	if o.Class == "stream" {
		epoch, epochErr := streamEpoch(o.Basename)
		if epochErr != nil || epoch > uint64(time.Now().Unix()+86400) {
			quarantine, quarantineErr := i.quarantineFutureStream(tmp, o)
			if quarantineErr != nil {
				return quarantined, tmp, quarantineErr
			}
			i.logger.Printf("future stream epoch refused and quarantined at %s", quarantine)
			return quarantined, quarantine, fmt.Errorf("stream Id epoch exceeds now+86400")
		}
	}
	if err := os.MkdirAll(filepath.Dir(dest), 0700); err != nil {
		return quarantined, tmp, err
	}

	// # AMBIGUOUS: the generic wire rule says same-path/different-digest
	// never overwrites, but D12 presence files are mutable epoch leases and
	// acceptance property 4 requires their continuing fan-out. C3's
	// Id=>bytes invariant applies to spool Id objects; presence has no Id.
	// Replace only presence atomically, without interpreting its contents.
	if o.Class == "presence" {
		if err := os.Rename(tmp, dest); err != nil {
			return quarantined, tmp, err
		}
		if err := syncDir(filepath.Dir(dest)); err != nil {
			return quarantined, dest, err
		}
		return installed, dest, nil
	}

	installErr := renameNoReplace(tmp, dest)
	linkedInstall := false
	if unsupportedNoReplace(installErr) {
		i.linkInstallLog.Do(func() {
			i.logger.Printf("filesystem refused atomic no-replace rename (%v); using atomic link create-if-absent", installErr)
		})
		installErr = os.Link(tmp, dest)
		linkedInstall = installErr == nil
	}
	if installErr == nil {
		if err := syncDir(filepath.Dir(dest)); err != nil {
			return quarantined, dest, fmt.Errorf("fsync install directory: %w", err)
		}
		if linkedInstall {
			// link(2) leaves the staging name. Move it onto one shared
			// committed slot so dial never calls unlink and tmp stays bounded,
			// including across process restarts and concurrent serve processes.
			committed := filepath.Join(i.home, "tmp", "link.committed")
			if err := os.Rename(tmp, committed); err != nil {
				i.logger.Printf("installed %s durably but could not compact staging link %s: %v", dest, tmp, err)
			}
		}
		return installed, dest, nil
	} else if os.IsExist(installErr) {
		equal, digestErr := sameDigest(dest, o.Digest)
		if digestErr == nil && equal {
			// Dial is literally unlink-free. Compact the redundant staging name
			// into the same bounded committed slot instead of deleting it.
			committed := filepath.Join(i.home, "tmp", "link.committed")
			if err := os.Rename(tmp, committed); err != nil {
				return quarantined, tmp, err
			}
			return alreadyStored, committed, nil
		}
		if digestErr != nil {
			quarantine, qerr := i.quarantine(tmp, o)
			if qerr != nil {
				return quarantined, tmp, qerr
			}
			return quarantined, quarantine, fmt.Errorf("existing destination cannot satisfy C3 (%v); incoming object quarantined at %s", digestErr, quarantine)
		}
		quarantine, qerr := i.quarantine(tmp, o)
		if qerr != nil {
			return quarantined, tmp, qerr
		}
		return quarantined, quarantine, fmt.Errorf("same path has a different digest; incoming object quarantined at %s", quarantine)
	} else {
		return quarantined, tmp, fmt.Errorf("atomic no-clobber install: %w", installErr)
	}
}

func unsupportedNoReplace(err error) bool {
	return errors.Is(err, syscall.EINVAL) || errors.Is(err, syscall.ENOSYS) || errors.Is(err, syscall.EOPNOTSUPP)
}

func (i *installer) quarantine(tmp string, o offer) (string, error) {
	dir := filepath.Join(i.home, "spool", "quarantine")
	if err := os.MkdirAll(dir, 0700); err != nil {
		return "", err
	}
	if err := os.Chmod(dir, 0700); err != nil {
		return "", err
	}
	dest := filepath.Join(dir, fmt.Sprintf("%s.%s.%d", o.Basename, o.ID, os.Getpid()))
	if err := os.Rename(tmp, dest); err != nil {
		return "", err
	}
	if err := syncDir(dir); err != nil {
		return "", err
	}
	return dest, nil
}

func streamEpoch(id string) (uint64, error) {
	epoch, _, ok := strings.Cut(id, ".")
	if !ok {
		return 0, fmt.Errorf("stream Id has no epoch")
	}
	return strconv.ParseUint(epoch, 10, 64)
}

func (i *installer) quarantineFutureStream(tmp string, o offer) (string, error) {
	dir := filepath.Join(i.home, "spool", "dead")
	if err := os.MkdirAll(dir, 0700); err != nil {
		return "", err
	}
	if err := os.Chmod(dir, 0700); err != nil {
		return "", err
	}
	dest := filepath.Join(dir, "stream."+o.Stream+"."+o.Node+"."+o.Basename)
	installErr := renameNoReplace(tmp, dest)
	linkedInstall := false
	if unsupportedNoReplace(installErr) {
		installErr = os.Link(tmp, dest)
		linkedInstall = installErr == nil
	}
	if installErr == nil {
		if err := syncDir(dir); err != nil {
			return "", err
		}
		if linkedInstall {
			committed := filepath.Join(i.home, "tmp", "link.committed")
			if err := os.Rename(tmp, committed); err != nil {
				i.logger.Printf("quarantined %s durably but could not compact staging link %s: %v", dest, tmp, err)
			}
		}
		return dest, nil
	}
	if !os.IsExist(installErr) {
		return "", fmt.Errorf("atomic future-stream quarantine: %w", installErr)
	}
	equal, digestErr := sameDigest(dest, o.Digest)
	if digestErr == nil && equal {
		committed := filepath.Join(i.home, "tmp", "link.committed")
		if err := os.Rename(tmp, committed); err != nil {
			return "", err
		}
		return dest, nil
	}
	if digestErr != nil {
		return "", digestErr
	}
	conflict := fmt.Sprintf("%s.%d.conflict", dest, os.Getpid())
	if err := os.Rename(tmp, conflict); err != nil {
		return "", err
	}
	if err := syncDir(dir); err != nil {
		return "", err
	}
	return conflict, nil
}

func syncDir(path string) error {
	d, err := os.Open(path)
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}

func recoverStaleTemps(home string, logger loggerLike) error {
	// # AMBIGUOUS: the brief requires TTL cleanup on next start but does not
	// set the TTL. Keep a 24h forensic window, then move (never unlink) stale
	// whole-object debris out of tmp into quarantine.
	ttl := durationEnv("KHALA_LINK_TEST_TMP_TTL", 24*time.Hour)
	tmpDir := filepath.Join(home, "tmp")
	entries, err := os.ReadDir(tmpDir)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	now := time.Now()
	var quarantineDir string
	moved := false
	for _, entry := range entries {
		if !entry.Type().IsRegular() || !strings.HasPrefix(entry.Name(), "link.") {
			continue
		}
		// The no-replace fallback deliberately retains one bounded hardlink
		// after a completed install. It is neither interrupted nor stale.
		if entry.Name() == "link.committed" {
			continue
		}
		info, err := entry.Info()
		if err != nil || now.Sub(info.ModTime()) <= ttl {
			continue
		}
		if quarantineDir == "" {
			quarantineDir = filepath.Join(home, "spool", "quarantine")
			if err := os.MkdirAll(quarantineDir, 0700); err != nil {
				return err
			}
			if err := os.Chmod(quarantineDir, 0700); err != nil {
				return err
			}
		}
		source := filepath.Join(tmpDir, entry.Name())
		dest := filepath.Join(quarantineDir, fmt.Sprintf("recovered-tmp.%s.%d", entry.Name(), os.Getpid()))
		if err := os.Rename(source, dest); err != nil {
			if os.IsNotExist(err) {
				continue
			}
			return err
		}
		logger.Printf("moved stale interrupted transfer from tmp to quarantine: %s", dest)
		moved = true
	}
	if !moved {
		return nil
	}
	if err := syncDir(tmpDir); err != nil {
		return err
	}
	return syncDir(quarantineDir)
}

// removeTransit is the only unlink call in the program. Its caller proves role
// serve and invokes it only after the destination spoke's STORED frame.
func removeTransit(path string, offered [sha256.Size]byte) error {
	current, err := digestFile(path)
	if err != nil {
		return err
	}
	if !bytes.Equal(current[:], offered[:]) {
		return fmt.Errorf("transit changed after OFFER; refusing unlink")
	}
	return os.Remove(path)
}
