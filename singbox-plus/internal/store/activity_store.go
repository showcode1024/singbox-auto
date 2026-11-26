package store

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"regexp"
	"sort"
	"strings"

	bolt "go.etcd.io/bbolt"
)

const (
	// MaxActivityPending caps the durable activity event queue count.
	MaxActivityPending = 20000
	// MaxActivityQueueBytes caps the durable activity event payload bytes (16 MiB).
	MaxActivityQueueBytes int64 = 16 * 1024 * 1024
	// MaxActivitySeen caps the deduplication cache size.
	MaxActivitySeen = 40000
	// MaxActivityContexts caps tracked connection authentication contexts.
	MaxActivityContexts = 4000
	// ActivityContextTTLSeconds is the connection context retention window (15 minutes).
	ActivityContextTTLSeconds int64 = 900
	// ActivityRetentionSeconds is the local offline queue expiry (7 days).
	ActivityRetentionSeconds int64 = 7 * 86400
)

var (
	bucketActMeta        = []byte("meta")
	bucketActPending     = []byte("pending")
	bucketActPendingByID = []byte("pending_by_id")
	bucketActSeen        = []byte("seen")
	bucketActSeenOrder   = []byte("seen_order")
	bucketActContexts    = []byte("contexts")
	ctrlCharRe           = regexp.MustCompile(`[\x00-\x1f\x7f]`)
)

// ActivityCursor tracks the collector's current log segment identity and byte offset.
type ActivityCursor struct {
	Dev     uint64 `json:"dev"`
	Ino     uint64 `json:"ino"`
	Offset  int64  `json:"offset"`
	Session string `json:"session"`
	Set     bool   `json:"set,omitempty"`
}

// ConnContext tracks authentication state for a sing-box connection ID.
type ConnContext struct {
	Inbound  string  `json:"inbound,omitempty"`
	SourceIP string  `json:"source_ip,omitempty"`
	UserID   *string `json:"user_id,omitempty"`
	Target   string  `json:"target,omitempty"`
	Port     int     `json:"port,omitempty"`
	Network  string  `json:"network,omitempty"`
}

type storedContext struct {
	TS    int64       `json:"ts"`
	Value ConnContext `json:"value"`
}

// ActivityEvent is the JSON event uploaded to /api/agent/activity.
type ActivityEvent struct {
	ID       string  `json:"id"`
	TS       int64   `json:"ts"`
	Kind     string  `json:"kind"`
	UserID   *string `json:"user_id"`
	SourceIP string  `json:"source_ip,omitempty"`
	Target   string  `json:"target,omitempty"`
	Port     int     `json:"port,omitempty"`
	Network  string  `json:"network,omitempty"`
	Inbound  string  `json:"inbound,omitempty"`
	Message  string  `json:"message,omitempty"`
}

// ActivityStatus matches the status object reported to /api/agent/activity.
type ActivityStatus struct {
	Pending     int    `json:"pending"`
	CollectedAt int64  `json:"collected_at"`
	Dropped     int64  `json:"dropped"`
	Gaps        int64  `json:"gaps"`
	Error       string `json:"error"`
}

// ActivityMetaSnapshot is loaded once on collector startup to seed in-memory caches.
type ActivityMetaSnapshot struct {
	Cursor      ActivityCursor
	HasCursor   bool
	CollectedAt int64
	Error       string
}

// ActivityStore is a bounded durable bbolt queue for parsed activity events.
type ActivityStore struct {
	path          string
	maxPending    int
	maxQueueBytes int64
}

