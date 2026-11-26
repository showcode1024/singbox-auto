package failover

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	// DefaultConfigPath is the default sing-box config path.
	DefaultConfigPath = "/etc/sing-box/config.json"
	// DefaultStatusPath is the default failover status JSON path.
	DefaultStatusPath = "/var/lib/ysq-failover/status.json"
	// DefaultInterval is the cycle polling interval.
	DefaultInterval = 10 * time.Second
	// DefaultThreshold is the consecutive probe threshold for failover and recovery.
	DefaultThreshold = 2
	// DefaultProbeTimeoutMs is the Clash API delay probe timeout in milliseconds.
	DefaultProbeTimeoutMs = 4000
	// DefaultMaxWorkers is the maximum number of concurrent delay probes.
	DefaultMaxWorkers = 4
	// MaxResponseBytes caps any Clash API response body (1 MiB).
	MaxResponseBytes = 1 << 20
)

// DefaultProbeURLs matches the upstream probe endpoints in order.
var DefaultProbeURLs = []string{
	"https://www.gstatic.com/generate_204",
	"https://cp.cloudflare.com/generate_204",
}

// ControllerError indicates a local Clash API / configuration error.
type ControllerError struct {
	Msg string
}

func (e *ControllerError) Error() string { return e.Msg }

// ProbeFailed indicates a confirmed outbound probe failure (503/504/timeout/invalid delay).
type ProbeFailed struct {
	Msg string
}

func (e *ProbeFailed) Error() string { return e.Msg }

// ProbeUnknown indicates an inconclusive probe result that preserves existing counters.
type ProbeUnknown struct {
	Msg string
}

func (e *ProbeUnknown) Error() string { return e.Msg }

// GroupStatus represents a single failover selector's status entry.
type GroupStatus struct {
	Tag              string `json:"tag"`
	Primary          string `json:"primary"`
	Backup           string `json:"backup"`
	Selected         string `json:"selected"`
	PrimaryOK        *bool  `json:"primary_ok"`
	BackupOK         *bool  `json:"backup_ok"`
	PrimaryFailures  int    `json:"primary_failures"`
	PrimarySuccesses int    `json:"primary_successes"`
	AllDown          bool   `json:"all_down"`
}

// StatusFile is the exact status.json schema written atomically each cycle.
type StatusFile struct {
	CheckedAt int64         `json:"checked_at"`
	Groups    []GroupStatus `json:"groups"`
	Error     string        `json:"error"`
}

type counter struct {
	Good int
	Bad  int
}

type singboxConfig struct {
	Outbounds    []outboundConfig   `json:"outbounds"`
	Experimental experimentalConfig `json:"experimental"`
}

type outboundConfig struct {
	Type      string   `json:"type"`
	Tag       string   `json:"tag"`
	Default   string   `json:"default"`
	Outbounds []string `json:"outbounds"`
}

type experimentalConfig struct {
	ClashAPI clashAPIConfig `json:"clash_api"`
}

type clashAPIConfig struct {
	ExternalController string `json:"external_controller"`
	Secret             string `json:"secret"`
}

// Monitor keeps each failover-* selector on its preferred landing outbound,
// switching only after Threshold consecutive failures and recovering after Threshold successes.
type Monitor struct {
	ConfigPath     string
	StatusPath     string
	Interval       time.Duration
	Threshold      int
	ProbeTimeoutMs int
	ProbeURLs      []string
	MaxWorkers     int
	Stdout         io.Writer
	Stderr         io.Writer

	counters      map[string]counter
	fingerprint   string
	hasConfigStat bool
	configStat    fileStatKey
	cachedConfig  *singboxConfig
	client        *http.Client
	transport     *http.Transport
	base          string
	secret        string
	lastError     string
}

