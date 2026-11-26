package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/showcode1024/singbox-auto/singbox-plus/internal/store"
)

type mockCenter struct {
	mu              sync.Mutex
	nodeID          string
	userID          string
	token           string
	regID           string
	revision        int64
	failNextReg     bool
	return410       bool
	waitChanged     bool
	syncedBatches   int
	activityAcked   int
	detachCalled    bool
	lastDesiredUser map[string]any
}

func (m *mockCenter) handler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		dec := json.NewDecoder(r.Body)
		dec.UseNumber()
		if err := dec.Decode(&body); err != nil {
			http.Error(w, `{"error":"bad json"}`, http.StatusBadRequest)
			return
		}

		m.mu.Lock()
		defer m.mu.Unlock()

		writeJSON := func(status int, payload any) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(status)
			raw, _ := store.CanonicalJSON(payload)
			_, _ = w.Write(raw)
		}

		switch r.URL.Path {
		case "/api/agent/register":
			if m.failNextReg {
				m.failNextReg = false
				writeJSON(http.StatusInternalServerError, map[string]any{"error": "temporary failure"})
				return
			}
			m.regID = mapString(body, "registration_id", "")
			m.token = mapString(body, "node_token", "")
			writeJSON(http.StatusOK, map[string]any{
				"protocol": Protocol,
				"node_id":  m.nodeID,
				"status":   "active",
				"revision": m.revision,
				"imported": []map[string]any{
					{"id": m.userID, "name": "alice", "old_name": "alice"},
				},
			})

		case "/api/agent/sync":
			if r.Header.Get("Authorization") != "Bearer "+m.token {
				writeJSON(http.StatusUnauthorized, map[string]any{"error": "unauthorized"})
				return
			}
			if m.return410 {
				writeJSON(http.StatusGone, map[string]any{"error": "node deleted"})
				return
			}
			applied, _ := parseInt64Exact(body["applied_revision"])
			var acks []map[string]any
			if batches, ok := body["batches"].([]any); ok {
				for _, rb := range batches {
					if bm, ok := rb.(map[string]any); ok {
						acks = append(acks, map[string]any{
							"epoch": bm["epoch"],
							"seq":   bm["seq"],
						})
						m.syncedBatches++
					}
				}
			}
			if acks == nil {
				acks = []map[string]any{}
			}
			var desired any
			if applied < m.revision {
				desired = map[string]any{
					"node_id":  m.nodeID,
					"revision": m.revision,
					"users":    []map[string]any{m.lastDesiredUser},
				}
			}
			writeJSON(http.StatusOK, map[string]any{
				"protocol":    Protocol,
				"node_id":     m.nodeID,
				"status":      "active",
				"server_time": time.Now().Unix(),
				"ack":         acks,
				"desired":     desired,
			})

		case "/api/agent/wait":
			if r.Header.Get("Authorization") != "Bearer "+m.token {
				writeJSON(http.StatusUnauthorized, map[string]any{"error": "unauthorized"})
				return
			}
			if m.return410 {
				writeJSON(http.StatusGone, map[string]any{"error": "node deleted"})
				return
			}
			changed := m.waitChanged
			m.waitChanged = false
			rev := m.revision
			if changed {
				rev++
			}
			writeJSON(http.StatusOK, map[string]any{
				"protocol": Protocol,
				"changed":  changed,
				"revision": rev,
			})

		case "/api/agent/activity":
			if r.Header.Get("Authorization") != "Bearer "+m.token {
				writeJSON(http.StatusUnauthorized, map[string]any{"error": "unauthorized"})
				return
			}
			if m.return410 {
				writeJSON(http.StatusGone, map[string]any{"error": "node deleted"})
				return
			}
			var acks []string
			if events, ok := body["events"].([]any); ok {
				for _, re := range events {
					if em, ok := re.(map[string]any); ok {
						if eid := mapString(em, "id", ""); eid != "" {
							acks = append(acks, eid)
							m.activityAcked++
						}
					}
				}
			}
			if acks == nil {
				acks = []string{}
			}
			writeJSON(http.StatusOK, map[string]any{
				"protocol": Protocol,
				"ack":      acks,
			})

		case "/api/agent/detach":
			if r.Header.Get("Authorization") != "Bearer "+m.token {
				writeJSON(http.StatusUnauthorized, map[string]any{"error": "unauthorized"})
				return
			}
			m.detachCalled = true
			writeJSON(http.StatusOK, map[string]any{
				"protocol": Protocol,
				"ok":       true,
			})

		default:
			http.NotFound(w, r)
		}
	})
}