// OpenActivityStore initializes or opens the scoped bbolt activity queue at boltPath.
func OpenActivityStore(boltPath string) (*ActivityStore, error) {
	if _, err := EnsurePrivateDir(boltPath); err != nil {
		return nil, err
	}
	if err := RejectSymlink(boltPath); err != nil {
		return nil, err
	}

	db, err := openBolt(boltPath, false)
	if err != nil {
		return nil, err
	}
	defer db.Close()

	err = db.Update(func(tx *bolt.Tx) error {
		for _, name := range [][]byte{
			bucketActMeta,
			bucketActPending,
			bucketActPendingByID,
			bucketActSeen,
			bucketActSeenOrder,
			bucketActContexts,
		} {
			if _, err := tx.CreateBucketIfNotExists(name); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	_ = os.Chmod(boltPath, 0o600)

	return &ActivityStore{
		path:          boltPath,
		maxPending:    MaxActivityPending,
		maxQueueBytes: MaxActivityQueueBytes,
	}, nil
}

// Path returns the activity bbolt file path on disk.
func (s *ActivityStore) Path() string { return s.path }

// SetLimits overrides capacity limits (intended for unit tests).
func (s *ActivityStore) SetLimits(maxPending int, maxQueueBytes int64) {
	if maxPending > 0 {
		s.maxPending = maxPending
	}
	if maxQueueBytes > 0 {
		s.maxQueueBytes = maxQueueBytes
	}
}

func makePendingKey(ts int64, seq uint64) []byte {
	var k [16]byte
	if ts < 0 {
		ts = 0
	}
	binary.BigEndian.PutUint64(k[0:8], uint64(ts))
	binary.BigEndian.PutUint64(k[8:16], seq)
	return k[:]
}

func pendingKeyTS(k []byte) int64 {
	if len(k) < 8 {
		return 0
	}
	return int64(binary.BigEndian.Uint64(k[0:8]))
}

func encodePendingValue(id string, payload []byte) []byte {
	out := make([]byte, 2+len(id)+len(payload))
	binary.BigEndian.PutUint16(out[0:2], uint16(len(id)))
	copy(out[2:], id)
	copy(out[2+len(id):], payload)
	return out
}

func decodePendingValue(v []byte) (string, []byte, error) {
	if len(v) < 2 {
		return "", nil, errors.New("corrupt pending activity entry")
	}
	idLen := int(binary.BigEndian.Uint16(v[0:2]))
	if len(v) < 2+idLen {
		return "", nil, errors.New("corrupt pending activity entry")
	}
	return string(v[2 : 2+idLen]), v[2+idLen:], nil
}

func encodeSeqKey(seq uint64) []byte {
	var b [8]byte
	binary.BigEndian.PutUint64(b[:], seq)
	return b[:]
}

func sanitizeField(s string, limit int) string {
	cleaned := strings.TrimSpace(ctrlCharRe.ReplaceAllString(s, " "))
	runes := []rune(cleaned)
	if len(runes) > limit {
		return string(runes[:limit])
	}
	return cleaned
}

// ActivityTx wraps a single atomic read-write transaction against ActivityStore.
type ActivityTx struct {
	tx            *bolt.Tx
	maxPending    int
	maxQueueBytes int64
	enqueued      bool
}

// Update executes fn inside a single atomic bbolt Update transaction.
func (s *ActivityStore) Update(fn func(tx *ActivityTx) error) error {
	db, err := openBolt(s.path, false)
	if err != nil {
		return err
	}
	defer db.Close()

	return db.Update(func(tx *bolt.Tx) error {
		return fn(&ActivityTx{
			tx:            tx,
			maxPending:    s.maxPending,
			maxQueueBytes: s.maxQueueBytes,
		})
	})
}

func (a *ActivityTx) nextSeq() (uint64, error) {
	bMeta := a.tx.Bucket(bucketActMeta)
	cur, _ := getMetaInt64(bMeta, "next_seq", 0)
	next := uint64(cur) + 1
	if err := putMetaTx(bMeta, "next_seq", int64(next)); err != nil {
		return 0, err
	}
	return next, nil
}

func (a *ActivityTx) pendingBytes() int64 {
	v, _ := getMetaInt64(a.tx.Bucket(bucketActMeta), "pending_bytes", 0)
	if v < 0 {
		return 0
	}
	return v
}

func (a *ActivityTx) setPendingBytes(n int64) error {
	if n < 0 {
		n = 0
	}
	return putMetaTx(a.tx.Bucket(bucketActMeta), "pending_bytes", n)
}

func (a *ActivityTx) pendingCount() int {
	v, _ := getMetaInt64(a.tx.Bucket(bucketActMeta), "pending_count", 0)
	if v < 0 {
		return 0
	}
	return int(v)
}

func (a *ActivityTx) setPendingCount(n int) error {
	if n < 0 {
		n = 0
	}
	return putMetaTx(a.tx.Bucket(bucketActMeta), "pending_count", int64(n))
}

func (a *ActivityTx) seenCount() int {
	v, _ := getMetaInt64(a.tx.Bucket(bucketActMeta), "seen_count", 0)
	if v < 0 {
		return 0
	}
	return int(v)
}

func (a *ActivityTx) setSeenCount(n int) error {
	if n < 0 {
		n = 0
	}
	return putMetaTx(a.tx.Bucket(bucketActMeta), "seen_count", int64(n))
}

// Enqueued reports whether at least one new event was queued during this transaction.
func (a *ActivityTx) Enqueued() bool { return a.enqueued }

// GetContext retrieves the persisted connection context for contextID.
func (a *ActivityTx) GetContext(contextID string) (ConnContext, bool, error) {
	raw := a.tx.Bucket(bucketActContexts).Get([]byte(contextID))
	if raw == nil {
		return ConnContext{}, false, nil
	}
	var sc storedContext
	if err := json.Unmarshal(raw, &sc); err != nil {
		return ConnContext{}, false, err
	}
	return sc.Value, true, nil
}

// SetContext saves or updates a connection context entry.
func (a *ActivityTx) SetContext(contextID string, ts int64, ctx ConnContext) error {
	raw, err := CanonicalJSON(storedContext{TS: ts, Value: ctx})
	if err != nil {
		return err
	}
	return a.tx.Bucket(bucketActContexts).Put([]byte(contextID), raw)
}

// Enqueue sanitizes, deduplicates via seen, and appends ev to pending.
func (a *ActivityTx) Enqueue(ev ActivityEvent) (bool, error) {
	ev.SourceIP = sanitizeField(ev.SourceIP, 64)
	ev.Target = sanitizeField(ev.Target, 512)
	ev.Inbound = sanitizeField(ev.Inbound, 100)
	ev.Message = sanitizeField(ev.Message, 500)

	payload, err := CanonicalJSON(ev)
	if err != nil {
		return false, err
	}

	bSeen := a.tx.Bucket(bucketActSeen)
	idBytes := []byte(ev.ID)
	if bSeen.Get(idBytes) != nil {
		return false, nil
	}

	seq, err := a.nextSeq()
	if err != nil {
		return false, err
	}
	seqKey := encodeSeqKey(seq)
	if err := bSeen.Put(idBytes, seqKey); err != nil {
		return false, err
	}
	if err := a.tx.Bucket(bucketActSeenOrder).Put(seqKey, idBytes); err != nil {
		return false, err
	}
	if err := a.setSeenCount(a.seenCount() + 1); err != nil {
		return false, err
	}

	bPendingByID := a.tx.Bucket(bucketActPendingByID)
	if bPendingByID.Get(idBytes) != nil {
		return false, nil
	}

	pKey := makePendingKey(ev.TS, seq)
	pVal := encodePendingValue(ev.ID, payload)
	if err := a.tx.Bucket(bucketActPending).Put(pKey, pVal); err != nil {
		return false, err
	}
	if err := bPendingByID.Put(idBytes, pKey); err != nil {
		return false, err
	}
	if err := a.setPendingCount(a.pendingCount() + 1); err != nil {
		return false, err
	}
	if err := a.setPendingBytes(a.pendingBytes() + int64(len(payload))); err != nil {
		return false, err
	}
	a.enqueued = true
	return true, nil
}

// RecordGap increments the gap counter and enqueues a gap event with a 64-hex random ID.
func (a *ActivityTx) RecordGap(reason string, ts int64) error {
	bMeta := a.tx.Bucket(bucketActMeta)
	gaps, _ := getMetaInt64(bMeta, "gaps", 0)
	if err := putMetaTx(bMeta, "gaps", gaps+1); err != nil {
		return err
	}
	id, err := NewRandomHex64()
	if err != nil {
		return err
	}
	_, err = a.Enqueue(ActivityEvent{
		ID:      id,
		TS:      ts,
		Kind:    "gap",
		UserID:  nil,
		Message: reason,
	})
	return err
}

// SetCursor persists the current log cursor.
func (a *ActivityTx) SetCursor(c ActivityCursor) error {
	c.Set = true
	return putMetaTx(a.tx.Bucket(bucketActMeta), "cursor", c)
}

// SetCollectedAt updates the last collection timestamp.
func (a *ActivityTx) SetCollectedAt(ts int64) error {
	return putMetaTx(a.tx.Bucket(bucketActMeta), "collected_at", ts)
}

// SetError records or clears the collector error string.
func (a *ActivityTx) SetError(msg string) error {
	return putMetaTx(a.tx.Bucket(bucketActMeta), "error", msg)
}

func (a *ActivityTx) deletePendingEntry(pKey, pVal []byte) (int64, error) {
	id, payload, err := decodePendingValue(pVal)
	if err != nil {
		return 0, err
	}
	if err := a.tx.Bucket(bucketActPending).Delete(pKey); err != nil {
		return 0, err
	}
	if err := a.tx.Bucket(bucketActPendingByID).Delete([]byte(id)); err != nil {
		return 0, err
	}
	return int64(len(payload)), nil
}

// CleanupExpired drops pending events older than 7 days, trims seen to 40,000 entries,
// and trims contexts older than 15 minutes or exceeding 4,000 entries.
func (a *ActivityTx) CleanupExpired(now int64) error {
	bPending := a.tx.Bucket(bucketActPending)
	bMeta := a.tx.Bucket(bucketActMeta)

	cutoff := now - ActivityRetentionSeconds
	var dropped int64
	var removedBytes int64

	type kv struct {
		k []byte
		v []byte
	}
	var expired []kv
	c := bPending.Cursor()
	for k, v := c.First(); k != nil; k, v = c.Next() {
		if pendingKeyTS(k) >= cutoff {
			break
		}
		kc := append([]byte(nil), k...)
		vc := append([]byte(nil), v...)
		expired = append(expired, kv{k: kc, v: vc})
	}
	for _, item := range expired {
		sz, err := a.deletePendingEntry(item.k, item.v)
		if err != nil {
			return err
		}
		dropped++
		removedBytes += sz
	}
	if dropped > 0 {
		if err := a.setPendingCount(a.pendingCount() - int(dropped)); err != nil {
			return err
		}
		if err := a.setPendingBytes(a.pendingBytes() - removedBytes); err != nil {
			return err
		}
		oldDropped, _ := getMetaInt64(bMeta, "dropped", 0)
		if err := putMetaTx(bMeta, "dropped", oldDropped+dropped); err != nil {
			return err
		}
		if err := a.RecordGap(fmt.Sprintf("本地行为缓存达到容量或 7 天期限，丢弃 %d 条记录", dropped), now); err != nil {
			return err
		}
	}

	// Trim seen deduplication table to MaxActivitySeen most recent entries.
	bSeenOrder := a.tx.Bucket(bucketActSeenOrder)
	bSeen := a.tx.Bucket(bucketActSeen)
	seenCount := a.seenCount()
	if seenCount > MaxActivitySeen {
		excess := seenCount - MaxActivitySeen
		var toDel []kv
		sc := bSeenOrder.Cursor()
		for k, v := sc.First(); k != nil && len(toDel) < excess; k, v = sc.Next() {
			toDel = append(toDel, kv{
				k: append([]byte(nil), k...),
				v: append([]byte(nil), v...),
			})
		}
		for _, item := range toDel {
			if err := bSeenOrder.Delete(item.k); err != nil {
				return err
			}
			if err := bSeen.Delete(item.v); err != nil {
				return err
			}
		}
		if err := a.setSeenCount(seenCount - len(toDel)); err != nil {
			return err
		}
	}

	// Trim contexts by TTL (15 min) and count (4,000).
	bCtx := a.tx.Bucket(bucketActContexts)
	ctxCutoff := now - ActivityContextTTLSeconds
	type ctxMeta struct {
		key []byte
		ts  int64
	}
	var kept []ctxMeta
	var expiredCtx [][]byte
	if err := bCtx.ForEach(func(k, v []byte) error {
		var sc storedContext
		if err := json.Unmarshal(v, &sc); err != nil || sc.TS < ctxCutoff {
			expiredCtx = append(expiredCtx, append([]byte(nil), k...))
			return nil
		}
		kept = append(kept, ctxMeta{key: append([]byte(nil), k...), ts: sc.TS})
		return nil
	}); err != nil {
		return err
	}
	for _, k := range expiredCtx {
		if err := bCtx.Delete(k); err != nil {
			return err
		}
	}
	if len(kept) > MaxActivityContexts {
		sort.Slice(kept, func(i, j int) bool { return kept[i].ts < kept[j].ts })
		for _, item := range kept[:len(kept)-MaxActivityContexts] {
			if err := bCtx.Delete(item.key); err != nil {
				return err
			}
		}
	}
	return nil
}

// EnforceCapacity evicts the oldest pending events whenever count > maxPending or bytes > maxQueueBytes.
func (a *ActivityTx) EnforceCapacity(now int64) error {
	bPending := a.tx.Bucket(bucketActPending)
	bMeta := a.tx.Bucket(bucketActMeta)

	count := a.pendingCount()
	size := a.pendingBytes()
	if count <= a.maxPending && size <= a.maxQueueBytes {
		return nil
	}

	targetCount := a.maxPending - 1
	if targetCount < 0 {
		targetCount = 0
	}
	targetBytes := a.maxQueueBytes - 2048
	if targetBytes < 0 {
		targetBytes = 0
	}

	type kv struct {
		k []byte
		v []byte
	}
	var toEvict []kv
	c := bPending.Cursor()
	curCount := count
	curSize := size
	for k, v := c.First(); k != nil; k, v = c.Next() {
		if curCount <= targetCount && curSize <= targetBytes {
			break
		}
		_, payload, err := decodePendingValue(v)
		if err != nil {
			return err
		}
		toEvict = append(toEvict, kv{
			k: append([]byte(nil), k...),
			v: append([]byte(nil), v...),
		})
		curCount--
		curSize -= int64(len(payload))
	}

	var dropped int64
	var removedBytes int64
	for _, item := range toEvict {
		sz, err := a.deletePendingEntry(item.k, item.v)
		if err != nil {
			return err
		}
		dropped++
		removedBytes += sz
	}
	if dropped > 0 {
		if err := a.setPendingCount(count - int(dropped)); err != nil {
			return err
		}
		if err := a.setPendingBytes(size - removedBytes); err != nil {
			return err
		}
		oldDropped, _ := getMetaInt64(bMeta, "dropped", 0)
		if err := putMetaTx(bMeta, "dropped", oldDropped+dropped); err != nil {
			return err
		}
		if err := a.RecordGap(fmt.Sprintf("本地行为缓存达到容量或 7 天期限，丢弃 %d 条记录", dropped), now); err != nil {
			return err
		}
	}
	return nil
}

// LoadMeta reads the persisted cursor, collected_at, and error state.
func (s *ActivityStore) LoadMeta() (ActivityMetaSnapshot, error) {
	db, err := openBolt(s.path, true)
	if err != nil {
		return ActivityMetaSnapshot{}, err
	}
	defer db.Close()

	var snap ActivityMetaSnapshot
	err = db.View(func(tx *bolt.Tx) error {
		bMeta := tx.Bucket(bucketActMeta)
		if raw := bMeta.Get([]byte("cursor")); raw != nil {
			var cur ActivityCursor
			if err := json.Unmarshal(raw, &cur); err == nil && (cur.Set || cur.Session != "" || cur.Ino != 0) {
				cur.Set = true
				snap.Cursor = cur
				snap.HasCursor = true
			}
		}
		snap.CollectedAt, _ = getMetaInt64(bMeta, "collected_at", 0)
		snap.Error = getMetaString(bMeta, "error", "")
		return nil
	})
	return snap, err
}

// SetError persists an error string in the activity metadata bucket.
func (s *ActivityStore) SetError(msg string) error {
	cleaned := strings.Join(strings.Fields(msg), " ")
	runes := []rune(cleaned)
	if len(runes) > 1000 {
		cleaned = string(runes[:1000])
	}
	return s.Update(func(tx *ActivityTx) error {
		return tx.SetError(cleaned)
	})
}

// Status returns the current queue depth and counters.
func (s *ActivityStore) Status() (ActivityStatus, error) {
	db, err := openBolt(s.path, true)
	if err != nil {
		return ActivityStatus{}, err
	}
	defer db.Close()

	var st ActivityStatus
	err = db.View(func(tx *bolt.Tx) error {
		bMeta := tx.Bucket(bucketActMeta)
		st.Pending = tx.Bucket(bucketActPending).Stats().KeyN
		st.CollectedAt, _ = getMetaInt64(bMeta, "collected_at", 0)
		st.Dropped, _ = getMetaInt64(bMeta, "dropped", 0)
		st.Gaps, _ = getMetaInt64(bMeta, "gaps", 0)
		st.Error = getMetaString(bMeta, "error", "")
		return nil
	})
	return st, err
}

// PeekBatch returns up to limit oldest pending events as raw JSON messages alongside their IDs.
func (s *ActivityStore) PeekBatch(limit int) ([]json.RawMessage, []string, error) {
	if limit <= 0 {
		limit = 400
	}
	db, err := openBolt(s.path, true)
	if err != nil {
		return nil, nil, err
	}
	defer db.Close()

	events := make([]json.RawMessage, 0)
	ids := make([]string, 0)
	err = db.View(func(tx *bolt.Tx) error {
		c := tx.Bucket(bucketActPending).Cursor()
		for k, v := c.First(); k != nil && len(events) < limit; k, v = c.Next() {
			id, payload, err := decodePendingValue(v)
			if err != nil {
				return err
			}
			events = append(events, append(json.RawMessage(nil), payload...))
			ids = append(ids, id)
		}
		return nil
	})
	return events, ids, err
}

// Ack deletes acknowledged event IDs in O(len(ids)) using pending_by_id.
func (s *ActivityStore) Ack(ids []string) error {
	if len(ids) == 0 {
		return nil
	}
	return s.Update(func(tx *ActivityTx) error {
		bPending := tx.tx.Bucket(bucketActPending)
		bByID := tx.tx.Bucket(bucketActPendingByID)
		var removedCount int
		var removedBytes int64
		for _, id := range ids {
			idBytes := []byte(id)
			pKey := bByID.Get(idBytes)
			if pKey == nil {
				continue
			}
			pVal := bPending.Get(pKey)
			if pVal != nil {
				if _, payload, err := decodePendingValue(pVal); err == nil {
					removedBytes += int64(len(payload))
				}
			}
			if err := bPending.Delete(pKey); err != nil {
				return err
			}
			if err := bByID.Delete(idBytes); err != nil {
				return err
			}
			removedCount++
		}
		if removedCount > 0 {
			if err := tx.setPendingCount(tx.pendingCount() - removedCount); err != nil {
				return err
			}
		}
		if removedBytes > 0 {
			return tx.setPendingBytes(tx.pendingBytes() - removedBytes)
		}
		return nil
	})
}
