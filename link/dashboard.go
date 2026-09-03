package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"embed"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

//go:embed dashboard/index.html dashboard/app.js dashboard/app.css
var dashboardAssets embed.FS

const (
	dashboardMaxRows       = 512
	dashboardLetterRows    = 50
	dashboardStreamRows    = 20
	dashboardLetterBodyMax = 256 << 10
	dashboardStreamBodyMax = 64 << 10
	dashboardTruncated     = "\n[truncated]\n"
)

type dashboardOptions struct {
	listen   string
	token    string
	withText bool
}

type dashboardFleet struct {
	APIVersion  int                `json:"apiVersion"`
	Nodes       []dashboardNode    `json:"nodes"`
	Sessions    []dashboardSession `json:"sessions"`
	Watchers    []dashboardWatcher `json:"watchers"`
	Streams     []dashboardStream  `json:"streams"`
	Letters     []dashboardLetter  `json:"letters,omitempty"`
	Self        dashboardSelf      `json:"self"`
	GeneratedAt int64              `json:"generatedAt"`
}

type dashboardNode struct {
	Node         string          `json:"node"`
	Hub          bool            `json:"hub"`
	State        string          `json:"state"`
	SnapshotAge  *int64          `json:"snapshotAge"`
	WrittenAt    *int64          `json:"writtenAt"`
	Skew         *int64          `json:"skew"`
	Complete     *bool           `json:"complete"`
	Components   []earsComponent `json:"components"`
	Capabilities []string        `json:"capabilities"`
	Gateway      any             `json:"gateway"`
	Mailbox      []string        `json:"mailbox"`
	LinkAge      *int64          `json:"linkAge"`
	Identities   []earsIdentity  `json:"identities"`
	Progressing  bool            `json:"progressing"`
}

type dashboardPending struct {
	Ring     int `json:"ring"`
	Info     int `json:"info"`
	Operator int `json:"operator"`
}

type dashboardSession struct {
	Address         string           `json:"address"`
	PrincipalType   string           `json:"principalType"`
	State           string           `json:"state"`
	LastSeen        int64            `json:"lastSeen"`
	Listening       bool             `json:"listening"`
	Route           string           `json:"route"`
	Reason          string           `json:"reason"`
	Model           string           `json:"model"`
	Effort          string           `json:"effort"`
	Role            string           `json:"role"`
	Charge          string           `json:"charge"`
	Freshness       string           `json:"freshness"`
	PendingByClass  dashboardPending `json:"pendingByClass"`
	PendingState    string           `json:"pendingState"`
	OldestPendingAt int64            `json:"oldestPendingAt"`
	Focus           string           `json:"focus,omitempty"`
	Stance          string           `json:"stance,omitempty"`
}

type dashboardWatcher struct {
	Name    string `json:"name"`
	Node    string `json:"node"`
	Owner   string `json:"owner"`
	Cadence int64  `json:"cadence"`
	Last    int64  `json:"last"`
	State   string `json:"state"`
	Since   *int64 `json:"since"`
}

type dashboardStream struct {
	Name        string                 `json:"name"`
	Entries     int                    `json:"entries"`
	Latest      string                 `json:"latest"`
	LocalUnread map[string]int         `json:"localUnread"`
	Recent      []dashboardStreamEntry `json:"recent,omitempty"`
}

type dashboardStreamEntry struct {
	ID      string `json:"id"`
	From    string `json:"from"`
	Date    string `json:"date"`
	Subject string `json:"subject"`
	Body    string `json:"body"`
}

type dashboardLetter struct {
	Identity     string `json:"identity"`
	ID           string `json:"id"`
	From         string `json:"from"`
	Date         string `json:"date"`
	Type         string `json:"type"`
	Urgency      string `json:"urgency"`
	Subject      string `json:"subject"`
	State        string `json:"state"`
	Age          int64  `json:"age"`
	AuthStatus   any    `json:"authStatus"`
	KeyID        any    `json:"keyId"`
	Actor        any    `json:"actor"`
	Origin       any    `json:"origin"`
	Conversation any    `json:"conversation"`
}

type dashboardSelf struct {
	Node    string   `json:"node"`
	Mailbox []string `json:"mailbox"`
	Version string   `json:"version"`
}

type dashboardConfig struct {
	self      string
	mailboxes []string
	ttl       int64
}

