package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

type sessionRegistration struct {
	BootID             string `json:"bootId"`
	InstanceID         string `json:"instanceId"`
	Identity           string `json:"identity"`
	PID                int    `json:"pid"`
	PIDStart           string `json:"pidStart"`
	ClaudeSessionID    string `json:"claudeSessionId"`
	SocketPath         string `json:"socketPath,omitempty"`
	ChannelSocket      string `json:"channelSocket,omitempty"`
	ChannelPID         int    `json:"channelPID,omitempty"`
	ChannelPIDStart    string `json:"channelPIDStart,omitempty"`
	ChannelVerified    bool   `json:"channelVerified,omitempty"`
	Kind               string `json:"kind"`
	ReceiveOptIn       bool   `json:"receiveOptIn"`
	Phase              string `json:"phase"`
	CCVersion          string `json:"ccVersion"`
	StartedAt          string `json:"startedAt"`
	LeaseEpoch         uint64 `json:"leaseEpoch"`
	ConduitVerified    bool   `json:"conduitVerified"`
	VerifiedAt         string `json:"verifiedAt,omitempty"`
	NativeStatus       string `json:"nativeStatus,omitempty"`
	NativeFailureCount int    `json:"nativeFailureCount,omitempty"`
	NativeWarningShown bool   `json:"nativeWarningShown,omitempty"`
}

type identityLease struct {
	BootID          string `json:"bootId"`
	Identity        string `json:"identity"`
	InstanceID      string `json:"instanceId"`
	Epoch           uint64 `json:"epoch"`
	PID             int    `json:"pid"`
	PIDStart        string `json:"pidStart"`
	ClaudeSessionID string `json:"claudeSessionId"`
	ClaimedAt       string `json:"claimedAt"`
	State           string `json:"state"`
}

type conduitStatus struct {
	BootID    string `json:"bootId"`
	PID       int    `json:"pid"`
	PIDStart  string `json:"pidStart"`
	Runtime   string `json:"runtime"`
	Adapter   string `json:"adapter"`
	StartedAt string `json:"startedAt"`
}

type claudeRegistry struct {
	PID       int
	SessionID string
	Name      string
	Version   string
	Socket    string
	Cwd       string
}

func runRuntime(args []string) int {
	if len(args) == 0 {
		return runtimeFatalf("missing runtime command")
	}
	var err error
	switch args[0] {
	case "register":
		err = runtimeRegister(args[1:], false)
	case "bind":
		err = runtimeRegister(args[1:], true)
	case "release":
		err = runtimeRelease(args[1:])
	case "status":
		err = runtimeStatus(args[1:])
	case "root":
		err = runtimePrintRoot(args[1:])
	case "whoami":
		err = runtimeWhoami(args[1:])
	case "session":
		err = runtimeSession(args[1:])
	case "register-channel":
		err = runtimeRegisterChannel(args[1:])
	case "watch-ready":
		err = runtimeWatchReady(args[1:])
	case "daemon-status":
		err = runtimeDaemonStatus(args[1:])
	case "process-start":
		err = runtimeProcessStart(args[1:])
	case "native-warning":
		err = runtimeNativeWarning(args[1:])
	default:
		err = fmt.Errorf("unknown runtime command %q", args[0])
	}
	if err != nil {
		return runtimeFatalf("%v", err)
	}
	return 0
}

func runtimeFatalf(format string, args ...any) int {
	fmt.Fprintf(os.Stderr, "khala-runtime: "+format+"\n", args...)
	return 1
}

func runtimeRoot() (string, error) {
	var root string
	if override := os.Getenv("KHALA_RUNTIME_DIR"); override != "" {
		root = override
	} else if runtime.GOOS == "linux" {
		base := filepath.Join("/run/user", strconv.Itoa(os.Geteuid()))
		info, err := os.Lstat(base)
		if err != nil && !os.IsNotExist(err) {
			return "", fmt.Errorf("inspect node runtime directory %s: %w", base, err)
		}
		if err == nil && info.Mode()&os.ModeSymlink == 0 && info.IsDir() {
			if stat, ok := info.Sys().(*syscall.Stat_t); ok && int(stat.Uid) == os.Geteuid() {
				root = filepath.Join(base, "khala")
			}
		}
		if root == "" {
			root = filepath.Join("/tmp", fmt.Sprintf("khala-%d", os.Geteuid()))
		}
	} else if runtime.GOOS == "darwin" {
		tmp := os.Getenv("TMPDIR")
		if tmp == "" {
			tmp = "/tmp"
		}
		root = filepath.Join(tmp, fmt.Sprintf("khala-%d", os.Geteuid()))
	} else {
		root = filepath.Join("/tmp", fmt.Sprintf("khala-%d", os.Geteuid()))
	}
	if !filepath.IsAbs(root) {
		return "", fmt.Errorf("runtime path is not absolute: %s", root)
	}
	if err := secureDirectory(root); err != nil {
		return "", err
	}
	for _, name := range []string{"sessions", "identities", "deliveries", "channels"} {
		if err := secureDirectory(filepath.Join(root, name)); err != nil {
			return "", err
		}
	}
	return root, nil
}

