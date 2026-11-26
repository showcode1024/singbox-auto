package agent

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/showcode1024/singbox-auto/singbox-plus/internal/activity"
	"github.com/showcode1024/singbox-auto/singbox-plus/internal/store"
	"github.com/showcode1024/singbox-auto/singbox-plus/internal/v2stats"
)

// CollectorFunc queries per-user uplink/downlink counters from sing-box.
type CollectorFunc func(ctx context.Context, cfg map[string]any) (map[string]store.Counter, error)

// CoreProbeFunc identifies the running sing-box process epoch.
type CoreProbeFunc func(cfg map[string]any, verifyOnly bool) (string, error)

// HelperRunnerFunc invokes an allowlisted local installer helper action.
type HelperRunnerFunc func(ctx context.Context, cfg map[string]any, action string, extra []string, timeout time.Duration) ([]byte, error)

// Options configures an Agent instance (all fields have production defaults).
type Options struct {
	AllowLoopbackHTTP bool
	Version           string
	TransportOverride Poster
	Collector         CollectorFunc
	CoreProbe         CoreProbeFunc
	HelperRunner      HelperRunnerFunc
	Stderr            io.Writer
	SampleInterval    time.Duration
	SyncInterval      time.Duration
	WaitSeconds       int
}

func (o Options) withDefaults() Options {
	if o.Version == "" {
		o.Version = "dev"
	}
	if o.Collector == nil {
		o.Collector = CollectCounters
	}
	if o.CoreProbe == nil {
		o.CoreProbe = ProbeCore
	}
	if o.HelperRunner == nil {
		o.HelperRunner = RunHelper
	}
	if o.Stderr == nil {
		o.Stderr = os.Stderr
	}
	if o.SampleInterval <= 0 {
		o.SampleInterval = DefaultSampleInterval
	}
	if o.SyncInterval <= 0 {
		o.SyncInterval = DefaultSyncInterval
	}
	if o.WaitSeconds <= 0 {
		o.WaitSeconds = DefaultWaitSeconds
	}
	return o
}

// CollectCounters queries sing-box's local V2Ray StatsService directly in-process via h2c gRPC.
func CollectCounters(ctx context.Context, _ map[string]any) (map[string]store.Counter, error) {
	qCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()

	resp, err := v2stats.Query(qCtx, v2stats.DefaultAddr)
	if err != nil {
		return nil, collectorErr("Stats API query failed: %v", err)
	}
	result := make(map[string]store.Counter)
	seen := make(map[string]struct{}, len(resp.Stat))
	for _, st := range resp.Stat {
		m := StatRe.FindStringSubmatch(st.Name)
		if m == nil {
			continue
		}
		if _, dup := seen[st.Name]; dup {
			return nil, collectorErr("Stats API returned a duplicate counter")
		}
		seen[st.Name] = struct{}{}
		if st.Value < 0 {
			return nil, collectorErr("Invalid integer: statistics byte counter")
		}
		key, dir := m[1], m[2]
		c := result[key]
		if dir == "uplink" {
			c.Uplink = st.Value
		} else {
			c.Downlink = st.Value
		}
		result[key] = c
	}
	return result, nil
}

// RunHelper executes an allowlisted action via bash <script_path> <action> [extra...].
func RunHelper(ctx context.Context, cfg map[string]any, action string, extra []string, timeout time.Duration) ([]byte, error) {
	switch action {
	case "agent-inventory", "agent-apply", "agent-detach":
	default:
		return nil, agentErr("Unsupported local helper action")
	}
	script := mapString(cfg, "script_path", DefaultScriptPath())
	if !filepath.IsAbs(script) {
		return nil, agentErr("Installer helper path is missing or is not absolute")
	}
	fi, err := os.Stat(script)
	if err != nil || !fi.Mode().IsRegular() {
		return nil, agentErr("Installer helper path is missing or is not absolute")
	}
	args := make([]string, 0, 3+len(extra))
	args = append(args, "bash", script, action)
	args = append(args, extra...)
	return RunProcess(ctx, args, timeout, 5*time.Second, cfg)
}

// Agent implements the YSQ node agent lifecycle (register, sample, sync, wait, activity, detach).
type Agent struct {
	configPath         string
	config             map[string]any
	ledger             *store.Ledger
	opts               Options
	syncedInboundsHash string
	notifiedRevision   int64
}

// New opens an Agent for the existing config at configPath.
func New(configPath string, opts Options) (*Agent, error) {
	opts = opts.withDefaults()
	cfg, err := ReadJSONMap(configPath)
	if err != nil {
		return nil, err
	}
	if rawProto, ok := cfg["protocol"]; ok {
		p, okInt := parseInt64Exact(rawProto)
		if !okInt || p != Protocol {
			return nil, agentErr("Unsupported local agent protocol")
		}
	}
	centerURL := mapString(cfg, "center_url", "")
	if _, err := ValidateOrigin(centerURL, opts.AllowLoopbackHTTP); err != nil {
		return nil, err
	}
	dbPath := mapString(cfg, "db_path", "")
	if dbPath == "" {
		return nil, agentErr("Agent configuration is missing db_path")
	}
	ledger, err := store.OpenLedger(dbPath)
	if err != nil {
		return nil, err
	}
	return &Agent{
		configPath: configPath,
		config:     cfg,
		ledger:     ledger,
		opts:       opts,
	}, nil
}

// Ledger exposes the underlying durable Ledger.
func (a *Agent) Ledger() *store.Ledger { return a.ledger }

// Config returns a defensive snapshot of the current config map.
func (a *Agent) Config() map[string]any { return cloneMap(a.config) }

// Reload refreshes the in-memory config snapshot from disk.
func (a *Agent) Reload() (map[string]any, error) {
	fresh, err := ReadJSONMap(a.configPath)
	if err != nil {
		return nil, err
	}
	if mapString(fresh, "db_path", "") != mapString(a.config, "db_path", "") {
		return nil, agentErr("Agent configuration changed to another ledger; restart the service")
	}
	a.config = fresh
	return fresh, nil
}

// Save atomically persists the current config snapshot to disk.
func (a *Agent) Save() error {
	return AtomicJSON(a.configPath, a.config)
}

func (a *Agent) poster(timeout time.Duration) (Poster, func(), error) {
	if a.opts.TransportOverride != nil {
		return a.opts.TransportOverride, func() {}, nil
	}
	tr, err := NewTransport(
		mapString(a.config, "center_url", ""),
		mapString(a.config, "node_token", ""),
		a.opts.Version,
		a.opts.AllowLoopbackHTTP,
		timeout,
	)
	if err != nil {
		return nil, nil, err
	}
	return tr, tr.Close, nil
}

