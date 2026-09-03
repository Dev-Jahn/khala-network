package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	earsReaderMaxBytes      = 128 << 10
	earsReaderMaxLines      = 320
	earsMaxRecordBytes      = 1024
	earsWriterMaxBytes      = 96 << 10
	earsWriterMaxIdentities = 256
)

var (
	earValuePattern      = regexp.MustCompile(`^[A-Za-z0-9._:+-]{1,64}$`)
	earGenerationPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)
)

type earsComponent struct {
	Name    string `json:"name"`
	Release string `json:"release"`
	Adapter string `json:"adapter"`
	Ears    string `json:"ears"`
}

type earsIdentity struct {
	Name            string `json:"name"`
	Principal       string `json:"principal"`
	Listening       bool   `json:"listening"`
	Route           string `json:"route"`
	Phase           string `json:"phase"`
	CCVersion       string `json:"cc"`
	Reason          string `json:"reason"`
	PendingRing     int    `json:"pendingRing"`
	PendingInfo     int    `json:"pendingInfo"`
	PendingOperator int    `json:"pendingOperator"`
	Generation      string `json:"generation"`
	FirstSeen       int64  `json:"firstSeen"`
	OldestPending   int64  `json:"oldestPending"`
	WrittenRings    int    `json:"writtenRings"`
	LastWritten     int64  `json:"lastWritten"`
	LastDrain       int64  `json:"lastDrain"`
	LastDrainBefore string `json:"lastDrainBefore"`
	LastDrainAfter  string `json:"lastDrainAfter"`
	LastDrainStatus string `json:"lastDrainStatus"`
}

type earsSnapshot struct {
	Node       string
	Generation int64
	WrittenAt  int64
	Interval   int64
	State      string
	Complete   bool
	Components []earsComponent
	Mailboxes  []string
	LinkAge    int64
	Identities []earsIdentity
	Truncated  int
}

type earsModel struct {
	Now        time.Time
	State      string
	LinkAge    int64
	Identities []earsIdentity
}

type earSidecar struct {
	Generation   string `json:"generation"`
	FirstSeen    int64  `json:"firstSeen"`
	WrittenRings int    `json:"writtenRings"`
	LastWritten  int64  `json:"lastWritten"`
}

type earDrainStamp struct {
	LastDrain       int64
	LastDrainBefore string
	LastDrainAfter  string
	LastDrainStatus string
}

func parseEars(path string) (earsSnapshot, error) {
	base := filepath.Base(path)
	node, ok := earSnapshotNode(base)
	if !ok {
		return earsSnapshot{}, fmt.Errorf("invalid ear filename %q", base)
	}
	f, err := openRegular(path)
	if err != nil {
		return earsSnapshot{}, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return earsSnapshot{}, err
	}
	if info.Size() > earsReaderMaxBytes {
		return earsSnapshot{}, fmt.Errorf("ear exceeds %d bytes", earsReaderMaxBytes)
	}
	data, err := io.ReadAll(io.LimitReader(f, earsReaderMaxBytes+1))
	if err != nil {
		return earsSnapshot{}, err
	}
	return parseEarsBytes(data, node)
}

func earSnapshotNode(base string) (string, bool) {
	if !strings.HasPrefix(base, "conduit@") || !strings.HasSuffix(base, ".ear") {
		return "", false
	}
	node := strings.TrimSuffix(strings.TrimPrefix(base, "conduit@"), ".ear")
	return node, validNode(node) && base == "conduit@"+node+".ear"
}

