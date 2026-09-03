package main

import (
	"bufio"
	"context"
	crand "crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

var implVersion = "0.5.0"

const linkVersion = "0.9.2"

type options struct {
	serve     bool
	servePeer string
	restart   bool
	maxBytes  int64
	scan      time.Duration
}

func main() { os.Exit(run(os.Args[1:])) }

func run(args []string) int {
	if len(args) > 0 {
		switch args[0] {
		case "conduit":
			return runConduit(args[1:])
		case "runtime":
			return runRuntime(args[1:])
		case "dashboard":
			return runDashboard(args[1:])
		case "version":
			if len(args) != 1 {
				return fatalf("version takes no arguments")
			}
			fmt.Fprintln(os.Stdout, linkVersion)
			return 0
		}
	}
	opts, err := parseOptions(args)
	if err != nil {
		return fatalf("%v", err)
	}
	brainPath := os.Getenv("KHALA_BRAIN")
	if brainPath == "" {
		return fatalf("KHALA_BRAIN is missing or empty; launch through the khala link wrapper")
	}
	if !filepath.IsAbs(brainPath) {
		return fatalf("KHALA_BRAIN must be the wrapper's absolute path, got %q", brainPath)
	}
	home, err := khalaHome()
	if err != nil {
		return fatalf("%v", err)
	}
	cfg, err := loadConfig(home)
	if err != nil {
		return fatalf("%v", err)
	}
	logger, err := newLogger(home)
	if err != nil {
		return fatalf("open log/link.log: %v", err)
	}
	if network, kind, statErr := networkFilesystem(home); statErr != nil {
		logger.Printf("WARN statfs %s failed: %v", home, statErr)
		fmt.Fprintf(os.Stderr, "khala-link: WARN statfs %s failed: %v\n", home, statErr)
	} else if network {
		logger.Printf("WARN KHALA_HOME %s is on %s; fsnotify may not observe remote-client changes", home, kind)
		fmt.Fprintf(os.Stderr, "khala-link: WARN KHALA_HOME %s is on %s; continuing with periodic scans\n", home, kind)
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	if opts.serve {
		guard, acquired, err := acquireServeSingleton(home, opts.servePeer)
		if err != nil {
			return fatalf("serve guard for %s: %v", opts.servePeer, err)
		}
		if !acquired {
			fmt.Fprintf(os.Stdout, "khala-link: serve for %s already running\n", opts.servePeer)
			return 0
		}
		defer guard.Close()
		if err := recoverStaleTemps(home, logger); err != nil {
			return fatalf("recover stale link tmp files: %v", err)
		}
		rw := readWriter{Reader: os.Stdin, Writer: os.Stdout}
		_, err = runPump(ctx, rw, home, "serve", cfg.self, opts.servePeer, brainPath, nil, opts.maxBytes, cfg.retainDays, opts.scan, newLogOnceSet(), logger)
		if err != nil && !errors.Is(err, context.Canceled) && !errors.Is(err, io.EOF) {
			logger.Printf("serve stopped: %v", err)
			return fatalf("serve stopped: %v", err)
		}
		return 0
	}
	lock, acquired, err := acquireSingleton(home)
	if err != nil {
		return fatalf("link singleton: %v", err)
	}
	if !acquired && !opts.restart {
		fmt.Fprintln(os.Stdout, "khala-link: dial already running")
		return 0
	}
	if !acquired {
		if err := terminatePrior(home, logger); err != nil {
			return fatalf("restart: %v", err)
		}
		lock, err = waitSingleton(ctx, home, 10*time.Second)
		if err != nil {
			return fatalf("restart: %v", err)
		}
	}
	defer lock.Close()
	if err := writeStatus(home); err != nil {
		return fatalf("write run/link.status: %v", err)
	}
	if err := recoverStaleTemps(home, logger); err != nil {
		return fatalf("recover stale link tmp files: %v", err)
	}
	endpoints, err := cfg.dialEndpoints()
	if testHome := os.Getenv("KHALA_LINK_TEST_SERVE_HOME"); testHome != "" {
		if !filepath.IsAbs(testHome) {
			return fatalf("KHALA_LINK_TEST_SERVE_HOME must be absolute")
		}
		peer := os.Getenv("KHALA_LINK_TEST_SERVE_NODE")
		if !validNode(peer) {
			return fatalf("KHALA_LINK_TEST_SERVE_NODE is missing or invalid")
		}
		endpoints = []dialEndpoint{{node: peer, address: "direct-test-carrier"}}
		err = nil
	}
	localOnly := errors.Is(err, errNoDialEndpoints)
	if err != nil && !localOnly {
		return fatalf("%v", err)
	}
	nodeBrain := newBrain(brainPath, home, logger, true)
	nodeBrainDone := make(chan struct{})
	go func() {
		nodeBrain.run(ctx)
		close(nodeBrainDone)
	}()
	if localOnly {
		nodeBrain.trigger()
	}
	periodicDone := make(chan struct{})
	if localOnly {
		go func() {
			defer close(periodicDone)
			ticker := time.NewTicker(opts.scan)
			defer ticker.Stop()
			for {
				select {
				case <-ctx.Done():
					return
				case <-ticker.C:
					nodeBrain.trigger()
				}
			}
		}()
	} else {
		close(periodicDone)
	}
	defer func() {
		stop()
		<-periodicDone
		select {
		case <-nodeBrainDone:
		case <-time.After(10 * time.Second):
			logger.Printf("node reconcile still running after link shutdown; leaving it to release brain.lock.d")
		}
	}()
	if localOnly {
		logger.Printf("no remote dial endpoint; running node reconcile singleton only")
		<-ctx.Done()
		return 0
	}
	if err := dialForever(ctx, home, cfg.self, brainPath, nodeBrain, cfg.retainDays, opts, endpoints, logger); err != nil && !errors.Is(err, context.Canceled) {
		return fatalf("dial stopped: %v", err)
	}
	return 0
}

func parseOptions(args []string) (options, error) {
	o := options{maxBytes: 1 << 20, scan: 30 * time.Second}
	for len(args) > 0 {
		switch args[0] {
		case "--serve":
			o.serve = true
			args = args[1:]
		case "--peer":
			if len(args) < 2 || !validNode(args[1]) {
				return o, errors.New("--peer needs a valid node name")
			}
			o.servePeer = args[1]
			args = args[2:]
		case "restart":
			o.restart = true
			args = args[1:]
		case "--max-object-bytes":
			if len(args) < 2 {
				return o, errors.New("--max-object-bytes needs a value")
			}
			n, err := strconv.ParseInt(args[1], 10, 64)
			if err != nil || n <= 0 || n > int64(^uint32(0))-4096 {
				return o, errors.New("--max-object-bytes must be a positive integer that fits one protocol frame")
			}
			o.maxBytes = n
			args = args[2:]
		default:
			return o, fmt.Errorf("unknown argument %q", args[0])
		}
	}
	if o.serve && o.restart {
		return o, errors.New("--serve and restart are mutually exclusive")
	}
	if o.serve && o.servePeer == "" {
		return o, errors.New("--serve requires --peer <node>")
	}
	if !o.serve && o.servePeer != "" {
		return o, errors.New("--peer is valid only with --serve")
	}
	o.scan = durationEnv("KHALA_LINK_TEST_SCAN_INTERVAL", o.scan)
	return o, nil
}

func khalaHome() (string, error) {
	if value, set := os.LookupEnv("KHALA_HOME"); set {
		if value == "" {
			return "", errors.New("KHALA_HOME is empty")
		}
		return filepath.Abs(value)
	}
	home := os.Getenv("HOME")
	if home == "" {
		return "", errors.New("HOME is not set")
	}
	return filepath.Join(home, ".khala"), nil
}

func acquireSingleton(home string) (*os.File, bool, error) {
	runDir := filepath.Join(home, "run")
	if err := os.MkdirAll(runDir, 0700); err != nil {
		return nil, false, err
	}
	f, err := os.OpenFile(filepath.Join(runDir, "link.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, false, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, false, nil
		}
		return nil, false, err
	}
	return f, true, nil
}

func acquireServeSingleton(home, peer string) (*os.File, bool, error) {
	if !validNode(peer) {
		return nil, false, errors.New("invalid peer")
	}
	runDir := filepath.Join(home, "run")
	if err := os.MkdirAll(runDir, 0700); err != nil {
		return nil, false, err
	}
	f, err := os.OpenFile(filepath.Join(runDir, "serve."+peer+".lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, false, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, false, nil
		}
		return nil, false, err
	}
	if err := f.Truncate(0); err != nil {
		f.Close()
		return nil, false, err
	}
	if _, err := fmt.Fprintf(f, "pid %d\npeer %s\n", os.Getpid(), peer); err != nil {
		f.Close()
		return nil, false, err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return nil, false, err
	}
	return f, true, nil
}

func waitSingleton(ctx context.Context, home string, limit time.Duration) (*os.File, error) {
	deadline := time.Now().Add(limit)
	for time.Now().Before(deadline) {
		f, ok, err := acquireSingleton(home)
		if err != nil {
			return nil, err
		}
		if ok {
			return f, nil
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(100 * time.Millisecond):
		}
	}
	return nil, errors.New("prior dial did not release run/link.lock within 10s")
}

func writeStatus(home string) error {
	path := filepath.Join(home, "run", "link.status")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0600)
	if err != nil {
		return err
	}
	_, writeErr := fmt.Fprintf(f, "pid %d\nepoch %d\n", os.Getpid(), time.Now().Unix())
	closeErr := f.Close()
	if writeErr != nil {
		return writeErr
	}
	return closeErr
}

func terminatePrior(home string, logger *log.Logger) error {
	f, err := os.Open(filepath.Join(home, "run", "link.status"))
	if err != nil {
		return fmt.Errorf("read link.status for lock holder: %w", err)
	}
	defer f.Close()
	s := bufio.NewScanner(f)
	pid := 0
	for s.Scan() {
		fields := strings.Fields(s.Text())
		if len(fields) == 2 && fields[0] == "pid" {
			pid, _ = strconv.Atoi(fields[1])
		}
	}
	if err := s.Err(); err != nil {
		return err
	}
	if pid <= 1 || pid == os.Getpid() {
		return fmt.Errorf("link.status has invalid prior pid %d", pid)
	}
	logger.Printf("restart sending TERM to prior khala-link pid %d", pid)
	return syscall.Kill(pid, syscall.SIGTERM)
}

func dialForever(ctx context.Context, home, self, brainPath string, nodeBrain *brain, retainDays uint64, opts options, endpoints []dialEndpoint, logger *log.Logger) error {
	attempt := 0
	index := 0
	expiredOfferLogs := newLogOnceSet()
	for {
		endpoint := endpoints[index%len(endpoints)]
		index++
		started := time.Now()
		err := runCarrier(ctx, home, self, brainPath, nodeBrain, retainDays, opts, endpoint, expiredOfferLogs, logger)
		if ctx.Err() != nil {
			return ctx.Err()
		}
		logger.Printf("carrier %s (%s) ended: %v", endpoint.address, endpoint.node, err)
		if time.Since(started) > 30*time.Second {
			attempt = 0
		} else if attempt < 7 {
			attempt++
		}
		delay, err := jitterDelay(attempt)
		if err != nil {
			return fmt.Errorf("full-jitter random source failed: %w", err)
		}
		logger.Printf("reconnect attempt=%d delay=%s endpoint=%s", attempt, delay, endpoint.address)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(delay):
		}
	}
}

