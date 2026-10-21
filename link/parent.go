package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// A parent is the session that launched an identity — for a codex lane, the
// main session that dispatched it (D18 §4.3). A lane cannot hear once its run
// has ended, so letters that reach it afterwards would wait unseen; the conduit
// tells the parent about them instead.

// parentNoticeGrace is how long an identity must have been waiting — no live
// registration, and a letter its parent has not heard about — before the
// parent hears about it. A lane resumed right after it ended (`codex exec
// resume`, a dispatcher's next round) registers again within seconds, and a
// parent that answers a report and then resumes the lane takes about a turn;
// two minutes covers both, while still telling the parent within minutes
// rather than the hours such letters sat unread before (D18 §1).
const parentNoticeGrace = 2 * time.Minute

// parentNoticeTTL matches `khala notify`'s default lifetime for a notice.
const parentNoticeTTL = 48 * time.Hour

func parentRecordPath(home, identity string) string {
	return filepath.Join(home, "parents", identity)
}

// validateParent checks a parent address for identity on node self: a full
// <identity>@<node> under the khala name rules, not a reserved name, and not
// the identity itself.
func validateParent(parent, identity, self string) error {
	name, node, ok := strings.Cut(parent, "@")
	if !ok || !validNode(name) || !validNode(node) {
		return fmt.Errorf("invalid parent %q: want <identity>@<node>", parent)
	}
	if isReservedIdentity(name) {
		return fmt.Errorf("invalid parent %q: reserved identity", parent)
	}
	if name == identity && node == self {
		return fmt.Errorf("invalid parent %q: an identity cannot be its own parent", parent)
	}
	return nil
}

// readParentRecord returns the recorded parent address, or "" when there is
// none or the record does not hold one valid address.
func readParentRecord(home, identity string) string {
	f, err := openRegular(parentRecordPath(home, identity))
	if err != nil {
		return ""
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, 257))
	if err != nil || len(data) > 256 {
		return ""
	}
	parent, ok := strings.CutSuffix(string(data), "\n")
	name, node, found := strings.Cut(parent, "@")
	if !ok || !found || !validNode(name) || !validNode(node) {
		return ""
	}
	return parent
}

// recordParent stores parent for identity as one line, written atomically and
// only when it differs from what is already recorded. The record lives in the
// khala home, so it outlives lease release and reboot.
func recordParent(home, identity, parent string) error {
	if readParentRecord(home, identity) == parent {
		return nil
	}
	return writeAtomicText(parentRecordPath(home, identity), parent+"\n")
}

// registrationLive: the registered process is running (same pid and start
// time), or the registration is under 30 s old and has no pid yet.
func registrationLive(reg sessionRegistration, bootID string) bool {
	if processAliveWithStart(reg.PID, reg.PIDStart, bootID) {
		return true
	}
	started, err := time.Parse(time.RFC3339Nano, reg.StartedAt)
	return err == nil && reg.PID <= 1 && time.Since(started) < 30*time.Second
}

func parentNoticePath(home, identity string) string {
	return filepath.Join(home, "run", "parent-notices", identity)
}

// readParentNoticed returns the letter Ids the last parent notice for identity
// covered, from run/parent-notices/<identity>: a header line, then one Id per
// line. A restarted conduit reads it so it does not tell the parent again.
//
//	notice 1 <epoch> <notice-id> <parent>
//	<letter-id>
func readParentNoticed(home, identity string) map[string]bool {
	covered := make(map[string]bool)
	f, err := openRegular(parentNoticePath(home, identity))
	if err != nil {
		return covered
	}
	defer f.Close()
	scanner := bufio.NewScanner(io.LimitReader(f, 1<<20))
	if !scanner.Scan() || !strings.HasPrefix(scanner.Text(), "notice 1 ") {
		return covered
	}
	for scanner.Scan() {
		if id := scanner.Text(); validBasename(id) {
			covered[id] = true
		}
	}
	return covered
}