func (a *Agent) readState() (map[string]any, error) {
	statePath := mapString(a.config, "state_path", DefaultStatePath())
	return ReadJSONMap(statePath)
}

func (a *Agent) subscriptionInbounds() ([]map[string]any, error) {
	state, err := a.readState()
	if err != nil {
		return nil, err
	}
	nodes, _ := state["nodes"].([]any)
	result := make([]map[string]any, 0, len(nodes))
	serverIP := truncateRunes(mapString(state, "server_ip", ""), 253)
	tuicSNI := truncateRunes(mapString(state, "tuic_sni", ""), 253)
	realitySNI := truncateRunes(mapString(state, "reality_sni", ""), 253)
	pubKey := truncateRunes(mapString(state, "public_key", ""), 253)
	shortID := truncateRunes(mapString(state, "short_id", ""), 253)

	for _, rawNode := range nodes {
		node, ok := rawNode.(map[string]any)
		if !ok {
			continue
		}
		kind := inboundFieldString(node["type"], 64)
		isTuic := strings.HasPrefix(kind, "tuic")
		sni := realitySNI
		nodePubKey := pubKey
		nodeShortID := shortID
		if isTuic {
			sni = tuicSNI
			nodePubKey = ""
			nodeShortID = ""
		}
		item := map[string]any{
			"name":             inboundFieldString(node["name"], 160),
			"tag":              inboundFieldString(node["tag"], 160),
			"type":             kind,
			"port":             orEmpty(node["port"]),
			"server":           serverIP,
			"sni":              sni,
			"public_key":       nodePubKey,
			"short_id":         nodeShortID,
			"skip_cert_verify": isTuic,
		}
		result = append(result, item)
	}
	return result, nil
}

func truncateRunes(s string, maxLen int) string {
	runes := []rune(s)
	if len(runes) > maxLen {
		return string(runes[:maxLen])
	}
	return s
}

func inboundFieldString(v any, maxLen int) string {
	if v == nil {
		return ""
	}
	return truncateRunes(fmt.Sprint(v), maxLen)
}

func orEmpty(v any) any {
	if v == nil {
		return ""
	}
	return v
}

func (a *Agent) isRunning() bool {
	_, err := a.opts.CoreProbe(a.config, false)
	return err == nil
}

func (a *Agent) rememberState(state map[string]any) error {
	existing, err := a.ledger.Aliases()
	if err != nil {
		return err
	}
	known := make(map[string]struct{}, len(existing))
	for _, item := range existing {
		known[item.StatsKey] = struct{}{}
	}
	rawUsers, _ := state["users"].([]any)
	var toAdd []store.AliasEntry
	for _, rawU := range rawUsers {
		u, ok := rawU.(map[string]any)
		if !ok {
			continue
		}
		uid := mapString(u, "id", "")
		if !UserIDRe.MatchString(uid) {
			continue
		}
		key := mapString(u, "stats_key", "")
		if key == "" {
			key = mapString(u, "name", "")
		}
		if key == "" || strings.Contains(key, ">") {
			continue
		}
		if _, exists := known[key]; !exists {
			toAdd = append(toAdd, store.AliasEntry{
				StatsKey:         key,
				UserID:           uid,
				BaselineRequired: true,
			})
			known[key] = struct{}{}
		}
	}
	return a.ledger.Remember(toAdd)
}

// SampleOnce collects one counter snapshot from sing-box and commits it to the ledger.
func (a *Agent) SampleOnce(ctx context.Context, allowDetaching bool) (map[string]any, error) {
	unlock, err := AcquireFileLock(ctx, a.ledger.LogicalPath()+".sample.lock", 500*time.Millisecond)
	if err != nil {
		return nil, err
	}
	defer unlock()

	if _, err := a.Reload(); err != nil {
		return nil, err
	}
	if mapBool(a.config, false, "detached") || (mapBool(a.config, false, "detaching") && !allowDetaching) {
		return map[string]any{"skipped": "detached_or_detaching"}, nil
	}
	nodeID := mapString(a.config, "node_id", "")
	status := mapString(a.config, "status", "")
	if nodeID == "" || status == "registering" || status == "pending" {
		return map[string]any{"skipped": "waiting_for_first_sync"}, nil
	}
	appliedRev, err := a.ledger.MetaInt64("applied_revision", 0)
	if err != nil {
		return nil, err
	}
	adoptionPrepared, err := a.ledger.MetaBool("adoption_prepared", false)
	if err != nil {
		return nil, err
	}
	if appliedRev == 0 && !adoptionPrepared {
		return map[string]any{"skipped": "waiting_for_first_sync"}, nil
	}

	sampleErr := func(orig error) (map[string]any, error) {
		msg := Redact(orig.Error(), a.config)
		if metaErr := a.ledger.SetMeta(map[string]any{
			"collector_error": msg,
			"service_running": a.isRunning(),
		}); metaErr != nil {
			return nil, agentErr("Ledger write failed; counters were not acknowledged or discarded: %v", metaErr)
		}
		return nil, &CollectorError{Msg: msg}
	}

	state, err := a.readState()
	if err != nil {
		return sampleErr(err)
	}
	if err := a.rememberState(state); err != nil {
		return sampleErr(err)
	}
	aliases, err := a.ledger.Aliases()
	if err != nil {
		return sampleErr(err)
	}
	if len(aliases) == 0 {
		return map[string]any{"skipped": "waiting_for_first_sync"}, nil
	}

	before, err := a.opts.CoreProbe(a.config, false)
	if err != nil {
		return sampleErr(err)
	}
	counters, err := a.opts.Collector(ctx, a.config)
	if err != nil {
		return sampleErr(err)
	}
	after, err := a.opts.CoreProbe(a.config, true)
	if err != nil {
		return sampleErr(err)
	}
	if before != after {
		return sampleErr(collectorErr("sing-box restarted during collection; sample was not committed"))
	}

	rec, err := a.ledger.Record(before, counters, time.Now().Unix())
	if err != nil {
		return sampleErr(err)
	}
	return map[string]any{
		"sampled_at": rec.SampledAt,
		"up":         rec.Up,
		"down":       rec.Down,
	}, nil
}