type dashboardServer struct {
	home        string
	tokenSum    [sha256.Size]byte
	withText    bool
	logger      *log.Logger
	warnMu      sync.Mutex
	warned      map[string]bool
	assets      http.Handler
	requests    chan struct{}
	progressMu  sync.Mutex
	generations map[string]int64
}

func runDashboard(args []string) int {
	options, err := parseDashboardOptions(args)
	if err != nil {
		fmt.Fprintf(os.Stderr, "khala-dashboard: %v\n", err)
		return 2
	}
	home, err := khalaHome()
	if err != nil {
		fmt.Fprintf(os.Stderr, "khala-dashboard: %v\n", err)
		return 2
	}
	listener, err := net.Listen("tcp", options.listen)
	if err != nil {
		fmt.Fprintf(os.Stderr, "khala-dashboard: listen %s: %v\n", options.listen, err)
		return 1
	}
	handler, err := newDashboardHandler(home, options.token, options.withText, log.New(os.Stderr, "khala-dashboard: ", log.LstdFlags))
	if err != nil {
		_ = listener.Close()
		fmt.Fprintf(os.Stderr, "khala-dashboard: %v\n", err)
		return 1
	}
	fmt.Fprintf(os.Stdout, "dashboard: http://%s/#%s\n", listener.Addr().String(), options.token)
	server := &http.Server{Handler: handler, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 30 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 16 << 10}
	serveDone := make(chan error, 1)
	go func() { serveDone <- server.Serve(listener) }()
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	select {
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		if err := server.Shutdown(shutdownCtx); err != nil {
			fmt.Fprintf(os.Stderr, "khala-dashboard: shutdown: %v\n", err)
			return 1
		}
		return 0
	case err := <-serveDone:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			fmt.Fprintf(os.Stderr, "khala-dashboard: serve: %v\n", err)
			return 1
		}
		return 0
	}
}

func parseDashboardOptions(args []string) (dashboardOptions, error) {
	flags := flag.NewFlagSet("dashboard", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	port := flags.Int("port", 47000, "")
	noText := flags.Bool("no-text", false, "")
	if err := flags.Parse(args); err != nil || flags.NArg() != 0 || *port < 0 || *port > 65535 {
		return dashboardOptions{}, errors.New("usage: khala-link dashboard [--port N] [--no-text]")
	}
	var raw [32]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return dashboardOptions{}, fmt.Errorf("generate token: %w", err)
	}
	return dashboardOptions{listen: net.JoinHostPort("127.0.0.1", strconv.Itoa(*port)), token: base64.RawURLEncoding.EncodeToString(raw[:]), withText: !*noText}, nil
}

func newDashboardHandler(home, token string, withText bool, logger *log.Logger) (http.Handler, error) {
	if token == "" {
		return nil, errors.New("dashboard token is empty")
	}
	if _, err := readDashboardConfig(home); err != nil {
		return nil, err
	}
	assets, err := fs.Sub(dashboardAssets, "dashboard")
	if err != nil {
		return nil, err
	}
	server := &dashboardServer{home: home, tokenSum: sha256.Sum256([]byte(token)), withText: withText, logger: logger, warned: make(map[string]bool), assets: http.FileServer(http.FS(assets)), requests: make(chan struct{}, 32), generations: make(map[string]int64)}
	return http.HandlerFunc(server.serveHTTP), nil
}

type dashboardHeadWriter struct{ http.ResponseWriter }

func (dashboardHeadWriter) Write(data []byte) (int, error) { return len(data), nil }