func setupTestEnv(t *testing.T) (rootDir, cfgPath, statePath string, center *mockCenter, srv *httptest.Server) {
	t.Helper()
	rootDir = t.TempDir()
	t.Setenv("YSQ_TEST_ROOT", rootDir)

	cfgPath = DefaultConfigPath()
	statePath = DefaultStatePath()

	uid := "u_11111111111111111111111111111111"
	userUUID := "550e8400-e29b-41d4-a716-446655440000"
	state := map[string]any{
		"server_ip":   "203.0.113.10",
		"reality_sni": "www.example.com",
		"public_key":  "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA",
		"short_id":    "aabb",
		"nodes": []map[string]any{
			{"name": "node-vless", "tag": "vless-in", "type": "vless", "port": 443},
		},
		"users": []map[string]any{
			{"name": "alice", "uuid": userUUID, "tuic_pass": "pass123456"},
		},
	}
	if err := AtomicJSON(statePath, state); err != nil {
		t.Fatalf("write initial state: %v", err)
	}

	center = &mockCenter{
		nodeID:   "n_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		userID:   uid,
		revision: 1,
		lastDesiredUser: map[string]any{
			"id":        uid,
			"name":      "alice",
			"uuid":      userUUID,
			"tuic_pass": "pass123456",
			"enabled":   true,
		},
	}
	srv = httptest.NewServer(center.handler())
	t.Cleanup(srv.Close)
	return rootDir, cfgPath, statePath, center, srv
}

func fakeHelperRunner(t *testing.T, statePath string, detached *atomic.Bool) HelperRunnerFunc {
	t.Helper()
	return func(ctx context.Context, cfg map[string]any, action string, extra []string, timeout time.Duration) ([]byte, error) {
		switch action {
		case "agent-inventory":
			st, err := ReadJSONMap(statePath)
			if err != nil {
				return nil, err
			}
			inv := map[string]any{
				"users": st["users"],
				"inbounds": []map[string]any{
					{"name": "node-vless", "tag": "vless-in", "type": "vless", "port": 443, "server": "203.0.113.10"},
				},
			}
			return store.CanonicalJSON(inv)
		case "agent-apply":
			desired, err := ReadJSONMap(extra[0])
			if err != nil {
				return nil, err
			}
			st, err := ReadJSONMap(statePath)
			if err != nil {
				return nil, err
			}
			st["management"] = map[string]any{
				"mode":     "managed",
				"node_id":  desired["node_id"],
				"revision": desired["revision"],
			}
			users, _ := desired["users"].([]any)
			for _, ru := range users {
				if um, ok := ru.(map[string]any); ok {
					um["stats_key"] = um["id"]
				}
			}
			st["users"] = users
			if err := AtomicJSON(statePath, st); err != nil {
				return nil, err
			}
			return []byte("ok"), nil
		case "agent-detach":
			if detached != nil {
				detached.Store(true)
			}
			return []byte("detached"), nil
		default:
			return nil, agentErr("unexpected action: %s", action)
		}
	}
}

