package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// Codex runs a plugin's hooks only while it trusts them, and ties that trust
// to the installed plugin directory. A marketplace refresh re-creates the
// directories under $CODEX_HOME/plugins/cache, after which the hooks silently
// stop running. For the plugins named in <KHALA_HOME>/codex-auto-trust (one
// per line; absent or empty = off) the conduit notices the re-creation and
// runs `khala-codex auto-trust --run`, which re-records trust only for an
// installed copy that equals the published release.
//
// A service has no usable PATH of its own (launchd gives /usr/bin:/bin:…), and
// khala-codex needs node and codex. Enabling (`khala-codex auto-trust NAME...`)
// therefore records one in <KHALA_HOME>/codex-auto-trust.path; the run gets
// exactly that PATH, and without the file nothing is run.
const (
	autoTrustTick     = 30 * time.Second
	autoTrustDeadline = 120 * time.Second
	autoTrustAnnounce = 24 * time.Hour
	autoTrustTrusted  = "trusted"
	// Exit codes the conduit itself records, beside khala-codex's own 0/3/4/5.
	autoTrustExitDeadline = 124
	autoTrustExitNotRun   = 127
)

// The first retry is early: a run that lands while Codex is still re-creating
// a directory is refused or cannot check, and writes nothing.
var autoTrustBackoff = []time.Duration{time.Minute, 2 * time.Minute, 5 * time.Minute, 15 * time.Minute, 30 * time.Minute}

type autoTrustResult struct {
	at       time.Time
	exit     int
	changed  [][4]string // plugin, event, was, now
	problems []string
	// stopping is set when the service shut down under the run; nothing is recorded.
	stopping bool
}

// autoTrust is driven by the notifier loop alone: tick on a slow ticker,
// finish when a run's result arrives. Only the run itself is on a goroutine.
type autoTrust struct {
	home      string
	codexHome string
	logger    *log.Logger
	now       func() time.Time
	locate    func(path string) (string, error)
	deadline  time.Duration
	backoff   []time.Duration
	results   chan autoTrustResult

	on bool
	// seen is the signature at the previous tick; handled the one the latest
	// run was started for.
	seen     string
	handled  string
	running  bool
	failures int
	retryAt  time.Time
	// notRun is the reason last recorded for not being able to start a run.
	notRun string
	warned string
	// The last-result file is lastBody plus, for 24 h after a run that
	// re-recorded trust, the recorded line.
	lastBody   string
	recorded   string
	recordedAt time.Time
}

func newAutoTrust(home string, logger *log.Logger) *autoTrust {
	codexHome := os.Getenv("CODEX_HOME")
	if codexHome == "" {
		codexHome = filepath.Join(os.Getenv("HOME"), ".codex")
	}
	return &autoTrust{
		home: home, codexHome: codexHome, logger: logger, now: time.Now,
		locate: locateKhalaCodex, deadline: autoTrustDeadline, backoff: autoTrustBackoff,
		results: make(chan autoTrustResult, 1),
	}
}

// locateKhalaCodex finds the adapter the way the SessionStart hook does — PATH
// first, then ~/.local/bin — on the recorded PATH, not the service's own.
func locateKhalaCodex(path string) (string, error) {
	dirs := filepath.SplitList(path)
	if home := os.Getenv("HOME"); home != "" {
		dirs = append(dirs, filepath.Join(home, ".local", "bin"))
	}
	for _, dir := range dirs {
		if !filepath.IsAbs(dir) {
			continue
		}
		candidate := filepath.Join(dir, "khala-codex")
		if info, err := os.Stat(candidate); err == nil && info.Mode().IsRegular() && info.Mode()&0111 != 0 {
			return candidate, nil
		}
	}
	return "", errors.New("khala-codex not found on the recorded PATH or in ~/.local/bin")
}

// recordedPath is the PATH written when automatic recovery was enabled; ""
// when the file is absent, empty or unreadable.
func (a *autoTrust) recordedPath() string {
	data, err := readRegularBytes(filepath.Join(a.home, "codex-auto-trust.path"), 1<<16)
	if err != nil {
		if !os.IsNotExist(err) {
			a.warn(fmt.Sprintf("cannot read codex-auto-trust.path: %v", err))
		}
		return ""
	}
	line, _, _ := strings.Cut(string(data), "\n")
	return strings.TrimSpace(line)
}

func (a *autoTrust) lastPath() string {
	return filepath.Join(a.home, "run", "codex-auto-trust.last")
}

// warn logs a standing condition once, not on every tick.
func (a *autoTrust) warn(message string) {
	if message != a.warned {
		a.warned = message
		a.logger.Printf("codex auto-trust: %s", message)
	}
}

// listed returns the opted-in plugin names. With the file absent this is the
// whole cost of the feature: one failed open per tick.
func (a *autoTrust) listed() []string {
	data, err := readRegularBytes(filepath.Join(a.home, "codex-auto-trust"), 1<<16)
	if err != nil {
		if !os.IsNotExist(err) {
			a.warn(fmt.Sprintf("cannot read the opt-in list (treated as off): %v", err))
		}
		return nil
	}
	var names []string
	for _, line := range strings.Split(string(data), "\n") {
		if name := strings.TrimSpace(line); name != "" {
			names = append(names, name)
		}
	}
	return names
}