func parseEarsBytes(data []byte, filenameNode string) (earsSnapshot, error) {
	if len(data) > earsReaderMaxBytes {
		return earsSnapshot{}, fmt.Errorf("ear exceeds %d bytes", earsReaderMaxBytes)
	}
	lines := bytes.Split(data, []byte{'\n'})
	if len(lines) > 0 && len(lines[len(lines)-1]) == 0 {
		lines = lines[:len(lines)-1]
	}
	if len(lines) > earsReaderMaxLines {
		return earsSnapshot{}, fmt.Errorf("ear exceeds %d lines", earsReaderMaxLines)
	}
	if len(lines) == 0 || string(lines[0]) != "ears 1" {
		return earsSnapshot{}, fmt.Errorf("ear first line is not ears 1")
	}
	for _, line := range lines {
		if len(line) > earsMaxRecordBytes {
			return earsSnapshot{}, fmt.Errorf("ear record exceeds %d bytes", earsMaxRecordBytes)
		}
	}
	result := earsSnapshot{LinkAge: -1}
	seen := make(map[string]bool)
	identityNames := make(map[string]bool)
	truncatedIndex := -1
	for index, raw := range lines[1:] {
		fields := strings.Fields(string(raw))
		if len(fields) == 0 {
			continue
		}
		key := fields[0]
		single := func() error {
			if seen[key] {
				return fmt.Errorf("duplicate %s record", key)
			}
			seen[key] = true
			return nil
		}
		switch key {
		case "node":
			if err := single(); err != nil || len(fields) != 2 {
				return earsSnapshot{}, fmt.Errorf("duplicate or malformed node record")
			}
			result.Node = fields[1]
		case "generation":
			if err := single(); err != nil || len(fields) != 2 {
				return earsSnapshot{}, fmt.Errorf("duplicate or malformed generation record")
			}
			value, err := parseNonnegativeInt64(fields[1])
			if err != nil {
				return earsSnapshot{}, fmt.Errorf("invalid ear generation")
			}
			result.Generation = value
		case "written-at":
			if err := single(); err != nil || len(fields) != 2 {
				return earsSnapshot{}, fmt.Errorf("duplicate or malformed written-at record")
			}
			value, err := parseNonnegativeInt64(fields[1])
			if err != nil {
				return earsSnapshot{}, fmt.Errorf("invalid written-at")
			}
			result.WrittenAt = value
		case "interval":
			if err := single(); err != nil || len(fields) != 2 {
				return earsSnapshot{}, fmt.Errorf("duplicate or malformed interval record")
			}
			value, err := parseNonnegativeInt64(fields[1])
			if err != nil || value == 0 {
				return earsSnapshot{}, fmt.Errorf("invalid ear interval")
			}
			result.Interval = value
		case "state":
			if err := single(); err != nil || len(fields) != 2 || (fields[1] != "running" && fields[1] != "stopping") {
				return earsSnapshot{}, fmt.Errorf("duplicate or malformed state record")
			}
			result.State = fields[1]
		case "complete":
			if err := single(); err != nil || len(fields) != 2 || (fields[1] != "yes" && fields[1] != "no") {
				return earsSnapshot{}, fmt.Errorf("duplicate or malformed complete record")
			}
			result.Complete = fields[1] == "yes"
		case "component":
			component, err := parseEarComponent(fields)
			if err != nil {
				return earsSnapshot{}, err
			}
			result.Components = append(result.Components, component)
		case "mailbox":
			if err := single(); err != nil || len(fields) < 2 {
				return earsSnapshot{}, fmt.Errorf("duplicate or malformed mailbox record")
			}
			if len(fields) != 2 || fields[1] != "-" {
				for _, mailbox := range fields[1:] {
					if !validNode(mailbox) {
						return earsSnapshot{}, fmt.Errorf("invalid mailbox value")
					}
					result.Mailboxes = append(result.Mailboxes, mailbox)
				}
			}
		case "link":
			if err := single(); err != nil || len(fields) != 2 {
				return earsSnapshot{}, fmt.Errorf("duplicate or malformed link record")
			}
			if fields[1] != "-" {
				value, err := parseNonnegativeInt64(fields[1])
				if err != nil {
					return earsSnapshot{}, fmt.Errorf("invalid link age")
				}
				result.LinkAge = value
			}
		case "identity":
			identity, err := parseEarsIdentity(fields[1:])
			if err != nil {
				return earsSnapshot{}, err
			}
			if identityNames[identity.Name] {
				return earsSnapshot{}, fmt.Errorf("duplicate identity name %q", identity.Name)
			}
			identityNames[identity.Name] = true
			result.Identities = append(result.Identities, identity)
		case "truncated":
			if err := single(); err != nil || len(fields) != 2 {
				return earsSnapshot{}, fmt.Errorf("duplicate or malformed truncated record")
			}
			value, err := strconv.Atoi(fields[1])
			if err != nil || value < 0 {
				return earsSnapshot{}, fmt.Errorf("invalid truncated count")
			}
			result.Truncated = value
			truncatedIndex = index + 1
		default:
			// Unknown header records are forward-compatible.
		}
	}
	for _, mandatory := range []string{"node", "generation", "written-at", "interval", "state", "complete", "mailbox", "link"} {
		if !seen[mandatory] {
			return earsSnapshot{}, fmt.Errorf("ear is missing mandatory %s record", mandatory)
		}
	}
	if len(result.Components) == 0 {
		return earsSnapshot{}, fmt.Errorf("ear is missing mandatory component record")
	}
	if result.Node != filenameNode {
		return earsSnapshot{}, fmt.Errorf("ear node %q does not match filename node %q", result.Node, filenameNode)
	}
	if seen["truncated"] != !result.Complete || (seen["truncated"] && truncatedIndex != len(lines)-1) {
		return earsSnapshot{}, fmt.Errorf("truncated record does not match complete state or is not last")
	}
	return result, nil
}