func TestFullAgentLifecycleRegisterSyncSampleWaitAnd410Detach(t *testing.T) {
	_, cfgPath, statePath, center, srv := setupTestEnv(t)

	// Seed legacy SQLite header at DefaultDBPath to verify non-destructive .bolt fallback end-to-end!
	legacyDBPath := DefaultDBPath()
	if _, err := store.EnsurePrivateDir(legacyDBPath); err != nil {
		t.Fatalf("mkdir db: %v", err)
	}
	legacyBytes := append([]byte("SQLite format 3\x00"), bytes.Repeat([]byte("L"), 64)...)
	if err := os.WriteFile(legacyDBPath, legacyBytes, 0o600); err != nil {
		t.Fatalf("seed sqlite: %v", err)
	}

	var detached atomic.Bool
	var upCounter atomic.Int64
	upCounter.Store(1000)

	opts := Options{
		AllowLoopbackHTTP: true,
		Version:           "0.2.0-test",
		HelperRunner:      fakeHelperRunner(t, statePath, &detached),
		CoreProbe: func(_ map[string]any, _ bool) (string, error) {
			return "boot1:1234:5678", nil
		},
		Collector: func(_ context.Context, _ map[string]any) (map[string]store.Counter, error) {
			return map[string]store.Counter{
				center.userID: {Uplink: upCounter.Load(), Downlink: 2000},
			}, nil
		},
		Stderr: ioDiscard{},
	}

	// First join fails on server 500 -> durable registration_payload preserved.
	center.failNextReg = true
	if _, err := Join(context.Background(), cfgPath, srv.URL, "code-1111111111111111", "vps-1", "", opts); err == nil {
		t.Fatal("expected initial join failure on 500")
	}

	// Retry join with a regenerated join_code -> idempotently reuses durable registration_id + node_token!
	regRes, err := Join(context.Background(), cfgPath, srv.URL, "code-2222222222222222", "vps-1", "", opts)
	if err != nil {
		t.Fatalf("Join retry failed: %v", err)
	}
	if regRes["node_id"] != center.nodeID || regRes["status"] != "active" {
		t.Fatalf("unexpected register result: %+v", regRes)
	}

	ag, err := New(cfgPath, opts)
	if err != nil {
		t.Fatalf("New agent: %v", err)
	}
	if ag.Ledger().Path() != legacyDBPath+".bolt" {
		t.Fatalf("expected .bolt fallback, got %q", ag.Ledger().Path())
	}

	// SyncOnce applies desired revision 1.
	syncRes, err := ag.SyncOnce(context.Background(), false, true)
	if err != nil {
		t.Fatalf("SyncOnce 1: %v", err)
	}
	if syncRes["applied"] != true || syncRes["applied_revision"] != int64(1) {
		t.Fatalf("expected revision 1 applied, got %+v", syncRes)
	}

	// SampleOnce 1 establishes baseline & records initial traffic for new stats_key u_...
	s1, err := ag.SampleOnce(context.Background(), false)
	if err != nil {
		t.Fatalf("SampleOnce 1: %v", err)
	}
	if s1["up"] != int64(1000) {
		t.Fatalf("SampleOnce 1 unexpected: %+v", s1)
	}

	// Counter drop within same epoch must fail with CollectorError and preserve baseline!
	upCounter.Store(500)
	if _, err := ag.SampleOnce(context.Background(), false); err == nil {
		t.Fatal("expected CollectorError on counter drop")
	}

	// Monotonic increase succeeds.
	upCounter.Store(1600)
	s2, err := ag.SampleOnce(context.Background(), false)
	if err != nil {
		t.Fatalf("SampleOnce 2: %v", err)
	}
	if s2["up"] != int64(600) {
		t.Fatalf("SampleOnce 2 delta = %+v, want up=600", s2)
	}

	// SyncOnce packages and uploads outbox batch -> center ACKs it.
	syncRes2, err := ag.SyncOnce(context.Background(), true, true)
	if err != nil {
		t.Fatalf("SyncOnce 2: %v", err)
	}
	if syncRes2["acknowledged_batches"] != 1 {
		t.Fatalf("expected 1 acked batch, got %+v", syncRes2)
	}

	// WaitChanges receives changed=true notification.
	center.mu.Lock()
	center.waitChanged = true
	center.mu.Unlock()
	waitRes, err := ag.WaitChanges(context.Background(), false)
	if err != nil || waitRes["changed"] != true {
		t.Fatalf("WaitChanges = (%+v, %v)", waitRes, err)
	}

	// Center deletes node (HTTP 410) -> SyncOnce automatically triggers local detach and removes node_token!
	center.mu.Lock()
	center.return410 = true
	center.mu.Unlock()
	detRes, err := ag.SyncOnce(context.Background(), false, true)
	if err != nil {
		t.Fatalf("SyncOnce 410: %v", err)
	}
	if detRes["status"] != "detached" || !detached.Load() {
		t.Fatalf("expected automatic local detach on 410, got %+v (detached=%v)", detRes, detached.Load())
	}
	finalCfg, err := ReadJSONMap(cfgPath)
	if err != nil {
		t.Fatalf("read final config: %v", err)
	}
	if _, hasToken := finalCfg["node_token"]; hasToken {
		t.Fatal("node_token must be removed on detach")
	}

	// Legacy SQLite file must remain untouched.
	afterLegacy, _ := os.ReadFile(legacyDBPath)
	if !bytes.Equal(afterLegacy, legacyBytes) {
		t.Fatal("legacy SQLite file was altered")
	}
}

