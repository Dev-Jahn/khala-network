package main

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

const (
	gatewayConfName     = "gateway.conf"
	gatewayStateName    = "gateway.state.json"
	gatewayThreadMaxAge = 7 * 24 * 3600
)

// gatewayConf is $KHALA_HOME/gateway.conf: `key value` lines, `#` comments.
type gatewayConf struct {
	adapter       string // telegram | fake
	token         string
	chat          int64
	allow         map[int64]bool
	chunkLimit    int
	userExpires   int64
	stallAfter    int64
	pollTimeout   int
	noticeForward string // off | urgent | all
	khalaBin      string
}

// errGatewayConfAbsent distinguishes "not configured" from "misconfigured".
var errGatewayConfAbsent = errors.New("gateway.conf is absent")

func checkPrivateFile(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("%s is a symlink", path)
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("%s is not a regular file", path)
	}
	if info.Mode().Perm()&0077 != 0 {
		return fmt.Errorf("%s has mode %04o; want 0600", path, info.Mode().Perm())
	}
	if stat, ok := info.Sys().(*syscall.Stat_t); ok && int(stat.Uid) != os.Geteuid() {
		return fmt.Errorf("%s is not owned by this user", path)
	}
	return nil
}

func loadGatewayConf(home string) (gatewayConf, error) {
	path := filepath.Join(home, gatewayConfName)
	if _, err := os.Lstat(path); os.IsNotExist(err) {
		return gatewayConf{}, fmt.Errorf("%w: create %s (mode 0600); see docs/GATEWAY.md", errGatewayConfAbsent, path)
	}
	if err := checkPrivateFile(path); err != nil {
		return gatewayConf{}, err
	}
	f, err := openRegular(path)
	if err != nil {
		return gatewayConf{}, err
	}
	defer f.Close()
	c := gatewayConf{allow: map[int64]bool{}, chunkLimit: 3, userExpires: 259200, stallAfter: 900, pollTimeout: 30, noticeForward: "off"}
	seen := map[string]bool{}
	tokenFile := ""
	scanner := bufio.NewScanner(io.LimitReader(f, 64<<10))
	for line := 1; scanner.Scan(); line++ {
		fields := strings.Fields(scanner.Text())
		if len(fields) == 0 || strings.HasPrefix(fields[0], "#") {
			continue
		}
		bad := func(format string, args ...any) error {
			return fmt.Errorf("gateway.conf line %d: "+format, append([]any{line}, args...)...)
		}
		key := fields[0]
		args := fields[1:]
		if (key == "telegram" || key == "user" || key == "notices" || key == "khala") && len(fields) >= 2 {
			key = fields[0] + " " + fields[1]
			args = fields[2:]
		}
		if key != "telegram allow" {
			if seen[key] {
				return gatewayConf{}, bad("duplicate key %q", key)
			}
			seen[key] = true
		}
		one := func() (string, error) {
			if len(args) != 1 {
				return "", bad("%q takes exactly one value", key)
			}
			return args[0], nil
		}
		integer := func(min, max int64) (int64, error) {
			value, err := one()
			if err != nil {
				return 0, err
			}
			n, err := strconv.ParseInt(value, 10, 64)
			if err != nil || n < min || n > max {
				return 0, bad("%q must be an integer in %d..%d", key, min, max)
			}
			return n, nil
		}
		var err error
		switch key {
		case "adapter":
			c.adapter, err = one()
			if err == nil && c.adapter != "telegram" && c.adapter != "fake" {
				err = bad("adapter must be telegram or fake")
			}
		case "telegram token":
			c.token, err = one()
		case "telegram token-file":
			tokenFile, err = one()
			if err == nil && !filepath.IsAbs(tokenFile) {
				err = bad("token-file must be an absolute path")
			}
		case "telegram chat":
			c.chat, err = integer(-1<<62, -1)
		case "telegram allow":
			if len(args) == 0 {
				err = bad("telegram allow needs at least one numeric user id")
			}
			for _, value := range args {
				id, parseErr := strconv.ParseInt(value, 10, 64)
				if parseErr != nil || id <= 0 {
					err = bad("telegram allow takes numeric user ids, got %q", value)
					break
				}
				c.allow[id] = true
			}
		case "telegram chunk-limit":
			var n int64
			n, err = integer(1, 20)
			c.chunkLimit = int(n)
		case "user expires":
			c.userExpires, err = integer(1, 5097600)
		case "stall-after":
			c.stallAfter, err = integer(60, 86400)
		case "poll-timeout":
			var n int64
			n, err = integer(0, 50)
			c.pollTimeout = int(n)
		case "notices forward":
			c.noticeForward, err = one()
			if err == nil && !oneOf(c.noticeForward, "off", "urgent", "all") {
				err = bad("notices forward must be off, urgent or all")
			}
		case "khala bin":
			c.khalaBin, err = one()
			if err == nil && !filepath.IsAbs(c.khalaBin) {
				err = bad("khala bin must be an absolute path")
			}
		default:
			err = bad("unknown key %q", key)
		}
		if err != nil {
			return gatewayConf{}, err
		}
	}
	if err := scanner.Err(); err != nil {
		return gatewayConf{}, fmt.Errorf("read gateway.conf: %w", err)
	}
	if c.adapter == "" {
		return gatewayConf{}, errors.New("gateway.conf: adapter is required (telegram or fake)")
	}
	if c.khalaBin == "" {
		return gatewayConf{}, errors.New("gateway.conf: khala bin /abs/path/to/khala is required")
	}
	if info, err := os.Stat(c.khalaBin); err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0111 == 0 {
		return gatewayConf{}, fmt.Errorf("gateway.conf: khala bin %s is not an executable file", c.khalaBin)
	}
	if c.token != "" && tokenFile != "" {
		return gatewayConf{}, errors.New("gateway.conf: use either telegram token or telegram token-file, not both")
	}
	if tokenFile != "" {
		if err := checkPrivateFile(tokenFile); err != nil {
			return gatewayConf{}, fmt.Errorf("gateway.conf token-file: %w", err)
		}
		data, err := os.ReadFile(tokenFile)
		if err != nil {
			return gatewayConf{}, fmt.Errorf("gateway.conf token-file: %w", err)
		}
		c.token = strings.TrimSpace(string(data))
	}
	if c.adapter == "telegram" {
		if c.token == "" || strings.ContainsAny(c.token, " /\t\r\n") {
			return gatewayConf{}, errors.New("gateway.conf: adapter telegram needs telegram token (or token-file)")
		}
		if c.chat == 0 {
			return gatewayConf{}, errors.New("gateway.conf: adapter telegram needs telegram chat <negative supergroup id>")
		}
	}
	return c, nil
}