func (s *dashboardServer) serveHTTP(response http.ResponseWriter, request *http.Request) {
	setDashboardHeaders(response.Header())
	if strings.HasPrefix(request.URL.Path, "/api/") && !s.authorized(request) {
		http.Error(response, "unauthorized", http.StatusUnauthorized)
		return
	}
	if request.Method != http.MethodGet && request.Method != http.MethodHead {
		response.Header().Set("Allow", "GET, HEAD")
		http.Error(response, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	select {
	case s.requests <- struct{}{}:
		defer func() { <-s.requests }()
	default:
		http.Error(response, "too many requests", http.StatusServiceUnavailable)
		return
	}
	var writer http.ResponseWriter = response
	if request.Method == http.MethodHead {
		writer = dashboardHeadWriter{response}
	}
	switch request.URL.Path {
	case "/api/v1/fleet":
		fleet, err := s.readFleet()
		if err != nil {
			s.warn("fleet", err)
			http.Error(writer, "could not read fleet", http.StatusInternalServerError)
			return
		}
		response.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(writer).Encode(fleet); err != nil {
			s.warn("fleet-response", err)
		}
	case "/api/v1/letter":
		s.serveLetter(writer, request)
	case "/", "/index.html", "/app.js", "/app.css":
		s.assets.ServeHTTP(writer, request)
	default:
		http.NotFound(writer, request)
	}
}

func setDashboardHeaders(header http.Header) {
	header.Set("Cache-Control", "no-store")
	header.Set("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
	header.Set("X-Content-Type-Options", "nosniff")
	header.Set("X-Frame-Options", "DENY")
	header.Set("Referrer-Policy", "no-referrer")
}

func (s *dashboardServer) authorized(request *http.Request) bool {
	const prefix = "Bearer "
	header := request.Header.Get("Authorization")
	if !strings.HasPrefix(header, prefix) {
		return false
	}
	got := sha256.Sum256([]byte(strings.TrimPrefix(header, prefix)))
	return subtle.ConstantTimeCompare(got[:], s.tokenSum[:]) == 1
}

func (s *dashboardServer) warn(key string, err error) {
	s.warnMu.Lock()
	defer s.warnMu.Unlock()
	if s.warned[key] {
		return
	}
	s.warned[key] = true
	if s.logger != nil {
		s.logger.Printf("WARN %s: %v", key, err)
	}
}

func ownedDirectory(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("not a real directory: %s", path)
	}
	if stat, ok := info.Sys().(*syscall.Stat_t); ok && int(stat.Uid) != os.Geteuid() {
		return fmt.Errorf("directory is not owned by caller: %s", path)
	}
	return nil
}

func dashboardPath(home string, parts ...string) (string, error) {
	if !filepath.IsAbs(home) {
		return "", errors.New("dashboard home is not absolute")
	}
	if err := ownedDirectory(home); err != nil {
		return "", err
	}
	current := home
	for _, part := range parts[:max(0, len(parts)-1)] {
		if part == "" || part == "." || part == ".." || strings.Contains(part, string(filepath.Separator)) {
			return "", errors.New("invalid dashboard path component")
		}
		current = filepath.Join(current, part)
		if err := ownedDirectory(current); err != nil {
			return "", err
		}
	}
	if len(parts) == 0 {
		return home, nil
	}
	last := parts[len(parts)-1]
	if last == "" || last == "." || last == ".." || strings.Contains(last, string(filepath.Separator)) {
		return "", errors.New("invalid dashboard path component")
	}
	return filepath.Join(current, last), nil
}

func dashboardReadDir(home string, parts ...string) ([]os.DirEntry, error) {
	path, err := dashboardPath(home, parts...)
	if err != nil {
		return nil, err
	}
	if err := ownedDirectory(path); err != nil {
		return nil, err
	}
	return os.ReadDir(path)
}

func dashboardReadFile(home string, limit int64, parts ...string) ([]byte, bool, error) {
	path, err := dashboardPath(home, parts...)
	if err != nil {
		return nil, false, err
	}
	f, err := openRegular(path)
	if err != nil {
		return nil, false, err
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, limit+1))
	if err != nil {
		return nil, false, err
	}
	if int64(len(data)) > limit {
		return data[:limit], true, nil
	}
	return data, false, nil
}

func readDashboardConfig(home string) (dashboardConfig, error) {
	data, truncated, err := dashboardReadFile(home, 1<<20, "config")
	if err != nil {
		return dashboardConfig{}, fmt.Errorf("read config: %w", err)
	}
	if truncated {
		return dashboardConfig{}, errors.New("config exceeds 1 MiB")
	}
	config := dashboardConfig{ttl: 120}
	selfSet, ttlSet := false, false
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 || strings.HasPrefix(fields[0], "#") {
			continue
		}
		switch fields[0] {
		case "self":
			if len(fields) != 2 || selfSet {
				return dashboardConfig{}, errors.New("invalid config self")
			}
			config.self, selfSet = fields[1], true
		case "mailbox":
			if len(fields) < 2 {
				return dashboardConfig{}, errors.New("invalid config mailbox")
			}
			config.mailboxes = append(config.mailboxes, fields[1:]...)
		case "ttl":
			if len(fields) != 2 || ttlSet {
				return dashboardConfig{}, errors.New("invalid config ttl")
			}
			ttl, parseErr := strconv.ParseInt(fields[1], 10, 64)
			if parseErr != nil || ttl <= 0 {
				return dashboardConfig{}, errors.New("invalid config ttl")
			}
			config.ttl, ttlSet = ttl, true
		}
	}
	if !validNode(config.self) {
		return dashboardConfig{}, errors.New("config self is missing or invalid")
	}
	for _, mailbox := range config.mailboxes {
		if !validNode(mailbox) {
			return dashboardConfig{}, errors.New("config mailbox is invalid")
		}
	}
	return config, nil
}

