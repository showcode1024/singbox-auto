package activity

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/showcode1024/singbox-auto/singbox-plus/internal/store"
)

const (
	// ProtocolVersion is the center API protocol version.
	ProtocolVersion = 1
	// ReadBytes is the per-pass read window (256 KiB).
	ReadBytes = 256 * 1024
	// MaxLineLen caps a single parsed log line (64 KiB).
	MaxLineLen = 65536
	// UploadBatchSize is the max events uploaded per request.
	UploadBatchSize = 400
)

var (
	lineRe    = regexp.MustCompile(`\b(INFO|WARN|ERROR|FATAL)\s+(?:\[(\d+)\s+[^\]]*\]\s+)?(.*)`)
	inboundRe = regexp.MustCompile(`inbound/([^\s:]+)\[([^\]]+)\]:\s*(.*)`)
	sourceRe  = regexp.MustCompile(`inbound (?:packet )?connection from (\S+)`)
	targetRe  = regexp.MustCompile(`\[([^\]]+)\]\s+inbound (packet )?connection to (\S+)`)
	ansiRe    = regexp.MustCompile(`\x1b\[[0-9;]*m`)
	tsRe      = regexp.MustCompile(`([+-]\d{4})\s+(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)`)
	userIDRe  = regexp.MustCompile(`^u_[0-9a-f]{32}$`)
)

// Poster sends authenticated JSON POST requests to the center server.
type Poster interface {
	Post(ctx context.Context, path string, body any, authenticated bool) (map[string]any, error)
}

type agentConfigSubset struct {
	NodeID                 string            `json:"node_id"`
	CenterURL              string            `json:"center_url"`
	DBPath                 string            `json:"db_path"`
	StatePath              string            `json:"state_path"`
	Status                 string            `json:"status"`
	Detached               bool              `json:"detached"`
	Detaching              bool              `json:"detaching"`
	ActivityLogPath        string            `json:"activity_log_path"`
	ActivityCoreConfigPath string            `json:"activity_core_config_path"`
	RegistrationAliases    map[string]string `json:"registration_aliases"`
}

type coreLogConfig struct {
	Disabled  bool   `json:"disabled"`
	Level     string `json:"level"`
	Output    string `json:"output"`
	Timestamp *bool  `json:"timestamp"`
}

type stateSubset struct {
	Management struct {
		NodeID string `json:"node_id"`
	} `json:"management"`
	Users []struct {
		ID       string `json:"id"`
		Name     string `json:"name"`
		StatsKey string `json:"stats_key"`
	} `json:"users"`
}

type statCacheKey struct {
	Ino     uint64
	MtimeNS int64
	Size    int64
	Present bool
}

type idleStat struct {
	Dev     uint64
	Ino     uint64
	Size    int64
	MtimeNS int64
	Valid   bool
}

type segment struct {
	path      string
	stat      fileStat
	isCurrent bool
}

// Collector reads immutable rotated log segments and the active sing-box.log
// into a durable scoped ActivityStore and uploads batches to the center server.
type Collector struct {
	configPath string
	store      *store.ActivityStore
	nowFn      func() time.Time

	mu            sync.Mutex
	collectedAt   int64
	cursor        store.ActivityCursor
	cursorLoaded  bool
	lastIdle      idleStat
	lastExpiryAt  time.Time
	hasExpiryRun  bool
	hasError      bool
	cfgCacheKey   statCacheKey
	cfgCacheVal   agentConfigSubset
	coreCachePath string
	coreCacheKey  statCacheKey
	coreCacheVal  coreLogConfig
	aliasCacheKey string
	aliasCacheVal map[string]string
}

func systemPath(p string) string {
	root := os.Getenv("YSQ_TEST_ROOT")
	if root == "" {
		return p
	}
	return filepath.Join(root, strings.TrimLeft(p, "/"))
}