// Register sends the durable pending registration payload to /api/agent/register.
func (a *Agent) Register(ctx context.Context) (map[string]any, error) {
	if _, err := a.Reload(); err != nil {
		return nil, err
	}
	if nid := mapString(a.config, "node_id", ""); nid != "" {
		return map[string]any{
			"node_id": nid,
			"status":  mapString(a.config, "status", "pending"),
		}, nil
	}
	payload, ok := a.config["registration_payload"].(map[string]any)
	if !ok || len(payload) == 0 {
		return nil, agentErr("No pending registration exists")
	}

	p, closePoster, err := a.poster(12 * time.Second)
	if err != nil {
		return nil, err
	}
	defer closePoster()

	resp, err := p.Post(ctx, "/api/agent/register", payload, false)
	if err != nil {
		return nil, err
	}
	nodeID := mapString(resp, "node_id", "")
	status := mapString(resp, "status", "")
	if !NodeIDRe.MatchString(nodeID) || (status != "pending" && status != "active") {
		return nil, &TransportError{Msg: "Invalid registration response"}
	}

	regUsers := make(map[string]struct{})
	if rawUsers, ok := payload["users"].([]any); ok {
		for _, ru := range rawUsers {
			if um, ok := ru.(map[string]any); ok {
				if name := mapString(um, "name", ""); name != "" {
					regUsers[name] = struct{}{}
				}
			}
		}
	}

	aliases := make(map[string]string)
	if rawImported, exists := resp["imported"]; exists && rawImported != nil {
		impList, ok := rawImported.([]any)
		if !ok {
			return nil, &TransportError{Msg: "Invalid imported user mappings"}
		}
		for _, rawItem := range impList {
			item, ok := rawItem.(map[string]any)
			if !ok {
				return nil, &TransportError{Msg: "Invalid imported user mapping"}
			}
			oldName := mapString(item, "old_name", "")
			uid := mapString(item, "id", "")
			if _, validOld := regUsers[oldName]; !validOld || !UserIDRe.MatchString(uid) {
				return nil, &TransportError{Msg: "Invalid imported user mapping"}
			}
			if prev, dup := aliases[oldName]; dup && prev != uid {
				return nil, &TransportError{Msg: "Ambiguous imported user mapping"}
			}
			aliases[oldName] = uid
		}
	}

	a.config["node_id"] = nodeID
	a.config["status"] = status
	a.config["registered_at"] = time.Now().Unix()
	a.config["registration_aliases"] = aliases
	delete(a.config, "registration_payload")
	if err := a.Save(); err != nil {
		return nil, err
	}
	return map[string]any{
		"node_id": nodeID,
		"status":  status,
	}, nil
}

// PrepareDesired validates a center desired snapshot and records alias mappings before applying.
func (a *Agent) PrepareDesired(ctx context.Context, desired map[string]any) (map[string]any, error) {
	if desired == nil || mapString(desired, "node_id", "") != mapString(a.config, "node_id", "") {
		return nil, agentErr("Desired configuration belongs to another node")
	}
	revision, err := requireInt64(desired["revision"], "desired revision", 1, math.MaxInt64)
	if err != nil {
		return nil, err
	}
	users, err := ValidatedUsers(desired["users"], true)
	if err != nil {
		return nil, err
	}
	currentRev, err := a.ledger.MetaInt64("applied_revision", 0)
	if err != nil {
		return nil, err
	}
	if revision < currentRev {
		return nil, agentErr("Center offered an older configuration revision")
	}

	state, err := a.readState()
	if err != nil {
		return nil, err
	}
	mgmt, _ := state["management"].(map[string]any)
	var knownRevs []int64
	if mgmt != nil {
		if v, ok := parseInt64Exact(mgmt["revision"]); ok && v >= 1 {
			knownRevs = append(knownRevs, v)
		}
		if v, ok := parseInt64Exact(mgmt["applying_revision"]); ok && v >= 1 {
			knownRevs = append(knownRevs, v)
		}
	}
	managedHere := mgmt != nil &&
		mapString(mgmt, "mode", "") == "managed" &&
		mapString(mgmt, "node_id", "") == mapString(a.config, "node_id", "") &&
		len(knownRevs) > 0

	stateUsers, _ := state["users"].([]any)
	if stateUsers == nil {
		stateUsers = []any{}
	}
	if managedHere {
		if _, err := ValidatedUsers(stateUsers, true); err != nil {
			return nil, err
		}
		maxKnown := knownRevs[0]
		for _, r := range knownRevs[1:] {
			if r > maxKnown {
				maxKnown = r
			}
		}
		if revision < maxKnown {
			return nil, agentErr("Center offered a revision older than the locally managed state")
		}
	}
	if currentRev == 0 && !managedHere {
		if regFP := mapString(a.config, "registration_fingerprint", ""); regFP != "" {
			curFP, err := Fingerprint(stateUsers)
			if err != nil {
				return nil, err
			}
			if curFP != regFP {
				return nil, agentErr("Local users changed after registration, before initial center sync. Review local users and reconnect")
			}
		}
	}

	byUUID := make(map[string]string, len(users))
	desiredIDs := make(map[string]struct{}, len(users))
	for _, u := range users {
		uid := u["id"].(string)
		byUUID[u["uuid"].(string)] = uid
		desiredIDs[uid] = struct{}{}
	}
	importedAliases := stringMap(a.config["registration_aliases"])

	var aliases []store.AliasEntry
	currentKeys := make(map[string]struct{}, len(stateUsers))
	for _, rawLocal := range stateUsers {
		local, ok := rawLocal.(map[string]any)
		if !ok {
			continue
		}
		oldKey := mapString(local, "stats_key", "")
		if oldKey == "" {
			oldKey = mapString(local, "name", "")
		}
		if oldKey != "" {
			currentKeys[oldKey] = struct{}{}
		}
		var identity string
		if currentRev > 0 || managedHere {
			identity = mapString(local, "id", "")
		}
		if !UserIDRe.MatchString(identity) {
			identity = importedAliases[mapString(local, "name", "")]
			if _, inDesired := desiredIDs[identity]; !inDesired {
				identity = byUUID[strings.ToLower(mapString(local, "uuid", ""))]
			}
		}
		if identity != "" && oldKey != "" {
			aliases = append(aliases, store.AliasEntry{
				StatsKey:         oldKey,
				UserID:           identity,
				BaselineRequired: true,
			})
		}
	}
	for _, u := range users {
		uid := u["id"].(string)
		_, inCurrent := currentKeys[uid]
		aliases = append(aliases, store.AliasEntry{
			StatsKey:         uid,
			UserID:           uid,
			BaselineRequired: inCurrent,
		})
	}

	unlock, err := AcquireFileLock(ctx, a.ledger.LogicalPath()+".sample.lock", 8*time.Second)
	if err != nil {
		return nil, err
	}
	defer unlock()

	if err := a.ledger.Remember(aliases); err != nil {
		return nil, err
	}
	if err := a.ledger.SetMeta(map[string]any{"adoption_prepared": true}); err != nil {
		return nil, err
	}

	return map[string]any{
		"node_id":  desired["node_id"],
		"revision": revision,
		"users":    users,
	}, nil
}

