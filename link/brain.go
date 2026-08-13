package main

import (
	"context"
	"log"
	"os"
	"os/exec"
	"syscall"
)

type brain struct {
	path   string
	home   string
	logger *log.Logger
	dirty  chan struct{}
}

func newBrain(path, home string, logger *log.Logger) *brain {
	return &brain{path: path, home: home, logger: logger, dirty: make(chan struct{}, 1)}
}

func (b *brain) trigger() {
	select {
	case b.dirty <- struct{}{}:
	default:
	}
}

func (b *brain) run(ctx context.Context) {
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
		}
		for {
			// Once a reconcile pass owns the bash brain lock, let that pass finish.
			// Killing it on link shutdown would strand brain.lock.d until the bash
			// stale timeout, blocking the store-and-forward path we must preserve.
			cmd := exec.Command(b.path, "reconcile")
			cmd.Env = replaceEnv(os.Environ(), map[string]string{"KHALA_HOME": b.home})
			cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
			cmd.Stdout = b.logger.Writer()
			cmd.Stderr = b.logger.Writer()
			if err := cmd.Run(); err != nil && ctx.Err() == nil {
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
