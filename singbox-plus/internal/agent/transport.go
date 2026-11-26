package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/netip"
	"net/url"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/showcode1024/singbox-auto/singbox-plus/internal/store"
)

// Poster is the minimal HTTP POST interface used by Agent and ActivityCollector.
type Poster interface {
	Post(ctx context.Context, path string, body any, authenticated bool) (map[string]any, error)
}

var allowedEndpoints = map[string]bool{
	"/api/agent/register": true,
	"/api/agent/sync":     true,
	"/api/agent/detach":   true,
	"/api/agent/wait":     true,
	"/api/agent/activity": true,
}

// ValidateOrigin ensures value is an HTTPS origin (or loopback HTTP when allowLoopbackHTTP is true).
func ValidateOrigin(value string, allowLoopbackHTTP bool) (string, error) {
	if value == "" {
		return "", agentErr("Center URL must be an HTTPS origin")
	}
	for _, r := range value {
		if unicode.IsSpace(r) {
			return "", agentErr("Center URL must be an HTTPS origin")
		}
	}
	if strings.ContainsAny(value, "?#") {
		return "", agentErr("Use only the center origin, for example https://panel.eulmo.com")
	}
	u, err := url.Parse(value)
	if err != nil {
		return "", agentErr("Invalid center URL")
	}
	scheme := strings.ToLower(u.Scheme)
	hostname := u.Hostname()
	if hostname == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || (u.Path != "" && u.Path != "/") {
		return "", agentErr("Use only the center origin, for example https://panel.eulmo.com")
	}
	if portStr := u.Port(); portStr != "" {
		p, pErr := strconv.Atoi(portStr)
		if pErr != nil || p < 1 || p > 65535 {
			return "", agentErr("Invalid center port")
		}
	}
	if scheme != "https" {
		loopback := strings.EqualFold(hostname, "localhost")
		if !loopback {
			if addr, aErr := netip.ParseAddr(hostname); aErr == nil && addr.IsLoopback() {
				loopback = true
			}
		}
		if !(allowLoopbackHTTP && scheme == "http" && loopback) {
			return "", agentErr("Production connections require HTTPS with certificate verification")
		}
	}
	return scheme + "://" + u.Host, nil
}

// Transport executes strict HTTPS (or loopback HTTP in tests) JSON POST requests to the center.
type Transport struct {
	origin  string
	token   string
	version string
	timeout time.Duration
	client  *http.Client
	tr      *http.Transport
}

// NewTransport creates a Transport with no proxy and redirects refused.
func NewTransport(origin, token, version string, allowLoopbackHTTP bool, timeout time.Duration) (*Transport, error) {
	normOrigin, err := ValidateOrigin(origin, allowLoopbackHTTP)
	if err != nil {
		return nil, err
	}
	if timeout <= 0 {
		timeout = 12 * time.Second
	}
	if version == "" {
		version = "dev"
	}
	tr := &http.Transport{
		Proxy: nil,
	}
	client := &http.Client{
		Transport: tr,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	return &Transport{
		origin:  normOrigin,
		token:   token,
		version: version,
		timeout: timeout,
		client:  client,
		tr:      tr,
	}, nil
}

// Close releases idle connections.
func (t *Transport) Close() {
	if t.tr != nil {
		t.tr.CloseIdleConnections()
	}
}

// Post sends a canonical JSON POST to an allowlisted agent endpoint and validates protocol == 1.
func (t *Transport) Post(ctx context.Context, path string, body any, authenticated bool) (map[string]any, error) {
	if !allowedEndpoints[path] {
		return nil, agentErr("unsupported agent endpoint")
	}
	data, err := store.CanonicalJSON(body)
	if err != nil {
		return nil, err
	}
	if len(data) > store.MaxBody {
		return nil, agentErr("agent request exceeds 2 MiB")
	}

	reqCtx, cancel := context.WithTimeout(ctx, t.timeout)
	defer cancel()

	req, err := http.NewRequestWithContext(reqCtx, http.MethodPost, t.origin+path, bytes.NewReader(data))
	if err != nil {
		return nil, &TransportError{Msg: "HTTPS request failed: " + err.Error()}
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "singbox-plus/"+t.version)
	if authenticated {
		if t.token == "" {
			return nil, agentErr("no node credential is configured")
		}
		req.Header.Set("Authorization", "Bearer "+t.token)
	}

	resp, err := t.client.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, &TransportError{Msg: "HTTPS request failed: " + err.Error()}
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 300 && resp.StatusCode < 400 {
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
		return nil, &TransportError{
			Status: resp.StatusCode,
			Msg:    "Center redirected the request; redirects are refused",
		}
	}
	if resp.StatusCode >= 400 {
		errBody, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		detail := "Request rejected"
		var errObj map[string]any
		if json.Unmarshal(errBody, &errObj) == nil {
			if s, ok := errObj["error"].(string); ok && s != "" {
				detail = s
			}
		}
		return nil, &TransportError{
			Status: resp.StatusCode,
			Msg:    fmt.Sprintf("Center HTTP %d: %s", resp.StatusCode, detail),
		}
	}

	respBytes, err := io.ReadAll(io.LimitReader(resp.Body, store.MaxBody+1))
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, &TransportError{Msg: "HTTPS request failed: " + err.Error()}
	}
	if len(respBytes) > store.MaxBody {
		return nil, &TransportError{Msg: "Center response exceeds 2 MiB"}
	}

	dec := json.NewDecoder(bytes.NewReader(respBytes))
	dec.UseNumber()
	var parsed any
	if err := dec.Decode(&parsed); err != nil {
		return nil, &TransportError{Msg: "Center did not return valid JSON"}
	}
	m, ok := parsed.(map[string]any)
	if !ok {
		return nil, &TransportError{Msg: "Unsupported center response protocol"}
	}
	protoVal, ok := parseInt64Exact(m["protocol"])
	if !ok || protoVal != Protocol {
		return nil, &TransportError{Msg: "Unsupported center response protocol"}
	}
	return m, nil
}
