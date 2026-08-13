package main

import (
	"bufio"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"sync"
)

const maxLogBytes = int64(1 << 20)

type rotatingLog struct {
	path string
	mu   sync.Mutex
}

func newLogger(home string) (*log.Logger, error) {
	dir := filepath.Join(home, "log")
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	return log.New(&rotatingLog{path: filepath.Join(dir, "link.log")}, "khala-link: ", log.LstdFlags|log.Lmicroseconds), nil
}

func (r *rotatingLog) Write(p []byte) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	flags := os.O_CREATE | os.O_WRONLY | os.O_APPEND
	if info, err := os.Stat(r.path); err == nil && info.Size()+int64(len(p)) > maxLogBytes {
		flags = os.O_CREATE | os.O_WRONLY | os.O_TRUNC
	}
	f, err := os.OpenFile(r.path, flags, 0600)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	if flags&os.O_TRUNC != 0 {
		if _, err := io.WriteString(f, "khala-link: log rotated at 1 MiB\n"); err != nil {
			return 0, err
		}
	}
	n, err := f.Write(p)
	return n, err
}

func logStderr(logger *log.Logger, r io.Reader) {
	scanner := bufio.NewScanner(r)
	for scanner.Scan() {
		logger.Printf("carrier stderr: %s", scanner.Text())
	}
	if err := scanner.Err(); err != nil {
		logger.Printf("carrier stderr read failed: %v", err)
	}
}

func fatalf(format string, args ...any) int {
	fmt.Fprintf(os.Stderr, "khala-link: "+format+"\n", args...)
	return 1
}