func TestForcedDetachAndConcurrentRunWithCLIStatusAndSample(t *testing.T) {
	rootDir, cfgPath, statePath, center, srv := setupTestEnv(t)

	// Configure activity log file & core config for daemon activity goroutines.
	logDir := filepath.Join(rootDir, "var", "log", "sing-box")
	if err := os.MkdirAll(logDir, 0o755); err != nil {
		t.Fatalf("mkdir logDir: %v", err)
	}
	logPath := filepath.Join(logDir, "sing-box.log")
	coreCfgPath := filepath.Join(filepath.Dir(statePath), "config.json")
	if err := os.WriteFile(coreCfgPath, []byte(`{"log":{"level":"info","timestamp":true}}`), 0o600); err != nil {
		t.Fatalf("write coreCfg: %v", err)
	}
	nowUTC := time.Now().UTC().Format("2006-01-02 15:04:05")
	logLine := "+0000 " + nowUTC + " INFO [42 1ms] inbound/vless[vless-in]: [" + center.userID + "] inbound connection to example.com:443\n"
	if err := os.WriteFile(logPath, []byte(logLine), 0o640); err != nil {
		t.Fatalf("write sing-box.log: %v", err)
	}

	var detached atomic.Bool
	var upCounter atomic.Int64
	upCounter.Store(250)

	opts := Options{
		AllowLoopbackHTTP: true,
		Version:           "0.2.0-test",
		HelperRunner:      fakeHelperRunner(t, statePath, &detached),
		CoreProbe: func(_ map[string]any, _ bool) (string, error) {
			return "boot1:99:111", nil
		},
		Collector: func(_ context.Context, _ map[string]any) (map[string]store.Counter, error) {
			return map[string]store.Counter{
				center.userID: {Uplink: upCounter.Add(50), Downlink: 100},
			}, nil
		},
		Stderr:         ioDiscard{},
		SampleInterval: 150 * time.Millisecond,
		SyncInterval:   200 * time.Millisecond,
		WaitSeconds:    1,
	}

	if _, err := Join(context.Background(), cfgPath, srv.URL, "code-3333333333333333", "vps-2", "", opts); err != nil {
		t.Fatalf("Join: %v", err)
	}

	daemon, err := New(cfgPath, opts)
	if err != nil {
		t.Fatalf("New daemon: %v", err)
	}

	runCtx, cancelRun := context.WithCancel(context.Background())
	runDone := make(chan error, 1)
	go func() {
		runDone <- daemon.Run(runCtx)
	}()

	// Wait briefly for daemon to sync + start workers, then concurrently run CLI Status() and SampleOnce()!
	deadline := time.Now().Add(4 * time.Second)
	var cliStatus map[string]any
	for time.Now().Before(deadline) {
		cliAgent, err := New(cfgPath, opts)
		if err != nil {
			t.Fatalf("CLI New: %v", err)
		}
		st, err := cliAgent.Status()
		if err != nil {
			t.Fatalf("CLI Status while daemon running: %v", err)
		}
		cliStatus = st
		if rev, _ := parseInt64Exact(st["applied_revision"]); rev == 1 {
			if _, sErr := cliAgent.SampleOnce(context.Background(), false); sErr != nil {
				var lb *LockBusy
				if !errors.As(sErr, &lb) {
					t.Fatalf("CLI SampleOnce while daemon running: %v", sErr)
				}
			}
			center.mu.Lock()
			actAcked := center.activityAcked
			center.mu.Unlock()
			if actAcked >= 1 {
				break
			}
		}
		time.Sleep(100 * time.Millisecond)
	}

	if rev, _ := parseInt64Exact(cliStatus["applied_revision"]); rev != 1 {
		t.Fatalf("daemon did not apply revision 1 in time: %+v", cliStatus)
	}
	center.mu.Lock()
	actAcked := center.activityAcked
	center.mu.Unlock()
	if actAcked < 1 {
		t.Fatalf("expected daemon activity uploader to upload at least 1 event, got %d", actAcked)
	}

	// Cancel daemon and verify fast graceful shutdown.
	cancelRun()
	select {
	case err := <-runDone:
		if err != nil {
			t.Fatalf("daemon.Run error: %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("daemon.Run did not shut down promptly on context cancel")
	}

	// Shut down mock server to test non-forced vs forced Detach!
	srv.Close()
	cliAgent, err := New(cfgPath, opts)
	if err != nil {
		t.Fatalf("New for detach: %v", err)
	}
	if _, err := cliAgent.Detach(context.Background(), false); err == nil {
		t.Fatal("expected non-forced Detach to fail when center is unreachable")
	}
	if detached.Load() {
		t.Fatal("agent-detach should not have run on failed non-forced detach")
	}

	// Forced local detach succeeds even with unreachable center.
	detRes, err := cliAgent.Detach(context.Background(), true)
	if err != nil {
		t.Fatalf("forced Detach failed: %v", err)
	}
	if detRes["status"] != "detached" || !detached.Load() {
		t.Fatalf("unexpected forced detach result: %+v", detRes)
	}
}

func TestTransportSecurityAndRedaction(t *testing.T) {
	// Reject HTTP on non-loopback even if allowLoopbackHTTP=true.
	if _, err := ValidateOrigin("http://panel.example.com", true); err == nil {
		t.Fatal("expected error for non-loopback HTTP")
	}
	// Reject HTTP on loopback when allowLoopbackHTTP=false.
	if _, err := ValidateOrigin("http://127.0.0.1:8099", false); err == nil {
		t.Fatal("expected error for loopback HTTP without flag")
	}

	// Refuse 3xx redirects.
	redirSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "https://evil.example.com/", http.StatusFound)
	}))
	defer redirSrv.Close()

	tr, err := NewTransport(redirSrv.URL, "token-abcdefghijklmnopqrstuvwxyz123456", "0.2.0", true, 5*time.Second)
	if err != nil {
		t.Fatalf("NewTransport: %v", err)
	}
	defer tr.Close()

	_, err = tr.Post(context.Background(), "/api/agent/sync", map[string]any{"protocol": 1}, true)
	var te *TransportError
	if !errors.As(err, &te) || te.Status != http.StatusFound {
		t.Fatalf("expected TransportError(302), got %v", err)
	}

	// Secret redaction.
	cfg := map[string]any{
		"node_token": "SECRET_NODE_TOKEN_ABC123",
		"registration_payload": map[string]any{
			"join_code": "SECRET_JOIN_CODE_XYZ",
		},
	}
	msg := "failed Bearer EXTRA_BEARER with SECRET_NODE_TOKEN_ABC123 and SECRET_JOIN_CODE_XYZ and 550e8400-e29b-41d4-a716-446655440000"
	redacted := Redact(msg, cfg)
	for _, secret := range []string{"SECRET_NODE_TOKEN_ABC123", "SECRET_JOIN_CODE_XYZ", "EXTRA_BEARER", "550e8400-e29b-41d4-a716-446655440000"} {
		if strings.Contains(redacted, secret) {
			t.Fatalf("Redact leaked %q in %q", secret, redacted)
		}
	}
}