type dashboardEarAt struct {
	node        string
	snapshot    *earsSnapshot
	state       string
	age         int64
	skew        int64
	progressing bool
}

func (s *dashboardServer) readEarSnapshots(now time.Time) map[string]dashboardEarAt {
	result := make(map[string]dashboardEarAt)
	entries, err := dashboardReadDir(s.home, "presence")
	if err != nil {
		return result
	}
	for _, entry := range entries {
		node, ok := earSnapshotNode(entry.Name())
		if !ok || entry.Type()&os.ModeSymlink != 0 || !entry.Type().IsRegular() {
			continue
		}
		path := filepath.Join(s.home, "presence", entry.Name())
		snapshot, err := parseEars(path)
		if err != nil {
			s.warn("ear:"+entry.Name(), err)
			result[node] = dashboardEarAt{node: node, state: "invalid"}
			continue
		}
		age := now.Unix() - snapshot.WrittenAt
		skew := snapshot.WrittenAt - now.Unix()
		interval := snapshot.Interval
		if interval < 10 {
			interval = 10
		} else if interval > 600 {
			interval = 600
		}
		state := "stale"
		if snapshot.State == "stopping" {
			state = "stopping"
		} else if age >= -60 && age <= 2*interval+60 {
			state = "fresh"
		}
		s.progressMu.Lock()
		previous, seen := s.generations[node]
		progressing := seen && snapshot.Generation > previous
		s.generations[node] = snapshot.Generation
		s.progressMu.Unlock()
		copy := snapshot
		result[node] = dashboardEarAt{node: node, snapshot: &copy, state: state, age: age, skew: skew, progressing: progressing}
	}
	return result
}

func newDashboardSession(address string) *dashboardSession {
	return &dashboardSession{Address: address, PrincipalType: "session", State: "unknown", Route: "-", Reason: "-", Model: "-", Effort: "-", Role: "-", Charge: "-", Freshness: "-", PendingState: "empty"}
}

func ensureDashboardSession(sessions map[string]*dashboardSession, address string) *dashboardSession {
	if sessions[address] == nil {
		sessions[address] = newDashboardSession(address)
	}
	return sessions[address]
}

func splitAddress(address string) (string, string, bool) {
	identity, node, ok := strings.Cut(address, "@")
	return identity, node, ok && validNode(identity) && validNode(node) && !strings.Contains(node, "@")
}

func skipFleetIdentity(identity string) bool {
	return identity == "conduit" || identity == "khala" || identity == "gateway" || identity == "operator"
}

func pendingState(identity earsIdentity) string {
	if identity.PendingRing == 0 {
		return "empty"
	}
	if identity.LastDrainBefore == identity.Generation {
		return "seen-but-left"
	}
	if identity.LastDrainAfter == identity.Generation {
		return "no-new-since-drain"
	}
	return "new-since-drain"
}