// NewMonitor constructs a Monitor with production defaults and a proxy-free HTTP client.
func NewMonitor(configPath, statusPath string) *Monitor {
	tr := &http.Transport{
		Proxy: nil,
	}
	urls := make([]string, len(DefaultProbeURLs))
	copy(urls, DefaultProbeURLs)
	return &Monitor{
		ConfigPath:     configPath,
		StatusPath:     statusPath,
		Interval:       DefaultInterval,
		Threshold:      DefaultThreshold,
		ProbeTimeoutMs: DefaultProbeTimeoutMs,
		ProbeURLs:      urls,
		MaxWorkers:     DefaultMaxWorkers,
		Stdout:         os.Stdout,
		Stderr:         os.Stderr,
		counters:       make(map[string]counter),
		transport:      tr,
		client:         &http.Client{Transport: tr},
	}
}

// Close releases idle connections held by the monitor's HTTP transport.
func (m *Monitor) Close() {
	if m.transport != nil {
		m.transport.CloseIdleConnections()
	}
}

func (m *Monitor) loadConfig() (*singboxConfig, bool, error) {
	fi, err := os.Stat(m.ConfigPath)
	if err != nil {
		return nil, false, err
	}
	key := makeFileStatKey(fi)
	if m.hasConfigStat && key == m.configStat && m.cachedConfig != nil {
		return m.cachedConfig, false, nil
	}

	raw, err := os.ReadFile(m.ConfigPath)
	if err != nil {
		return nil, false, err
	}

	var generic any
	if err := json.Unmarshal(raw, &generic); err != nil {
		return nil, false, err
	}
	// Go's json.Marshal deterministically sorts map keys with compact separators.
	canon, err := json.Marshal(generic)
	if err != nil {
		return nil, false, err
	}
	var cfg singboxConfig
	if err := json.Unmarshal(raw, &cfg); err != nil {
		return nil, false, err
	}

	fp := string(canon)
	changed := fp != m.fingerprint
	m.configStat = key
	m.hasConfigStat = true
	m.cachedConfig = &cfg
	if changed {
		m.fingerprint = fp
	}
	return &cfg, changed, nil
}

func (m *Monitor) api(ctx context.Context, path, method string, payload any, probe bool) (map[string]any, error) {
	var bodyReader io.Reader
	if payload != nil {
		b, err := json.Marshal(payload)
		if err != nil {
			return nil, &ControllerError{Msg: "marshal request payload failed"}
		}
		bodyReader = bytes.NewReader(b)
	}

	timeout := time.Duration(m.probeTimeoutMs())*time.Millisecond + 2*time.Second
	reqCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	req, err := http.NewRequestWithContext(reqCtx, method, m.base+path, bodyReader)
	if err != nil {
		if probe {
			return nil, &ProbeUnknown{Msg: "probe error: invalid request"}
		}
		return nil, &ControllerError{Msg: "local controller unavailable: invalid request"}
	}
	req.Header.Set("Authorization", "Bearer "+m.secret)
	req.Header.Set("Content-Type", "application/json")

	resp, err := m.client.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		if isTimeoutError(err) {
			if probe {
				return nil, &ProbeFailed{Msg: "probe timeout"}
			}
			return nil, &ControllerError{Msg: "local controller unavailable: timeout"}
		}
		if probe {
			return nil, &ProbeUnknown{Msg: "probe error: " + classifyErr(err)}
		}
		return nil, &ControllerError{Msg: "local controller unavailable: " + classifyErr(err)}
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
		if probe {
			if resp.StatusCode == http.StatusServiceUnavailable || resp.StatusCode == http.StatusGatewayTimeout {
				return nil, &ProbeFailed{Msg: fmt.Sprintf("probe HTTP %d", resp.StatusCode)}
			}
			if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
				return nil, &ControllerError{Msg: fmt.Sprintf("local controller HTTP %d", resp.StatusCode)}
			}
			return nil, &ProbeUnknown{Msg: fmt.Sprintf("probe HTTP %d", resp.StatusCode)}
		}
		return nil, &ControllerError{Msg: fmt.Sprintf("local controller HTTP %d", resp.StatusCode)}
	}

	raw, err := io.ReadAll(io.LimitReader(resp.Body, MaxResponseBytes+1))
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		if isTimeoutError(err) {
			if probe {
				return nil, &ProbeFailed{Msg: "probe timeout"}
			}
			return nil, &ControllerError{Msg: "local controller unavailable: timeout"}
		}
		if probe {
			return nil, &ProbeUnknown{Msg: "probe error: " + classifyErr(err)}
		}
		return nil, &ControllerError{Msg: "local controller unavailable: " + classifyErr(err)}
	}
	if len(raw) > MaxResponseBytes {
		return nil, &ControllerError{Msg: "local controller response too large"}
	}
	if len(bytes.TrimSpace(raw)) == 0 {
		return map[string]any{}, nil
	}
	var out map[string]any
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&out); err != nil {
		if probe {
			return nil, &ProbeUnknown{Msg: "probe error: invalid json"}
		}
		return nil, &ControllerError{Msg: "local controller unavailable: invalid json"}
	}
	if out == nil {
		out = map[string]any{}
	}
	return out, nil
}