// NewCollector creates a Collector bound to the agent configuration at configPath.
func NewCollector(configPath string) (*Collector, error) {
	c := &Collector{
		configPath: configPath,
		nowFn:      time.Now,
	}
	cfg, err := c.readConfig()
	if err != nil {
		return nil, err
	}
	nodeID := cfg.NodeID
	if nodeID == "" {
		nodeID = "pending"
	}
	scope := nodeID + "@" + cfg.CenterURL
	resolvedLedger, err := store.ResolveBoltPath(cfg.DBPath)
	if err != nil {
		return nil, err
	}
	actPath := store.ActivityBoltPath(resolvedLedger, scope)
	actStore, err := store.OpenActivityStore(actPath)
	if err != nil {
		return nil, err
	}
	c.store = actStore
	return c, nil
}

// Store exposes the underlying ActivityStore (useful for tests/inspection).
func (c *Collector) Store() *store.ActivityStore { return c.store }

// SetNow overrides the clock function (for deterministic tests).
func (c *Collector) SetNow(fn func() time.Time) {
	if fn != nil {
		c.nowFn = fn
	}
}

func fileCacheKey(path string) statCacheKey {
	st, err := statPath(path)
	if err != nil {
		return statCacheKey{}
	}
	return statCacheKey{Ino: st.Ino, MtimeNS: st.MtimeNS, Size: st.Size, Present: true}
}

func readLimitedJSON(path string, target any) (statCacheKey, error) {
	f, err := os.Open(path)
	if err != nil {
		return statCacheKey{}, err
	}
	defer f.Close()

	st, err := statFile(f)
	if err != nil {
		return statCacheKey{}, err
	}
	limit := int64(store.MaxBody * 4)
	data, err := io.ReadAll(io.LimitReader(f, limit+1))
	if err != nil {
		return statCacheKey{}, err
	}
	if int64(len(data)) > limit {
		return statCacheKey{}, errors.New("local JSON file is too large")
	}
	if err := json.Unmarshal(data, target); err != nil {
		return statCacheKey{}, err
	}
	return statCacheKey{Ino: st.Ino, MtimeNS: st.MtimeNS, Size: st.Size, Present: true}, nil
}

func (c *Collector) readConfig() (agentConfigSubset, error) {
	key := fileCacheKey(c.configPath)
	c.mu.Lock()
	if key.Present && c.cfgCacheKey.Present && c.cfgCacheKey == key {
		val := c.cfgCacheVal
		c.mu.Unlock()
		return val, nil
	}
	c.mu.Unlock()

	var cfg agentConfigSubset
	actualKey, err := readLimitedJSON(c.configPath, &cfg)
	if err != nil {
		return agentConfigSubset{}, err
	}
	c.mu.Lock()
	c.cfgCacheKey = actualKey
	c.cfgCacheVal = cfg
	c.mu.Unlock()
	return cfg, nil
}

func (c *Collector) checkCoreLogConfig(corePath, logPath string) error {
	st, err := statPath(corePath)
	if err != nil || !st.IsReg {
		c.mu.Lock()
		c.coreCacheKey = statCacheKey{}
		c.mu.Unlock()
		return nil
	}
	key := statCacheKey{Ino: st.Ino, MtimeNS: st.MtimeNS, Size: st.Size, Present: true}

	c.mu.Lock()
	var logCfg coreLogConfig
	hit := c.coreCacheKey.Present && c.coreCachePath == corePath && c.coreCacheKey == key
	if hit {
		logCfg = c.coreCacheVal
	}
	c.mu.Unlock()

	if !hit {
		var wrapper struct {
			Log coreLogConfig `json:"log"`
		}
		actualKey, err := readLimitedJSON(corePath, &wrapper)
		if err != nil {
			return err
		}
		logCfg = wrapper.Log
		c.mu.Lock()
		c.coreCachePath = corePath
		c.coreCacheKey = actualKey
		c.coreCacheVal = logCfg
		c.mu.Unlock()
	}

	level := logCfg.Level
	if level == "" {
		level = "info"
	}
	levelOK := level == "info" || level == "debug" || level == "trace"
	outputOK := logCfg.Output == "" || logCfg.Output == logPath
	tsOK := logCfg.Timestamp != nil && *logCfg.Timestamp
	if logCfg.Disabled || !levelOK || !outputOK || !tsOK {
		return errors.New("行为日志未启用：请升级 VPS 脚本，使用 info 日志并开启 timestamp")
	}
	return nil
}