// ApplyDesired applies a center desired snapshot via the agent-apply helper and confirms the revision on disk.
func (a *Agent) ApplyDesired(ctx context.Context, desired map[string]any) (bool, error) {
	payload, err := a.PrepareDesired(ctx, desired)
	if err != nil {
		return false, err
	}
	revision := payload["revision"].(int64)
	appliedRev, err := a.ledger.MetaInt64("applied_revision", 0)
	if err != nil {
		return false, err
	}
	if revision == appliedRev {
		return false, nil
	}

	parent, err := store.EnsurePrivateDir(a.ledger.Path())
	if err != nil {
		return false, err
	}
	rawPayload, err := store.CanonicalJSON(payload)
	if err != nil {
		return false, err
	}
	tmp, err := os.CreateTemp(parent, ".desired-*.json")
	if err != nil {
		return false, err
	}
	tmpPath := tmp.Name()
	defer func() {
		_ = os.Remove(tmpPath)
	}()

	_ = tmp.Chmod(0o600)
	if _, err := tmp.Write(rawPayload); err != nil {
		_ = tmp.Close()
		return false, err
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return false, err
	}
	if err := tmp.Close(); err != nil {
		return false, err
	}

	helperCfg := cloneMap(a.config)
	helperCfg["_redact_users"] = payload["users"]
	if _, err := a.opts.HelperRunner(ctx, helperCfg, "agent-apply", []string{tmpPath}, 120*time.Second); err != nil {
		return false, err
	}

	state, err := a.readState()
	if err != nil {
		return false, err
	}
	mgmt, _ := state["management"].(map[string]any)
	confirmedRev, okRev := parseInt64Exact(mgmt["revision"])
	if mgmt == nil ||
		mapString(mgmt, "mode", "") != "managed" ||
		mapString(mgmt, "node_id", "") != mapString(payload, "node_id", "") ||
		!okRev || confirmedRev != revision || !a.isRunning() {
		return false, agentErr("Helper did not confirm the requested revision and a healthy core")
	}

	if err := a.ledger.SetMeta(map[string]any{
		"applied_revision": revision,
		"apply_error":      "",
		"last_apply_at":    time.Now().Unix(),
	}); err != nil {
		return false, err
	}
	return true, nil
}

// SyncOnce acquires the sync lock and runs one sync round against the center server.
func (a *Agent) SyncOnce(ctx context.Context, forcePackage, apply bool) (map[string]any, error) {
	unlock, err := AcquireFileLock(ctx, a.configPath+".sync.lock", time.Second)
	if err != nil {
		return nil, err
	}
	defer unlock()

	if _, err := a.Reload(); err != nil {
		return nil, err
	}
	if mapBool(a.config, false, "detached") || mapBool(a.config, false, "detaching") {
		return nil, agentErr("Node is detached or detaching")
	}
	if mapBool(a.config, false, "remote_detached") {
		return a.detachLocal(ctx)
	}
	return a.syncLocked(ctx, forcePackage, apply)
}

func (a *Agent) syncLocked(ctx context.Context, forcePackage, apply bool) (map[string]any, error) {
	if mapString(a.config, "node_id", "") == "" {
		if _, err := a.Register(ctx); err != nil {
			var te *TransportError
			if errors.As(err, &te) && (te.Status == 403 || te.Status == 410) {
				return a.detachLocal(ctx)
			}
			return nil, err
		}
	}

	if _, err := a.ledger.Package(time.Now().Unix(), forcePackage); err != nil {
		return nil, err
	}
	summary, err := a.ledger.Summary()
	if err != nil {
		return nil, err
	}
	batches, err := a.ledger.Batches()
	if err != nil {
		return nil, err
	}
	inbounds, err := a.subscriptionInbounds()
	if err != nil {
		return nil, err
	}
	rawInbounds, err := store.CanonicalJSON(inbounds)
	if err != nil {
		return nil, err
	}
	inbSum := sha256.Sum256(rawInbounds)
	inboundsHash := hex.EncodeToString(inbSum[:])

	var lastSampleAt int64
	if summary.LastSampleAt != nil {
		lastSampleAt = *summary.LastSampleAt
	}
	nodeID := mapString(a.config, "node_id", "")
	payload := map[string]any{
		"protocol":         Protocol,
		"node_id":          nodeID,
		"agent_version":    a.opts.Version,
		"applied_revision": summary.AppliedRevision,
		"apply_error":      summary.ApplyError,
		"service_running":  a.isRunning(),
		"collector_error":  summary.CollectorError,
		"last_sample_at":   lastSampleAt,
		"pending_batches":  summary.PendingBatches,
		"batches":          batches,
	}
	if inboundsHash != a.syncedInboundsHash {
		payload["inbounds"] = inbounds
	}

	p, closePoster, err := a.poster(12 * time.Second)
	if err != nil {
		_ = a.ledger.SetMeta(map[string]any{"sync_error": Redact(err.Error(), a.config)})
		return nil, err
	}
	defer closePoster()

	resp, err := p.Post(ctx, "/api/agent/sync", payload, true)
	if err != nil {
		var te *TransportError
		if errors.As(err, &te) && te.Status == 410 {
			return a.detachLocal(ctx)
		}
		if ctx.Err() == nil {
			_ = a.ledger.SetMeta(map[string]any{"sync_error": Redact(err.Error(), a.config)})
		}
		return nil, err
	}

	respNodeID := mapString(resp, "node_id", "")
	respStatus := mapString(resp, "status", "")
	if respNodeID != nodeID || (respStatus != "active" && respStatus != "pending") {
		err := &TransportError{Msg: "Center returned an invalid node status"}
		_ = a.ledger.SetMeta(map[string]any{"sync_error": Redact(err.Error(), a.config)})
		return nil, err
	}

	acks, err := parseAcks(resp["ack"])
	if err != nil {
		_ = a.ledger.SetMeta(map[string]any{"sync_error": Redact(err.Error(), a.config)})
		return nil, err
	}
	ackedCount, err := a.ledger.Acknowledge(acks, batches)
	if err != nil {
		te := &TransportError{Msg: err.Error()}
		_ = a.ledger.SetMeta(map[string]any{"sync_error": Redact(te.Error(), a.config)})
		return nil, te
	}

	a.syncedInboundsHash = inboundsHash
	if err := a.ledger.SetMeta(map[string]any{
		"last_sync_at": time.Now().Unix(),
		"sync_error":   "",
	}); err != nil {
		return nil, err
	}
	if mapString(a.config, "status", "") != respStatus {
		a.config["status"] = respStatus
		if err := a.Save(); err != nil {
			return nil, err
		}
	}

	applied := false
	if apply && resp["desired"] != nil {
		desiredMap, ok := resp["desired"].(map[string]any)
		if !ok {
			msg := Redact("Invalid desired snapshot", a.config)
			_ = a.ledger.SetMeta(map[string]any{"apply_error": msg})
			return nil, agentErr("Configuration was not acknowledged: %s", msg)
		}
		if respStatus != "active" {
			msg := Redact("Node is not yet active", a.config)
			_ = a.ledger.SetMeta(map[string]any{"apply_error": msg})
			return nil, agentErr("Configuration was not acknowledged: %s", msg)
		}
		applied, err = a.ApplyDesired(ctx, desiredMap)
		if err != nil {
			msg := Redact(err.Error(), a.config)
			_ = a.ledger.SetMeta(map[string]any{"apply_error": msg})
			return nil, agentErr("Configuration was not acknowledged: %s", msg)
		}
	}

	newAppliedRev, _ := a.ledger.MetaInt64("applied_revision", 0)
	return map[string]any{
		"node_id":              nodeID,
		"status":               respStatus,
		"acknowledged_batches": ackedCount,
		"applied":              applied,
		"applied_revision":     newAppliedRev,
	}, nil
}

