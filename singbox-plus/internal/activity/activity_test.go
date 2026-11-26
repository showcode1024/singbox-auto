package activity

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/showcode1024/singbox-auto/singbox-plus/internal/store"
)

type fakePoster struct {
	fn func(ctx context.Context, path string, body any, authenticated bool) (map[string]any, error)
}

func (f fakePoster) Post(ctx context.Context, path string, body any, authenticated bool) (map[string]any, error) {
	return f.fn(ctx, path, body, authenticated)
}

func TestCollectorRotatedSegmentsParsingAndUpload(t *testing.T) {
	dir := t.TempDir()
	logDir := filepath.Join(dir, "logs")
	if err := os.MkdirAll(logDir, 0o755); err != nil {
		t.Fatalf("mkdir logs: %v", err)
	}
	logPath := filepath.Join(logDir, "sing-box.log")
	seg1Path := filepath.Join(logDir, "sing-box.20261126-100000-0001.log")
	coreCfgPath := filepath.Join(dir, "config.json")
	statePath := filepath.Join(dir, "state.json")
	dbPath := filepath.Join(dir, "agent.db")
	agentCfgPath := filepath.Join(dir, "agent-config.json")

	nodeID := "n_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	uid1 := "u_11111111111111111111111111111111"

	// Core sing-box config with info level, timestamp=true, empty output (stdout wrapped by singbox-plus wrap).
	if err := os.WriteFile(coreCfgPath, []byte(`{"log":{"level":"info","timestamp":true}}`), 0o600); err != nil {
		t.Fatalf("write core config: %v", err)
	}
	stateJSON := `{"management":{"node_id":"` + nodeID + `"},"users":[{"id":"` + uid1 + `","name":"alice","stats_key":"` + uid1 + `"}]}`
	if err := os.WriteFile(statePath, []byte(stateJSON), 0o600); err != nil {
		t.Fatalf("write state: %v", err)
	}
	agentCfg := map[string]any{
		"node_id":                   nodeID,
		"center_url":                "https://panel.example.com",
		"db_path":                   dbPath,
		"state_path":                statePath,
		"status":                    "active",
		"activity_log_path":         logPath,
		"activity_core_config_path": coreCfgPath,
	}
	rawCfg, _ := json.Marshal(agentCfg)
	if err := os.WriteFile(agentCfgPath, rawCfg, 0o600); err != nil {
		t.Fatalf("write agent config: %v", err)
	}

	// Rotated segment 1: authenticated TCP connection for cid=100, then error for cid=100.
	seg1Lines := "" +
		"\x1b[36m+0000 2026-11-26 10:00:01 INFO [100 0ms] inbound/vless[vless-in]: inbound connection from 198.51.100.7:54321\x1b[0m\n" +
		"+0000 2026-11-26 10:00:02 INFO [100 1ms] inbound/vless[vless-in]: [" + uid1 + "] inbound connection to example.com:443\n" +
		"+0000 2026-11-26 10:00:03 ERROR [100 2ms] inbound/vless[vless-in]: connection reset by peer\n"
	if err := os.WriteFile(seg1Path, []byte(seg1Lines), 0o640); err != nil {
		t.Fatalf("write seg1: %v", err)
	}

	// Active log: cid=100 reused by unauthenticated scanner -> early error must NOT be attributed to uid1!
	// Followed by a UDP packet connection for cid=200.
	activeLines := "" +
		"+0000 2026-11-26 10:00:04 INFO [100 0ms] inbound/vless[vless-in]: inbound connection from 203.0.113.99:40000\n" +
		"+0000 2026-11-26 10:00:05 ERROR [100 1ms] inbound/vless[vless-in]: tls handshake failed\n" +
		"+0000 2026-11-26 10:00:06 INFO [200 0ms] inbound/tuic[tuic-in]: inbound packet connection from [2001:db8::5]:51234\n" +
		"+0000 2026-11-26 10:00:07 INFO [200 1ms] inbound/tuic[tuic-in]: [" + uid1 + "] inbound packet connection to dns.google:53\n"
	if err := os.WriteFile(logPath, []byte(activeLines), 0o640); err != nil {
		t.Fatalf("write active log: %v", err)
	}

	col, err := NewCollector(agentCfgPath)
	if err != nil {
		t.Fatalf("NewCollector: %v", err)
	}
	fixedNow := time.Date(2026, 11, 26, 10, 1, 0, 0, time.UTC)
	col.SetNow(func() time.Time { return fixedNow })

	// Pass 1 reads seg1 and advances cursor to active log.
	hasMore, changed, err := col.CollectOnce()
	if err != nil {
		t.Fatalf("CollectOnce 1: %v", err)
	}
	if !hasMore || !changed {
		t.Fatalf("expected hasMore=true changed=true after seg1, got (%v, %v)", hasMore, changed)
	}

	// Pass 2 reads active log to EOF.
	hasMore, changed, err = col.CollectOnce()
	if err != nil {
		t.Fatalf("CollectOnce 2: %v", err)
	}
	if hasMore || !changed {
		t.Fatalf("expected hasMore=false changed=true after active log, got (%v, %v)", hasMore, changed)
	}

	// Pass 3 hits idle fast path.
	hasMore, changed, err = col.CollectOnce()
	if err != nil {
		t.Fatalf("CollectOnce 3: %v", err)
	}
	if hasMore || changed {
		t.Fatalf("expected idle fast path (false, false), got (%v, %v)", hasMore, changed)
	}

	rawEvents, _, err := col.Store().PeekBatch(100)
	if err != nil {
		t.Fatalf("PeekBatch: %v", err)
	}
	if len(rawEvents) != 4 {
		t.Fatalf("expected 4 events, got %d", len(rawEvents))
	}

	var events []store.ActivityEvent
	for _, raw := range rawEvents {
		var ev store.ActivityEvent
		if err := json.Unmarshal(raw, &ev); err != nil {
			t.Fatalf("unmarshal: %v", err)
		}
		events = append(events, ev)
	}

	// Event 0: authenticated TCP connection for uid1.
	if events[0].Kind != "connection" || events[0].UserID == nil || *events[0].UserID != uid1 ||
		events[0].SourceIP != "198.51.100.7" || events[0].Target != "example.com" || events[0].Port != 443 || events[0].Network != "tcp" {
		t.Errorf("event 0 mismatch: %+v", events[0])
	}
	// Event 1: error attributed to uid1 (same authenticated cid=100).
	if events[1].Kind != "error" || events[1].UserID == nil || *events[1].UserID != uid1 {
		t.Errorf("event 1 mismatch: %+v", events[1])
	}
	// Event 2: reused cid=100 handshake error must NOT have uid1!
	if events[2].Kind != "error" || events[2].UserID != nil || events[2].SourceIP != "203.0.113.99" {
		t.Errorf("event 2 misattributed or wrong source: %+v", events[2])
	}
	// Event 3: authenticated UDP packet connection with IPv6 source.
	if events[3].Kind != "connection" || events[3].UserID == nil || *events[3].UserID != uid1 ||
		events[3].SourceIP != "2001:db8::5" || events[3].Target != "dns.google" || events[3].Port != 53 || events[3].Network != "udp" {
		t.Errorf("event 3 mismatch: %+v", events[3])
	}

	// Reject unknown ack ID during UploadOnce.
	badPoster := fakePoster{fn: func(ctx context.Context, path string, body any, authenticated bool) (map[string]any, error) {
		return map[string]any{"protocol": 1, "ack": []any{"0000000000000000000000000000000000000000000000000000000000000000"}}, nil
	}}
	if _, err := col.UploadOnce(context.Background(), badPoster); err == nil {
		t.Fatal("expected UploadOnce to reject unknown ack ID")
	}

	// Valid ack clears queue.
	goodPoster := fakePoster{fn: func(ctx context.Context, path string, body any, authenticated bool) (map[string]any, error) {
		ackList := make([]any, 0, len(events))
		for _, ev := range events {
			ackList = append(ackList, ev.ID)
		}
		return map[string]any{"protocol": 1, "ack": ackList}, nil
	}}
	sent, err := col.UploadOnce(context.Background(), goodPoster)
	if err != nil || sent != 4 {
		t.Fatalf("UploadOnce = (%d, %v), want (4, nil)", sent, err)
	}
	st, err := col.Status()
	if err != nil || st.Pending != 0 {
		t.Fatalf("expected 0 pending after upload, got (%+v, %v)", st, err)
	}
}

func TestCollectorRejectsDisabledLogConfig(t *testing.T) {
	dir := t.TempDir()
	coreCfgPath := filepath.Join(dir, "config.json")
	agentCfgPath := filepath.Join(dir, "agent-config.json")

	if err := os.WriteFile(coreCfgPath, []byte(`{"log":{"level":"warn","timestamp":true}}`), 0o600); err != nil {
		t.Fatalf("write core config: %v", err)
	}
	rawCfg, _ := json.Marshal(map[string]any{
		"node_id":                   "n_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		"center_url":                "https://panel.example.com",
		"db_path":                   filepath.Join(dir, "agent.db"),
		"status":                    "active",
		"activity_log_path":         filepath.Join(dir, "sing-box.log"),
		"activity_core_config_path": coreCfgPath,
	})
	if err := os.WriteFile(agentCfgPath, rawCfg, 0o600); err != nil {
		t.Fatalf("write agent config: %v", err)
	}

	col, err := NewCollector(agentCfgPath)
	if err != nil {
		t.Fatalf("NewCollector: %v", err)
	}
	if _, _, err := col.CollectOnce(); err == nil {
		t.Fatal("expected error for log level=warn")
	}
}
