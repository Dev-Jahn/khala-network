package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func dashboardFixture(t *testing.T) string {
	t.Helper()
	home := t.TempDir()
	for _, dir := range []string{
		"presence", "minds/alpha/ink", "streams/ops/alpha", "join/ink", "cursor/ink",
		"inbox/ink/new", "inbox/ink/cur", "run",
	} {
		if err := os.MkdirAll(filepath.Join(home, dir), 0700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(home, "config"), []byte("self alpha\nmailbox mini\nttl 120\npeer mini peer-sentinel.invalid\n"), 0600); err != nil {
		t.Fatal(err)
	}
	now := time.Now().Unix()
	snapshotRow := validListenerSnapshotFixture("alpha", now)
	snapshotRow = strings.Replace(snapshotRow, "written-at 1788402001", fmt.Sprintf("written-at %d", now), 1)
	files := map[string][]byte{
		"presence/ink@alpha":                         []byte(fmt.Sprintf("%d\n", now)),
		"presence/old@beta":                          []byte(fmt.Sprintf("%d\n", now)),
		"presence/guard@alpha.watcher":               []byte("1700000000\n60\nink@alpha\n1700000010\nactive\n1700000000\n"),
		"presence/legacy@alpha.watcher":              []byte("1700000000\n60\nink@alpha\n1700000010\nactive\n"),
		"presence/conduit@alpha.ear":                 []byte(snapshotRow),
		"presence/conduit@gamma.ear":                 []byte("broken\n"),
		"minds/alpha/ink/1700000000.1":               []byte(statusFixture("ink", "alpha")),
		"streams/ops/alpha/1700000000.1.1.ink@alpha": messageFixtureBytes("1700000000.1.1.ink@alpha", "ink@alpha", "entry", "</script> stream", "<img onerror=stream>\n"),
		"join/ink/ops":                               []byte("joined 0\n"),
		"inbox/ink/new/1700000001.1.1.sender@alpha":  messageFixtureBytes("1700000001.1.1.sender@alpha", "sender@alpha", "message", "</script> letter", "<img onerror=letter>\n\xff"),
	}
	for name, data := range files {
		if err := os.WriteFile(filepath.Join(home, name), data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	return home
}

func statusFixture(identity, node string) string {
	return "Generation: 1700000000.1\nSession: " + identity + "\nNode: " + node + "\nState: active\n" +
		"Model: opus\nEffort: high\nRole: builder\nCharge: implementation\nFocus: </script> focus\nStance: \"stance\" ‮\n" +
		"Declared-State: 1700000000\nDeclared-Model: 1700000000\nDeclared-Effort: 1700000000\nDeclared-Role: 1700000000\nDeclared-Charge: 1700000000\nDeclared-Focus: 1700000000\nDeclared-Stance: 1700000000\n\n"
}

func messageFixtureBytes(id, from, typ, subject, body string) []byte {
	return []byte("Khala: 0.1\nId: " + id + "\nFrom: " + from + "\nTo: ink@alpha\nDate: 2026-09-03T00:00:00Z\nType: " + typ + "\nSubject: " + subject + "\n\n" + body)
}

func dashboardRequest(t *testing.T, handler http.Handler, method, target, token string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, target, nil)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	res := httptest.NewRecorder()
	handler.ServeHTTP(res, req)
	return res
}

func TestDashboardR3OptionsAuthMethodsHeadersAndAssets(t *testing.T) {
	options, err := parseDashboardOptions([]string{"--port", "0", "--no-text"})
	if err != nil || options.listen != "127.0.0.1:0" || options.withText {
		t.Fatalf("options=%+v err=%v", options, err)
	}
	for _, args := range [][]string{{"--listen", "127.0.0.1:1"}, {"--token-file", "x"}, {"--port", "-1"}, {"--port", "65536"}, {"--with-text"}} {
		if _, err := parseDashboardOptions(args); err == nil {
			t.Errorf("accepted removed/invalid options %v", args)
		}
	}
	home := dashboardFixture(t)
	handler, err := newDashboardHandler(home, "unit-token", false, log.New(io.Discard, "", 0))
	if err != nil {
		t.Fatal(err)
	}
	for _, target := range []string{"/api/v1/fleet", "/api/v1/fleet?token=unit-token", "/api/v1/unknown"} {
		res := dashboardRequest(t, handler, http.MethodGet, target, "")
		if res.Code != http.StatusUnauthorized {
			t.Errorf("%s status=%d want=401", target, res.Code)
		}
		assertDashboardHeaders(t, res.Header())
	}
	post := dashboardRequest(t, handler, http.MethodPost, "/", "")
	if post.Code != http.StatusMethodNotAllowed || post.Header().Get("Allow") != "GET, HEAD" {
		t.Fatalf("POST status=%d allow=%q", post.Code, post.Header().Get("Allow"))
	}
	for _, method := range []string{http.MethodGet, http.MethodHead} {
		res := dashboardRequest(t, handler, method, "/api/v1/fleet", "unit-token")
		if res.Code != http.StatusOK {
			t.Fatalf("%s fleet status=%d body=%s", method, res.Code, res.Body.String())
		}
		if method == http.MethodHead && res.Body.Len() != 0 {
			t.Fatalf("HEAD returned %d body bytes", res.Body.Len())
		}
	}
	asset := dashboardRequest(t, handler, http.MethodGet, "/app.js", "")
	if asset.Code != http.StatusOK {
		t.Fatalf("app.js status=%d", asset.Code)
	}
	for _, forbidden := range []string{"innerHTML", "localStorage", "sessionStorage", "onclick=", "onerror=", "replaceChildren"} {
		if strings.Contains(asset.Body.String(), forbidden) {
			t.Errorf("app.js contains forbidden API %q", forbidden)
		}
	}
	for _, required := range []string{
		"location.hash", "history.replaceState", "textContent", "/api/v1/fleet",
		"createElementNS", "setInterval", "data-key", "pendingByClass", "localUnread",
	} {
		if !strings.Contains(asset.Body.String(), required) {
			t.Errorf("app.js missing %q", required)
		}
	}
	page := dashboardRequest(t, handler, http.MethodGet, "/", "")
	if page.Code != http.StatusOK {
		t.Fatalf("index status=%d", page.Code)
	}
	for _, required := range []string{"fleet-map", "fleet-legend", "session-board", "watcher-board", "stream-board", "detail-panel", "error-banner"} {
		if !strings.Contains(page.Body.String(), `id="`+required+`"`) {
			t.Errorf("index missing visual surface %q", required)
		}
	}
	if strings.Contains(page.Body.String(), "<table") || strings.Contains(page.Body.String(), "style=") {
		t.Error("index contains a table or inline style")
	}
}

func assertDashboardHeaders(t *testing.T, header http.Header) {
	t.Helper()
	wantCSP := "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
	if header.Get("Cache-Control") != "no-store" || header.Get("Content-Security-Policy") != wantCSP ||
		header.Get("X-Content-Type-Options") != "nosniff" || header.Get("X-Frame-Options") != "DENY" ||
		header.Get("Referrer-Policy") != "no-referrer" || header.Get("Access-Control-Allow-Origin") != "" {
		t.Fatalf("security headers=%v", header)
	}
}

func TestDashboardFleetR3SchemaFreshnessPendingStateAndNoText(t *testing.T) {
	home := dashboardFixture(t)
	handler, err := newDashboardHandler(home, "token", false, log.New(io.Discard, "", 0))
	if err != nil {
		t.Fatal(err)
	}
	res := dashboardRequest(t, handler, http.MethodGet, "/api/v1/fleet", "token")
	if res.Code != http.StatusOK {
		t.Fatalf("fleet status=%d body=%s", res.Code, res.Body.String())
	}
	var cluster map[string]any
	if err := json.Unmarshal(res.Body.Bytes(), &cluster); err != nil {
		t.Fatalf("fleet JSON: %v\n%s", err, res.Body.String())
	}
	if cluster["apiVersion"] != float64(1) {
		t.Fatalf("apiVersion=%v", cluster["apiVersion"])
	}
	lower := strings.ToLower(res.Body.String())
	for _, forbidden := range []string{"\"subject\"", "\"body\"", "\"focus\"", "\"stance\"", "peer-sentinel", "onerror=letter"} {
		if strings.Contains(lower, strings.ToLower(forbidden)) {
			t.Errorf("--no-text response contains %q", forbidden)
		}
	}
	nodes := cluster["nodes"].([]any)
	states := make(map[string]string)
	for _, raw := range nodes {
		node := raw.(map[string]any)
		states[node["node"].(string)] = node["state"].(string)
		_, hasGateway := node["gateway"]
		if node["capabilities"] == nil || !hasGateway {
			t.Errorf("node reserved fields missing: %v", node)
		}
	}
	if states["alpha"] != "fresh" || states["beta"] != "absent" || states["gamma"] != "invalid" {
		t.Fatalf("node states=%v", states)
	}
	sessions := cluster["sessions"].([]any)
	if len(sessions) != 2 {
		t.Fatalf("sessions=%v", sessions)
	}
	ink := sessions[0].(map[string]any)
	if ink["address"] != "ink@alpha" || ink["principalType"] != "session" || ink["pendingState"] != "seen-but-left" {
		t.Fatalf("ink session=%v", ink)
	}
	watchdogs := cluster["watchers"].([]any)
	var legacy map[string]any
	for _, raw := range watchdogs {
		watchdog := raw.(map[string]any)
		if watchdog["name"] == "legacy" {
			legacy = watchdog
		}
	}
	if legacy == nil || legacy["since"] != nil {
		t.Fatalf("legacy watcher since=%v", legacy)
	}
	if got := dashboardRequest(t, handler, http.MethodGet, "/api/v1/letter?identity=ink&id=1700000001.1.1.sender@alpha", "token"); got.Code != http.StatusNotFound {
		t.Fatalf("--no-text letter status=%d", got.Code)
	}
}

func TestDashboardFreshnessClampsIntervalAndPendingStateOrder(t *testing.T) {
	home := dashboardFixture(t)
	now := time.Now().Unix()
	stale := strings.Replace(validListenerSnapshotFixture("delta", 1), "written-at 1788402001", fmt.Sprintf("written-at %d", now-1300), 1)
	stale = strings.Replace(stale, "interval 60", "interval 86400", 1)
	ahead := strings.Replace(validListenerSnapshotFixture("epsilon", 1), "written-at 1788402001", fmt.Sprintf("written-at %d", now+61), 1)
	stopping := strings.Replace(validListenerSnapshotFixture("zeta", 1), "written-at 1788402001", fmt.Sprintf("written-at %d", now), 1)
	stopping = strings.Replace(stopping, "state running", "state stopping", 1)
	for node, data := range map[string]string{"delta": stale, "epsilon": ahead, "zeta": stopping} {
		if err := os.WriteFile(filepath.Join(home, "presence", "conduit@"+node+".ear"), []byte(data), 0600); err != nil {
			t.Fatal(err)
		}
	}
	server := &dashboardServer{home: home, warned: make(map[string]bool), snapshotSequences: make(map[string]int64)}
	snapshotSet := server.readListenerSnapshots(time.Unix(now, 0))
	if snapshotSet["delta"].state != "stale" || snapshotSet["epsilon"].state != "stale" || snapshotSet["epsilon"].skew != 61 || snapshotSet["zeta"].state != "stopping" {
		t.Fatalf("freshness=%+v", snapshotSet)
	}
	for _, test := range []struct {
		identity listenerIdentity
		want     string
	}{
		{listenerIdentity{}, "empty"},
		{listenerIdentity{PendingRing: 1, Generation: testQueueDigest, LastDrainBefore: testQueueDigest, LastDrainAfter: testQueueDigest}, "seen-but-left"},
		{listenerIdentity{PendingRing: 1, Generation: testQueueDigest, LastDrainBefore: "-", LastDrainAfter: testQueueDigest}, "no-new-since-drain"},
		{listenerIdentity{PendingRing: 1, Generation: testQueueDigest, LastDrainBefore: "-", LastDrainAfter: "-"}, "new-since-drain"},
	} {
		if got := pendingState(test.identity); got != test.want {
			t.Errorf("pendingState(%+v)=%q want=%q", test.identity, got, test.want)
		}
	}
}

func TestDashboardTextPreservesDataAndValidatesLetterIdentityAndID(t *testing.T) {
	home := dashboardFixture(t)
	handler, err := newDashboardHandler(home, "token", true, log.New(io.Discard, "", 0))
	if err != nil {
		t.Fatal(err)
	}
	res := dashboardRequest(t, handler, http.MethodGet, "/api/v1/fleet", "token")
	if res.Code != http.StatusOK {
		t.Fatalf("fleet status=%d body=%s", res.Code, res.Body.String())
	}
	var cluster dashboardCluster
	if err := json.Unmarshal(res.Body.Bytes(), &cluster); err != nil {
		t.Fatal(err)
	}
	if len(cluster.Sessions) == 0 || cluster.Sessions[0].Focus != "</script> focus" || cluster.Sessions[0].Stance != "\"stance\" ‮" {
		t.Errorf("mind strings changed: %+v", cluster.Sessions)
	}
	if len(cluster.Streams) == 0 || len(cluster.Streams[0].Recent) == 0 || cluster.Streams[0].Recent[0].Body != "<img onerror=stream>\n" {
		t.Errorf("stream string changed: %+v", cluster.Streams)
	}
	id := "1700000001.1.1.sender@alpha"
	for _, target := range []string{
		"/api/v1/letter?id=" + id,
		"/api/v1/letter?identity=missing&id=" + id,
		"/api/v1/letter?identity=ink&id=bad",
		"/api/v1/letter?identity=ink&id=" + strings.Repeat("1", 256),
	} {
		if got := dashboardRequest(t, handler, http.MethodGet, target, "token"); got.Code != http.StatusBadRequest {
			t.Errorf("%s status=%d want=400", target, got.Code)
		}
	}
	valid := dashboardRequest(t, handler, http.MethodGet, "/api/v1/letter?identity=ink&id="+id, "token")
	if valid.Code != http.StatusOK || !strings.Contains(valid.Body.String(), "<img onerror=letter>") || !bytes.HasSuffix(valid.Body.Bytes(), []byte{'\n', 0xff}) {
		t.Fatalf("letter status=%d body=%q", valid.Code, valid.Body.String())
	}
	path := filepath.Join(home, "inbox", "ink", "new", id)
	if err := os.WriteFile(path, messageFixtureBytes("1700000099.1.1.sender@alpha", "sender@alpha", "message", "wrong", "wrong"), 0600); err != nil {
		t.Fatal(err)
	}
	if got := dashboardRequest(t, handler, http.MethodGet, "/api/v1/letter?identity=ink&id="+id, "token"); got.Code != http.StatusNotFound {
		t.Fatalf("mismatched Id status=%d", got.Code)
	}
}

func TestDashboardRejectsSymlinkParentAndDoesNotCreateRuntime(t *testing.T) {
	home := dashboardFixture(t)
	outside := t.TempDir()
	if err := os.Rename(filepath.Join(home, "inbox"), filepath.Join(outside, "inbox")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(outside, "inbox"), filepath.Join(home, "inbox")); err != nil {
		t.Fatal(err)
	}
	runtimePath := filepath.Join(home, "runtime-must-not-exist")
	t.Setenv("KHALA_RUNTIME_DIR", runtimePath)
	handler, err := newDashboardHandler(home, "token", true, log.New(io.Discard, "", 0))
	if err != nil {
		t.Fatal(err)
	}
	id := "1700000001.1.1.sender@alpha"
	got := dashboardRequest(t, handler, http.MethodGet, "/api/v1/letter?identity=ink&id="+id, "token")
	if got.Code != http.StatusBadRequest && got.Code != http.StatusNotFound {
		t.Fatalf("symlink parent status=%d", got.Code)
	}
	if _, err := os.Lstat(runtimePath); !os.IsNotExist(err) {
		t.Fatalf("dashboard touched runtime path: %v", err)
	}
}
