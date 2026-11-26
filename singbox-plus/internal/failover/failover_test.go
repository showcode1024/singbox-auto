package failover

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

type mockClashAPI struct {
	mu       sync.Mutex
	secret   string
	selected string
	// status per tag: "ok", "fail503", "unknown500", "auth401", "hang"
	behavior map[string]string
	switches []string
}

func (m *mockClashAPI) setBehavior(tag, mode string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.behavior[tag] = mode
}

func (m *mockClashAPI) getSelected() string {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.selected
}

func (m *mockClashAPI) handler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		m.mu.Lock()
		secret := m.secret
		m.mu.Unlock()

		if r.Header.Get("Authorization") != "Bearer "+secret {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}

		if r.URL.Path == "/proxies/" && r.Method == http.MethodGet {
			m.mu.Lock()
			sel := m.selected
			m.mu.Unlock()
			w.Header().Set("Content-Type", "application/json")
			_, _ = fmt.Fprintf(w, `{"proxies":{"failover-node1":{"now":%q}}}`, sel)
			return
		}

		if r.URL.Path == "/proxies/failover-node1" && r.Method == http.MethodPut {
			var body struct {
				Name string `json:"name"`
			}
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				http.Error(w, "bad body", http.StatusBadRequest)
				return
			}
			m.mu.Lock()
			m.selected = body.Name
			m.switches = append(m.switches, body.Name)
			m.mu.Unlock()
			w.WriteHeader(http.StatusNoContent)
			return
		}

		if strings.HasPrefix(r.URL.Path, "/proxies/") && strings.HasSuffix(r.URL.Path, "/delay") {
			tag := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/proxies/"), "/delay")
			m.mu.Lock()
			mode := m.behavior[tag]
			m.mu.Unlock()

			switch mode {
			case "ok":
				w.Header().Set("Content-Type", "application/json")
				_, _ = w.Write([]byte(`{"delay":42}`))
			case "fail503":
				http.Error(w, "unavailable", http.StatusServiceUnavailable)
			case "unknown500":
				http.Error(w, "internal", http.StatusInternalServerError)
			case "auth401":
				http.Error(w, "unauthorized", http.StatusUnauthorized)
			case "hang":
				select {
				case <-r.Context().Done():
				case <-time.After(10 * time.Second):
				}
			default:
				http.Error(w, "unknown tag", http.StatusNotFound)
			}
			return
		}

		http.NotFound(w, r)
	})
}

func writeTestConfig(t *testing.T, path, controller, secret, extraComment string) {
	t.Helper()
	cfg := map[string]any{
		"outbounds": []map[string]any{
			{
				"type":      "selector",
				"tag":       "failover-node1",
				"default":   "primary-out",
				"outbounds": []string{"primary-out", "backup-out"},
			},
		},
		"experimental": map[string]any{
			"clash_api": map[string]any{
				"external_controller": controller,
				"secret":              secret,
			},
		},
	}
	if extraComment != "" {
		cfg["log"] = map[string]any{"level": extraComment}
	}
	raw, err := json.Marshal(cfg)
	if err != nil {
		t.Fatalf("marshal config: %v", err)
	}
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}
}

func readStatusRaw(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read status: %v", err)
	}
	return string(b)
}