func parseAcks(raw any) ([]store.Ack, error) {
	if raw == nil {
		return nil, nil
	}
	list, ok := raw.([]any)
	if !ok {
		return nil, &TransportError{Msg: "Center acknowledgement is not a list"}
	}
	out := make([]store.Ack, 0, len(list))
	for _, item := range list {
		m, ok := item.(map[string]any)
		if !ok {
			return nil, &TransportError{Msg: "Invalid center acknowledgement"}
		}
		epoch, ok := m["epoch"].(string)
		if !ok || epoch == "" {
			return nil, &TransportError{Msg: "Invalid center acknowledgement"}
		}
		seq, ok := parseInt64Exact(m["seq"])
		if !ok || seq < 1 {
			return nil, &TransportError{Msg: "Invalid center acknowledgement"}
		}
		out = append(out, store.Ack{Epoch: epoch, Seq: seq})
	}
	return out, nil
}

// WaitChanges long-polls /api/agent/wait without holding the sync lock.
func (a *Agent) WaitChanges(ctx context.Context, detach bool) (map[string]any, error) {
	if _, err := a.Reload(); err != nil {
		return nil, err
	}
	if mapBool(a.config, false, "detached") {
		return map[string]any{"status": "detached", "changed": false}, nil
	}
	if mapBool(a.config, false, "remote_detached") {
		if detach {
			return a.DetachFromCenter(ctx)
		}
		return map[string]any{"changed": false, "detach_requested": true}, nil
	}
	if mapBool(a.config, false, "detaching") || mapString(a.config, "node_id", "") == "" {
		return map[string]any{"changed": false, "skipped": true}, nil
	}

	appliedRev, err := a.ledger.MetaInt64("applied_revision", 0)
	if err != nil {
		return nil, err
	}
	cursor := appliedRev
	if a.notifiedRevision > cursor {
		cursor = a.notifiedRevision
	}

	p, closePoster, err := a.poster(time.Duration(a.opts.WaitSeconds+5) * time.Second)
	if err != nil {
		return nil, err
	}
	defer closePoster()

	resp, err := p.Post(ctx, "/api/agent/wait", map[string]any{
		"protocol":         Protocol,
		"node_id":          mapString(a.config, "node_id", ""),
		"applied_revision": cursor,
		"timeout":          a.opts.WaitSeconds,
	}, true)
	if err != nil {
		var te *TransportError
		if errors.As(err, &te) && te.Status == 410 {
			if detach {
				return a.DetachFromCenter(ctx)
			}
			return map[string]any{"changed": false, "detach_requested": true}, nil
		}
		return nil, err
	}

	changed, ok := resp["changed"].(bool)
	if !ok {
		return nil, &TransportError{Msg: "Invalid center change notification"}
	}
	rev, err := requireInt64(resp["revision"], "notified revision", 0, math.MaxInt64)
	if err != nil {
		return nil, err
	}
	if changed {
		if rev <= cursor {
			resp["changed"] = false
			resp["stale_revision"] = true
			return resp, nil
		}
		a.notifiedRevision = rev
	}
	return resp, nil
}

// DetachFromCenter executes local detachment after the center already removed this binding (HTTP 410).
func (a *Agent) DetachFromCenter(ctx context.Context) (map[string]any, error) {
	unlock, err := AcquireFileLock(ctx, a.configPath+".sync.lock", 20*time.Second)
	if err != nil {
		return nil, err
	}
	defer unlock()

	if _, err := a.Reload(); err != nil {
		return nil, err
	}
	return a.detachLocal(ctx)
}

func (a *Agent) detachLocal(ctx context.Context) (map[string]any, error) {
	if mapBool(a.config, false, "detached") {
		return map[string]any{
			"status":           "detached",
			"changed":          false,
			"ledger_preserved": a.ledger.Path(),
		}, nil
	}
	a.config["remote_detached"] = true
	a.config["detaching"] = true
	if err := a.Save(); err != nil {
		return nil, err
	}

	if _, err := a.opts.HelperRunner(ctx, a.config, "agent-detach", nil, 120*time.Second); err != nil {
		a.config["detaching"] = false
		_ = a.Save()
		return nil, err
	}

	a.config["detached"] = true
	a.config["detaching"] = false
	a.config["status"] = "detached"
	a.config["detached_at"] = time.Now().Unix()
	for _, k := range []string{"node_token", "registration_payload", "registration_fingerprint", "registration_aliases"} {
		delete(a.config, k)
	}
	if err := a.Save(); err != nil {
		return nil, err
	}
	_ = a.ledger.SetMeta(map[string]any{"sync_error": "", "apply_error": ""})
	sum, _ := a.ledger.Summary()
	return map[string]any{
		"node_id":              a.config["node_id"],
		"status":               "detached",
		"changed":              false,
		"acknowledged_batches": 0,
		"applied":              false,
		"ledger_preserved":     a.ledger.Path(),
		"pending_batches":      sum.PendingBatches,
	}, nil
}