// signature names what a marketplace refresh re-creates for the listed
// plugins: every <marketplace>/<plugin> directory under the cache and its
// <version> directories, with their mtimes. The list and the recorded PATH
// are part of it, so enabling again is a change too. Recording trust rewrites
// $CODEX_HOME/config.toml, which is outside it, so a run cannot trigger the
// next one.
func (a *autoTrust) signature(names []string, path string) (string, error) {
	var signature strings.Builder
	signature.WriteString(strings.Join(names, "\n") + "\n\n" + path + "\n\n")
	cache := filepath.Join(a.codexHome, "plugins", "cache")
	marketplaces, err := os.ReadDir(cache)
	if err != nil && !os.IsNotExist(err) {
		return "", err
	}
	for _, marketplace := range marketplaces {
		if !marketplace.IsDir() {
			continue
		}
		for _, name := range names {
			// A listed name is one directory name; anything else matches nothing.
			if name != filepath.Base(name) || name == "." || name == ".." {
				continue
			}
			plugin := filepath.Join(cache, marketplace.Name(), name)
			info, err := os.Lstat(plugin)
			if os.IsNotExist(err) || (err == nil && !info.IsDir()) {
				continue
			}
			if err != nil {
				return "", err
			}
			fmt.Fprintf(&signature, "%s/%s %d\n", marketplace.Name(), name, info.ModTime().UnixNano())
			versions, err := os.ReadDir(plugin)
			if err != nil {
				return "", err
			}
			for _, version := range versions {
				if !version.IsDir() {
					continue
				}
				info, err := version.Info()
				if err != nil {
					return "", err
				}
				fmt.Fprintf(&signature, "%s/%s/%s %d\n", marketplace.Name(), name, version.Name(), info.ModTime().UnixNano())
			}
		}
	}
	return signature.String(), nil
}

// tick starts a run when the signature differs from the one last handled and
// has held still since the previous tick (Codex may still be writing when a
// change is first seen), or when a failed run's retry is due.
func (a *autoTrust) tick(ctx context.Context) {
	names := a.listed()
	if len(names) == 0 {
		a.on, a.seen, a.handled, a.failures = false, "", "", 0
		return
	}
	now := a.now()
	if !a.on {
		a.on = true
		a.loadLast()
	}
	if a.recorded != "" && now.Sub(a.recordedAt) >= autoTrustAnnounce {
		a.recorded = ""
		a.writeLast()
	}
	path := a.recordedPath()
	signature, err := a.signature(names, path)
	if err != nil {
		a.warn(fmt.Sprintf("cannot read the Codex plugin cache: %v", err))
		return
	}
	if signature != a.seen {
		a.seen = signature
		return
	}
	if a.running {
		return
	}
	if signature != a.handled {
		a.handled, a.failures = signature, 0
	} else if a.failures == 0 || now.Before(a.retryAt) {
		return
	}
	bin, err := "", errors.New("no PATH recorded for the run (codex-auto-trust.path is missing or empty); "+
		"enable automatic recovery again: khala-codex auto-trust <plugins>")
	if path != "" {
		bin, err = a.locate(path)
	}
	if err != nil {
		// Retried on the backoff, but reported once per reason.
		a.failed(now)
		if reason := err.Error(); reason != a.notRun {
			a.notRun = reason
			a.record(autoTrustResult{at: now, exit: autoTrustExitNotRun, problems: []string{reason}})
		}
		return
	}
	a.notRun = ""
	a.running = true
	go func() { a.results <- a.execute(ctx, bin, path) }()
}

func (a *autoTrust) failed(now time.Time) {
	a.retryAt = now.Add(a.backoff[min(a.failures, len(a.backoff)-1)])
	a.failures++
}

func (a *autoTrust) finish(result autoTrustResult) {
	a.running = false
	if result.stopping {
		return
	}
	if result.exit == 0 {
		a.failures = 0
	} else {
		a.failed(a.now())
	}
	a.record(result)
}

// cappedBuffer keeps the first limit bytes and drops the rest.
type cappedBuffer struct {
	bytes.Buffer
	limit int
}

func (b *cappedBuffer) Write(data []byte) (int, error) {
	if room := b.limit - b.Len(); room > 0 {
		b.Buffer.Write(data[:min(room, len(data))])
	}
	return len(data), nil
}