func TestFailoverAndRecoveryLifecycle(t *testing.T) {
	mock := &mockClashAPI{
		secret:   "test-secret",
		selected: "primary-out",
		behavior: map[string]string{
			"primary-out": "fail503",
			"backup-out":  "ok",
		},
	}
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	controller := strings.TrimPrefix(srv.URL, "http://")
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.json")
	statusPath := filepath.Join(dir, "status.json")
	writeTestConfig(t, cfgPath, controller, "test-secret", "")

	var stdout, stderr bytes.Buffer
	mon := NewMonitor(cfgPath, statusPath)
	mon.Stdout = &stdout
	mon.Stderr = &stderr
	defer mon.Close()

	// Cycle 1: 1st failure -> stays on primary-out.
	groups, err := mon.Cycle(context.Background())
	if err != nil {
		t.Fatalf("cycle 1: %v", err)
	}
	if len(groups) != 1 || groups[0].Selected != "primary-out" || groups[0].PrimaryFailures != 1 {
		t.Fatalf("cycle 1 unexpected groups: %+v", groups)
	}

	// Cycle 2: 2nd failure -> switches to backup-out.
	groups, err = mon.Cycle(context.Background())
	if err != nil {
		t.Fatalf("cycle 2: %v", err)
	}
	if groups[0].Selected != "backup-out" || mock.getSelected() != "backup-out" {
		t.Fatalf("expected switch to backup-out, got %+v", groups[0])
	}
	if !strings.Contains(stdout.String(), "failover-node1 primary-out -> backup-out") {
		t.Errorf("expected switch log, got %q", stdout.String())
	}

	// Cycle 3: primary recovers once -> stays on backup-out (good=1 < 2).
	mock.setBehavior("primary-out", "ok")
	groups, err = mon.Cycle(context.Background())
	if err != nil {
		t.Fatalf("cycle 3: %v", err)
	}
	if groups[0].Selected != "backup-out" || groups[0].PrimarySuccesses != 1 {
		t.Fatalf("cycle 3 unexpected: %+v", groups[0])
	}

	// Cycle 4: primary recovers twice -> switches back to primary-out.
	groups, err = mon.Cycle(context.Background())
	if err != nil {
		t.Fatalf("cycle 4: %v", err)
	}
	if groups[0].Selected != "primary-out" || mock.getSelected() != "primary-out" || groups[0].PrimarySuccesses != 2 {
		t.Fatalf("cycle 4 expected recovery to primary-out: %+v", groups[0])
	}

	// Verify status.json schema.
	var sf StatusFile
	raw := readStatusRaw(t, statusPath)
	if err := json.Unmarshal([]byte(raw), &sf); err != nil {
		t.Fatalf("parse status.json: %v", err)
	}
	if sf.CheckedAt <= 0 || sf.Error != "" || len(sf.Groups) != 1 || sf.Groups[0].AllDown {
		t.Fatalf("unexpected status file: %+v", sf)
	}
}

func TestNoSwitchWhenBackupDown(t *testing.T) {
	mock := &mockClashAPI{
		secret:   "test-secret",
		selected: "primary-out",
		behavior: map[string]string{
			"primary-out": "fail503",
			"backup-out":  "fail503",
		},
	}
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.json")
	statusPath := filepath.Join(dir, "status.json")
	writeTestConfig(t, cfgPath, strings.TrimPrefix(srv.URL, "http://"), "test-secret", "")

	mon := NewMonitor(cfgPath, statusPath)
	defer mon.Close()

	for i := 0; i < 3; i++ {
		groups, err := mon.Cycle(context.Background())
		if err != nil {
			t.Fatalf("cycle %d: %v", i, err)
		}
		if groups[0].Selected != "primary-out" {
			t.Fatalf("should not switch when backup is down: %+v", groups[0])
		}
		if !groups[0].AllDown {
			t.Fatalf("expected all_down=true: %+v", groups[0])
		}
	}
}

func TestUnknownErrorPreservesCountersAndSerializesNull(t *testing.T) {
	mock := &mockClashAPI{
		secret:   "test-secret",
		selected: "primary-out",
		behavior: map[string]string{
			"primary-out": "fail503",
			"backup-out":  "ok",
		},
	}
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.json")
	statusPath := filepath.Join(dir, "status.json")
	writeTestConfig(t, cfgPath, strings.TrimPrefix(srv.URL, "http://"), "test-secret", "")

	mon := NewMonitor(cfgPath, statusPath)
	defer mon.Close()

	// 1 failure sets primary_failures=1.
	groups, err := mon.Cycle(context.Background())
	if err != nil {
		t.Fatalf("cycle 1: %v", err)
	}
	if groups[0].PrimaryFailures != 1 {
		t.Fatalf("expected 1 failure, got %d", groups[0].PrimaryFailures)
	}

	// Next cycle returns HTTP 500 -> ProbeUnknown -> must preserve failures=1 and emit "primary_ok":null.
	mock.setBehavior("primary-out", "unknown500")
	groups, err = mon.Cycle(context.Background())
	if err != nil {
		t.Fatalf("cycle 2: %v", err)
	}
	if groups[0].PrimaryFailures != 1 || groups[0].PrimarySuccesses != 0 || groups[0].PrimaryOK != nil {
		t.Fatalf("expected preserved counters and nil PrimaryOK, got %+v", groups[0])
	}
	raw := readStatusRaw(t, statusPath)
	if !strings.Contains(raw, `"primary_ok":null`) {
		t.Fatalf("expected primary_ok:null in status.json, got %s", raw)
	}
}