func (c *Collector) aliases(cfg agentConfigSubset) (map[string]string, error) {
	statePath := cfg.StatePath
	if statePath == "" {
		statePath = systemPath("/etc/sing-box/ysq-state.db")
	}
	boltPath, err := store.ResolveBoltPath(cfg.DBPath)
	if err != nil {
		return nil, err
	}
	cacheKey := fmt.Sprintf("%s|%v|%s|%v|%s|%v",
		c.configPath, fileCacheKey(c.configPath),
		statePath, fileCacheKey(statePath),
		boltPath, fileCacheKey(boltPath))

	c.mu.Lock()
	if c.aliasCacheKey == cacheKey && c.aliasCacheVal != nil {
		res := c.aliasCacheVal
		c.mu.Unlock()
		return res, nil
	}
	c.mu.Unlock()

	out := make(map[string]string)
	ledger, err := store.OpenLedger(cfg.DBPath)
	if err == nil {
		if list, aErr := ledger.Aliases(); aErr == nil {
			for _, a := range list {
				out[a.StatsKey] = a.UserID
			}
		}
	}

	for name, uid := range cfg.RegistrationAliases {
		if userIDRe.MatchString(uid) {
			out[name] = uid
		}
	}

	var state stateSubset
	if _, err := readLimitedJSON(statePath, &state); err == nil {
		managedHere := state.Management.NodeID != "" && state.Management.NodeID == cfg.NodeID
		for _, u := range state.Users {
			var uid string
			if managedHere {
				uid = u.ID
			} else {
				uid = cfg.RegistrationAliases[u.Name]
			}
			if userIDRe.MatchString(uid) {
				out[uid] = uid
				key := u.StatsKey
				if key == "" {
					key = u.Name
				}
				if key != "" {
					out[key] = uid
				}
			}
		}
	}

	c.mu.Lock()
	c.aliasCacheKey = cacheKey
	c.aliasCacheVal = out
	c.mu.Unlock()
	return out, nil
}

func parseEndpoint(val string) (string, int) {
	idx := strings.LastIndexByte(val, ':')
	if idx < 0 {
		return truncateRunes(val, 512), 0
	}
	hostPart := val[:idx]
	portPart := val[idx+1:]
	port, err := strconv.Atoi(portPart)
	if err != nil || port < 0 || port > 65535 {
		return truncateRunes(val, 512), 0
	}
	hostPart = strings.Trim(hostPart, "[]")
	return truncateRunes(hostPart, 512), port
}

func parseLogTimestamp(line string, fallback int64) int64 {
	m := tsRe.FindStringSubmatch(line)
	if m == nil {
		return fallback
	}
	t, err := time.Parse("2006-01-02 15:04:05-0700", m[2]+m[1])
	if err != nil {
		return fallback
	}
	return t.Unix()
}

func newSessionHex() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

func listSegments(logPath string) []segment {
	dir := filepath.Dir(logPath)
	if dir == "" {
		dir = "."
	}
	base := filepath.Base(logPath)
	ext := filepath.Ext(base)
	stem := strings.TrimSuffix(base, ext)
	pat := regexp.MustCompile(`^` + regexp.QuoteMeta(stem) + `\.\d{8}-\d{6}-\d+` + regexp.QuoteMeta(ext) + `$`)

	entries, err := os.ReadDir(dir)
	var names []string
	if err == nil {
		for _, e := range entries {
			names = append(names, e.Name())
		}
		sort.Strings(names)
	}

	var segs []segment
	for _, name := range names {
		if name == base || !pat.MatchString(name) {
			continue
		}
		full := filepath.Join(dir, name)
		st, err := statPath(full)
		if err != nil || !st.IsReg {
			continue
		}
		segs = append(segs, segment{path: full, stat: st, isCurrent: false})
	}
	if curSt, err := statPath(logPath); err == nil && curSt.IsReg {
		segs = append(segs, segment{path: logPath, stat: curSt, isCurrent: true})
	}
	return segs
}