func parseEarComponent(fields []string) (earsComponent, error) {
	if len(fields) < 2 || !validEarValue(fields[1]) {
		return earsComponent{}, fmt.Errorf("malformed component record")
	}
	values, err := parseEarKeyValues(fields[2:])
	if err != nil {
		return earsComponent{}, fmt.Errorf("malformed component record: %w", err)
	}
	return earsComponent{Name: fields[1], Release: values["release"], Adapter: values["adapter"], Ears: values["ears"]}, nil
}

func parseEarsIdentity(fields []string) (earsIdentity, error) {
	values, err := parseEarKeyValues(fields)
	if err != nil {
		return earsIdentity{}, fmt.Errorf("malformed identity record: %w", err)
	}
	for _, key := range []string{"name", "principal", "listening", "route", "reason"} {
		if _, ok := values[key]; !ok {
			return earsIdentity{}, fmt.Errorf("identity record missing %s", key)
		}
	}
	identity := earsIdentity{Name: values["name"], Principal: values["principal"], Route: values["route"], Phase: valueOrDash(values["phase"]), CCVersion: valueOrDash(values["cc"]), Reason: values["reason"], Generation: valueOrDash(values["generation"]), LastDrainBefore: valueOrDash(values["last-drain-before"]), LastDrainAfter: valueOrDash(values["last-drain-after"]), LastDrainStatus: valueOrDash(values["last-drain-status"])}
	if values["listening"] != "yes" && values["listening"] != "no" {
		return earsIdentity{}, fmt.Errorf("invalid listening value")
	}
	identity.Listening = values["listening"] == "yes"
	if !oneOf(identity.Principal, "session", "watcher", "gateway") || !oneOf(identity.Route, "socket", "channel", "channel+socket", "none") || !oneOf(identity.Reason, "-", "noreg", "boot", "phase", "optin", "pid", "session", "socket", "registry", "lease") || !oneOf(identity.Phase, "ready", "starting", "-") || !oneOf(identity.LastDrainStatus, "ok", "partial", "-") {
		return earsIdentity{}, fmt.Errorf("invalid identity enum")
	}
	if identity.Listening && identity.Route == "none" || !identity.Listening && identity.Route != "none" {
		return earsIdentity{}, fmt.Errorf("identity listening and route disagree")
	}
	if identity.Generation != "-" && !earGenerationPattern.MatchString(identity.Generation) || identity.LastDrainBefore != "-" && !earGenerationPattern.MatchString(identity.LastDrainBefore) || identity.LastDrainAfter != "-" && !earGenerationPattern.MatchString(identity.LastDrainAfter) {
		return earsIdentity{}, fmt.Errorf("invalid identity generation")
	}
	for key, destination := range map[string]*int64{"first-seen": &identity.FirstSeen, "oldest-pending": &identity.OldestPending, "last-written": &identity.LastWritten, "last-drain": &identity.LastDrain} {
		if values[key] == "" {
			continue
		}
		value, err := parseNonnegativeInt64(values[key])
		if err != nil {
			return earsIdentity{}, fmt.Errorf("invalid identity %s", key)
		}
		*destination = value
	}
	for key, destination := range map[string]*int{"pending-ring": &identity.PendingRing, "pending-info": &identity.PendingInfo, "pending-operator": &identity.PendingOperator, "written-rings": &identity.WrittenRings} {
		if values[key] == "" {
			continue
		}
		value, err := strconv.Atoi(values[key])
		if err != nil || value < 0 {
			return earsIdentity{}, fmt.Errorf("invalid identity %s", key)
		}
		*destination = value
	}
	return identity, nil
}

func parseEarKeyValues(fields []string) (map[string]string, error) {
	values := make(map[string]string)
	for _, field := range fields {
		key, value, ok := strings.Cut(field, "=")
		if !ok || key == "" || !validEarValue(value) || values[key] != "" {
			return nil, fmt.Errorf("invalid or duplicate token %q", field)
		}
		values[key] = value
	}
	return values, nil
}

