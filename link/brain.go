package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"syscall"
	"time"
)

type brain struct {
	path   string
	home   string
	logger *log.Logger
	dirty  chan struct{}
	mu     sync.Mutex
	remote bool
}

func newBrain(path, home string, logger *log.Logger, ownerValue ...bool) *brain {
	owner := true
	if len(ownerValue) > 0 {
		owner = ownerValue[0]
	}
	return &brain{path: path, home: home, logger: logger, dirty: make(chan struct{}, 1), remote: !owner}
}

func (b *brain) trigger() {
	if b.remote {
		if err := b.writeTrigger(); err != nil {
			b.logger.Printf("write dial reconcile trigger failed: %v", err)
		}
		return
	}
	select {
	case b.dirty <- struct{}{}:
	default:
	}
}

func (b *brain) ownsReconcile() bool { return !b.remote }

func (b *brain) writeTrigger() error {
	tmpDir := filepath.Join(b.home, "tmp")
	if err := os.MkdirAll(tmpDir, 0700); err != nil {
		return err
	}
	runDir := filepath.Join(b.home, "run")
	if err := os.MkdirAll(runDir, 0700); err != nil {
		return err
	}
	f, err := os.CreateTemp(tmpDir, "link-trigger.")
	if err != nil {
		return err
	}
	tmp := f.Name()
	ok := false
	defer func() {
		_ = f.Close()
		if !ok {
			_ = os.Remove(tmp)
		}
	}()
	if _, err := fmt.Fprintf(f, "%d\n", time.Now().UnixNano()); err != nil {
		return err
	}
	if err := f.Sync(); err != nil {
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp, filepath.Join(runDir, "reconcile.trigger")); err != nil {
		return err
	}
	ok = true
	return nil
}

func (b *brain) reconcile(scanGate bool) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	cmd := exec.Command(b.path, "reconcile")
	scanGateValue := ""
	if scanGate {
		scanGateValue = "1"
	}
	cmd.Env = replaceEnv(os.Environ(), map[string]string{
		"KHALA_HOME": b.home, "KHALA_LINK_SCAN_GATE": scanGateValue,
	})
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Stdout = b.logger.Writer()
	cmd.Stderr = b.logger.Writer()
	return cmd.Run()
}

func (b *brain) run(ctx context.Context) {
	if b.remote {
		return
	}
	ticker := time.NewTicker(200 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}
		select {
		case <-ctx.Done():
			return
		case <-b.dirty:
		case <-ticker.C:
			trigger := filepath.Join(b.home, "run", "reconcile.trigger")
			if err := os.Remove(trigger); err != nil {
				if os.IsNotExist(err) {
					continue
				}
				b.logger.Printf("consume reconcile trigger failed: %v", err)
				continue
			}
		}
		for {
			// Once a reconcile pass owns the bash brain lock, let that pass finish.
			// Killing it on link shutdown would strand brain.lock.d until the bash
			// stale timeout, blocking the store-and-forward path we must preserve.
			if err := b.reconcile(false); err != nil && ctx.Err() == nil {
				b.logger.Printf("brain reconcile failed: %v", err)
			}
			if ctx.Err() != nil {
				return
			}
			select {
			case <-b.dirty:
				continue
			default:
			}
			break
		}
	}
}