func secureDirectory(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		if !os.IsNotExist(err) {
			return fmt.Errorf("inspect runtime directory %s: %w", path, err)
		}
		if err := os.MkdirAll(path, 0700); err != nil {
			return fmt.Errorf("create runtime directory %s: %w", path, err)
		}
		info, err = os.Lstat(path)
		if err != nil {
			return fmt.Errorf("inspect created runtime directory %s: %w", path, err)
		}
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("runtime directory is a symlink; refusing: %s", path)
	}
	if !info.IsDir() {
		return fmt.Errorf("runtime path is not a directory: %s", path)
	}
	if stat, ok := info.Sys().(*syscall.Stat_t); ok && int(stat.Uid) != os.Geteuid() {
		return fmt.Errorf("runtime directory is owned by uid %d, not %d: %s", stat.Uid, os.Geteuid(), path)
	}
	if info.Mode().Perm() != 0700 {
		if err := os.Chmod(path, 0700); err != nil {
			return fmt.Errorf("chmod 0700 runtime directory %s: %w", path, err)
		}
	}
	return nil
}

var bootIDGOOS = runtime.GOOS
var bootIDReadFile = os.ReadFile
var bootIDSysctl = func(name string) ([]byte, error) {
	return exec.Command("sysctl", "-n", name).Output()
}
var bootIDFallbackOnce sync.Once
var bootIDFallbackLog = func() {
	fmt.Fprintln(os.Stderr, "boot id: kern.bootsessionuuid unavailable; using kern.boottime")
}

func currentBootID() (string, error) {
	if value := os.Getenv("KHALA_TEST_BOOT_ID"); value != "" {
		return value, nil
	}
	if bootIDGOOS == "linux" {
		if data, err := bootIDReadFile("/proc/sys/kernel/random/boot_id"); err == nil {
			if value := strings.TrimSpace(string(data)); value != "" {
				return value, nil
			}
		}
	}
	if bootIDGOOS == "darwin" {
		if data, err := bootIDSysctl("kern.bootsessionuuid"); err == nil {
			if value := strings.TrimSpace(string(data)); value != "" {
				return value, nil
			}
		}
		bootIDFallbackOnce.Do(bootIDFallbackLog)
		data, err := bootIDSysctl("kern.boottime")
		if err != nil {
			return "", fmt.Errorf("read macOS boot id: %w", err)
		}
		value := strings.TrimSpace(string(data))
		if value != "" {
			return value, nil
		}
	}
	return "", errors.New("cannot determine boot id")
}

func newUUID() (string, error) {
	var value [16]byte
	if _, err := io.ReadFull(rand.Reader, value[:]); err != nil {
		return "", err
	}
	value[6] = (value[6] & 0x0f) | 0x40
	value[8] = (value[8] & 0x3f) | 0x80
	encoded := hex.EncodeToString(value[:])
	return encoded[0:8] + "-" + encoded[8:12] + "-" + encoded[12:16] + "-" + encoded[16:20] + "-" + encoded[20:32], nil
}

func writeAtomicJSON(path string, value any, mode os.FileMode) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	data = append(data, '\n')
	dir := filepath.Dir(path)
	if err := secureDirectory(dir); err != nil {
		return err
	}
	f, err := os.CreateTemp(dir, ".khala-write-")
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
	if err := f.Chmod(mode); err != nil {
		return err
	}
	if _, err := f.Write(data); err != nil {
		return err
	}
	if err := f.Sync(); err != nil {
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		return err
	}
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	syncErr := d.Sync()
	closeErr := d.Close()
	if syncErr != nil {
		return syncErr
	}
	if closeErr != nil {
		return closeErr
	}
	ok = true
	return nil
}

func readJSON(path string, value any) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	if err := json.Unmarshal(data, value); err != nil {
		return fmt.Errorf("parse %s: %w", path, err)
	}
	return nil
}

func processStart(pid int, bootID string) (string, error) {
	if pid <= 1 {
		return "", fmt.Errorf("invalid pid %d", pid)
	}
	if runtime.GOOS == "linux" {
		data, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "stat"))
		if err != nil {
			return "", err
		}
		line := string(data)
		end := strings.LastIndex(line, ")")
		if end < 0 {
			return "", errors.New("malformed /proc stat")
		}
		fields := strings.Fields(line[end+1:])
		if len(fields) <= 19 {
			return "", errors.New("short /proc stat")
		}
		return bootID + ":" + fields[19], nil
	}
	data, err := exec.Command("ps", "-o", "lstart=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return "", err
	}
	value := strings.TrimSpace(string(data))
	if value == "" {
		return "", errors.New("empty process start time")
	}
	return bootID + ":" + value, nil
}

func processParent(pid int) (int, error) {
	if runtime.GOOS == "linux" {
		data, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "stat"))
		if err != nil {
			return 0, err
		}
		line := string(data)
		end := strings.LastIndex(line, ")")
		if end < 0 {
			return 0, errors.New("malformed /proc stat")
		}
		fields := strings.Fields(line[end+1:])
		if len(fields) < 2 {
			return 0, errors.New("short /proc stat")
		}
		return strconv.Atoi(fields[1])
	}
	data, err := exec.Command("ps", "-o", "ppid=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return 0, err
	}
	return strconv.Atoi(strings.TrimSpace(string(data)))
}

func processIsAncestor(ancestor, child int) bool {
	for child > 1 {
		if child == ancestor {
			return true
		}
		parent, err := processParent(child)
		if err != nil || parent == child {
			return false
		}
		child = parent
	}
	return false
}

func processAliveWithStart(pid int, start, bootID string) bool {
	if pid <= 1 || start == "" {
		return false
	}
	got, err := processStart(pid, bootID)
	return err == nil && got == start
}