func (s *dashboardServer) readFleet() (dashboardFleet, error) {
	config, err := readDashboardConfig(s.home)
	if err != nil {
		return dashboardFleet{}, err
	}
	now := time.Now()
	fleet := dashboardFleet{APIVersion: 1, Self: dashboardSelf{Node: config.self, Mailbox: config.mailboxes, Version: linkVersion}, GeneratedAt: now.Unix()}
	sessions := make(map[string]*dashboardSession)
	nodeSet := map[string]bool{config.self: true}
	hubs := make(map[string]bool)
	for _, mailbox := range config.mailboxes {
		hubs[mailbox] = true
	}
	earsByNode := s.readEarSnapshots(now)
	for node, ear := range earsByNode {
		nodeSet[node] = true
		if ear.snapshot != nil {
			for _, mailbox := range ear.snapshot.Mailboxes {
				hubs[mailbox] = true
			}
		}
	}
	s.readPresence(config, now, sessions, nodeSet, &fleet)
	s.readMinds(now, sessions, nodeSet)
	for _, watcher := range fleet.Watchers {
		delete(sessions, watcher.Name+"@"+watcher.Node)
	}
	for node, ear := range earsByNode {
		if ear.snapshot == nil {
			continue
		}
		for _, identity := range ear.snapshot.Identities {
			if skipFleetIdentity(identity.Name) {
				continue
			}
			session := sessions[identity.Name+"@"+node]
			if session == nil {
				continue
			}
			session.PrincipalType = identity.Principal
			session.Listening = ear.state == "fresh" && identity.Listening
			session.Route, session.Reason = identity.Route, identity.Reason
			session.PendingByClass = dashboardPending{Ring: identity.PendingRing, Info: identity.PendingInfo, Operator: identity.PendingOperator}
			session.PendingState = pendingState(identity)
			session.OldestPendingAt = identity.OldestPending
		}
	}
	addresses := make([]string, 0, len(sessions))
	for address := range sessions {
		addresses = append(addresses, address)
	}
	sort.Strings(addresses)
	for _, address := range addresses[:min(len(addresses), dashboardMaxRows)] {
		fleet.Sessions = append(fleet.Sessions, *sessions[address])
	}
	nodes := make([]string, 0, len(nodeSet))
	for node := range nodeSet {
		nodes = append(nodes, node)
	}
	sort.Strings(nodes)
	for _, node := range nodes[:min(len(nodes), dashboardMaxRows)] {
		item := dashboardNode{Node: node, Hub: hubs[node], State: "absent", Components: []earsComponent{}, Capabilities: []string{}, Gateway: nil, Mailbox: []string{}, Identities: []earsIdentity{}}
		if ear, ok := earsByNode[node]; ok {
			item.State, item.Progressing = ear.state, ear.progressing
			if ear.snapshot != nil {
				item.SnapshotAge, item.WrittenAt, item.Skew = int64Pointer(ear.age), int64Pointer(ear.snapshot.WrittenAt), int64Pointer(ear.skew)
				item.Complete = boolPointer(ear.snapshot.Complete)
				item.Components = append(item.Components, ear.snapshot.Components...)
				item.Mailbox = append(item.Mailbox, ear.snapshot.Mailboxes...)
				if ear.snapshot.LinkAge >= 0 {
					item.LinkAge = int64Pointer(ear.snapshot.LinkAge)
				}
				for _, identity := range ear.snapshot.Identities {
					if !skipFleetIdentity(identity.Name) {
						item.Identities = append(item.Identities, identity)
					}
				}
			}
		}
		if node == config.self {
			if age := linkFreshAge(s.home, now); age >= 0 {
				item.LinkAge = int64Pointer(age)
			}
		}
		fleet.Nodes = append(fleet.Nodes, item)
	}
	localIdentities := s.localIdentities()
	fleet.Streams = s.readStreams(localIdentities)
	if s.withText {
		fleet.Letters = s.readLetters(localIdentities, now)
	}
	return fleet, nil
}

func int64Pointer(value int64) *int64 { return &value }
func boolPointer(value bool) *bool    { return &value }

func (s *dashboardServer) readPresence(config dashboardConfig, now time.Time, sessions map[string]*dashboardSession, nodeSet map[string]bool, fleet *dashboardFleet) {
	entries, err := dashboardReadDir(s.home, "presence")
	if err != nil {
		return
	}
	for _, entry := range entries {
		name := entry.Name()
		if node, ok := presenceNode(name); ok {
			nodeSet[node] = true
		}
		switch {
		case strings.HasSuffix(name, ".watcher"):
			if watcher, ok := s.readWatcher(strings.TrimSuffix(name, ".watcher")); ok && len(fleet.Watchers) < dashboardMaxRows {
				fleet.Watchers = append(fleet.Watchers, watcher)
			}
		case strings.HasSuffix(name, ".watching"), strings.HasSuffix(name, ".ear"):
			continue
		default:
			identity, node, ok := splitAddress(name)
			if !ok || skipFleetIdentity(identity) {
				continue
			}
			data, _, err := dashboardReadFile(s.home, 256, "presence", name)
			if err != nil {
				continue
			}
			fields := strings.Fields(string(data))
			if len(fields) != 1 {
				continue
			}
			epoch, err := strconv.ParseInt(fields[0], 10, 64)
			if err != nil || epoch < 0 {
				continue
			}
			session := ensureDashboardSession(sessions, identity+"@"+node)
			session.LastSeen = epoch
			if now.Unix()-epoch <= config.ttl {
				if node == config.self {
					session.State = "alive-here"
				} else {
					session.State = "alive-elsewhere"
				}
			} else {
				session.State = "asleep"
			}
		}
	}
	sort.Slice(fleet.Watchers, func(i, j int) bool {
		if fleet.Watchers[i].Node != fleet.Watchers[j].Node {
			return fleet.Watchers[i].Node < fleet.Watchers[j].Node
		}
		return fleet.Watchers[i].Name < fleet.Watchers[j].Name
	})
}