func formatEars(snapshot earsSnapshot) ([]byte, error) {
	if !validNode(snapshot.Node) || snapshot.Generation < 0 || snapshot.WrittenAt < 0 || snapshot.Interval <= 0 || !oneOf(snapshot.State, "running", "stopping") || len(snapshot.Components) == 0 {
		return nil, fmt.Errorf("invalid ear snapshot header")
	}
	identities := append([]earsIdentity(nil), snapshot.Identities...)
	sort.Slice(identities, func(i, j int) bool { return safeEarValue(identities[i].Name) < safeEarValue(identities[j].Name) })
	lines := make([]string, 0, len(identities))
	for _, identity := range identities {
		line, err := formatEarsIdentity(identity)
		if err != nil {
			return nil, err
		}
		if len(line)-1 > earsMaxRecordBytes {
			return nil, fmt.Errorf("identity record exceeds %d bytes", earsMaxRecordBytes)
		}
		lines = append(lines, line)
	}
	buildHeader := func(complete bool) string {
		var out strings.Builder
		fmt.Fprintf(&out, "ears 1\nnode %s\ngeneration %d\nwritten-at %d\ninterval %d\nstate %s\ncomplete %s\n", snapshot.Node, snapshot.Generation, snapshot.WrittenAt, snapshot.Interval, snapshot.State, yesNo(complete))
		for _, component := range snapshot.Components {
			fmt.Fprintf(&out, "component %s release=%s adapter=%s ears=%s\n", safeEarValue(component.Name), safeEarValue(component.Release), safeEarValue(component.Adapter), safeEarValue(component.Ears))
		}
		mailboxes := safeSortedUnique(snapshot.Mailboxes)
		if len(mailboxes) == 0 {
			mailboxes = []string{"-"}
		}
		fmt.Fprintf(&out, "mailbox %s\n", strings.Join(mailboxes, " "))
		link := "-"
		if snapshot.LinkAge >= 0 {
			link = strconv.FormatInt(snapshot.LinkAge, 10)
		}
		fmt.Fprintf(&out, "link %s\n", link)
		return out.String()
	}
	complete := len(lines) <= earsWriterMaxIdentities
	header := buildHeader(complete)
	if err := validateEarsRecordLengths(header); err != nil {
		return nil, err
	}
	if complete {
		total := len(header)
		for _, line := range lines {
			total += len(line)
		}
		complete = total <= earsWriterMaxBytes
	}
	if complete {
		return []byte(header + strings.Join(lines, "")), nil
	}
	header = buildHeader(false)
	if err := validateEarsRecordLengths(header); err != nil {
		return nil, err
	}
	var out strings.Builder
	out.WriteString(header)
	written := 0
	for written < len(lines) && written < earsWriterMaxIdentities {
		omittedAfter := len(lines) - written - 1
		trailer := fmt.Sprintf("truncated %d\n", omittedAfter)
		if out.Len()+len(lines[written])+len(trailer) > earsWriterMaxBytes {
			break
		}
		out.WriteString(lines[written])
		written++
	}
	omitted := len(lines) - written
	trailer := fmt.Sprintf("truncated %d\n", omitted)
	if out.Len()+len(trailer) > earsWriterMaxBytes {
		return nil, fmt.Errorf("ear header leaves no room for truncation record")
	}
	out.WriteString(trailer)
	return []byte(out.String()), nil
}

func validateEarsRecordLengths(text string) error {
	for _, line := range strings.Split(strings.TrimSuffix(text, "\n"), "\n") {
		if len(line) > earsMaxRecordBytes {
			return fmt.Errorf("ear record exceeds %d bytes", earsMaxRecordBytes)
		}
	}
	return nil
}

func formatEarsIdentity(identity earsIdentity) (string, error) {
	if !oneOf(identity.Principal, "session", "watcher", "gateway") || !oneOf(identity.Route, "socket", "channel", "channel+socket", "none") || !oneOf(identity.Phase, "ready", "starting", "-") || !oneOf(identity.Reason, "-", "noreg", "boot", "phase", "optin", "pid", "session", "socket", "registry", "lease") || !oneOf(identity.LastDrainStatus, "ok", "partial", "-") {
		return "", fmt.Errorf("invalid ear identity enums")
	}
	if identity.Listening && identity.Route == "none" || !identity.Listening && identity.Route != "none" || identity.PendingRing < 0 || identity.PendingInfo < 0 || identity.PendingOperator < 0 || identity.FirstSeen < 0 || identity.OldestPending < 0 || identity.WrittenRings < 0 || identity.LastWritten < 0 || identity.LastDrain < 0 {
		return "", fmt.Errorf("invalid ear identity state")
	}
	generation := safeEarGeneration(identity.Generation)
	before := safeEarGeneration(identity.LastDrainBefore)
	after := safeEarGeneration(identity.LastDrainAfter)
	return fmt.Sprintf("identity name=%s principal=%s listening=%s route=%s phase=%s cc=%s reason=%s pending-ring=%d pending-info=%d pending-operator=%d generation=%s first-seen=%d oldest-pending=%d written-rings=%d last-written=%d last-drain=%d last-drain-before=%s last-drain-after=%s last-drain-status=%s\n", safeEarValue(identity.Name), identity.Principal, yesNo(identity.Listening), identity.Route, identity.Phase, safeEarValue(identity.CCVersion), identity.Reason, identity.PendingRing, identity.PendingInfo, identity.PendingOperator, generation, identity.FirstSeen, identity.OldestPending, identity.WrittenRings, identity.LastWritten, identity.LastDrain, before, after, identity.LastDrainStatus), nil
}

