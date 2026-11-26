package agent

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/showcode1024/singbox-auto/singbox-plus/internal/store"
)

const (
	// Protocol is the center API protocol version.
	Protocol = 1
	// DefaultSampleInterval is the traffic sampling cadence (10s).
	DefaultSampleInterval = 10 * time.Second
	// DefaultSyncInterval is the regular center sync cadence (15s).
	DefaultSyncInterval = 15 * time.Second
	// DefaultWaitSeconds is the /api/agent/wait long-poll timeout (20s).
	DefaultWaitSeconds = 20
)

var (
	uuidAnyRe = regexp.MustCompile(`[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}`)
	bearerRe  = regexp.MustCompile(`(?i)bearer\s+\S+`)
)

// SystemPath resolves an absolute system path under YSQ_TEST_ROOT when set.
func SystemPath(p string) string {
	root := os.Getenv("YSQ_TEST_ROOT")
	if root == "" {
		return p
	}
	return filepath.Join(root, strings.TrimLeft(p, "/"))
}

// DefaultConfigPath returns the default agent config path (honoring YSQ_TEST_ROOT).
func DefaultConfigPath() string { return SystemPath("/etc/ysq-agent/config.json") }

// DefaultDBPath returns the default ledger db path (honoring YSQ_TEST_ROOT).
func DefaultDBPath() string { return SystemPath("/var/lib/ysq-agent/agent.db") }

// DefaultScriptPath returns the default installer helper script path.
func DefaultScriptPath() string { return SystemPath("/root/install-singbox-ysq.sh") }

// DefaultStatePath returns the default sing-box ysq-state.db path.
func DefaultStatePath() string { return SystemPath("/etc/sing-box/ysq-state.db") }

// AtomicJSON writes value as canonical UTF-8 JSON with trailing newline atomically (mode 0600).
func AtomicJSON(path string, value any) error {
	parent, err := store.EnsurePrivateDir(path)
	if err != nil {
		return err
	}
	raw, err := store.CanonicalJSON(value)
	if err != nil {
		return err
	}
	raw = append(raw, '\n')

	tmp, err := os.CreateTemp(parent, ".ysq-*.tmp")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	cleanup := true
	defer func() {
		if cleanup {
			_ = os.Remove(tmpPath)
		}
	}()

	_ = tmp.Chmod(0o600)
	if _, err := tmp.Write(raw); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmpPath, path); err != nil {
		return err
	}
	cleanup = false

	// Best-effort directory fsync (succeeds on Linux/Unix, ignored on Windows).
	if df, err := os.Open(parent); err == nil {
		_ = df.Sync()
		_ = df.Close()
	}
	return nil
}

// ReadJSONMap reads a bounded JSON object (<= 8 MiB) from path using json.Number for integers.
func ReadJSONMap(path string) (map[string]any, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	limit := int64(store.MaxBody * 4)
	data, err := io.ReadAll(io.LimitReader(f, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, agentErr("local JSON file is too large")
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	var parsed any
	if err := dec.Decode(&parsed); err != nil {
		return nil, err
	}
	m, ok := parsed.(map[string]any)
	if !ok {
		return nil, agentErr("expected a JSON object")
	}
	return m, nil
}

// Redact strips known secrets, UUIDs, and Bearer tokens from message and bounds it to the last 900 runes.
func Redact(message string, cfg map[string]any) string {
	text := message
	secretSet := make(map[string]struct{})
	addSecret := func(v any) {
		if s, ok := v.(string); ok && s != "" {
			secretSet[s] = struct{}{}
		}
	}

	if cfg != nil {
		addSecret(cfg["node_token"])
		var users []any
		if pending, ok := cfg["registration_payload"].(map[string]any); ok {
			addSecret(pending["join_code"])
			if pu, ok := pending["users"].([]any); ok {
				users = append(users, pu...)
			}
		}
		if ru, ok := cfg["_redact_users"].([]any); ok {
			users = append(users, ru...)
		}
		if ruMaps, ok := cfg["_redact_users"].([]map[string]any); ok {
			for _, u := range ruMaps {
				users = append(users, u)
			}
		}
		if statePath, ok := cfg["state_path"].(string); ok && statePath != "" {
			if st, err := ReadJSONMap(statePath); err == nil {
				for _, k := range []string{"uuid", "private_key", "short_id", "tuic_pass"} {
					addSecret(st[k])
				}
				if su, ok := st["users"].([]any); ok {
					users = append(users, su...)
				}
				if landings, ok := st["landings"].([]any); ok {
					for _, l := range landings {
						if lm, ok := l.(map[string]any); ok {
							for _, k := range []string{"uuid", "password", "private_key", "short_id"} {
								addSecret(lm[k])
							}
						}
					}
				}
			}
		}
		for _, u := range users {
			if um, ok := u.(map[string]any); ok {
				addSecret(um["uuid"])
				addSecret(um["tuic_pass"])
			}
		}
	}

	secrets := make([]string, 0, len(secretSet))
	for s := range secretSet {
		secrets = append(secrets, s)
	}
	sort.Slice(secrets, func(i, j int) bool {
		if len(secrets[i]) != len(secrets[j]) {
			return len(secrets[i]) > len(secrets[j])
		}
		return secrets[i] < secrets[j]
	})
	for _, s := range secrets {
		text = strings.ReplaceAll(text, s, "[redacted]")
	}
	text = uuidAnyRe.ReplaceAllString(text, "[uuid]")
	text = bearerRe.ReplaceAllString(text, "Bearer [redacted]")
	text = strings.Join(strings.Fields(text), " ")
	runes := []rune(text)
	if len(runes) > 900 {
		return string(runes[len(runes)-900:])
	}
	return text
}

// Log writes a UTC-timestamped redacted message to w (or os.Stderr if w is nil).
func Log(w io.Writer, message string, cfg map[string]any) {
	if w == nil {
		w = os.Stderr
	}
	ts := time.Now().UTC().Format("2006-01-02T15:04:05Z")
	_, _ = fmt.Fprintf(w, "%s %s\n", ts, Redact(message, cfg))
}

func mapString(m map[string]any, key, def string) string {
	if m == nil {
		return def
	}
	if s, ok := m[key].(string); ok {
		return s
	}
	return def
}

func mapBool(m map[string]any, key bool, field string) bool {
	if m == nil {
		return key
	}
	if b, ok := m[field].(bool); ok {
		return b
	}
	return key
}

func cloneMap(src map[string]any) map[string]any {
	if src == nil {
		return make(map[string]any)
	}
	raw, err := store.CanonicalJSON(src)
	if err != nil {
		dst := make(map[string]any, len(src))
		for k, v := range src {
			dst[k] = v
		}
		return dst
	}
	var out map[string]any
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&out); err != nil {
		dst := make(map[string]any, len(src))
		for k, v := range src {
			dst[k] = v
		}
		return dst
	}
	return out
}