func (s *dashboardServer) readWatcher(address string) (dashboardWatcher, bool) {
	name, node, ok := splitAddress(address)
	if !ok || skipFleetIdentity(name) {
		return dashboardWatcher{}, false
	}
	data, truncated, err := dashboardReadFile(s.home, 4096, "presence", address+".watcher")
	if err != nil || truncated {
		return dashboardWatcher{}, false
	}
	lines := strings.Split(strings.TrimSuffix(string(data), "\n"), "\n")
	if len(lines) != 5 && len(lines) != 6 {
		return dashboardWatcher{}, false
	}
	first := strings.Fields(lines[0])
	stateFields := strings.Fields(lines[4])
	if len(first) != 1 || first[0] == "retired" || len(stateFields) == 0 || !oneOf(stateFields[0], "active", "silent") {
		return dashboardWatcher{}, false
	}
	declared, err1 := strconv.ParseInt(first[0], 10, 64)
	cadence, err2 := strconv.ParseInt(strings.TrimSpace(lines[1]), 10, 64)
	last, err3 := strconv.ParseInt(strings.TrimSpace(lines[3]), 10, 64)
	if err1 != nil || err2 != nil || err3 != nil || declared < 0 || cadence < 0 || last < 0 {
		return dashboardWatcher{}, false
	}
	var since *int64
	if len(lines) == 6 {
		value, err := strconv.ParseInt(strings.TrimSpace(lines[5]), 10, 64)
		if err != nil || value < 0 {
			return dashboardWatcher{}, false
		}
		since = int64Pointer(value)
	}
	return dashboardWatcher{Name: name, Node: node, Owner: strings.TrimSpace(lines[2]), Cadence: cadence, Last: last, State: stateFields[0], Since: since}, true
}

type dashboardMind struct {
	model, effort, role, charge, focus, stance, freshness string
	active                                                bool
}

func (s *dashboardServer) readMinds(now time.Time, sessions map[string]*dashboardSession, nodeSet map[string]bool) {
	nodes, err := dashboardReadDir(s.home, "minds")
	if err != nil {
		return
	}
	for _, nodeEntry := range nodes {
		node := nodeEntry.Name()
		if !nodeEntry.IsDir() || !validNode(node) {
			continue
		}
		identities, err := dashboardReadDir(s.home, "minds", node)
		if err != nil {
			continue
		}
		for _, identityEntry := range identities {
			identity := identityEntry.Name()
			if !identityEntry.IsDir() || !validNode(identity) || skipFleetIdentity(identity) {
				continue
			}
			mind, ok := s.readCurrentMind(node, identity, now)
			if !ok {
				continue
			}
			session := ensureDashboardSession(sessions, identity+"@"+node)
			session.Model, session.Effort, session.Role, session.Charge = mind.model, mind.effort, mind.role, mind.charge
			session.Freshness = mind.freshness
			if s.withText && mind.active {
				session.Focus, session.Stance = mind.focus, mind.stance
			}
			nodeSet[node] = true
		}
	}
}