func writeParentNoticed(home, identity, noticeID, parent string, at time.Time, letters []pendingMessage) error {
	var b strings.Builder
	fmt.Fprintf(&b, "notice 1 %d %s %s\n", at.Unix(), noticeID, parent)
	for _, letter := range letters {
		b.WriteString(letter.id + "\n")
	}
	return writeAtomicText(parentNoticePath(home, identity), b.String())
}

// noticeParents sends each parent at most one notice per pending set. An
// identity is waiting when it has a parent record, unread letters (notices do
// not count, so a parent notice never cascades to a grandparent), no live
// registration — a Codex worker that is never rung counts as live — and a
// letter the last notice did not cover. Once it has been waiting for the grace
// period, one urgent notice from conduit@<self> goes to the parent and covers
// every letter then unread.
func (c *notifier) noticeParents(regs map[string]sessionRegistration) {
	if c.parentWaiting == nil {
		c.parentWaiting = make(map[string]time.Time)
		c.parentNoticed = make(map[string]map[string]bool)
		c.parentNoticeErr = make(map[string]string)
	}
	entries, _ := os.ReadDir(filepath.Join(c.home, "parents"))
	waiting := make(map[string]bool)
	for _, entry := range entries {
		identity := entry.Name()
		if !entry.Type().IsRegular() || !validNode(identity) || isReservedIdentity(identity) {
			continue
		}
		letters := unreadLetters(c.readPending(identity, true))
		if len(letters) == 0 {
			continue
		}
		covered, loaded := c.parentNoticed[identity]
		if !loaded {
			covered = readParentNoticed(c.home, identity)
			c.parentNoticed[identity] = covered
		}
		if !hasUncovered(letters, covered) {
			continue
		}
		parent := readParentRecord(c.home, identity)
		if parent == "" || identityLive(regs, identity, c.bootID) {
			continue
		}
		waiting[identity] = true
		c.maybeNoticeParent(identity, parent, letters)
	}
	for identity := range c.parentWaiting {
		if !waiting[identity] {
			delete(c.parentWaiting, identity)
		}
	}
}

func unreadLetters(messages []pendingMessage) []pendingMessage {
	letters := make([]pendingMessage, 0, len(messages))
	for _, messageItem := range messages {
		if !messageItem.alert {
			letters = append(letters, messageItem)
		}
	}
	return letters
}

func hasUncovered(letters []pendingMessage, covered map[string]bool) bool {
	for _, letter := range letters {
		if !covered[letter.id] {
			return true
		}
	}
	return false
}

func identityLive(regs map[string]sessionRegistration, identity, bootID string) bool {
	for _, reg := range regs {
		if reg.Identity == identity && registrationLive(reg, bootID) {
			return true
		}
	}
	return false
}

func (c *notifier) maybeNoticeParent(identity, parent string, letters []pendingMessage) {
	now := time.Now()
	since, seen := c.parentWaiting[identity]
	if !seen {
		c.parentWaiting[identity] = now
		since = now
	}
	if now.Sub(since) < c.parentNoticeDelay() {
		return
	}
	oldest, newest := letters[0].installedAt, letters[0].installedAt
	for _, letter := range letters {
		oldest = min(oldest, letter.installedAt)
		newest = max(newest, letter.installedAt)
	}
	noticeID := parentNoticeID(c.self, newest, now, letters)
	if err := c.queueParentNotice(identity, parent, noticeID, len(letters), now.Sub(time.Unix(oldest, 0)), now); err != nil {
		if c.parentNoticeErr[identity] != err.Error() {
			c.logger.Printf("parent notice %s -> %s failed: %v", identity, parent, err)
			c.parentNoticeErr[identity] = err.Error()
		}
		return
	}
	delete(c.parentNoticeErr, identity)
	delete(c.parentWaiting, identity)
	covered := make(map[string]bool, len(letters))
	for _, letter := range letters {
		covered[letter.id] = true
	}
	c.parentNoticed[identity] = covered
	if err := writeParentNoticed(c.home, identity, noticeID, parent, now, letters); err != nil {
		c.logger.Printf("record parent notice %s failed: %v", identity, err)
	}
	c.logger.Printf("parent notice %s -> %s: %d unread, no live registration (%s)", identity, parent, len(letters), noticeID)
}