func (a *autoTrust) execute(parent context.Context, bin, path string) autoTrustResult {
	ctx, cancel := context.WithTimeout(parent, a.deadline)
	defer cancel()
	stdout, stderr := &cappedBuffer{limit: 1 << 16}, &cappedBuffer{limit: 1 << 16}
	cmd := exec.CommandContext(ctx, bin, "auto-trust", "--run")
	cmd.Env = append(os.Environ(), "KHALA_HOME="+a.home, "CODEX_HOME="+a.codexHome, "PATH="+path)
	cmd.Stdout, cmd.Stderr = stdout, stderr
	// khala-codex starts a Codex app server; the deadline ends the whole group.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = 5 * time.Second
	err := cmd.Run()
	result := autoTrustResult{at: a.now()}
	for _, line := range strings.Split(stdout.String(), "\n") {
		fields := strings.Split(line, "\t")
		switch {
		case line == "":
		case len(fields) != 4:
			result.problems = append(result.problems, "unexpected output line: "+line)
		case fields[2] != fields[3]:
			result.changed = append(result.changed, [4]string(fields))
		}
	}
	for _, line := range strings.Split(stderr.String(), "\n") {
		if line = strings.TrimPrefix(line, "khala-codex: "); strings.TrimSpace(line) != "" {
			result.problems = append(result.problems, line)
		}
	}
	var exitErr *exec.ExitError
	switch {
	case parent.Err() != nil:
		result.stopping = true
	case ctx.Err() != nil:
		result.exit = autoTrustExitDeadline
		result.problems = append(result.problems, fmt.Sprintf("khala-codex auto-trust --run did not finish in %s", a.deadline))
	case err == nil:
	case errors.As(err, &exitErr) && exitErr.ExitCode() >= 0:
		result.exit = exitErr.ExitCode()
	default:
		result.exit = autoTrustExitNotRun
		result.problems = append(result.problems, err.Error())
	}
	return result
}

// autoTrustField makes text safe as one tab-separated field of the last-result
// file, which the SessionStart hook prints: no control characters, never empty.
func autoTrustField(value string) string {
	value = strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return ' '
		}
		return r
	}, strings.ToValidUTF8(value, "?"))
	if value = strings.TrimSpace(value); len(value) > 300 {
		value = strings.ToValidUTF8(value[:300], "") + "…"
	}
	if value == "" {
		return "-"
	}
	return value
}

// record logs the run in one line and replaces the last-result file:
//
//	time<TAB>epoch<TAB>local time
//	exit<TAB>code
//	changed<TAB>plugin<TAB>event<TAB>was<TAB>now    (per hook whose state changed)
//	error<TAB>text                                  (per problem)
//	recorded<TAB>epoch<TAB>local time<TAB>plugins   (latest run that re-recorded trust; kept 24 h)
func (a *autoTrust) record(result autoTrustResult) {
	const stamp = "2006-01-02 15:04"
	var body strings.Builder
	fmt.Fprintf(&body, "time\t%d\t%s\nexit\t%d\n", result.at.Unix(), result.at.Format(stamp), result.exit)
	var changes, plugins []string
	for _, hook := range result.changed[:min(len(result.changed), 100)] {
		for i := range hook {
			hook[i] = autoTrustField(hook[i])
		}
		fmt.Fprintf(&body, "changed\t%s\n", strings.Join(hook[:], "\t"))
		changes = append(changes, fmt.Sprintf("%s %s %s→%s", hook[0], hook[1], hook[2], hook[3]))
		if hook[3] == autoTrustTrusted && !slices.Contains(plugins, hook[0]) {
			plugins = append(plugins, hook[0])
		}
	}
	problems := result.problems[:min(len(result.problems), 20)]
	for i, problem := range problems {
		problems[i] = autoTrustField(problem)
		fmt.Fprintf(&body, "error\t%s\n", problems[i])
	}
	a.logger.Printf("codex auto-trust: exit=%d changed=[%s] problems=[%s]",
		result.exit, strings.Join(changes, "; "), strings.Join(problems, "; "))
	a.lastBody = body.String()
	if len(plugins) > 0 {
		a.recordedAt = result.at
		a.recorded = fmt.Sprintf("recorded\t%d\t%s\t%s\n", result.at.Unix(), result.at.Format(stamp), strings.Join(plugins, ", "))
	}
	a.writeLast()
}

func (a *autoTrust) writeLast() {
	if err := writeAtomicText(a.lastPath(), a.lastBody+a.recorded); err != nil {
		a.logger.Printf("codex auto-trust: write %s failed: %v", a.lastPath(), err)
	}
}

// loadLast restores the previous service's last result so that its recorded
// line still expires 24 h after the run it describes.
func (a *autoTrust) loadLast() {
	a.lastBody, a.recorded, a.recordedAt = "", "", time.Time{}
	data, err := readRegularBytes(a.lastPath(), 1<<20)
	if err != nil {
		if !os.IsNotExist(err) {
			a.logger.Printf("codex auto-trust: read %s failed: %v", a.lastPath(), err)
		}
		return
	}
	for _, line := range strings.SplitAfter(string(data), "\n") {
		fields := strings.Split(line, "\t")
		if fields[0] != "recorded" {
			a.lastBody += line
			continue
		}
		if epoch, err := strconv.ParseInt(fields[min(1, len(fields)-1)], 10, 64); err == nil && strings.HasSuffix(line, "\n") {
			a.recorded, a.recordedAt = line, time.Unix(epoch, 0)
		}
	}
}