func (s *dashboardServer) readCurrentMind(node, identity string, now time.Time) (dashboardMind, bool) {
	entries, err := dashboardReadDir(s.home, "minds", node, identity)
	if err != nil {
		return dashboardMind{}, false
	}
	var names []string
	for _, entry := range entries {
		if entry.Type().IsRegular() && validGeneration(entry.Name()) {
			names = append(names, entry.Name())
		}
	}
	if len(names) == 0 {
		return dashboardMind{}, false
	}
	sort.Slice(names, func(i, j int) bool { return compareGenerations(names[i], names[j]) > 0 })
	data, _, err := dashboardReadFile(s.home, 64<<10, "minds", node, identity, names[0])
	if err != nil {
		return dashboardMind{}, false
	}
	headers, _ := parseHeaderBody(data)
	if headers["Session"] != identity || headers["Node"] != node || !oneOf(headers["State"], "active", "cleared") {
		return dashboardMind{}, false
	}
	active := headers["State"] == "active"
	declared, _ := strconv.ParseInt(headers["Declared-Focus"], 10, 64)
	freshness := "-"
	if declared > 0 {
		freshness = "fresh"
		if now.Unix()-declared > 3600 {
			freshness = "stale"
		}
	}
	if !active {
		freshness = "cleared"
	}
	return dashboardMind{model: headers["Model"], effort: headers["Effort"], role: headers["Role"], charge: headers["Charge"], focus: headers["Focus"], stance: headers["Stance"], freshness: freshness, active: active}, true
}

func compareGenerations(left, right string) int {
	leftParts, rightParts := strings.Split(left, "."), strings.Split(right, ".")
	for index := 0; index < 2; index++ {
		leftNumber, _ := strconv.ParseUint(leftParts[index], 10, 64)
		rightNumber, _ := strconv.ParseUint(rightParts[index], 10, 64)
		if leftNumber < rightNumber {
			return -1
		}
		if leftNumber > rightNumber {
			return 1
		}
	}
	return 0
}

func (s *dashboardServer) localIdentities() []string {
	entries, err := dashboardReadDir(s.home, "inbox")
	if err != nil {
		return nil
	}
	names := make([]string, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() && validNode(entry.Name()) && !skipFleetIdentity(entry.Name()) {
			names = append(names, entry.Name())
		}
	}
	sort.Strings(names)
	if len(names) > dashboardMaxRows {
		names = names[:dashboardMaxRows]
	}
	return names
}

type dashboardStreamFile struct{ id, node string }

func (s *dashboardServer) readStreams(localIdentities []string) []dashboardStream {
	streamEntries, err := dashboardReadDir(s.home, "streams")
	if err != nil {
		return []dashboardStream{}
	}
	result := make([]dashboardStream, 0, min(len(streamEntries), dashboardMaxRows))
	for _, streamEntry := range streamEntries {
		name := streamEntry.Name()
		if len(result) >= dashboardMaxRows || !streamEntry.IsDir() || !validNode(name) {
			continue
		}
		var files []dashboardStreamFile
		shards, err := dashboardReadDir(s.home, "streams", name)
		if err != nil {
			continue
		}
		for _, shard := range shards {
			if !shard.IsDir() || !validNode(shard.Name()) {
				continue
			}
			entries, err := dashboardReadDir(s.home, "streams", name, shard.Name())
			if err != nil {
				continue
			}
			for _, entry := range entries {
				if entry.Type().IsRegular() && validMessageID(entry.Name()) {
					files = append(files, dashboardStreamFile{id: entry.Name(), node: shard.Name()})
				}
			}
		}
		sort.Slice(files, func(i, j int) bool { return compareMessageIDs(files[i].id, files[j].id) > 0 })
		stream := dashboardStream{Name: name, Entries: len(files), Latest: "-", LocalUnread: make(map[string]int)}
		if len(files) > 0 {
			stream.Latest = files[0].id
		}
		for _, identity := range localIdentities {
			stream.LocalUnread[identity] = s.streamUnread(identity, name, files)
		}
		if s.withText {
			for _, file := range files[:min(len(files), dashboardStreamRows)] {
				data, truncated, err := dashboardReadFile(s.home, dashboardStreamBodyMax+(64<<10), "streams", name, file.node, file.id)
				if err != nil {
					continue
				}
				headers, body := parseHeaderBody(data)
				if truncated || len(body) > dashboardStreamBodyMax {
					body = truncateString(body, dashboardStreamBodyMax) + dashboardTruncated
				}
				stream.Recent = append(stream.Recent, dashboardStreamEntry{ID: file.id, From: headers["From"], Date: headers["Date"], Subject: headers["Subject"], Body: body})
			}
		}
		result = append(result, stream)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Name < result[j].Name })
	return result
}