func (c *notifier) parentNoticeDelay() time.Duration {
	if c.parentGrace > 0 {
		return c.parentGrace
	}
	return parentNoticeGrace
}

// parentNoticeID is derived from the covered letters, so a conduit that dies
// between queueing a notice and recording it queues the same Id again and the
// receiving node's Id dedup absorbs the copy.
func parentNoticeID(self string, newest int64, now time.Time, letters []pendingMessage) string {
	ids := make([]string, 0, len(letters))
	for _, letter := range letters {
		ids = append(ids, letter.id)
	}
	sort.Strings(ids)
	sum := sha256.Sum256([]byte(strings.Join(ids, "\n")))
	if newest <= 0 {
		newest = now.Unix()
	}
	return fmt.Sprintf("%d.0.%d.conduit@%s", newest, binary.BigEndian.Uint32(sum[:4]), self)
}

// queueParentNotice writes one urgent notice into spool/for/<parent node>/ in
// the format `khala notify` writes, without clobbering a copy already queued.
// A notice for this node also leaves run/reconcile.trigger, as notify does, so
// the relay's reconcile delivers it now.
func (c *notifier) queueParentNotice(identity, parent, noticeID string, unreadCount int, oldestAge time.Duration, now time.Time) error {
	node := parent[strings.LastIndex(parent, "@")+1:]
	address := identity + "@" + c.self
	unread := "1 unread letter"
	if unreadCount != 1 {
		unread = strconv.Itoa(unreadCount) + " unread letters"
	}
	var b strings.Builder
	fmt.Fprintf(&b, "Khala: 0.1\nId: %s\nFrom: conduit@%s\nTo: %s\nDate: %s\nType: notice\nUrgency: urgent\n",
		noticeID, c.self, parent, now.UTC().Format("2006-01-02T15:04:05Z"))
	fmt.Fprintf(&b, "Subject: %s has %s and no live session\nExpires: %d\n\n", address, unread, now.Add(parentNoticeTTL).Unix())
	fmt.Fprintf(&b, "%s has %s (oldest %s) and no live session.\n", address, unread, shortAge(oldestAge))
	fmt.Fprintf(&b, "Read them: khala inbox list --as %s, then khala inbox read <Id> --as %s;\n", identity, identity)
	fmt.Fprintf(&b, "mark the ones you handled with khala inbox ack-read --as %s <Id>...\n", identity)
	b.WriteString("Or resume the lane: it receives them when it starts.\n")

	spool := filepath.Join(c.home, "spool", "for", node)
	if err := os.MkdirAll(spool, 0700); err != nil {
		return err
	}
	tmpDir := filepath.Join(c.home, "tmp")
	if err := os.MkdirAll(tmpDir, 0700); err != nil {
		return err
	}
	f, err := os.CreateTemp(tmpDir, "parent-notice.")
	if err != nil {
		return err
	}
	tmp := f.Name()
	defer os.Remove(tmp)
	if _, err := io.WriteString(f, b.String()); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if err := os.Link(tmp, filepath.Join(spool, noticeID)); err != nil && !errors.Is(err, os.ErrExist) {
		return err
	}
	if node == c.self {
		if err := (&coreCLI{home: c.home}).writeTrigger(); err != nil {
			c.logger.Printf("parent notice %s: write reconcile trigger failed: %v", identity, err)
		}
	}
	return nil
}

// shortAge renders a duration the way a person reads an age: 45s, 14m, 3h, 2d.
func shortAge(d time.Duration) string {
	switch {
	case d < time.Minute:
		return strconv.Itoa(int(max(d, 0)/time.Second)) + "s"
	case d < time.Hour:
		return strconv.Itoa(int(d/time.Minute)) + "m"
	case d < 48*time.Hour:
		return strconv.Itoa(int(d/time.Hour)) + "h"
	}
	return strconv.Itoa(int(d/(24*time.Hour))) + "d"
}