func validEarValue(value string) bool { return earValuePattern.MatchString(value) }

func safeEarValue(value string) string {
	if !validEarValue(value) {
		return "-"
	}
	return value
}

func safeEarGeneration(value string) string {
	if value == "-" || earGenerationPattern.MatchString(value) {
		return value
	}
	return "-"
}

func safeSortedUnique(values []string) []string {
	set := make(map[string]bool)
	for _, value := range values {
		set[safeEarValue(value)] = true
	}
	result := make([]string, 0, len(set))
	for value := range set {
		result = append(result, value)
	}
	sort.Strings(result)
	return result
}

func valueOrDash(value string) string {
	if value == "" {
		return "-"
	}
	return value
}

func oneOf(value string, allowed ...string) bool {
	for _, candidate := range allowed {
		if value == candidate {
			return true
		}
	}
	return false
}

func parseNonnegativeInt64(value string) (int64, error) {
	parsed, err := strconv.ParseInt(value, 10, 64)
	if err != nil || parsed < 0 {
		return 0, fmt.Errorf("not a non-negative integer")
	}
	return parsed, nil
}

func earReason(reason string) (string, bool) {
	switch reason {
	case "boot id mismatch":
		return "boot", true
	case "phase is not ready":
		return "phase", true
	case "non-interactive registration lacks opt-in":
		return "optin", true
	case "pid/start mismatch":
		return "pid", true
	case "Claude session id is empty":
		return "session", true
	case "socket is not bound", "socket is missing or not a Unix socket", "socket uid mismatch":
		return "socket", true
	case "Claude registry pid/socket mismatch", "Claude registry session id mismatch":
		return "registry", true
	default:
		return "", false
	}
}

func readEarGeneration(path string) int64 {
	snapshot, err := parseEars(path)
	if err != nil {
		return 0
	}
	return snapshot.Generation
}

func (c *conduit) writeEars(model earsModel) error {
	if c.earInterval <= 0 {
		c.earInterval = 60 * time.Second
	}
	if model.Now.IsZero() {
		model.Now = time.Now()
	}
	if model.State == "" {
		model.State = "running"
	}
	cfg, err := loadConfig(c.home)
	if err != nil {
		return err
	}
	c.earMailboxes = append(c.earMailboxes[:0], cfg.mailboxes...)
	if !cfg.earsEnabled {
		c.earMu.Lock()
		alreadySuppressed := c.earSuppressed
		c.earSuppressed = true
		c.earMu.Unlock()
		if alreadySuppressed {
			return nil
		}
		model.State = "stopping"
		model.Identities = nil
	} else {
		c.earMu.Lock()
		c.earSuppressed = false
		c.earMu.Unlock()
	}
	generation, err := c.nextEarGeneration(model.Now)
	if err != nil {
		return err
	}
	mailboxes := append([]string(nil), c.earMailboxes...)
	if len(mailboxes) == 1 && mailboxes[0] == c.self {
		mailboxes = nil
	}
	snapshot := earsSnapshot{Node: c.self, Generation: generation, WrittenAt: model.Now.Unix(), Interval: int64(c.earInterval / time.Second), State: model.State, Components: []earsComponent{{Name: "conduit", Release: linkVersion, Adapter: conduitAdapterVersion, Ears: "1"}}, Mailboxes: mailboxes, LinkAge: model.LinkAge, Identities: append([]earsIdentity(nil), model.Identities...)}
	data, err := formatEars(snapshot)
	if err != nil {
		return err
	}
	path := filepath.Join(c.home, "presence", "conduit@"+c.self+".ear")
	if err := writeEarAtomic(c.home, path, data); err != nil {
		return err
	}
	c.earMu.Lock()
	c.earGeneration = generation
	c.earLastWrite = model.Now
	c.earLastSignature = earsListeningSignature(model.Identities)
	c.earForceWrite = false
	c.earMu.Unlock()
	return nil
}

