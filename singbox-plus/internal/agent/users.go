package agent

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"math"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/showcode1024/singbox-auto/singbox-plus/internal/store"
)

var (
	// UserIDRe matches central user IDs (`u_` + 32 hex chars).
	UserIDRe = regexp.MustCompile(`^u_[0-9a-f]{32}$`)
	// NodeIDRe matches central node IDs (`n_` + 32 hex chars).
	NodeIDRe = regexp.MustCompile(`^n_[0-9a-f]{32}$`)
	// NameRe matches valid user names.
	NameRe = regexp.MustCompile(`^[A-Za-z0-9]{1,32}$`)
	// PasswordRe matches valid TUIC passwords.
	PasswordRe = regexp.MustCompile(`^[A-Za-z0-9_-]{6,128}$`)
	// StatRe matches per-user V2Ray traffic counter names.
	StatRe = regexp.MustCompile(`^user>>>([^>]+)>>>traffic>>>(uplink|downlink)$`)
	// CanonicalUUIDRe matches canonical 36-char hyphenated UUIDs (case-insensitive).
	CanonicalUUIDRe = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)
)

func parseInt64Exact(v any) (int64, bool) {
	switch val := v.(type) {
	case int:
		return int64(val), true
	case int64:
		return val, true
	case json.Number:
		n, err := strconv.ParseInt(val.String(), 10, 64)
		return n, err == nil
	case float64:
		if math.Trunc(val) == val && val >= math.MinInt64 && val <= math.MaxInt64 {
			return int64(val), true
		}
	}
	return 0, false
}

func requireInt64(v any, label string, minVal, maxVal int64) (int64, error) {
	n, ok := parseInt64Exact(v)
	if !ok || n < minVal || n > maxVal {
		return 0, agentErr("Invalid integer: %s", label)
	}
	return n, nil
}

// ValidatedUsers validates and normalizes user records from local state or center desired snapshots.
func ValidatedUsers(raw any, snapshots bool) ([]map[string]any, error) {
	var slice []any
	switch v := raw.(type) {
	case []any:
		slice = v
	case []map[string]any:
		slice = make([]any, len(v))
		for i, item := range v {
			slice[i] = item
		}
	default:
		return nil, agentErr("Invalid user list")
	}
	if len(slice) > 20000 {
		return nil, agentErr("Invalid user list")
	}

	names := make(map[string]struct{}, len(slice))
	ids := make(map[string]struct{}, len(slice))
	creds := make(map[string]struct{}, len(slice))
	result := make([]map[string]any, 0, len(slice))

	for _, rawUser := range slice {
		user, ok := rawUser.(map[string]any)
		if !ok {
			return nil, agentErr("Invalid user record")
		}
		name, ok := user["name"].(string)
		if !ok || !NameRe.MatchString(name) {
			return nil, agentErr("Invalid user name")
		}
		cred, ok := user["uuid"].(string)
		if !ok || !CanonicalUUIDRe.MatchString(cred) {
			return nil, agentErr("Invalid user UUID")
		}
		normalized := strings.ToLower(cred)
		password, ok := user["tuic_pass"].(string)
		if !ok || !PasswordRe.MatchString(password) {
			return nil, agentErr("Invalid TUIC credential")
		}
		if _, dup := names[name]; dup {
			return nil, agentErr("Duplicate name or UUID in node users")
		}
		if _, dup := creds[normalized]; dup {
			return nil, agentErr("Duplicate name or UUID in node users")
		}
		names[name] = struct{}{}
		creds[normalized] = struct{}{}

		item := map[string]any{
			"name":      name,
			"uuid":      normalized,
			"tuic_pass": password,
		}
		if snapshots {
			identity, ok := user["id"].(string)
			if !ok || !UserIDRe.MatchString(identity) {
				return nil, agentErr("Invalid or duplicate global user ID")
			}
			if _, dup := ids[identity]; dup {
				return nil, agentErr("Invalid or duplicate global user ID")
			}
			enabled, ok := user["enabled"].(bool)
			if !ok {
				return nil, agentErr("User enabled flag must be a boolean")
			}
			ids[identity] = struct{}{}
			item["id"] = identity
			item["enabled"] = enabled
		}
		result = append(result, item)
	}
	return result, nil
}

// Fingerprint computes the SHA-256 hex digest of sorted canonical users, matching ysq-agent.py.
func Fingerprint(raw any) (string, error) {
	normalized, err := ValidatedUsers(raw, false)
	if err != nil {
		return "", err
	}
	sort.Slice(normalized, func(i, j int) bool {
		ni, nj := normalized[i]["name"].(string), normalized[j]["name"].(string)
		if ni != nj {
			return ni < nj
		}
		return normalized[i]["uuid"].(string) < normalized[j]["uuid"].(string)
	})
	data, err := store.CanonicalJSON(normalized)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:]), nil
}