func registryDirectory() string {
	if path := os.Getenv("KHALA_CLAUDE_SESSIONS_DIR"); path != "" {
		return path
	}
	home := os.Getenv("HOME")
	if home == "" {
		return ""
	}
	return filepath.Join(home, ".claude", "sessions")
}

func jsonString(raw map[string]json.RawMessage, names ...string) string {
	for _, name := range names {
		if value, ok := raw[name]; ok {
			var result string
			if json.Unmarshal(value, &result) == nil {
				return result
			}
		}
	}
	return ""
}

func jsonInt(raw map[string]json.RawMessage, names ...string) int {
	for _, name := range names {
		if value, ok := raw[name]; ok {
			var result int
			if json.Unmarshal(value, &result) == nil {
				return result
			}
		}
	}
	return 0
}

func loadClaudeRegistries() ([]claudeRegistry, error) {
	dir := registryDirectory()
	if dir == "" {
		return nil, nil
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var result []claudeRegistry
	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".json" {
			continue
		}
		data, err := os.ReadFile(filepath.Join(dir, entry.Name()))
		if err != nil {
			continue
		}
		var raw map[string]json.RawMessage
		if json.Unmarshal(data, &raw) != nil {
			continue
		}
		registry := claudeRegistry{
			PID:       jsonInt(raw, "pid"),
			SessionID: jsonString(raw, "sessionId", "session_id", "claudeSessionId"),
			Name:      jsonString(raw, "name"),
			Version:   jsonString(raw, "version"),
			Socket:    jsonString(raw, "messagingSocketPath"),
			Cwd:       jsonString(raw, "cwd"),
		}
		if registry.PID > 1 && registry.Socket != "" {
			result = append(result, registry)
		}
	}
	return result, nil
}

func flagPassed(fs *flag.FlagSet, name string) bool {
	passed := false
	fs.Visit(func(f *flag.Flag) {
		if f.Name == name {
			passed = true
		}
	})
	return passed
}

func matchingRegistry(reg sessionRegistration, registries []claudeRegistry) (claudeRegistry, bool) {
	for _, candidate := range registries {
		if reg.SocketPath != "" && candidate.Socket != reg.SocketPath {
			continue
		}
		if reg.PID > 1 && candidate.PID != reg.PID {
			continue
		}
		if reg.ClaudeSessionID != "" && candidate.SessionID != "" && candidate.SessionID != reg.ClaudeSessionID {
			continue
		}
		if reg.SocketPath == "" && reg.PID <= 1 && reg.ClaudeSessionID != "" &&
			candidate.SessionID != reg.ClaudeSessionID {
			continue
		}
		return candidate, true
	}
	return claudeRegistry{}, false
}

func loadRegistrations(root, bootID string) (map[string]sessionRegistration, error) {
	entries, err := os.ReadDir(filepath.Join(root, "sessions"))
	if err != nil {
		return nil, err
	}
	result := make(map[string]sessionRegistration)
	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".json" {
			continue
		}
		var reg sessionRegistration
		if readJSON(filepath.Join(root, "sessions", entry.Name()), &reg) != nil {
			continue
		}
		if reg.BootID != bootID || !validInstanceID(reg.InstanceID) || !validNode(reg.Identity) ||
			strings.TrimSuffix(entry.Name(), ".json") != reg.InstanceID {
			continue
		}
		result[reg.InstanceID] = reg
	}
	return result, nil
}

func withRegistrationLock(root, bootID string, fn func() error) error {
	return withRuntimeLock(filepath.Join(root, "sessions", ".sessions.lock"), bootID, fn)
}

func writeRegistration(root, bootID string, reg sessionRegistration) error {
	return withRegistrationLock(root, bootID, func() error {
		return writeAtomicJSON(filepath.Join(root, "sessions", reg.InstanceID+".json"), reg, 0600)
	})
}

func mutateRegistration(root, bootID, instance string, fn func(*sessionRegistration) error) error {
	return withRegistrationLock(root, bootID, func() error {
		path := filepath.Join(root, "sessions", instance+".json")
		var reg sessionRegistration
		if err := readJSON(path, &reg); err != nil {
			return err
		}
		if reg.BootID != bootID || reg.InstanceID != instance {
			return errors.New("registration boot/instance mismatch")
		}
		if err := fn(&reg); err != nil {
			return err
		}
		return writeAtomicJSON(path, reg, 0600)
	})
}

func runtimePrintRoot(args []string) error {
	if len(args) != 0 {
		return errors.New("root takes no arguments")
	}
	root, err := runtimeRoot()
	if err != nil {
		return err
	}
	fmt.Fprintln(os.Stdout, root)
	return nil
}