func runCarrier(ctx context.Context, home, self, brainPath string, nodeBrain *brain, retainDays uint64, opts options, endpoint dialEndpoint, expiredOfferLogs *logOnceSet, logger *log.Logger) error {
	cmd, err := carrierCommand(brainPath, opts, endpoint, self)
	if err != nil {
		return err
	}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return err
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		return err
	}
	stderrDone := make(chan struct{})
	go func() { logStderr(logger, stderr); close(stderrDone) }()
	rw := readWriter{Reader: stdout, Writer: stdin}
	_, pumpErr := runPump(ctx, rw, home, "dial", self, endpoint.node, brainPath, nodeBrain, opts.maxBytes, retainDays, opts.scan, expiredOfferLogs, logger)
	// Carrier cleanup is deliberately process-group scoped. It never signals a
	// user session; only the child carrier started immediately above.
	_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
	_ = stdin.Close()
	waited := make(chan error, 1)
	go func() { waited <- cmd.Wait() }()
	var waitErr error
	select {
	case waitErr = <-waited:
	case <-time.After(2 * time.Second):
		logger.Printf("carrier process group %d ignored TERM for 2s; sending KILL", cmd.Process.Pid)
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		waitErr = <-waited
	}
	<-stderrDone
	if pumpErr != nil {
		return pumpErr
	}
	return waitErr
}