func isTimeoutError(err error) bool {
	if errors.Is(err, context.DeadlineExceeded) {
		return true
	}
	var netErr net.Error
	return errors.As(err, &netErr) && netErr.Timeout()
}

func classifyErr(err error) string {
	var urlErr *url.Error
	if errors.As(err, &urlErr) && urlErr.Err != nil {
		return fmt.Sprintf("%T", urlErr.Err)
	}
	return fmt.Sprintf("%T", err)
}

func (m *Monitor) probeTimeoutMs() int {
	if m.ProbeTimeoutMs <= 0 {
		return DefaultProbeTimeoutMs
	}
	return m.ProbeTimeoutMs
}

func (m *Monitor) threshold() int {
	if m.Threshold <= 0 {
		return DefaultThreshold
	}
	return m.Threshold
}

func (m *Monitor) maxWorkers() int {
	if m.MaxWorkers <= 0 {
		return DefaultMaxWorkers
	}
	return m.MaxWorkers
}

func (m *Monitor) probeURLs() []string {
	if len(m.ProbeURLs) == 0 {
		return DefaultProbeURLs
	}
	return m.ProbeURLs
}

func (m *Monitor) healthy(ctx context.Context, tag string) (*bool, error) {
	sawFailure := false
	sawUnknown := false
	timeoutStr := strconv.Itoa(m.probeTimeoutMs())

	for _, probeURL := range m.probeURLs() {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		q := url.Values{}
		q.Set("url", probeURL)
		q.Set("timeout", timeoutStr)
		path := "/proxies/" + url.PathEscape(tag) + "/delay?" + q.Encode()

		result, err := m.api(ctx, path, http.MethodGet, nil, true)
		if err != nil {
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			var pf *ProbeFailed
			if errors.As(err, &pf) {
				sawFailure = true
				continue
			}
			var pu *ProbeUnknown
			if errors.As(err, &pu) {
				sawUnknown = true
				continue
			}
			return nil, err
		}

		if delayVal, ok := result["delay"]; ok {
			if delay, okNum := parsePositiveDelay(delayVal); okNum && delay > 0 {
				v := true
				return &v, nil
			}
		}
		sawFailure = true
	}

	if sawUnknown {
		return nil, nil
	}
	if sawFailure {
		v := false
		return &v, nil
	}
	v := false
	return &v, nil
}

func parsePositiveDelay(v any) (float64, bool) {
	switch val := v.(type) {
	case json.Number:
		f, err := val.Float64()
		return f, err == nil
	case float64:
		return val, true
	case int:
		return float64(val), true
	case int64:
		return float64(val), true
	default:
		return 0, false
	}
}

// WriteStatus atomically writes the status JSON file with mode 0600.
func (m *Monitor) WriteStatus(status StatusFile) error {
	if status.Groups == nil {
		status.Groups = make([]GroupStatus, 0)
	}
	dir := filepath.Dir(m.StatusPath)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}

	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(status); err != nil {
		return err
	}
	data := bytes.TrimSuffix(buf.Bytes(), []byte("\n"))

	tmp, err := os.CreateTemp(dir, ".status-*")
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

	if _, err := tmp.Write(data); err != nil {
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
	if err := os.Rename(tmpPath, m.StatusPath); err != nil {
		return err
	}
	cleanup = false
	return nil
}