// runtimeSession prints "<claudeSessionId>\t<cwd>" for the nearest ancestor
// (starting at --pid itself) that Claude Code registered in its sessions
// directory. A plugin MCP child is spawned by the session process, so this is
// how it learns which session and project it belongs to without trusting env.
func runtimeSession(args []string) error {
	fs := flag.NewFlagSet("runtime session", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	pid := fs.Int("pid", os.Getppid(), "")
	if err := fs.Parse(args); err != nil || fs.NArg() != 0 || *pid <= 1 {
		return errors.New("session needs --pid N")
	}
	registries, err := loadClaudeRegistries()
	if err != nil {
		return err
	}
	byPID := make(map[int]claudeRegistry, len(registries))
	for _, registry := range registries {
		byPID[registry.PID] = registry
	}
	for cursor, hops := *pid, 0; cursor > 1 && hops < 32; hops++ {
		if registry, ok := byPID[cursor]; ok && registry.SessionID != "" {
			fmt.Fprintf(os.Stdout, "%s\t%s\n", registry.SessionID, registry.Cwd)
			return nil
		}
		parent, err := processParent(cursor)
		if err != nil || parent == cursor {
			break
		}
		cursor = parent
	}
	return errors.New("no ancestor is a registered Claude session")
}

func runtimeWhoami(args []string) error {
	fs := flag.NewFlagSet("runtime whoami", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	identity := fs.String("identity", "", "")
	sessionID := fs.String("session-id", "", "")
	if err := fs.Parse(args); err != nil || fs.NArg() != 0 || !validNode(*identity) || *sessionID == "" {
		return errors.New("whoami needs a valid --identity and --session-id")
	}
	root, err := runtimeRoot()
	if err != nil {
		return err
	}
	bootID, err := currentBootID()
	if err != nil {
		return err
	}
	regs, err := loadRegistrations(root, bootID)
	if err != nil {
		return err
	}
	var instance string
	for _, reg := range regs {
		if reg.Identity != *identity || reg.ClaudeSessionID != *sessionID {
			continue
		}
		if instance != "" && instance != reg.InstanceID {
			return errors.New("multiple registrations match identity and Claude session id")
		}
		instance = reg.InstanceID
	}
	if instance == "" {
		return errors.New("no registration matches identity and Claude session id")
	}
	fmt.Fprintln(os.Stdout, instance)
	return nil
}

func runtimeRegisterChannel(args []string) error {
	if len(args) == 1 && args[0] == "--help" {
		fmt.Fprintln(os.Stdout, "usage: khala-link runtime register-channel --instance ID --session-id ID --channel-socket PATH --caller-pid PID [--verified|--clear]")
		return nil
	}
	fs := flag.NewFlagSet("runtime register-channel", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	instance := fs.String("instance", "", "")
	sessionID := fs.String("session-id", "", "")
	channelSocket := fs.String("channel-socket", "", "")
	callerPID := fs.Int("caller-pid", os.Getppid(), "")
	verified := fs.Bool("verified", false, "")
	clearChannel := fs.Bool("clear", false, "")
	if err := fs.Parse(args); err != nil || fs.NArg() != 0 || !validInstanceID(*instance) || *sessionID == "" {
		return errors.New("register-channel needs a valid --instance and --session-id")
	}
	root, err := runtimeRoot()
	if err != nil {
		return err
	}
	bootID, err := currentBootID()
	if err != nil {
		return err
	}
	return mutateRegistration(root, bootID, *instance, func(reg *sessionRegistration) error {
		if reg.ClaudeSessionID != *sessionID {
			return errors.New("channel caller Claude session id does not match registration")
		}
		if *clearChannel {
			if reg.ChannelPID == 0 {
				return nil
			}
			callerStart, err := processStart(*callerPID, bootID)
			if err != nil {
				return fmt.Errorf("read channel caller pid start: %w", err)
			}
			if reg.ChannelPID != *callerPID || reg.ChannelPIDStart != callerStart {
				return nil // a stale child must not clear its replacement
			}
			reg.ChannelSocket = ""
			reg.ChannelPID = 0
			reg.ChannelPIDStart = ""
			reg.ChannelVerified = false
			return nil
		}
		if *callerPID <= 1 || *channelSocket == "" {
			return errors.New("register-channel needs --channel-socket and --caller-pid")
		}
		expectedSocket := filepath.Join(root, "channels", reg.InstanceID+".sock")
		if filepath.Clean(*channelSocket) != expectedSocket {
			return fmt.Errorf("channel socket must be %s", expectedSocket)
		}
		info, err := os.Lstat(expectedSocket)
		if err != nil {
			return fmt.Errorf("inspect channel socket: %w", err)
		}
		if info.Mode()&os.ModeSymlink != 0 || info.Mode()&os.ModeSocket == 0 {
			return errors.New("channel socket is not a real Unix socket")
		}
		if stat, ok := info.Sys().(*syscall.Stat_t); ok && int(stat.Uid) != os.Geteuid() {
			return errors.New("channel socket uid mismatch")
		}
		pidStart, err := processStart(*callerPID, bootID)
		if err != nil {
			return fmt.Errorf("read channel pid start: %w", err)
		}
		reg.ChannelSocket = expectedSocket
		reg.ChannelPID = *callerPID
		reg.ChannelPIDStart = pidStart
		reg.ChannelVerified = *verified
		return nil
	})
}

func runtimeRegister(args []string, publicBind bool) error {
	fs := flag.NewFlagSet("runtime register", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	identity := fs.String("identity", os.Getenv("KHALA_SESSION"), "")
	instance := fs.String("instance", os.Getenv("KHALA_SESSION_INSTANCE"), "")
	sessionID := fs.String("session-id", firstNonempty(os.Getenv("KHALA_CLAUDE_SESSION_ID"), os.Getenv("CLAUDE_CODE_SESSION_ID")), "")
	socketPath := fs.String("socket", os.Getenv("CLAUDE_CODE_MESSAGING_SOCKET"), "")
	kind := fs.String("kind", firstNonempty(os.Getenv("KHALA_SESSION_KIND"), "auto"), "")
	phase := fs.String("phase", "ready", "")
	ccVersion := fs.String("cc-version", os.Getenv("CLAUDE_CODE_VERSION"), "")
	pid := fs.Int("pid", envInt("KHALA_SESSION_PID"), "")
	callerPID := fs.Int("caller-pid", os.Getppid(), "")
	receiveOptIn := fs.Bool("receive-opt-in", os.Getenv("KHALA_RECEIVE") == "1", "")
	takeover := fs.Bool("takeover", false, "")
	if err := fs.Parse(args); err != nil || fs.NArg() != 0 {
		return errors.New("invalid runtime registration arguments")
	}
	if !validNode(*identity) {
		return fmt.Errorf("invalid identity %q", *identity)
	}
	if *phase != "starting" && *phase != "ready" {
		return fmt.Errorf("invalid registration phase %q", *phase)
	}
	if *kind == "" {
		return errors.New("registration kind is empty")
	}
	root, err := runtimeRoot()
	if err != nil {
		return err
	}
	bootID, err := currentBootID()
	if err != nil {
		return err
	}
	registrations, err := loadRegistrations(root, bootID)
	if err != nil {
		return err
	}
	registries, err := loadClaudeRegistries()
	if err != nil {
		return err
	}
	if *instance == "" {
		for _, existing := range registrations {
			if existing.Identity == *identity && *sessionID != "" && existing.ClaudeSessionID == *sessionID {
				*instance = existing.InstanceID
				break
			}
		}
	}
	if *instance == "" && publicBind {
		for _, existing := range registrations {
			if existing.Identity == *identity && processIsAncestor(existing.PID, *callerPID) {
				*instance = existing.InstanceID
				break
			}
		}
	}
	if *instance == "" {
		*instance, err = newUUID()
		if err != nil {
			return err
		}
	}
	if !validInstanceID(*instance) {
		return fmt.Errorf("invalid registration instance %q", *instance)
	}
	reg, exists := registrations[*instance]
	if exists && reg.Identity != *identity {
		return errors.New("registration instance belongs to another identity")
	}
	if !exists {
		reg = sessionRegistration{
			BootID: bootID, InstanceID: *instance, Identity: *identity,
			StartedAt: time.Now().UTC().Format(time.RFC3339Nano),
		}
	}
	reg.ClaudeSessionID = firstNonempty(*sessionID, reg.ClaudeSessionID)
	// A socket inherited from the environment (CLAUDE_CODE_MESSAGING_SOCKET
	// reaches every Bash child of a session) must not replace the socket an
	// existing registration already binds — a session running `khala bind` on
	// behalf of another instance would otherwise re-point that instance at its
	// own inbox. Only an explicit --socket, or a first registration, sets it.
	if exists && reg.SocketPath != "" && !flagPassed(fs, "socket") {
		// keep reg.SocketPath
	} else {
		reg.SocketPath = firstNonempty(*socketPath, reg.SocketPath)
	}
	reg.Kind = *kind
	reg.ReceiveOptIn = *receiveOptIn || reg.ReceiveOptIn
	reg.Phase = *phase
	reg.CCVersion = firstNonempty(*ccVersion, reg.CCVersion)
	if *pid > 1 {
		reg.PID = *pid
	}
	if registry, ok := matchingRegistry(reg, registries); ok {
		reg.PID = registry.PID
		reg.SocketPath = registry.Socket
		reg.CCVersion = firstNonempty(reg.CCVersion, registry.Version)
	}
	if reg.PID <= 1 && publicBind {
		reg.PID = *callerPID
	}
	if *kind == "auto" {
		reg.Kind = detectSessionKind(firstPositive(reg.PID, *callerPID))
	}
	if reg.PID > 1 {
		reg.PIDStart, err = processStart(reg.PID, bootID)
		if err != nil {
			return fmt.Errorf("read registration pid start: %w", err)
		}
	}
	reg.ConduitVerified = false
	reg.VerifiedAt = ""
	if err := writeRegistration(root, bootID, reg); err != nil {
		return err
	}
	owner, epoch, err := claimLease(root, bootID, &reg, *takeover)
	if err != nil {
		return err
	}
	reg.LeaseEpoch = epoch
	if err := mutateRegistration(root, bootID, reg.InstanceID, func(current *sessionRegistration) error {
		current.LeaseEpoch = epoch
		return nil
	}); err != nil {
		return err
	}
	fmt.Fprintf(os.Stdout, "instance %s\nowner %s\nepoch %d\n", reg.InstanceID, yesNo(owner), epoch)
	return nil
}

func firstPositive(values ...int) int {
	for _, value := range values {
		if value > 1 {
			return value
		}
	}
	return 0
}

func validInstanceID(value string) bool {
	return len(value) <= 128 && validNode(value)
}

func processArgs(pid int) []string {
	if pid <= 1 {
		return nil
	}
	if runtime.GOOS == "linux" {
		data, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "cmdline"))
		if err != nil {
			return nil
		}
		parts := strings.Split(strings.TrimRight(string(data), "\x00"), "\x00")
		return parts
	}
	data, err := exec.Command("ps", "-o", "command=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return nil
	}
	return strings.Fields(string(data))
}

func detectSessionKind(pid int) string {
	// A fork flag can live on a bg-pty-host ancestor above the registered
	// Claude process, so worker markers take precedence across the whole walk.
	foundClaude := false
	for current, depth := pid, 0; current > 1 && depth < 12; depth++ {
		args := processArgs(current)
		isClaude := false
		for _, arg := range args {
			base := filepath.Base(arg)
			if base == "claude" || strings.HasPrefix(base, "claude-") {
				isClaude = true
			}
			if arg == "-p" || arg == "--print" || arg == "--fork-session" ||
				strings.HasPrefix(arg, "--fork-session=") {
				return "worker"
			}
		}
		if isClaude {
			foundClaude = true
		}
		parent, err := processParent(current)
		if err != nil || parent == current {
			break
		}
		current = parent
	}
	if foundClaude {
		return "interactive"
	}
	return "unknown"
}

func firstNonempty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}

func envInt(name string) int {
	value, _ := strconv.Atoi(os.Getenv(name))
	return value
}

func yesNo(value bool) string {
	if value {
		return "yes"
	}
	return "no"
}

func withRuntimeLock(path, bootID string, fn func() error) error {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return err
	}
	defer f.Close()
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		return err
	}
	defer syscall.Flock(int(f.Fd()), syscall.LOCK_UN) //nolint:errcheck
	want := fmt.Sprintf("{\"bootId\":%q}\n", bootID)
	current, err := io.ReadAll(f)
	if err != nil {
		return err
	}
	if string(current) != want {
		if err := f.Truncate(0); err != nil {
			return err
		}
		if _, err := f.Seek(0, io.SeekStart); err != nil {
			return err
		}
		if _, err := io.WriteString(f, want); err != nil {
			return err
		}
		if err := f.Sync(); err != nil {
			return err
		}
	}
	return fn()
}