// Detach flushes final traffic, notifies the center (unless force=true on failure), and detaches locally.
func (a *Agent) Detach(ctx context.Context, force bool) (map[string]any, error) {
	unlock, err := AcquireFileLock(ctx, a.configPath+".sync.lock", 20*time.Second)
	if err != nil {
		return nil, err
	}
	defer unlock()

	if _, err := a.Reload(); err != nil {
		return nil, err
	}
	if mapBool(a.config, false, "detached") {
		return map[string]any{
			"status":           "detached",
			"ledger_preserved": a.ledger.Path(),
		}, nil
	}
	a.config["detaching"] = true
	if err := a.Save(); err != nil {
		return nil, err
	}

	rollbackDetaching := func() {
		if !mapBool(a.config, false, "remote_detached") {
			a.config["detaching"] = false
			_ = a.Save()
		}
	}

	if _, err := a.SampleOnce(ctx, true); err != nil {
		Log(a.opts.Stderr, "Final sample failed: "+err.Error(), a.config)
	}

	if !mapBool(a.config, false, "remote_detached") {
		remoteErr := func() error {
			nodeID := mapString(a.config, "node_id", "")
			if nodeID != "" {
				drained := false
				for i := 0; i < 64; i++ {
					res, err := a.syncLocked(ctx, true, false)
					if err != nil {
						return err
					}
					if mapString(res, "status", "") == "detached" {
						return errAlreadyDetached
					}
					sum, err := a.ledger.Summary()
					if err != nil {
						return err
					}
					if sum.PendingBatches == 0 && sum.UnpackagedRows == 0 {
						drained = true
						break
					}
					acked, _ := parseInt64Exact(res["acknowledged_batches"])
					if acked == 0 {
						return agentErr("Center did not acknowledge pending traffic")
					}
				}
				if !drained {
					return agentErr("Traffic backlog is too large; finish syncing before detaching")
				}

				p, closePoster, err := a.poster(12 * time.Second)
				if err != nil {
					return err
				}
				defer closePoster()

				resp, err := p.Post(ctx, "/api/agent/detach", map[string]any{
					"protocol": Protocol,
					"node_id":  nodeID,
				}, true)
				if err != nil {
					return err
				}
				if respNode := mapString(resp, "node_id", nodeID); respNode != nodeID {
					return &TransportError{Msg: "Invalid detach acknowledgement"}
				}
			} else if !force {
				return agentErr("Registration is incomplete; use --force for local detachment")
			}
			a.config["remote_detached"] = true
			return a.Save()
		}()

		if errors.Is(remoteErr, errAlreadyDetached) {
			sum, _ := a.ledger.Summary()
			return map[string]any{
				"node_id":              a.config["node_id"],
				"status":               "detached",
				"changed":              false,
				"acknowledged_batches": 0,
				"applied":              false,
				"ledger_preserved":     a.ledger.Path(),
				"pending_batches":      sum.PendingBatches,
			}, nil
		}
		if remoteErr != nil {
			var te *TransportError
			if errors.As(remoteErr, &te) && te.Status == 410 {
				return a.detachLocal(ctx)
			}
			if !force {
				rollbackDetaching()
				return nil, agentErr("Center detachment could not be confirmed. Local configuration was retained; use detach --force for an explicit local detachment. %s", Redact(remoteErr.Error(), a.config))
			}
			Log(a.opts.Stderr, "Forced local detachment; unacknowledged traffic stays in the ledger: "+remoteErr.Error(), a.config)
		}
	}

	res, err := a.detachLocal(ctx)
	if err != nil {
		rollbackDetaching()
		return nil, err
	}
	return res, nil
}

var errAlreadyDetached = errors.New("already detached")

// Status returns the complete agent + ledger status snapshot.
func (a *Agent) Status() (map[string]any, error) {
	sum, err := a.ledger.Summary()
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"version":          a.opts.Version,
		"node_id":          a.config["node_id"],
		"status":           mapString(a.config, "status", "registering"),
		"center_url":       mapString(a.config, "center_url", ""),
		"detached":         mapBool(a.config, false, "detached"),
		"service_running":  a.isRunning(),
		"ledger_epoch":     sum.LedgerEpoch,
		"applied_revision": sum.AppliedRevision,
		"last_sample_at":   sum.LastSampleAt,
		"last_sync_at":     sum.LastSyncAt,
		"collector_error":  sum.CollectorError,
		"apply_error":      sum.ApplyError,
		"sync_error":       sum.SyncError,
		"pending_batches":  sum.PendingBatches,
		"unpackaged_rows":  sum.UnpackagedRows,
		"usage":            sum.Usage,
	}, nil
}