func (c *conduit) earWriteDelay() time.Duration {
	c.earMu.Lock()
	defer c.earMu.Unlock()
	if c.earLastWrite.IsZero() {
		return 0
	}
	remaining := time.Second - time.Since(c.earLastWrite)
	if remaining < 0 {
		return 0
	}
	return remaining
}

func (c *conduit) waitEarWriteSlot() {
	if wait := c.earWriteDelay(); wait > 0 {
		time.Sleep(wait)
	}
}

func (c *conduit) nextEarGeneration(now time.Time) (int64, error) {
	own := readEarGeneration(filepath.Join(c.home, "presence", "conduit@"+c.self+".ear"))
	runtimeGeneration := readGenerationState(filepath.Join(c.runtime, "ears", "generation"))
	next := now.Unix()
	for _, current := range []int64{own, runtimeGeneration} {
		if current >= next {
			if current == math.MaxInt64 {
				return 0, fmt.Errorf("ear generation cannot advance past %d", current)
			}
			next = current + 1
		}
	}
	if err := writeAtomicText(filepath.Join(c.runtime, "ears", "generation"), strconv.FormatInt(next, 10)+"\n"); err != nil {
		return 0, err
	}
	return next, nil
}

func readGenerationState(path string) int64 {
	data, err := readRegularBytes(path, 65)
	if err != nil || len(data) > 64 {
		return 0
	}
	value, err := parseNonnegativeInt64(strings.TrimSpace(string(data)))
	if err != nil {
		return 0
	}
	return value
}

func writeAtomicText(path, value string) error {
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
	if err := f.Chmod(0600); err != nil {
		return err
	}
	if _, err := io.WriteString(f, value); err != nil {
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
	if err := syncDir(dir); err != nil {
		return err
	}
	ok = true
	return nil
}

func earsListeningSignature(identities []earsIdentity) string {
	ordered := append([]earsIdentity(nil), identities...)
	sort.Slice(ordered, func(i, j int) bool { return ordered[i].Name < ordered[j].Name })
	var signature strings.Builder
	for _, identity := range ordered {
		fmt.Fprintf(&signature, "%s\x00%t\x00%s\x00%s\n", identity.Name, identity.Listening, identity.Route, identity.Reason)
	}
	return signature.String()
}

func loadEarLeases(root, bootID string) (map[string]identityLease, error) {
	entries, err := os.ReadDir(filepath.Join(root, "identities"))
	if err != nil {
		return nil, err
	}
	leases := make(map[string]identityLease)
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".lease") {
			continue
		}
		identity := strings.TrimSuffix(entry.Name(), ".lease")
		if !validNode(identity) {
			continue
		}
		var lease identityLease
		if readJSON(filepath.Join(root, "identities", entry.Name()), &lease) == nil && lease.BootID == bootID && lease.Identity == identity {
			leases[identity] = lease
		}
	}
	return leases, nil
}

func (c *conduit) buildEarsModel(registrations map[string]sessionRegistration, leases map[string]identityLease, now time.Time, state string) (earsModel, error) {
	identities, err := c.buildEarIdentities(registrations, leases)
	if err != nil {
		return earsModel{}, err
	}
	return earsModel{Now: now, State: state, LinkAge: linkFreshAge(c.home, now), Identities: identities}, nil
}

func (c *conduit) captureEarsModel(state string) (earsModel, error) {
	registrations, err := loadRegistrations(c.runtime, c.bootID)
	if err != nil {
		return earsModel{}, err
	}
	leases, err := loadEarLeases(c.runtime, c.bootID)
	if err != nil {
		return earsModel{}, err
	}
	return c.buildEarsModel(registrations, leases, time.Now(), state)
}

func (c *conduit) buildEarIdentities(registrations map[string]sessionRegistration, leases map[string]identityLease) ([]earsIdentity, error) {
	byIdentity := make(map[string][]sessionRegistration)
	for _, registration := range registrations {
		byIdentity[registration.Identity] = append(byIdentity[registration.Identity], registration)
	}
	set := make(map[string]bool)
	for identity := range byIdentity {
		set[identity] = true
	}
	for identity, lease := range leases {
		if lease.State == "owned" {
			set[identity] = true
		}
	}
	names := make([]string, 0, len(set))
	for identity := range set {
		names = append(names, identity)
	}
	sort.Strings(names)
	result := make([]earsIdentity, 0, len(names))
	for _, identity := range names {
		row, err := c.buildEarIdentity(identity, byIdentity[identity], leases[identity])
		if err != nil {
			return nil, err
		}
		result = append(result, row)
	}
	return result, nil
}