func claimLease(root, bootID string, reg *sessionRegistration, takeover bool) (bool, uint64, error) {
	eligible := reg.Kind == "interactive" || reg.ReceiveOptIn
	leasePath := filepath.Join(root, "identities", reg.Identity+".lease")
	var owner bool
	var epoch uint64
	err := withRuntimeLock(filepath.Join(root, "identities", ".leases.lock"), bootID, func() error {
		var lease identityLease
		if err := readJSON(leasePath, &lease); err != nil && !os.IsNotExist(err) {
			return err
		}
		hasCurrentEpoch := lease.BootID == bootID && lease.Epoch > 0
		if lease.BootID == bootID {
			epoch = lease.Epoch
		}
		if epoch == 0 {
			epoch = 1
		}
		if takeover {
			if !eligible {
				return errors.New("non-interactive registration requires receive opt-in for takeover")
			}
			if reg.Kind != "interactive" {
				if current, live := liveLeaseOwnerRegistration(root, bootID, lease); live && current.Kind == "interactive" {
					return errors.New("non-interactive registration cannot take over a live interactive owner")
				}
			}
			if hasCurrentEpoch {
				epoch++
			}
			owner = true
		} else if lease.InstanceID == reg.InstanceID && lease.BootID == bootID && lease.State == "owned" {
			if eligible {
				owner = true
			} else {
				lease.InstanceID = ""
				lease.PID = 0
				lease.PIDStart = ""
				lease.ClaudeSessionID = ""
				lease.State = "released"
				return writeAtomicJSON(leasePath, lease, 0600)
			}
		} else if eligible && !leaseOwnerLive(root, bootID, lease) {
			if lease.InstanceID != "" || lease.State == "released" || lease.BootID == bootID {
				epoch++
			}
			owner = true
		}
		if !owner {
			return nil
		}
		lease = identityLease{
			BootID: bootID, Identity: reg.Identity, InstanceID: reg.InstanceID, Epoch: epoch,
			PID: reg.PID, PIDStart: reg.PIDStart, ClaudeSessionID: reg.ClaudeSessionID,
			ClaimedAt: time.Now().UTC().Format(time.RFC3339Nano), State: "owned",
		}
		return writeAtomicJSON(leasePath, lease, 0600)
	})
	return owner, epoch, err
}