func validateLoopbackController(controller, secret string) error {
	idx := strings.LastIndexByte(controller, ':')
	if idx < 0 {
		return &ControllerError{Msg: "missing authenticated loopback controller"}
	}
	host := controller[:idx]
	port := controller[idx+1:]
	if host != "127.0.0.1" || port == "" || secret == "" {
		return &ControllerError{Msg: "missing authenticated loopback controller"}
	}
	for i := 0; i < len(port); i++ {
		if port[i] < '0' || port[i] > '9' {
			return &ControllerError{Msg: "missing authenticated loopback controller"}
		}
	}
	return nil
}

// Cycle performs one complete health-check and failover/recovery pass.
func (m *Monitor) Cycle(ctx context.Context) ([]GroupStatus, error) {
	cfg, configChanged, err := m.loadConfig()
	if err != nil {
		return nil, err
	}

	var selectors []outboundConfig
	for _, ob := range cfg.Outbounds {
		if ob.Type == "selector" && strings.HasPrefix(ob.Tag, "failover-") {
			selectors = append(selectors, ob)
		}
	}
	if len(selectors) == 0 {
		clear(m.counters)
		if err := m.WriteStatus(StatusFile{
			CheckedAt: time.Now().Unix(),
			Groups:    make([]GroupStatus, 0),
			Error:     "",
		}); err != nil {
			return nil, err
		}
		return make([]GroupStatus, 0), nil
	}

	controller := cfg.Experimental.ClashAPI.ExternalController
	secret := cfg.Experimental.ClashAPI.Secret
	if err := validateLoopbackController(controller, secret); err != nil {
		return nil, err
	}
	m.base = "http://" + controller
	m.secret = secret
	if configChanged {
		clear(m.counters)
	}

	proxiesResp, err := m.api(ctx, "/proxies/", http.MethodGet, nil, false)
	if err != nil {
		return nil, err
	}
	proxiesMap, _ := proxiesResp["proxies"].(map[string]any)

	tagSet := make(map[string]struct{})
	selectedMap := make(map[string]string, len(selectors))
	for _, sel := range selectors {
		if len(sel.Outbounds) != 2 || sel.Outbounds[0] == sel.Outbounds[1] || !containsString(sel.Outbounds, sel.Default) {
			return nil, &ControllerError{Msg: "invalid failover selector"}
		}
		for _, member := range sel.Outbounds {
			tagSet[member] = struct{}{}
		}
		entry, _ := proxiesMap[sel.Tag].(map[string]any)
		now, _ := entry["now"].(string)
		if !containsString(sel.Outbounds, now) {
			return nil, &ControllerError{Msg: "selector unavailable in running core"}
		}
		selectedMap[sel.Tag] = now
	}

	sortedTags := make([]string, 0, len(tagSet))
	for tag := range tagSet {
		sortedTags = append(sortedTags, tag)
	}
	sort.Strings(sortedTags)

	type probeResult struct {
		ok  *bool
		err error
	}
	results := make([]probeResult, len(sortedTags))

	probeCtx, cancelProbes := context.WithCancel(ctx)
	defer cancelProbes()

	sem := make(chan struct{}, m.maxWorkers())
	var wg sync.WaitGroup
	for i, tag := range sortedTags {
		wg.Add(1)
		go func(idx int, t string) {
			defer wg.Done()
			select {
			case sem <- struct{}{}:
				defer func() { <-sem }()
			case <-probeCtx.Done():
				results[idx] = probeResult{err: probeCtx.Err()}
				return
			}
			okVal, pErr := m.healthy(probeCtx, t)
			results[idx] = probeResult{ok: okVal, err: pErr}
			if pErr != nil {
				cancelProbes()
			}
		}(i, tag)
	}
	wg.Wait()

	if ctx.Err() != nil {
		return nil, ctx.Err()
	}

	var firstErr error
	for i := range sortedTags {
		if err := results[i].err; err != nil {
			if firstErr == nil || errors.Is(firstErr, context.Canceled) {
				firstErr = err
			}
		}
	}
	if firstErr != nil {
		return nil, firstErr
	}

	health := make(map[string]*bool, len(sortedTags))
	for i, tag := range sortedTags {
		health[tag] = results[i].ok
	}

	thresh := m.threshold()
	for _, tag := range sortedTags {
		status := health[tag]
		old := m.counters[tag]
		if status != nil && *status {
			m.counters[tag] = counter{Good: min(thresh, old.Good+1), Bad: 0}
		} else if status != nil && !*status {
			m.counters[tag] = counter{Good: 0, Bad: min(thresh, old.Bad+1)}
		} else {
			m.counters[tag] = old
		}
	}

	groups := make([]GroupStatus, 0, len(selectors))
	for _, sel := range selectors {
		tag := sel.Tag
		primary := sel.Default
		backup := sel.Outbounds[0]
		if backup == primary {
			backup = sel.Outbounds[1]
		}
		selected := selectedMap[tag]
		desired := selected
		if selected == primary && m.counters[primary].Bad >= thresh && health[backup] != nil && *health[backup] {
			desired = backup
		} else if selected != primary && m.counters[primary].Good >= thresh {
			desired = primary
		}
		if desired != selected {
			if _, err := m.api(ctx, "/proxies/"+url.PathEscape(tag), http.MethodPut, map[string]string{"name": desired}, false); err != nil {
				return nil, err
			}
			if m.Stdout != nil {
				_, _ = fmt.Fprintf(m.Stdout, "%s %s %s -> %s\n", time.Now().Format("2006-01-02 15:04:05"), tag, selected, desired)
			}
			selected = desired
		}

		allDown := health[primary] != nil && !*health[primary] && health[backup] != nil && !*health[backup]
		groups = append(groups, GroupStatus{
			Tag:              tag,
			Primary:          primary,
			Backup:           backup,
			Selected:         selected,
			PrimaryOK:        health[primary],
			BackupOK:         health[backup],
			PrimaryFailures:  m.counters[primary].Bad,
			PrimarySuccesses: m.counters[primary].Good,
			AllDown:          allDown,
		})
	}

	if err := m.WriteStatus(StatusFile{
		CheckedAt: time.Now().Unix(),
		Groups:    groups,
		Error:     "",
	}); err != nil {
		return nil, err
	}
	return groups, nil
}