func (c *conduit) buildEarIdentityBase(identity string, registrations []sessionRegistration, lease identityLease) (earsIdentity, error) {
	selected := sessionRegistration{}
	owned := lease.State == "owned" && lease.InstanceID != ""
	if owned {
		for _, registration := range registrations {
			if registration.InstanceID == lease.InstanceID {
				selected = registration
				break
			}
		}
	}
	selectedOwned := selected.InstanceID != ""
	if !selectedOwned && len(registrations) > 0 {
		sortRegistrationsForReclaim(registrations)
		selected = registrations[0]
	}
	row := earsIdentity{Name: identity, Principal: "session", Route: "none", Phase: "-", CCVersion: "-", Reason: "noreg", Generation: "-", LastDrainBefore: "-", LastDrainAfter: "-", LastDrainStatus: "-"}
	if selected.InstanceID != "" {
		row.Phase = valueOrDash(selected.Phase)
		row.CCVersion = valueOrDash(selected.CCVersion)
		switch {
		case !selectedOwned:
			row.Reason = "lease"
		case !selected.ConduitVerified:
			mapped, ok := earReason(c.verificationReasons[selected.InstanceID])
			if !ok {
				return earsIdentity{}, fmt.Errorf("registration %s has unmapped verification reason %q", selected.InstanceID, c.verificationReasons[selected.InstanceID])
			}
			row.Reason = mapped
		case !registrationRingReady(selected, lease):
			row.Reason = "lease"
		default:
			row.Listening = true
			row.Reason = "-"
			switch {
			case selected.ChannelSocket != "" && selected.ChannelVerified:
				row.Route = "channel"
			case selected.ChannelSocket != "":
				row.Route = "channel+socket"
			default:
				row.Route = "socket"
			}
		}
	}
	return row, nil
}

func (c *conduit) buildEarIdentity(identity string, registrations []sessionRegistration, lease identityLease) (earsIdentity, error) {
	row, err := c.buildEarIdentityBase(identity, registrations, lease)
	if err != nil {
		return earsIdentity{}, err
	}
	letters := c.pendingForSnapshot(identity)
	mail, notices, urgent := letterCounts(letters)
	row.PendingRing = mail + urgent
	row.PendingInfo = notices - urgent
	if row.PendingRing > 0 {
		row.Generation = letterGeneration(letters)
		for _, letter := range ringLetters(letters) {
			if letter.installedAt > 0 && (row.OldestPending == 0 || letter.installedAt < row.OldestPending) {
				row.OldestPending = letter.installedAt
			}
		}
		if sidecar, err := c.readEarSidecar(identity); err == nil && sidecar.Generation == row.Generation {
			row.FirstSeen, row.WrittenRings = sidecar.FirstSeen, sidecar.WrittenRings
			row.LastWritten = sidecar.LastWritten
		} else if err != nil && !os.IsNotExist(err) {
			return earsIdentity{}, err
		}
	} else if sidecar, err := c.readEarSidecar(identity); err == nil {
		row.LastWritten = sidecar.LastWritten
	} else if err != nil && !os.IsNotExist(err) {
		return earsIdentity{}, err
	}
	drain := c.readDrainStamp(identity)
	row.LastDrain, row.LastDrainBefore, row.LastDrainAfter, row.LastDrainStatus = drain.LastDrain, drain.LastDrainBefore, drain.LastDrainAfter, drain.LastDrainStatus
	return row, nil
}

func sortRegistrationsForReclaim(registrations []sessionRegistration) {
	sort.Slice(registrations, func(i, j int) bool {
		left, leftErr := time.Parse(time.RFC3339Nano, registrations[i].StartedAt)
		right, rightErr := time.Parse(time.RFC3339Nano, registrations[j].StartedAt)
		if leftErr == nil && rightErr == nil && !left.Equal(right) {
			return left.After(right)
		}
		if leftErr == nil && rightErr != nil {
			return true
		}
		if leftErr != nil && rightErr == nil {
			return false
		}
		if registrations[i].StartedAt != registrations[j].StartedAt {
			return registrations[i].StartedAt > registrations[j].StartedAt
		}
		return registrations[i].InstanceID < registrations[j].InstanceID
	})
}