func (c *Collector) parseLine(tx *store.ActivityTx, raw []byte, session string, aliases map[string]string, fallback int64, logicalOffset string) error {
	line := strings.TrimSpace(ansiRe.ReplaceAllString(string(raw), ""))
	m := lineRe.FindStringSubmatch(line)
	if m == nil {
		return nil
	}
	level, cid, message := m[1], m[2], m[3]
	nowTS := c.nowFn().Unix()
	ts := parseLogTimestamp(line, fallback)
	if ts < 1577836800 || ts > nowTS+300 {
		return nil
	}

	var contextID string
	var ctx store.ConnContext
	if cid != "" {
		contextID = session + ":" + cid
		if found, ok, err := tx.GetContext(contextID); err == nil && ok {
			ctx = found
		}
	}

	inbound := inboundRe.FindStringSubmatch(message)
	if inbound != nil {
		ctx.Inbound = truncateRunes(inbound[2], 100)
	}
	source := sourceRe.FindStringSubmatch(message)
	if source != nil {
		// Reused connection ID starts a brand new authentication context.
		srcHost, _ := parseEndpoint(source[1])
		ctx = store.ConnContext{
			SourceIP: truncateRunes(srcHost, 64),
		}
		if inbound != nil {
			ctx.Inbound = truncateRunes(inbound[2], 100)
		}
	}

	target := targetRe.FindStringSubmatch(message)
	var ev *store.ActivityEvent
	if target != nil && inbound != nil {
		if uid, ok := aliases[target[1]]; ok && uid != "" {
			u := uid
			ctx.UserID = &u
		} else {
			ctx.UserID = nil
		}
		tHost, tPort := parseEndpoint(target[3])
		ctx.Target = tHost
		ctx.Port = tPort
		if target[2] != "" {
			ctx.Network = "udp"
		} else {
			ctx.Network = "tcp"
		}
		ev = &store.ActivityEvent{
			Kind:     "connection",
			UserID:   ctx.UserID,
			SourceIP: ctx.SourceIP,
			Target:   ctx.Target,
			Port:     ctx.Port,
			Network:  ctx.Network,
			Inbound:  ctx.Inbound,
		}
	} else if level == "ERROR" || level == "FATAL" {
		// Only a previously authenticated context can attribute an error.
		ev = &store.ActivityEvent{
			Kind:     "error",
			UserID:   ctx.UserID,
			SourceIP: ctx.SourceIP,
			Target:   ctx.Target,
			Port:     ctx.Port,
			Network:  ctx.Network,
			Inbound:  ctx.Inbound,
			Message:  truncateRunes(strings.Join(strings.Fields(message), " "), 500),
		}
	}

	if contextID != "" && !isEmptyContext(ctx) {
		if err := tx.SetContext(contextID, ts, ctx); err != nil {
			return err
		}
	}

	if ev != nil {
		eventKey := session + ":" + logicalOffset + ":" + line
		sum := sha256.Sum256([]byte(eventKey))
		ev.ID = hex.EncodeToString(sum[:])
		ev.TS = ts
		if _, err := tx.Enqueue(*ev); err != nil {
			return err
		}
	}
	return nil
}

func isEmptyContext(ctx store.ConnContext) bool {
	return ctx.Inbound == "" && ctx.SourceIP == "" && ctx.UserID == nil &&
		ctx.Target == "" && ctx.Port == 0 && ctx.Network == ""
}