// Run executes the monitoring loop until ctx is cancelled.
func (m *Monitor) Run(ctx context.Context) error {
	defer m.Close()

	interval := m.Interval
	if interval <= 0 {
		interval = DefaultInterval
	}
	minSleep := time.Second
	if interval < minSleep {
		minSleep = interval
	}

	for ctx.Err() == nil {
		started := time.Now()
		_, err := m.Cycle(ctx)
		if ctx.Err() != nil {
			break
		}
		if err != nil {
			errMsg := truncateRunes(err.Error(), 240)
			if m.lastError != errMsg && m.Stderr != nil {
				_, _ = fmt.Fprintf(m.Stderr, "failover: %s\n", errMsg)
			}
			m.lastError = errMsg
			_ = m.WriteStatus(StatusFile{
				CheckedAt: time.Now().Unix(),
				Groups:    make([]GroupStatus, 0),
				Error:     errMsg,
			})
		} else {
			m.lastError = ""
		}

		wait := interval - time.Since(started)
		if wait < minSleep {
			wait = minSleep
		}
		timer := time.NewTimer(wait)
		select {
		case <-ctx.Done():
			timer.Stop()
			return nil
		case <-timer.C:
		}
	}
	return nil
}

func containsString(list []string, target string) bool {
	for _, s := range list {
		if s == target {
			return true
		}
	}
	return false
}

func truncateRunes(s string, max int) string {
	runes := []rune(s)
	if len(runes) <= max {
		return s
	}
	return string(runes[:max])
}