func leaseOwnerLive(root, bootID string, lease identityLease) bool {
	_, live := liveLeaseOwnerRegistration(root, bootID, lease)
	return live
}

func liveLeaseOwnerRegistration(root, bootID string, lease identityLease) (sessionRegistration, bool) {
	if lease.BootID != bootID || lease.InstanceID == "" || lease.State != "owned" {
		return sessionRegistration{}, false
	}
	var reg sessionRegistration
	if readJSON(filepath.Join(root, "sessions", lease.InstanceID+".json"), &reg) != nil ||
		reg.BootID != bootID || reg.InstanceID != lease.InstanceID || reg.Identity != lease.Identity {
		return sessionRegistration{}, false
	}
	if processAliveWithStart(reg.PID, reg.PIDStart, bootID) {
		return reg, true
	}
	started, err := time.Parse(time.RFC3339Nano, reg.StartedAt)
	return reg, err == nil && reg.PID <= 1 && time.Since(started) < 30*time.Second
}

func runtimeRelease(args []string) error {
	fs := flag.NewFlagSet("runtime release", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	identity := fs.String("identity", os.Getenv("KHALA_SESSION"), "")
	instance := fs.String("instance", os.Getenv("KHALA_SESSION_INSTANCE"), "")
	sessionID := fs.String("session-id", firstNonempty(os.Getenv("KHALA_CLAUDE_SESSION_ID"), os.Getenv("CLAUDE_CODE_SESSION_ID")), "")
	callerPIDFlag := fs.Int("caller-pid", os.Getppid(), "")
	if err := fs.Parse(args); err != nil || fs.NArg() != 0 {
		return errors.New("invalid release arguments")
	}
	if *instance != "" && !validInstanceID(*instance) {
		return errors.New("release instance is invalid")
	}
	if *instance == "" && *sessionID == "" {
		return errors.New("release requires an instance or Claude session id")
	}
	// An explicit instance is the whole address. Do not additionally filter by
	// a session id that merely leaked in from the environment (every Bash
	// child of a Claude Code session carries CLAUDE_CODE_SESSION_ID) — that
	// would silently match nothing when releasing another instance.
	if *instance != "" && !flagPassed(fs, "session-id") {
		*sessionID = ""
	}
	root, err := runtimeRoot()
	if err != nil {
		return err
	}
	bootID, err := currentBootID()
	if err != nil {
		return err
	}
	regs, err := loadRegistrations(root, bootID)
	if err != nil {
		return err
	}
	callerPID := *callerPIDFlag
	var targets []sessionRegistration
	for _, reg := range regs {
		if *instance != "" && reg.InstanceID != *instance {
			continue
		}
		if *sessionID != "" && reg.ClaudeSessionID != *sessionID {
			continue
		}
		if *identity != "" && reg.Identity != *identity {
			continue
		}
		// A session-id match alone is not ownership: `claude --resume` gives
		// the new process the same Claude session id as the one it resumed,
		// so a late SessionEnd of the old process would delete the live
		// registration (measured 2026-08-17: steno resumed 4x, left deaf).
		// Without an explicit --instance, release only what this caller
		// owns: a registration whose pid is dead, or one whose pid is this
		// process's own ancestor.
		if *instance == "" && reg.PID > 1 && !processIsAncestor(reg.PID, callerPID) &&
			processAliveWithStart(reg.PID, reg.PIDStart, bootID) {
			continue
		}
		targets = append(targets, reg)
	}
	for _, reg := range targets {
		if err := withRegistrationLock(root, bootID, func() error {
			if err := os.Remove(filepath.Join(root, "sessions", reg.InstanceID+".json")); err != nil && !os.IsNotExist(err) {
				return err
			}
			return nil
		}); err != nil {
			return err
		}
		leasePath := filepath.Join(root, "identities", reg.Identity+".lease")
		if err := withRuntimeLock(filepath.Join(root, "identities", ".leases.lock"), bootID, func() error {
			var lease identityLease
			if readJSON(leasePath, &lease) != nil || lease.InstanceID != reg.InstanceID ||
				lease.BootID != bootID || lease.State != "owned" {
				return nil
			}
			home, err := khalaHome()
			if err != nil {
				return err
			}
			logger, err := newConduitLogger(home)
			if err != nil {
				return err
			}
			lease.InstanceID = ""
			lease.PID = 0
			lease.PIDStart = ""
			lease.ClaudeSessionID = ""
			lease.State = "released"
			if err := writeAtomicJSON(leasePath, lease, 0600); err != nil {
				return err
			}
			return logger.Output(2, fmt.Sprintf("released lease %s for instance %s", reg.Identity, reg.InstanceID))
		}); err != nil {
			return err
		}
	}
	return nil
}

func runtimeStatus(args []string) error {
	if len(args) != 0 {
		return errors.New("status takes no arguments")
	}
	root, err := runtimeRoot()
	if err != nil {
		return err
	}
	bootID, err := currentBootID()
	if err != nil {
		return err
	}
	regs, err := loadRegistrations(root, bootID)
	if err != nil {
		return err
	}
	identities := make(map[string]struct{})
	for _, reg := range regs {
		identities[reg.Identity] = struct{}{}
	}
	entries, _ := os.ReadDir(filepath.Join(root, "identities"))
	for _, entry := range entries {
		if strings.HasSuffix(entry.Name(), ".lease") {
			identities[strings.TrimSuffix(entry.Name(), ".lease")] = struct{}{}
		}
	}
	names := make([]string, 0, len(identities))
	for identity := range identities {
		names = append(names, identity)
	}
	sort.Strings(names)
	home, _ := khalaHome()
	fmt.Fprintf(os.Stdout, "runtime: %s\n", root)
	fmt.Fprintln(os.Stdout, "IDENTITY\tPENDING\tOWNER\tINSTANCE\tPHASE\tSOCKET\tCHANNEL\tCC_VERSION\tADAPTER\tLAST_ATTEMPT\tLAST_STATUS\tACK\tNATIVE")
	for _, identity := range names {
		pending := countRegularFiles(filepath.Join(home, "inbox", identity, "new"))
		var lease identityLease
		_ = readJSON(filepath.Join(root, "identities", identity+".lease"), &lease)
		reg := regs[lease.InstanceID]
		socket := "-"
		if reg.SocketPath != "" {
			socket = "yes"
		}
		channel := "-"
		if reg.ChannelSocket != "" {
			channel = "yes"
		}
		native := firstNonempty(reg.NativeStatus, "-")
		adapter := "-"
		if reg.ConduitVerified {
			adapter = "socket-v1"
		}
		lastAttempt, lastStatus, ack := "-", "-", "-"
		if journal, ok := latestDeliveryJournal(root, identity, reg.InstanceID, bootID); ok {
			lastAttempt = journal.AttemptedAt
			lastStatus = journal.Status
			if len(journal.LetterIDs) > 0 {
				ack = "consumed"
				for _, id := range journal.LetterIDs {
					if _, err := os.Stat(filepath.Join(home, "inbox", identity, "cur", id)); err != nil {
						ack = "-"
						break
					}
				}
			}
		}
		fmt.Fprintf(os.Stdout, "%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", identity, pending,
			yesNo(lease.BootID == bootID && lease.InstanceID != "" && lease.State == "owned"), firstNonempty(lease.InstanceID, "-"),
			firstNonempty(reg.Phase, "-"), socket, channel, firstNonempty(reg.CCVersion, "-"), adapter,
			lastAttempt, lastStatus, ack, native)
	}
	return nil
}

func latestDeliveryJournal(root, identity, instance, bootID string) (deliveryJournal, bool) {
	if instance == "" {
		return deliveryJournal{}, false
	}
	entries, err := os.ReadDir(filepath.Join(root, "deliveries", identity, instance))
	if err != nil {
		return deliveryJournal{}, false
	}
	var latest deliveryJournal
	var latestAt time.Time
	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".json" {
			continue
		}
		var candidate deliveryJournal
		if readJSON(filepath.Join(root, "deliveries", identity, instance, entry.Name()), &candidate) != nil || candidate.BootID != bootID {
			continue
		}
		attempted, err := time.Parse(time.RFC3339Nano, candidate.AttemptedAt)
		if err == nil && attempted.After(latestAt) {
			latest, latestAt = candidate, attempted
		}
	}
	return latest, !latestAt.IsZero()
}