func TestConfigChangeResetsCounters(t *testing.T) {
	mock := &mockClashAPI{
		secret:   "test-secret",
		selected: "primary-out",
		behavior: map[string]string{
			"primary-out": "fail503",
			"backup-out":  "ok",
		},
	}
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	controller := strings.TrimPrefix(srv.URL, "http://")
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.json")
	statusPath := filepath.Join(dir, "status.json")
	writeTestConfig(t, cfgPath, controller, "test-secret", "info")

	mon := NewMonitor(cfgPath, statusPath)
	defer mon.Close()

	// 1st failure -> bad=1.
	if _, err := mon.Cycle(context.Background()); err != nil {
		t.Fatalf("cycle 1: %v", err)
	}

	// Rewrite config with changed content (different size/mtime & fingerprint) -> counters reset!
	writeTestConfig(t, cfgPath, controller, "test-secret", "warning")

	// Next failure should only bring bad to 1 (NOT 2), so no switch occurs.
	groups, err := mon.Cycle(context.Background())
	if err != nil {
		t.Fatalf("cycle 2: %v", err)
	}
	if groups[0].PrimaryFailures != 1 || groups[0].Selected != "primary-out" {
		t.Fatalf("expected counters reset after config change, got %+v", groups[0])
	}
}

func TestImmediateContextCancellation(t *testing.T) {
	mock := &mockClashAPI{
		secret:   "test-secret",
		selected: "primary-out",
		behavior: map[string]string{
			"primary-out": "hang",
			"backup-out":  "hang",
		},
	}
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()

	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.json")
	statusPath := filepath.Join(dir, "status.json")
	writeTestConfig(t, cfgPath, strings.TrimPrefix(srv.URL, "http://"), "test-secret", "")

	mon := NewMonitor(cfgPath, statusPath)
	defer mon.Close()

	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(100 * time.Millisecond)
		cancel()
	}()

	start := time.Now()
	_, err := mon.Cycle(ctx)
	elapsed := time.Since(start)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("expected context.Canceled, got %v", err)
	}
	if elapsed > 2*time.Second {
		t.Fatalf("cancellation took too long: %v", elapsed)
	}
}

func TestControllerValidationAndAuthError(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.json")
	statusPath := filepath.Join(dir, "status.json")

	// Non-loopback controller must be rejected.
	writeTestConfig(t, cfgPath, "0.0.0.0:9090", "secret", "")
	mon := NewMonitor(cfgPath, statusPath)
	defer mon.Close()
	_, err := mon.Cycle(context.Background())
	var ce *ControllerError
	if !errors.As(err, &ce) {
		t.Fatalf("expected ControllerError for non-loopback controller, got %v", err)
	}

	// Probe HTTP 401 must be classified as ControllerError.
	mock := &mockClashAPI{
		secret:   "test-secret",
		selected: "primary-out",
		behavior: map[string]string{
			"primary-out": "auth401",
			"backup-out":  "ok",
		},
	}
	srv := httptest.NewServer(mock.handler())
	defer srv.Close()
	writeTestConfig(t, cfgPath, strings.TrimPrefix(srv.URL, "http://"), "test-secret", "")
	_, err = mon.Cycle(context.Background())
	if !errors.As(err, &ce) {
		t.Fatalf("expected ControllerError for probe 401, got %v", err)
	}
}