// threadRef ties a khala message Id the gateway sent to the chat message it came from.
type threadRef struct {
	Chat      int64 `json:"chat"`
	Thread    int64 `json:"thread"`
	MessageID int64 `json:"message_id"`
	UpdateID  int64 `json:"update_id"`
	At        int64 `json:"at"`
}

// statusRecord is the last status posted to an address's topic, plus the
// gateway's own first observation of unread messages (the stall clock of last
// resort when the listener snapshot carries no age).
type statusRecord struct {
	Kind         string `json:"kind,omitempty"`
	At           int64  `json:"at,omitempty"`
	PendingSince int64  `json:"pending_since,omitempty"`
}

type gatewayState struct {
	Version int                     `json:"version"`
	Offset  int64                   `json:"offset"`
	Topics  map[string]int64        `json:"topics"`
	Threads map[string]threadRef    `json:"threads"`
	Status  map[string]statusRecord `json:"status"`
	Notices map[string]string       `json:"notices"`
}

func newGatewayState() *gatewayState {
	return &gatewayState{Version: 1, Topics: map[string]int64{}, Threads: map[string]threadRef{}, Status: map[string]statusRecord{}, Notices: map[string]string{}}
}

// loadGatewayState returns an empty state when the file is absent and an
// error when it is present but unreadable: a lost mapping must be noticed,
// not silently replaced by an empty one.
func loadGatewayState(home string) (*gatewayState, error) {
	path := filepath.Join(home, gatewayStateName)
	if _, err := os.Lstat(path); os.IsNotExist(err) {
		return newGatewayState(), nil
	}
	if err := checkPrivateFile(path); err != nil {
		return nil, err
	}
	st := newGatewayState()
	if err := readJSON(path, st); err != nil {
		return nil, err
	}
	if st.Version != 1 {
		return nil, fmt.Errorf("%s: unsupported version %d", path, st.Version)
	}
	if st.Topics == nil {
		st.Topics = map[string]int64{}
	}
	if st.Threads == nil {
		st.Threads = map[string]threadRef{}
	}
	if st.Status == nil {
		st.Status = map[string]statusRecord{}
	}
	if st.Notices == nil {
		st.Notices = map[string]string{}
	}
	return st, nil
}

func (st *gatewayState) prune(now int64) {
	for id, ref := range st.Threads {
		if now-ref.At > gatewayThreadMaxAge {
			delete(st.Threads, id)
		}
	}
}

func saveGatewayState(home string, st *gatewayState) error {
	return writeAtomicJSON(filepath.Join(home, gatewayStateName), st, 0600)
}

// topicFor returns the address mapped to a thread.
func (st *gatewayState) topicFor(thread int64) (string, bool) {
	for address, id := range st.Topics {
		if id == thread {
			return address, true
		}
	}
	return "", false
}