// Run starts the daemon with 4 coordinated background goroutines and the main sync loop,
// shutting down cleanly as soon as ctx is cancelled or the node becomes detached.
func (a *Agent) Run(ctx context.Context) error {
	unlock, err := AcquireFileLock(ctx, a.ledger.LogicalPath()+".run.lock", 100*time.Millisecond)
	if err != nil {
		return err
	}
	defer unlock()

	runCtx, cancelRun := context.WithCancel(ctx)
	defer cancelRun()

	changeCh := make(chan struct{}, 1)
	signalChange := func() {
		select {
		case changeCh <- struct{}{}:
		default:
		}
	}

	var centerDetached atomic.Bool

	// Separate Agent instances per worker avoid sharing mutable config maps across goroutines.
	samplingAgent, err := New(a.configPath, a.opts)
	if err != nil {
		return err
	}
	waitingAgent, err := New(a.configPath, a.opts)
	if err != nil {
		return err
	}

	var actMu sync.Mutex
	var sharedAct *activity.Collector
	getActivity := func() (*activity.Collector, error) {
		actMu.Lock()
		defer actMu.Unlock()
		if sharedAct == nil {
			col, err := activity.NewCollector(a.configPath)
			if err != nil {
				return nil, err
			}
			sharedAct = col
		}
		return sharedAct, nil
	}

	var wg sync.WaitGroup

	// 1. Traffic sampler goroutine (every SampleInterval, default 10s).
	wg.Add(1)
	go func() {
		defer wg.Done()
		for runCtx.Err() == nil {
			started := time.Now()
			cur, rErr := ReadJSONMap(a.configPath)
			if rErr == nil {
				if mapBool(cur, false, "detached") {
					cancelRun()
					signalChange()
					return
				}
				if mapBool(cur, false, "detaching") {
					if !sleepCtx(runCtx, 250*time.Millisecond) {
						return
					}
					continue
				}
				if _, err := samplingAgent.SampleOnce(runCtx, false); err != nil {
					var lb *LockBusy
					if !errors.As(err, &lb) && runCtx.Err() == nil {
						Log(a.opts.Stderr, "Collector: "+err.Error(), cur)
					}
				}
			} else if runCtx.Err() == nil {
				Log(a.opts.Stderr, "Collector: "+rErr.Error(), nil)
			}
			wait := a.opts.SampleInterval - time.Since(started)
			if wait < 100*time.Millisecond {
				wait = 100 * time.Millisecond
			}
			if !sleepCtx(runCtx, wait) {
				return
			}
		}
	}()

	// 2. Change listener goroutine (/api/agent/wait long-poll).
	wg.Add(1)
	go func() {
		defer wg.Done()
		for runCtx.Err() == nil {
			res, err := waitingAgent.WaitChanges(runCtx, false)
			if err != nil {
				if runCtx.Err() != nil {
					return
				}
				var te *TransportError
				if errors.As(err, &te) && (te.Status == 404 || te.Status == 405) {
					Log(a.opts.Stderr, "Center has no change listener; keeping 15-second sync", waitingAgent.config)
					return
				}
				Log(a.opts.Stderr, "Change listener: "+err.Error(), waitingAgent.config)
				if !sleepCtx(runCtx, 3*time.Second) {
					return
				}
				continue
			}
			if mapBool(res, false, "detach_requested") {
				centerDetached.Store(true)
				signalChange()
				return
			}
			if mapString(res, "status", "") == "detached" {
				cancelRun()
				signalChange()
				return
			}
			if mapBool(res, false, "stale_revision") {
				if !sleepCtx(runCtx, 3*time.Second) {
					return
				}
				continue
			}
			if mapBool(res, false, "changed") {
				signalChange()
			} else if mapBool(res, false, "skipped") {
				if !sleepCtx(runCtx, 500*time.Millisecond) {
					return
				}
			}
		}
	}()

	// 3. Activity log reader goroutine.
	wg.Add(1)
	go func() {
		defer wg.Done()
		idleStreak := 0
		for runCtx.Err() == nil {
			delay := time.Second
			cur, rErr := ReadJSONMap(a.configPath)
			if rErr != nil {
				if !sleepCtx(runCtx, 3*time.Second) {
					return
				}
				continue
			}
			if mapBool(cur, false, "detached") {
				return
			}
			if mapBool(cur, false, "detaching") {
				if !sleepCtx(runCtx, 250*time.Millisecond) {
					return
				}
				continue
			}
			if mapString(cur, "status", "") != "active" || mapString(cur, "node_id", "") == "" {
				if !sleepCtx(runCtx, time.Second) {
					return
				}
				continue
			}
			col, err := getActivity()
			if err != nil {
				if !sleepCtx(runCtx, 3*time.Second) {
					return
				}
				continue
			}
			hasMore, cursorChanged, err := col.CollectOnce()
			if err != nil {
				_ = col.SetError(Redact(err.Error(), cur))
				delay = 3 * time.Second
			} else if hasMore {
				idleStreak = 0
				delay = 50 * time.Millisecond
			} else if cursorChanged {
				idleStreak = 0
				delay = time.Second
			} else {
				if idleStreak < 2 {
					idleStreak++
				}
				delay = time.Duration(1+idleStreak) * time.Second
				if delay > 3*time.Second {
					delay = 3 * time.Second
				}
			}
			if !sleepCtx(runCtx, delay) {
				return
			}
		}
	}()

	// 4. Activity uploader goroutine.
	wg.Add(1)
	go func() {
		defer wg.Done()
		var lastUpload time.Time
		type statusKey struct {
			dropped int64
			gaps    int64
			err     string
		}
		var hasLastKey bool
		var lastKey statusKey

		for runCtx.Err() == nil {
			delay := a.opts.SyncInterval
			cur, rErr := ReadJSONMap(a.configPath)
			if rErr != nil {
				if !sleepCtx(runCtx, 3*time.Second) {
					return
				}
				continue
			}
			if mapBool(cur, false, "detached") {
				return
			}
			if mapBool(cur, false, "detaching") {
				if !sleepCtx(runCtx, 250*time.Millisecond) {
					return
				}
				continue
			}
			if mapString(cur, "status", "") != "active" || mapString(cur, "node_id", "") == "" {
				if !sleepCtx(runCtx, time.Second) {
					return
				}
				continue
			}
			col, err := getActivity()
			if err != nil {
				if !sleepCtx(runCtx, 3*time.Second) {
					return
				}
				continue
			}
			st, err := col.Status()
			if err != nil {
				if !sleepCtx(runCtx, 3*time.Second) {
					return
				}
				continue
			}
			sk := statusKey{dropped: st.Dropped, gaps: st.Gaps, err: st.Error}
			if st.Pending > 0 || !hasLastKey || sk != lastKey || time.Since(lastUpload) >= 45*time.Second {
				var p Poster
				var closeP func()
				if a.opts.TransportOverride != nil {
					p = a.opts.TransportOverride
					closeP = func() {}
				} else {
					tr, tErr := NewTransport(
						mapString(cur, "center_url", ""),
						mapString(cur, "node_token", ""),
						a.opts.Version,
						a.opts.AllowLoopbackHTTP,
						12*time.Second,
					)
					if tErr != nil {
						if !sleepCtx(runCtx, 3*time.Second) {
							return
						}
						continue
					}
					p = tr
					closeP = tr.Close
				}
				sent, uErr := col.UploadOnce(runCtx, p)
				closeP()
				if uErr != nil {
					if runCtx.Err() != nil {
						return
					}
					var te *TransportError
					if errors.As(uErr, &te) && te.Status == 410 {
						centerDetached.Store(true)
						signalChange()
						return
					}
					if errors.As(uErr, &te) && (te.Status == 404 || te.Status == 405) {
						delay = 60 * time.Second
					}
				} else {
					lastUpload = time.Now()
					lastKey = sk
					hasLastKey = true
					if sent == activity.UploadBatchSize {
						delay = 250 * time.Millisecond
					}
				}
			}
			if !sleepCtx(runCtx, delay) {
				return
			}
		}
	}()

	// Main sync loop with exponential backoff up to 120s.
	failures := 0
	for runCtx.Err() == nil {
		started := time.Now()
		// Drain pending change signal before running sync.
		select {
		case <-changeCh:
		default:
		}

		if _, err := a.Reload(); err != nil {
			failures = min(failures+1, 5)
			Log(a.opts.Stderr, "Sync: "+err.Error(), a.config)
		} else if mapBool(a.config, false, "detached") {
			cancelRun()
			break
		} else if mapBool(a.config, false, "detaching") {
			if !sleepCtx(runCtx, 250*time.Millisecond) {
				break
			}
			continue
		} else {
			var res map[string]any
			if centerDetached.Load() {
				res, err = a.DetachFromCenter(runCtx)
			} else {
				res, err = a.SyncOnce(runCtx, false, true)
			}
			if err != nil {
				var lb *LockBusy
				if !errors.As(err, &lb) && runCtx.Err() == nil {
					failures = min(failures+1, 5)
					Log(a.opts.Stderr, "Sync: "+err.Error(), a.config)
				}
			} else {
				if mapString(res, "status", "") == "detached" {
					cancelRun()
					break
				}
				if mapBool(res, false, "applied") {
					signalChange()
				}
				failures = 0
			}
		}

		backoff := a.opts.SyncInterval
		if failures > 1 {
			backoff = a.opts.SyncInterval * time.Duration(1<<(failures-1))
		}
		if backoff > 120*time.Second {
			backoff = 120 * time.Second
		}
		wait := backoff - time.Since(started)
		if wait < 100*time.Millisecond {
			wait = 100 * time.Millisecond
		}

		timer := time.NewTimer(wait)
		select {
		case <-runCtx.Done():
			timer.Stop()
		case <-changeCh:
			timer.Stop()
		case <-timer.C:
		}
	}

	cancelRun()
	wg.Wait()
	return nil
}