func runtimeWatchReady(args []string) error {
	fs := flag.NewFlagSet("watch-ready", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	identity := fs.String("identity", os.Getenv("KHALA_SESSION"), "")
	instance := fs.String("instance", os.Getenv("KHALA_SESSION_INSTANCE"), "")
	sessionID := fs.String("session-id", firstNonempty(os.Getenv("KHALA_CLAUDE_SESSION_ID"), os.Getenv("CLAUDE_CODE_SESSION_ID")), "")
	callerPID := fs.Int("caller-pid", os.Getppid(), "")
	if err := fs.Parse(args); err != nil || fs.NArg() != 0 || !validNode(*identity) ||
		(*instance != "" && !validInstanceID(*instance)) {
		return errors.New("invalid watch-ready arguments")
	}
	root, err := runtimeRoot()
	if err != nil {
		return err
	}
	bootID, err := currentBootID()
	if err != nil {
		return err
	}
	regs, err := loadRegistrations(root, bootID)
	if err != nil {
		return err
	}
	var lease identityLease
	if readJSON(filepath.Join(root, "identities", *identity+".lease"), &lease) != nil ||
		lease.BootID != bootID || lease.State != "owned" {
		return errors.New("no live identity lease")
	}
	reg, ok := regs[lease.InstanceID]
	if !ok || reg.Identity != *identity || !reg.ConduitVerified || reg.Phase != "ready" || reg.SocketPath == "" ||
		lease.Epoch == 0 || lease.Epoch != reg.LeaseEpoch || lease.PID != reg.PID ||
		lease.PIDStart != reg.PIDStart || lease.ClaudeSessionID != reg.ClaudeSessionID ||
		!processAliveWithStart(reg.PID, reg.PIDStart, bootID) {
		return errors.New("registration is not conduit verified")
	}
	info, err := os.Lstat(reg.SocketPath)
	if err != nil || info.Mode()&os.ModeSocket == 0 {
		return errors.New("registration socket is unavailable")
	}
	own := (*instance != "" && reg.InstanceID == *instance) ||
		(*sessionID != "" && reg.ClaudeSessionID == *sessionID) || processIsAncestor(reg.PID, *callerPID)
	if !own {
		return errors.New("verified registration belongs to another session")
	}
	if reg.ChannelSocket != "" && !reg.ChannelVerified {
		return errors.New("conduit path unverified")
	}
	return nil
}

func runtimeDaemonStatus(args []string) error {
	if len(args) != 0 {
		return errors.New("daemon-status takes no arguments")
	}
	root, err := runtimeRoot()
	if err != nil {
		return err
	}
	bootID, err := currentBootID()
	if err != nil {
		return err
	}
	var status conduitStatus
	if err := readJSON(filepath.Join(root, "conduit.status.json"), &status); err != nil {
		return err
	}
	if status.BootID != bootID || !processAliveWithStart(status.PID, status.PIDStart, bootID) {
		return errors.New("conduit is not live")
	}
	return nil
}

func runtimeProcessStart(args []string) error {
	fs := flag.NewFlagSet("process-start", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	pid := fs.Int("pid", 0, "")
	if err := fs.Parse(args); err != nil || fs.NArg() != 0 || *pid <= 1 {
		return errors.New("process-start needs --pid N")
	}
	bootID, err := currentBootID()
	if err != nil {
		return err
	}
	start, err := processStart(*pid, bootID)
	if err != nil {
		return err
	}
	fmt.Fprintln(os.Stdout, start)
	return nil
}

func runtimeNativeWarning(args []string) error {
	fs := flag.NewFlagSet("native-warning", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	instance := fs.String("instance", os.Getenv("KHALA_SESSION_INSTANCE"), "")
	if err := fs.Parse(args); err != nil || fs.NArg() != 0 || !validInstanceID(*instance) {
		return errors.New("native-warning needs an instance")
	}
	root, err := runtimeRoot()
	if err != nil {
		return err
	}
	bootID, err := currentBootID()
	if err != nil {
		return err
	}
	warn := false
	err = mutateRegistration(root, bootID, *instance, func(reg *sessionRegistration) error {
		if reg.NativeStatus == "native-degraded" && !reg.NativeWarningShown {
			warn = true
			reg.NativeWarningShown = true
		}
		return nil
	})
	if err != nil {
		return err
	}
	if warn {
		fmt.Fprintln(os.Stdout, "native-degraded")
	}
	return nil
}

func countRegularFiles(path string) int {
	entries, err := os.ReadDir(path)
	if err != nil {
		return 0
	}
	count := 0
	for _, entry := range entries {
		if entry.Type().IsRegular() {
			count++
		}
	}
	return count
}