func (s *dashboardServer) streamUnread(identity, stream string, entries []dashboardStreamFile) int {
	joinData, truncated, err := dashboardReadFile(s.home, 256, "join", identity, stream)
	if err != nil || truncated {
		return 0
	}
	fields := strings.Fields(string(joinData))
	if len(fields) != 2 || !oneOf(fields[0], "joined", "quiet") {
		return 0
	}
	joinEpoch, err := strconv.ParseInt(fields[1], 10, 64)
	if err != nil || joinEpoch < 0 {
		return 0
	}
	cursor := ""
	if cursorData, truncated, err := dashboardReadFile(s.home, 4096, "cursor", identity, stream); err == nil && !truncated {
		cursor = strings.TrimSpace(string(cursorData))
	}
	count := 0
	for _, entry := range entries {
		epoch, _ := strconv.ParseInt(strings.SplitN(entry.id, ".", 2)[0], 10, 64)
		if epoch >= joinEpoch && (cursor == "" || compareMessageIDs(entry.id, cursor) > 0) {
			count++
		}
	}
	return count
}

func (s *dashboardServer) readLetters(localIdentities []string, now time.Time) []dashboardLetter {
	var result []dashboardLetter
	for _, identity := range localIdentities {
		for _, state := range []string{"new", "cur"} {
			entries, err := dashboardReadDir(s.home, "inbox", identity, state)
			if err != nil {
				continue
			}
			for _, entry := range entries {
				if !entry.Type().IsRegular() || !validMessageID(entry.Name()) || len(entry.Name()) > 255 {
					continue
				}
				data, _, err := dashboardReadFile(s.home, 64<<10, "inbox", identity, state, entry.Name())
				if err != nil {
					continue
				}
				headers, _ := parseHeaderBody(data)
				if headers["Id"] != entry.Name() {
					continue
				}
				epoch, _ := strconv.ParseInt(strings.SplitN(entry.Name(), ".", 2)[0], 10, 64)
				age := max(int64(0), now.Unix()-epoch)
				result = append(result, dashboardLetter{Identity: identity, ID: entry.Name(), From: headers["From"], Date: headers["Date"], Type: headers["Type"], Urgency: headers["Urgency"], Subject: headers["Subject"], State: state, Age: age})
			}
		}
	}
	sort.Slice(result, func(i, j int) bool { return compareMessageIDs(result[i].ID, result[j].ID) > 0 })
	if len(result) > dashboardLetterRows {
		result = result[:dashboardLetterRows]
	}
	return result
}

func (s *dashboardServer) serveLetter(response http.ResponseWriter, request *http.Request) {
	if !s.withText {
		http.NotFound(response, request)
		return
	}
	identity := request.URL.Query().Get("identity")
	id := request.URL.Query().Get("id")
	if !validNode(identity) || isReservedIdentity(identity) || len(id) > 255 || !messageIDPattern.MatchString(id) {
		http.Error(response, "invalid letter identity or id", http.StatusBadRequest)
		return
	}
	if _, err := dashboardReadDir(s.home, "inbox", identity); err != nil {
		http.Error(response, "invalid letter identity or id", http.StatusBadRequest)
		return
	}
	for _, state := range []string{"new", "cur"} {
		data, truncated, err := dashboardReadFile(s.home, dashboardLetterBodyMax+(64<<10), "inbox", identity, state, id)
		if err != nil {
			continue
		}
		headers, body := parseHeaderBody(data)
		if headers["Id"] != id {
			continue
		}
		if truncated || len(body) > dashboardLetterBodyMax {
			body = truncateString(body, dashboardLetterBodyMax) + dashboardTruncated
		}
		response.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = io.WriteString(response, body)
		return
	}
	http.NotFound(response, request)
}

func truncateString(value string, limit int) string {
	if len(value) <= limit {
		return value
	}
	return value[:limit]
}

func parseHeaderBody(data []byte) (map[string]string, string) {
	text := strings.ReplaceAll(string(data), "\r\n", "\n")
	headerText, body, _ := strings.Cut(text, "\n\n")
	headers := make(map[string]string)
	for _, line := range strings.Split(headerText, "\n") {
		key, value, ok := strings.Cut(line, ": ")
		if ok {
			headers[key] = value
		}
	}
	return headers, body
}