// CollectOnce reads up to ReadBytes from the next log segment, updates durable state atomically,
// and returns (hasMore, cursorChanged, err).
func (c *Collector) CollectOnce() (bool, bool, error) {
	cfg, err := c.readConfig()
	if err != nil {
		return false, false, err
	}
	if cfg.Detached || cfg.Detaching || cfg.Status != "active" {
		return false, false, nil
	}

	logPath := cfg.ActivityLogPath
	if logPath == "" {
		logPath = systemPath("/var/log/sing-box/sing-box.log")
	}
	corePath := cfg.ActivityCoreConfigPath
	if corePath == "" {
		corePath = systemPath("/etc/sing-box/config.json")
	}
	ts := c.nowFn().Unix()

	if err := c.checkCoreLogConfig(corePath, logPath); err != nil {
		return false, false, err
	}

	c.mu.Lock()
	cachedCursor := c.cursor
	cursorLoaded := c.cursorLoaded
	lastIdle := c.lastIdle
	hasError := c.hasError
	c.mu.Unlock()

	preStat, preErr := statPath(logPath)
	if preErr != nil {
		c.mu.Lock()
		c.lastIdle = idleStat{}
		c.mu.Unlock()
	} else if cursorLoaded && cachedCursor.Set &&
		cachedCursor.Dev == preStat.Dev && cachedCursor.Ino == preStat.Ino &&
		cachedCursor.Offset == preStat.Size &&
		lastIdle.Valid && lastIdle.Dev == preStat.Dev && lastIdle.Ino == preStat.Ino &&
		lastIdle.Size == preStat.Size && lastIdle.MtimeNS == preStat.MtimeNS &&
		!hasError {
		c.mu.Lock()
		if ts > c.collectedAt {
			c.collectedAt = ts
		}
		c.mu.Unlock()
		return false, false, nil
	}

	cursor := cachedCursor
	if !cursorLoaded {
		snap, err := c.store.LoadMeta()
		if err != nil {
			return false, false, err
		}
		cursor = snap.Cursor
		hasError = snap.Error != ""
		c.mu.Lock()
		c.cursor = cursor
		c.cursorLoaded = true
		c.hasError = hasError
		if snap.CollectedAt > c.collectedAt {
			c.collectedAt = snap.CollectedAt
		}
		c.mu.Unlock()
	}
	beforeCursor := cursor

	segments := listSegments(logPath)
	if len(segments) == 0 {
		c.mu.Lock()
		c.lastIdle = idleStat{}
		c.mu.Unlock()
		return false, false, &os.PathError{Op: "stat", Path: logPath, Err: os.ErrNotExist}
	}

	targetIdx := -1
	if cursor.Set {
		for idx, seg := range segments {
			if seg.stat.Dev == cursor.Dev && seg.stat.Ino == cursor.Ino {
				targetIdx = idx
				break
			}
		}
	}

	var gapReason string
	var readOffset int64
	var session string
	var seg segment

	if targetIdx >= 0 {
		seg = segments[targetIdx]
		if seg.stat.Size < cursor.Offset {
			readOffset = 0
			session = newSessionHex()
			gapReason = "原始日志被截断，已重新续读"
		} else {
			readOffset = cursor.Offset
			session = cursor.Session
			if session == "" {
				session = newSessionHex()
			}
		}
	} else {
		targetIdx = 0
		seg = segments[0]
		readOffset = 0
		session = newSessionHex()
		if cursor.Set {
			gapReason = "历史日志分片已轮转清理，已从最早可用分片续读"
		}
	}

	f, err := os.Open(seg.path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			c.mu.Lock()
			c.lastIdle = idleStat{}
			c.mu.Unlock()
			return true, false, nil
		}
		return false, false, err
	}
	fdStat, err := statFile(f)
	if err != nil {
		_ = f.Close()
		return false, false, err
	}
	if fdStat.Dev != seg.stat.Dev || fdStat.Ino != seg.stat.Ino {
		_ = f.Close()
		c.mu.Lock()
		c.lastIdle = idleStat{}
		c.mu.Unlock()
		return true, false, nil
	}
	if fdStat.Size < readOffset {
		readOffset = 0
		session = newSessionHex()
		gapReason = "原始日志被截断，已重新续读"
	}
	if _, err := f.Seek(readOffset, io.SeekStart); err != nil {
		_ = f.Close()
		return false, false, err
	}
	block := make([]byte, ReadBytes)
	nRead, readErr := io.ReadFull(f, block)
	_ = f.Close()
	if readErr != nil && !errors.Is(readErr, io.EOF) && !errors.Is(readErr, io.ErrUnexpectedEOF) {
		return false, false, readErr
	}
	block = block[:nRead]

	complete := bytes.LastIndexByte(block, '\n') + 1
	oversizedPartial := false
	if complete == 0 && len(block) >= MaxLineLen {
		complete = len(block)
		oversizedPartial = true
	} else if !seg.isCurrent && readOffset+int64(len(block)) >= fdStat.Size && complete < len(block) {
		complete = len(block)
		if complete > MaxLineLen && bytes.IndexByte(block, '\n') < 0 {
			oversizedPartial = true
		}
	}

	newOffset := readOffset + int64(complete)
	atEOF := newOffset >= fdStat.Size
	var nextSeg *segment
	if !seg.isCurrent && atEOF && targetIdx+1 < len(segments) {
		s := segments[targetIdx+1]
		nextSeg = &s
	}

	if nextSeg == nil && cursor.Set && cursor.Dev == fdStat.Dev && cursor.Ino == fdStat.Ino &&
		gapReason == "" && complete == 0 && !hasError {
		c.mu.Lock()
		if ts > c.collectedAt {
			c.collectedAt = ts
		}
		if seg.isCurrent && newOffset == fdStat.Size {
			c.lastIdle = idleStat{
				Dev:     fdStat.Dev,
				Ino:     fdStat.Ino,
				Size:    fdStat.Size,
				MtimeNS: fdStat.MtimeNS,
				Valid:   true,
			}
		} else {
			c.lastIdle = idleStat{}
		}
		c.mu.Unlock()
		return false, false, nil
	}

	aliasMap, err := c.aliases(cfg)
	if err != nil {
		return false, false, err
	}

	var newCursor store.ActivityCursor
	if nextSeg != nil {
		newCursor = store.ActivityCursor{
			Dev:     nextSeg.stat.Dev,
			Ino:     nextSeg.stat.Ino,
			Offset:  0,
			Session: session,
			Set:     true,
		}
	} else {
		newCursor = store.ActivityCursor{
			Dev:     fdStat.Dev,
			Ino:     fdStat.Ino,
			Offset:  newOffset,
			Session: session,
			Set:     true,
		}
	}

	nowMono := time.Now()
	c.mu.Lock()
	runExpiry := !c.hasExpiryRun || nowMono.Sub(c.lastExpiryAt) >= 60*time.Second
	c.mu.Unlock()

	err = c.store.Update(func(tx *store.ActivityTx) error {
		if gapReason != "" {
			if err := tx.RecordGap(gapReason, ts); err != nil {
				return err
			}
		}
		if oversizedPartial {
			if err := tx.RecordGap("跳过超长或损坏的日志行", ts); err != nil {
				return err
			}
		} else if complete > 0 {
			pos := readOffset
			slice := block[:complete]
			for len(slice) > 0 {
				var lineWithNL []byte
				if nl := bytes.IndexByte(slice, '\n'); nl >= 0 {
					lineWithNL = slice[:nl+1]
					slice = slice[nl+1:]
				} else {
					lineWithNL = slice
					slice = nil
				}
				rawLine := bytes.TrimRight(lineWithNL, "\r\n")
				lineOffset := fmt.Sprintf("%d:%d:%d", fdStat.Dev, fdStat.Ino, pos)
				pos += int64(len(lineWithNL))
				if len(rawLine) <= MaxLineLen {
					if err := c.parseLine(tx, rawLine, session, aliasMap, ts, lineOffset); err != nil {
						return err
					}
				} else {
					if err := tx.RecordGap("跳过超长或损坏的日志行", ts); err != nil {
						return err
					}
				}
			}
		}
		if err := tx.SetCursor(newCursor); err != nil {
			return err
		}
		if err := tx.SetCollectedAt(ts); err != nil {
			return err
		}
		if err := tx.SetError(""); err != nil {
			return err
		}
		if runExpiry {
			if err := tx.CleanupExpired(ts); err != nil {
				return err
			}
		}
		if tx.Enqueued() {
			if err := tx.EnforceCapacity(ts); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return false, false, err
	}

	c.mu.Lock()
	c.cursor = newCursor
	c.cursorLoaded = true
	if ts > c.collectedAt {
		c.collectedAt = ts
	}
	c.hasError = false
	if runExpiry {
		c.lastExpiryAt = nowMono
		c.hasExpiryRun = true
	}
	if nextSeg == nil && seg.isCurrent && atEOF {
		c.lastIdle = idleStat{
			Dev:     fdStat.Dev,
			Ino:     fdStat.Ino,
			Size:    fdStat.Size,
			MtimeNS: fdStat.MtimeNS,
			Valid:   true,
		}
	} else {
		c.lastIdle = idleStat{}
	}
	c.mu.Unlock()

	hasMore := nextSeg != nil || (!atEOF && complete > 0)
	return hasMore, beforeCursor != newCursor, nil
}

// SetError records a collector error in the activity store and clears idle fast-path cache.
func (c *Collector) SetError(msg string) error {
	err := c.store.SetError(msg)
	c.mu.Lock()
	c.hasError = true
	c.lastIdle = idleStat{}
	c.mu.Unlock()
	return err
}

// Status returns the current activity queue status merged with in-memory collected_at.
func (c *Collector) Status() (store.ActivityStatus, error) {
	c.mu.Lock()
	memCollected := c.collectedAt
	c.mu.Unlock()

	st, err := c.store.Status()
	if err != nil {
		return store.ActivityStatus{}, err
	}
	if memCollected > st.CollectedAt {
		st.CollectedAt = memCollected
	}
	return st, nil
}

// UploadOnce uploads up to 400 oldest pending events to /api/agent/activity and deletes strictly validated acks.
func (c *Collector) UploadOnce(ctx context.Context, poster Poster) (int, error) {
	cfg, err := c.readConfig()
	if err != nil {
		return 0, err
	}
	if cfg.Detached || cfg.Detaching || cfg.Status != "active" {
		return 0, nil
	}
	events, ids, err := c.store.PeekBatch(UploadBatchSize)
	if err != nil {
		return 0, err
	}
	st, err := c.Status()
	if err != nil {
		return 0, err
	}
	payload := map[string]any{
		"protocol": ProtocolVersion,
		"node_id":  cfg.NodeID,
		"events":   events,
		"status":   st,
	}
	resp, err := poster.Post(ctx, "/api/agent/activity", payload, true)
	if err != nil {
		return 0, err
	}
	rawAck, ok := resp["ack"].([]any)
	if !ok {
		return 0, errors.New("invalid activity acknowledgement")
	}
	sentSet := make(map[string]struct{}, len(ids))
	for _, id := range ids {
		sentSet[id] = struct{}{}
	}
	acked := make([]string, 0, len(rawAck))
	for _, item := range rawAck {
		eid, isStr := item.(string)
		if !isStr {
			return 0, errors.New("invalid activity acknowledgement")
		}
		if _, wasSent := sentSet[eid]; !wasSent {
			return 0, errors.New("invalid activity acknowledgement")
		}
		acked = append(acked, eid)
	}
	if len(acked) > 0 {
		if err := c.store.Ack(acked); err != nil {
			return 0, err
		}
	}
	return len(acked), nil
}

func truncateRunes(s string, limit int) string {
	runes := []rune(s)
	if len(runes) <= limit {
		return s
	}
	return string(runes[:limit])
}