func TestWaitChangesStaleRevisionAndRunBackoff(t *testing.T) {
	_, cfgPath, statePath, center, srv := setupTestEnv(t)
	center.revision = 5

	opts := Options{
		AllowLoopbackHTTP: true,
		Version:           "0.2.0-test",
		HelperRunner:      fakeHelperRunner(t, statePath, nil),
		CoreProbe: func(_ map[string]any, _ bool) (string, error) {
			return "boot1:100:200", nil
		},
		Collector: func(_ context.Context, _ map[string]any) (map[string]store.Counter, error) {
			return map[string]store.Counter{}, nil
		},
		Stderr:         ioDiscard{},
		SampleInterval: 10 * time.Second,
		SyncInterval:   10 * time.Second,
		WaitSeconds:    1,
	}

	if _, err := Join(context.Background(), cfgPath, srv.URL, "code-4444444444444444", "vps-stale", "", opts); err != nil {
		t.Fatalf("Join: %v", err)
	}
	ag, err := New(cfgPath, opts)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	syncRes, err := ag.SyncOnce(context.Background(), false, true)
	if err != nil || syncRes["applied_revision"] != int64(5) {
		t.Fatalf("initial SyncOnce = (%+v, %v), want applied_revision=5", syncRes, err)
	}

	// Custom server returning stale or fresh change notifications on /api/agent/wait.
	var waitCalls atomic.Int32
	var syncCalls atomic.Int32
	var waitMu sync.Mutex
	waitRespChanged := true
	waitRespRev := int64(3) // older than applied_revision=5 (e.g. DB restore)

	staleSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/agent/wait":
			waitCalls.Add(1)
			waitMu.Lock()
			ch := waitRespChanged
			rv := waitRespRev
			waitMu.Unlock()
			raw, _ := store.CanonicalJSON(map[string]any{
				"protocol": Protocol,
				"changed":  ch,
				"revision": rv,
			})
			_, _ = w.Write(raw)
		case "/api/agent/sync":
			syncCalls.Add(1)
			raw, _ := store.CanonicalJSON(map[string]any{
				"protocol":    Protocol,
				"node_id":     center.nodeID,
				"status":      "active",
				"server_time": time.Now().Unix(),
				"ack":         []any{},
				"desired":     nil,
			})
			_, _ = w.Write(raw)
		default:
			http.NotFound(w, r)
		}
	}))
	defer staleSrv.Close()

	// Point agent config at staleSrv.
	cfgMap, err := ReadJSONMap(cfgPath)
	if err != nil {
		t.Fatalf("read cfg: %v", err)
	}
	cfgMap["center_url"] = staleSrv.URL
	if err := AtomicJSON(cfgPath, cfgMap); err != nil {
		t.Fatalf("write cfg: %v", err)
	}

	ag, err = New(cfgPath, opts)
	if err != nil {
		t.Fatalf("New stale agent: %v", err)
	}

	// 1. rev < appliedRev with changed=true -> marked stale_revision=true, changed=false.
	res, err := ag.WaitChanges(context.Background(), false)
	if err != nil {
		t.Fatalf("WaitChanges (rev < applied): %v", err)
	}
	if res["changed"] != false || res["stale_revision"] != true {
		t.Fatalf("expected changed=false, stale_revision=true for rev=3 < applied=5, got %+v", res)
	}
	if ag.notifiedRevision != 0 {
		t.Fatalf("notifiedRevision should not be lowered/set on stale rev, got %d", ag.notifiedRevision)
	}

	// 2. rev == appliedRev with changed=true -> also stale_revision=true, changed=false.
	waitMu.Lock()
	waitRespRev = 5
	waitMu.Unlock()
	res, err = ag.WaitChanges(context.Background(), false)
	if err != nil {
		t.Fatalf("WaitChanges (rev == applied): %v", err)
	}
	if res["changed"] != false || res["stale_revision"] != true {
		t.Fatalf("expected changed=false, stale_revision=true for rev=5 == applied=5, got %+v", res)
	}

	// 3. rev > appliedRev with changed=true -> normal instant notification preserved.
	waitMu.Lock()
	waitRespRev = 6
	waitMu.Unlock()
	res, err = ag.WaitChanges(context.Background(), false)
	if err != nil {
		t.Fatalf("WaitChanges (rev > applied): %v", err)
	}
	if res["changed"] != true || mapBool(res, false, "stale_revision") {
		t.Fatalf("expected changed=true without stale_revision for rev=6 > applied=5, got %+v", res)
	}
	if ag.notifiedRevision != 6 {
		t.Fatalf("notifiedRevision = %d, want 6", ag.notifiedRevision)
	}

	// 4. Same rev=6 returned again before SyncOnce advances appliedRev -> rev <= cursor -> stale.
	res, err = ag.WaitChanges(context.Background(), false)
	if err != nil {
		t.Fatalf("WaitChanges (rev == cursor): %v", err)
	}
	if res["changed"] != false || res["stale_revision"] != true {
		t.Fatalf("expected stale_revision=true when rev=6 <= cursor=6, got %+v", res)
	}

	// 5. In Run(), stale rev=2 must sleep 3s (no 0ms storm) and must NOT trigger signalChange().
	waitCalls.Store(0)
	syncCalls.Store(0)
	waitMu.Lock()
	waitRespChanged = true
	waitRespRev = 2
	waitMu.Unlock()

	daemon, err := New(cfgPath, opts)
	if err != nil {
		t.Fatalf("New daemon: %v", err)
	}
	runCtx, cancelRun := context.WithCancel(context.Background())
	runDone := make(chan error, 1)
	go func() {
		runDone <- daemon.Run(runCtx)
	}()

	time.Sleep(400 * time.Millisecond)
	cancelRun()
	select {
	case err := <-runDone:
		if err != nil {
			t.Fatalf("daemon.Run error: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("daemon.Run did not cancel promptly during stale_revision sleep")
	}

	if got := waitCalls.Load(); got != 1 {
		t.Fatalf("waitCalls = %d during 400ms stale revision window, want 1 (backoff must prevent 0ms storm)", got)
	}
	if got := syncCalls.Load(); got != 1 {
		t.Fatalf("syncCalls = %d (expected only initial sync=1, no stale signalChange wakeups)", got)
	}

	// 6. In Run(), valid rev=7 > applied=5 triggers instant signalChange() without waiting for SyncInterval.
	waitCalls.Store(0)
	syncCalls.Store(0)
	var firstWaitDone atomic.Bool
	stopWait := make(chan struct{})
	instantSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/agent/wait":
			waitCalls.Add(1)
			if firstWaitDone.CompareAndSwap(false, true) {
				raw, _ := store.CanonicalJSON(map[string]any{
					"protocol": Protocol,
					"changed":  true,
					"revision": 7,
				})
				_, _ = w.Write(raw)
				return
			}
			// Subsequent poll blocks until request context is cancelled or server cleanup.
			select {
			case <-r.Context().Done():
			case <-stopWait:
			case <-time.After(5 * time.Second):
			}
		case "/api/agent/sync":
			syncCalls.Add(1)
			raw, _ := store.CanonicalJSON(map[string]any{
				"protocol":    Protocol,
				"node_id":     center.nodeID,
				"status":      "active",
				"server_time": time.Now().Unix(),
				"ack":         []any{},
				"desired":     nil,
			})
			_, _ = w.Write(raw)
		default:
			http.NotFound(w, r)
		}
	}))
	defer instantSrv.Close()
	defer close(stopWait)

	cfgMap["center_url"] = instantSrv.URL
	if err := AtomicJSON(cfgPath, cfgMap); err != nil {
		t.Fatalf("write cfg instantSrv: %v", err)
	}
	daemon2, err := New(cfgPath, opts)
	if err != nil {
		t.Fatalf("New daemon2: %v", err)
	}
	runCtx2, cancelRun2 := context.WithCancel(context.Background())
	runDone2 := make(chan error, 1)
	go func() {
		runDone2 <- daemon2.Run(runCtx2)
	}()

	deadline := time.Now().Add(1500 * time.Millisecond)
	for time.Now().Before(deadline) && syncCalls.Load() < 2 {
		time.Sleep(25 * time.Millisecond)
	}
	cancelRun2()
	select {
	case err := <-runDone2:
		if err != nil {
			t.Fatalf("daemon2.Run error: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("daemon2.Run did not shut down promptly")
	}
	if syncCalls.Load() < 2 {
		t.Fatalf("expected instant sync wakeup on rev=7 > applied=5, got syncCalls=%d", syncCalls.Load())
	}
}

func TestInboundFieldTruncationAndTUICFields(t *testing.T) {
	_, cfgPath, statePath, center, _ := setupTestEnv(t)

	longName := strings.Repeat("名", 200)
	longTag := strings.Repeat("标", 200)
	longVlessType := "vless-" + strings.Repeat("v", 100)
	longTuicType := "tuic-" + strings.Repeat("t", 100)
	longServer := strings.Repeat("s", 300)
	longRealitySNI := strings.Repeat("r", 300)
	longTuicSNI := strings.Repeat("u", 300)
	longPubKey := strings.Repeat("p", 300)
	longShortID := strings.Repeat("i", 300)

	state := map[string]any{
		"server_ip":   longServer,
		"reality_sni": longRealitySNI,
		"tuic_sni":    longTuicSNI,
		"public_key":  longPubKey,
		"short_id":    longShortID,
		"nodes": []map[string]any{
			{"name": longName, "tag": longTag, "type": longVlessType, "port": 443},
			{"name": longName, "tag": longTag, "type": longTuicType, "port": 8443},
		},
		"users": []map[string]any{
			{"name": "alice", "uuid": "550e8400-e29b-41d4-a716-446655440000", "tuic_pass": "pass123456"},
		},
	}
	if err := AtomicJSON(statePath, state); err != nil {
		t.Fatalf("write state: %v", err)
	}

	var regMu sync.Mutex
	var regPayload map[string]any
	regSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		dec := json.NewDecoder(r.Body)
		dec.UseNumber()
		if err := dec.Decode(&body); err != nil {
			http.Error(w, `{"error":"bad json"}`, http.StatusBadRequest)
			return
		}
		if r.URL.Path == "/api/agent/register" {
			regMu.Lock()
			regPayload = body
			regMu.Unlock()
			w.Header().Set("Content-Type", "application/json")
			raw, _ := store.CanonicalJSON(map[string]any{
				"protocol": Protocol,
				"node_id":  center.nodeID,
				"status":   "active",
				"revision": 1,
				"imported": []map[string]any{},
			})
			_, _ = w.Write(raw)
			return
		}
		http.NotFound(w, r)
	}))
	defer regSrv.Close()

	opts := Options{
		AllowLoopbackHTTP: true,
		Version:           "0.2.0-test",
		HelperRunner: func(ctx context.Context, cfg map[string]any, action string, extra []string, timeout time.Duration) ([]byte, error) {
			if action != "agent-inventory" {
				return nil, agentErr("unexpected action: %s", action)
			}
			inv := map[string]any{
				"users": state["users"],
				"inbounds": []map[string]any{
					{
						"name":             longName,
						"tag":              longTag,
						"type":             longVlessType,
						"port":             443,
						"server":           longServer,
						"sni":              longRealitySNI,
						"public_key":       longPubKey,
						"short_id":         longShortID,
						"skip_cert_verify": false,
					},
				},
			}
			return store.CanonicalJSON(inv)
		},
		Stderr: ioDiscard{},
	}

	if _, err := Join(context.Background(), cfgPath, regSrv.URL, "code-5555555555555555", "vps-trunc", "", opts); err != nil {
		t.Fatalf("Join: %v", err)
	}

	// Verify Join() truncated inbound fields to center-panel.py limits.
	regMu.Lock()
	rawInbs, _ := regPayload["inbounds"].([]any)
	regMu.Unlock()
	if len(rawInbs) != 1 {
		t.Fatalf("expected 1 registered inbound, got %d", len(rawInbs))
	}
	regInb := rawInbs[0].(map[string]any)
	wantLimits := map[string]int{
		"name":       160,
		"tag":        160,
		"type":       64,
		"server":     253,
		"sni":        253,
		"public_key": 253,
		"short_id":   253,
	}
	for k, wantLen := range wantLimits {
		got := mapString(regInb, k, "")
		if gotLen := len([]rune(got)); gotLen != wantLen {
			t.Fatalf("Join inbound[%q] rune len = %d, want %d", k, gotLen, wantLen)
		}
	}

	// Verify subscriptionInbounds() truncates all fields and clears public_key/short_id for TUIC.
	ag, err := New(cfgPath, opts)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	inbs, err := ag.subscriptionInbounds()
	if err != nil {
		t.Fatalf("subscriptionInbounds: %v", err)
	}
	if len(inbs) != 2 {
		t.Fatalf("expected 2 subscription inbounds, got %d", len(inbs))
	}

	vlessInb := inbs[0]
	for k, wantLen := range wantLimits {
		got := mapString(vlessInb, k, "")
		if gotLen := len([]rune(got)); gotLen != wantLen {
			t.Fatalf("subscriptionInbounds vless[%q] rune len = %d, want %d", k, gotLen, wantLen)
		}
	}
	if vlessInb["skip_cert_verify"] != false {
		t.Fatalf("vless skip_cert_verify = %v, want false", vlessInb["skip_cert_verify"])
	}
	if !strings.HasPrefix(mapString(vlessInb, "sni", ""), "rrr") {
		t.Fatalf("vless sni should come from reality_sni, got %q", mapString(vlessInb, "sni", ""))
	}

	tuicInb := inbs[1]
	for k, wantLen := range map[string]int{
		"name":   160,
		"tag":    160,
		"type":   64,
		"server": 253,
		"sni":    253,
	} {
		got := mapString(tuicInb, k, "")
		if gotLen := len([]rune(got)); gotLen != wantLen {
			t.Fatalf("subscriptionInbounds tuic[%q] rune len = %d, want %d", k, gotLen, wantLen)
		}
	}
	if tuicInb["public_key"] != "" || tuicInb["short_id"] != "" {
		t.Fatalf("TUIC inbound must send empty public_key/short_id, got public_key=%q short_id=%q", tuicInb["public_key"], tuicInb["short_id"])
	}
	if tuicInb["skip_cert_verify"] != true {
		t.Fatalf("tuic skip_cert_verify = %v, want true", tuicInb["skip_cert_verify"])
	}
	if !strings.HasPrefix(mapString(tuicInb, "sni", ""), "uuu") {
		t.Fatalf("tuic sni should come from tuic_sni, got %q", mapString(tuicInb, "sni", ""))
	}
}

type ioDiscard struct{}

func (ioDiscard) Write(p []byte) (int, error) { return len(p), nil }