func carrierCommand(brainPath string, opts options, endpoint dialEndpoint, self string) (*exec.Cmd, error) {
	if endpoint.address == "direct-test-carrier" {
		exe, err := os.Executable()
		if err != nil {
			return nil, err
		}
		args := []string{"--serve", "--peer", self, "--max-object-bytes", strconv.FormatInt(opts.maxBytes, 10)}
		cmd := exec.Command(exe, args...)
		serveHome := os.Getenv("KHALA_LINK_TEST_SERVE_HOME")
		cmd.Env = replaceEnv(os.Environ(), map[string]string{"KHALA_HOME": serveHome, "KHALA_BRAIN": brainPath})
		return cmd, nil
	}
	cmd := exec.Command("ssh", "-T", "-o", "BatchMode=yes", endpoint.address,
		"exec ~/.local/bin/khala link --serve --peer "+self)
	return cmd, nil
}

func replaceEnv(env []string, values map[string]string) []string {
	out := make([]string, 0, len(env)+len(values))
	for _, item := range env {
		key := item
		if i := strings.IndexByte(item, '='); i >= 0 {
			key = item[:i]
		}
		if _, replace := values[key]; !replace {
			out = append(out, item)
		}
	}
	for key, value := range values {
		out = append(out, key+"="+value)
	}
	return out
}

func jitterDelay(attempt int) (time.Duration, error) {
	if attempt < 1 {
		attempt = 1
	}
	capDelay := time.Second << (attempt - 1)
	if capDelay > 60*time.Second {
		capDelay = 60 * time.Second
	}
	var b [8]byte
	if _, err := crand.Read(b[:]); err != nil {
		return 0, err
	}
	n := binary.BigEndian.Uint64(b[:])
	return time.Duration(n % uint64(capDelay+1)), nil
}