func registrationRingReady(registration sessionRegistration, lease identityLease) bool {
	return registration.ConduitVerified && registration.Phase == "ready" && lease.State == "owned" && lease.InstanceID == registration.InstanceID && lease.Epoch > 0 && lease.Epoch == registration.LeaseEpoch && lease.PID == registration.PID && lease.PIDStart == registration.PIDStart && lease.ClaudeSessionID == registration.ClaudeSessionID
}

func (c *conduit) readEarSidecar(identity string) (earSidecar, error) {
	data, err := readRegularBytes(filepath.Join(c.runtime, "ears", identity+".json"), 4097)
	if err != nil {
		return earSidecar{}, err
	}
	if len(data) > 4096 {
		return earSidecar{}, fmt.Errorf("ear sidecar too large")
	}
	var sidecar earSidecar
	if err := json.Unmarshal(data, &sidecar); err != nil || (sidecar.Generation != "" && !earGenerationPattern.MatchString(sidecar.Generation)) || sidecar.FirstSeen < 0 || sidecar.WrittenRings < 0 || sidecar.LastWritten < 0 {
		return earSidecar{}, fmt.Errorf("invalid ear sidecar for %s", identity)
	}
	return sidecar, nil
}

func (c *conduit) writeEarSidecar(identity string, state conduitState) error {
	if !validNode(identity) || state.generation == "" || !earGenerationPattern.MatchString(state.generation) {
		return fmt.Errorf("invalid ear sidecar identity or generation")
	}
	firstSeen, lastWritten := int64(0), int64(0)
	if !state.firstSeen.IsZero() {
		firstSeen = state.firstSeen.Unix()
	}
	if !state.lastWritten.IsZero() {
		lastWritten = state.lastWritten.Unix()
	}
	return writeAtomicJSON(filepath.Join(c.runtime, "ears", identity+".json"), earSidecar{Generation: state.generation, FirstSeen: firstSeen, WrittenRings: state.writtenRings, LastWritten: lastWritten}, 0600)
}

func (c *conduit) readDrainStamp(identity string) earDrainStamp {
	result := earDrainStamp{LastDrainBefore: "-", LastDrainAfter: "-", LastDrainStatus: "-"}
	data, err := readRegularBytes(filepath.Join(c.home, "run", "drained", identity), 4097)
	if err != nil {
		if os.IsNotExist(err) {
			return result
		}
		return c.malformedDrain(identity, result)
	}
	fields := strings.Fields(string(data))
	if len(data) > 4096 || len(fields) != 9 || fields[0] != "drain" || fields[1] != "1" || !oneOf(fields[8], "ok", "partial") || (fields[3] != "-" && !earGenerationPattern.MatchString(fields[3])) || (fields[4] != "-" && !earGenerationPattern.MatchString(fields[4])) {
		return c.malformedDrain(identity, result)
	}
	for _, value := range fields[5:8] {
		if _, err := parseNonnegativeInt64(value); err != nil {
			return c.malformedDrain(identity, result)
		}
	}
	at, err := parseNonnegativeInt64(fields[2])
	if err != nil {
		return c.malformedDrain(identity, result)
	}
	result.LastDrain, result.LastDrainBefore, result.LastDrainAfter, result.LastDrainStatus = at, fields[3], fields[4], fields[8]
	return result
}

func (c *conduit) malformedDrain(identity string, result earDrainStamp) earDrainStamp {
	if c.drainedWarned == nil {
		c.drainedWarned = make(map[string]bool)
	}
	if !c.drainedWarned[identity] && c.logger != nil {
		c.logger.Printf("malformed drained stamp ignored: %s", identity)
		c.drainedWarned[identity] = true
	}
	return result
}

func linkFreshAge(home string, now time.Time) int64 {
	info, err := os.Lstat(filepath.Join(home, "run", "link.fresh"))
	if err != nil || !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
		return -1
	}
	age := int64(now.Sub(info.ModTime()) / time.Second)
	if age < 0 {
		return 0
	}
	return age
}

func writeEarAtomic(home, destination string, data []byte) error {
	tmpDir := filepath.Join(home, "tmp")
	if err := os.MkdirAll(tmpDir, 0700); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(destination), 0700); err != nil {
		return err
	}
	f, err := os.CreateTemp(tmpDir, "ear.*")
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
	if err := f.Chmod(0600); err != nil {
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
	if err := os.Rename(tmp, destination); err != nil {
		return err
	}
	if err := syncDir(filepath.Dir(destination)); err != nil {
		return err
	}
	ok = true
	return nil
}