// Join enrolls the node with the center server, persisting durable identity before the first request.
func Join(ctx context.Context, configPath, rawURL, code, name, script string, opts Options) (map[string]any, error) {
	opts = opts.withDefaults()
	origin, err := ValidateOrigin(rawURL, opts.AllowLoopbackHTTP)
	if err != nil {
		return nil, err
	}

	unlock, err := AcquireFileLock(ctx, configPath+".sync.lock", 5*time.Second)
	if err != nil {
		return nil, err
	}
	defer unlock()

	var previous map[string]any
	if fi, err := os.Stat(configPath); err == nil && fi.Mode().IsRegular() {
		previous, err = ReadJSONMap(configPath)
		if err != nil {
			return nil, err
		}
	}

	if previous != nil && !mapBool(previous, false, "detached") {
		if mapString(previous, "center_url", "") != origin {
			return nil, agentErr("Already enrolled with another center; detach before joining another")
		}
		ag, err := New(configPath, opts)
		if err != nil {
			return nil, err
		}
		if nid := mapString(ag.config, "node_id", ""); nid != "" {
			return map[string]any{
				"node_id": nid,
				"status":  mapString(ag.config, "status", "pending"),
			}, nil
		}
		pending, ok := ag.config["registration_payload"].(map[string]any)
		if !ok {
			return nil, agentErr("An unfinished registration has no saved request; inspect agent state")
		}
		if mapString(pending, "join_code", "") != code {
			pending["join_code"] = code
			if err := ag.Save(); err != nil {
				return nil, err
			}
		}
		return ag.Register(ctx)
	}

	var regBytes [16]byte
	if _, err := rand.Read(regBytes[:]); err != nil {
		return nil, err
	}
	registrationID := hex.EncodeToString(regBytes[:])

	var tokBytes [32]byte
	if _, err := rand.Read(tokBytes[:]); err != nil {
		return nil, err
	}
	nodeToken := base64.RawURLEncoding.EncodeToString(tokBytes[:])

	dbPath := DefaultDBPath()
	var history []any
	if previous != nil {
		if prevHist, ok := previous["previous_ledgers"].([]any); ok {
			history = append(history, prevHist...)
		}
		prevDB := mapString(previous, "db_path", DefaultDBPath())
		history = append(history, map[string]any{
			"db_path":    prevDB,
			"node_id":    previous["node_id"],
			"center_url": previous["center_url"],
		})
		dbPath = filepath.Join(filepath.Dir(prevDB), "agent-"+registrationID+".db")
	} else {
		history = make([]any, 0)
	}

	scriptPath := script
	if scriptPath == "" {
		scriptPath = DefaultScriptPath()
	}
	absScript, err := filepath.Abs(scriptPath)
	if err != nil {
		return nil, err
	}

	cfg := map[string]any{
		"protocol":         Protocol,
		"agent_version":    opts.Version,
		"node_id":          nil,
		"node_token":       nodeToken,
		"center_url":       origin,
		"script_path":      absScript,
		"db_path":          dbPath,
		"state_path":       DefaultStatePath(),
		"registration_id":  registrationID,
		"status":           "registering",
		"detached":         false,
		"created_at":       time.Now().Unix(),
		"previous_ledgers": history,
	}

	rawInv, err := opts.HelperRunner(ctx, cfg, "agent-inventory", nil, 20*time.Second)
	if err != nil {
		return nil, err
	}
	var invParsed any
	dec := json.NewDecoder(strings.NewReader(string(rawInv)))
	dec.UseNumber()
	if err := dec.Decode(&invParsed); err != nil {
		return nil, agentErr("Inventory helper did not return JSON")
	}
	inventory, ok := invParsed.(map[string]any)
	if !ok {
		return nil, agentErr("Invalid inventory helper response")
	}

	users, err := ValidatedUsers(inventory["users"], false)
	if err != nil {
		return nil, err
	}
	rawInbounds, _ := inventory["inbounds"].([]any)
	inbounds := make([]map[string]any, 0, len(rawInbounds))
	for _, rawInb := range rawInbounds {
		inb, ok := rawInb.(map[string]any)
		if !ok {
			return nil, agentErr("Invalid inbound inventory")
		}
		port, err := requireInt64(inb["port"], "inbound port", 1, 65535)
		if err != nil {
			return nil, err
		}
		clean := map[string]any{
			"port":             port,
			"skip_cert_verify": mapBool(inb, false, "skip_cert_verify"),
		}
		for _, spec := range []struct {
			key    string
			maxLen int
		}{
			{"name", 160},
			{"tag", 160},
			{"type", 64},
			{"server", 253},
			{"sni", 253},
			{"public_key", 253},
			{"short_id", 253},
		} {
			clean[spec.key] = inboundFieldString(inb[spec.key], spec.maxLen)
		}
		if strings.HasPrefix(mapString(clean, "type", ""), "tuic") {
			clean["public_key"] = ""
			clean["short_id"] = ""
		}
		inbounds = append(inbounds, clean)
	}

	fp, err := Fingerprint(users)
	if err != nil {
		return nil, err
	}
	hostname := name
	if hostname == "" {
		if h, hErr := os.Hostname(); hErr == nil && h != "" {
			hostname = h
		} else {
			hostname = "unknown"
		}
	}
	if runes := []rune(hostname); len(runes) > 253 {
		hostname = string(runes[:253])
	}

	cfg["registration_fingerprint"] = fp
	cfg["registration_payload"] = map[string]any{
		"protocol":        Protocol,
		"join_code":       code,
		"registration_id": registrationID,
		"node_token":      nodeToken,
		"agent_version":   opts.Version,
		"hostname":        hostname,
		"users":           users,
		"inbounds":        inbounds,
	}

	if _, err := store.OpenLedger(dbPath); err != nil {
		return nil, err
	}
	if err := AtomicJSON(configPath, cfg); err != nil {
		return nil, err
	}

	ag, err := New(configPath, opts)
	if err != nil {
		return nil, err
	}
	return ag.Register(ctx)
}

func sleepCtx(ctx context.Context, d time.Duration) bool {
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

func stringMap(v any) map[string]string {
	out := make(map[string]string)
	switch m := v.(type) {
	case map[string]string:
		for k, val := range m {
			out[k] = val
		}
	case map[string]any:
		for k, val := range m {
			if s, ok := val.(string); ok {
				out[k] = s
			}
		}
	}
	return out
}
