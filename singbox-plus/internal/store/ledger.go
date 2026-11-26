package store

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strconv"
	"time"

	bolt "go.etcd.io/bbolt"
)

var (
	bucketMeta         = []byte("meta")
	bucketAliases      = []byte("aliases")
	bucketBaselines    = []byte("baselines")
	bucketUsage        = []byte("usage")
	bucketPendingUsage = []byte("pending_usage")
	bucketOutbox       = []byte("outbox")
	bucketOutboxByID   = []byte("outbox_by_id")
)

// Counter holds monotonic uplink and downlink byte totals for a sing-box stats key.
type Counter struct {
	Uplink   int64
	Downlink int64
}

// AliasEntry binds a sing-box stats_key to a central user_id.
type AliasEntry struct {
	StatsKey         string `json:"stats_key"`
	UserID           string `json:"user_id"`
	BaselineRequired bool   `json:"baseline_required"`
}

type baselineRecord struct {
	StatsKey  string `json:"stats_key"`
	CoreEpoch string `json:"core_epoch"`
	Up        int64  `json:"up"`
	Down      int64  `json:"down"`
	TS        int64  `json:"ts"`
}

// UsageRecord represents cumulative accounted traffic for one user on this node.
type UsageRecord struct {
	UserID string `json:"user_id"`
	Up     int64  `json:"up"`
	Down   int64  `json:"down"`
	LastAt int64  `json:"last_at"`
}

// UsageRow is a single 15-second bucketed usage delta row inside an outbox batch.
type UsageRow struct {
	Down   int64  `json:"down"`
	TS     int64  `json:"ts"`
	Up     int64  `json:"up"`
	UserID string `json:"user_id"`
}

// Batch is an idempotent traffic upload batch keyed by (Epoch, Seq).
type Batch struct {
	Epoch string     `json:"epoch"`
	Rows  []UsageRow `json:"rows"`
	Seq   int64      `json:"seq"`
}

// Ack identifies a batch acknowledged by the center server.
type Ack struct {
	Epoch string `json:"epoch"`
	Seq   int64  `json:"seq"`
}

// RecordResult is returned by Ledger.Record.
type RecordResult struct {
	SampledAt int64 `json:"sampled_at"`
	Up        int64 `json:"up"`
	Down      int64 `json:"down"`
}

// Summary matches the exact JSON fields returned by Ledger.summary() in ysq-agent.
type Summary struct {
	LedgerEpoch     string        `json:"ledger_epoch"`
	AppliedRevision int64         `json:"applied_revision"`
	LastSampleAt    *int64        `json:"last_sample_at"`
	LastSyncAt      *int64        `json:"last_sync_at"`
	CollectorError  string        `json:"collector_error"`
	ApplyError      string        `json:"apply_error"`
	SyncError       string        `json:"sync_error"`
	PendingBatches  int           `json:"pending_batches"`
	UnpackagedRows  int           `json:"unpackaged_rows"`
	Usage           []UsageRecord `json:"usage"`
}

// Ledger is a durable bbolt-backed byte-accounting ledger that opens and closes
// bbolt per operation so CLI commands and the daemon coexist cleanly.
type Ledger struct {
	logicalPath string
	boltPath    string
}

// OpenLedger initializes (or opens) a durable bbolt Ledger for dbPath.
// If dbPath is an existing SQLite 3 database, it non-destructively uses dbPath + ".bolt".
func OpenLedger(dbPath string) (*Ledger, error) {
	boltPath, err := ResolveBoltPath(dbPath)
	if err != nil {
		return nil, err
	}

	db, err := openBolt(boltPath, false)
	if err != nil {
		return nil, err
	}
	defer db.Close()

	err = db.Update(func(tx *bolt.Tx) error {
		for _, name := range [][]byte{
			bucketMeta,
			bucketAliases,
			bucketBaselines,
			bucketUsage,
			bucketPendingUsage,
			bucketOutbox,
			bucketOutboxByID,
		} {
			if _, err := tx.CreateBucketIfNotExists(name); err != nil {
				return err
			}
		}
		meta := tx.Bucket(bucketMeta)
		if meta.Get([]byte("epoch")) == nil {
			u, err := NewUUIDv4()
			if err != nil {
				return err
			}
			if err := putMetaTx(meta, "epoch", u); err != nil {
				return err
			}
		}
		if meta.Get([]byte("next_seq")) == nil {
			if err := putMetaTx(meta, "next_seq", int64(1)); err != nil {
				return err
			}
		}
		if meta.Get([]byte("applied_revision")) == nil {
			if err := putMetaTx(meta, "applied_revision", int64(0)); err != nil {
				return err
			}
		}
		if meta.Get([]byte("last_packaged_at")) == nil {
			if err := putMetaTx(meta, "last_packaged_at", int64(0)); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	_ = os.Chmod(boltPath, 0o600)

	return &Ledger{
		logicalPath: dbPath,
		boltPath:    boltPath,
	}, nil
}

// Path returns the resolved bbolt database path on disk.
func (l *Ledger) Path() string { return l.boltPath }

// LogicalPath returns the configured db_path (which may differ from Path() when a legacy SQLite file exists).
func (l *Ledger) LogicalPath() string { return l.logicalPath }

func putMetaTx(b *bolt.Bucket, key string, value any) error {
	raw, err := CanonicalJSON(value)
	if err != nil {
		return err
	}
	return b.Put([]byte(key), raw)
}

func getMetaInt64(b *bolt.Bucket, key string, def int64) (int64, bool) {
	raw := b.Get([]byte(key))
	if raw == nil {
		return def, false
	}
	var v int64
	if err := json.Unmarshal(raw, &v); err != nil {
		return def, false
	}
	return v, true
}

func getMetaString(b *bolt.Bucket, key, def string) string {
	raw := b.Get([]byte(key))
	if raw == nil {
		return def
	}
	var v string
	if err := json.Unmarshal(raw, &v); err != nil {
		return def
	}
	return v
}

func getMetaBool(b *bolt.Bucket, key string, def bool) bool {
	raw := b.Get([]byte(key))
	if raw == nil {
		return def
	}
	var v bool
	if err := json.Unmarshal(raw, &v); err != nil {
		return def
	}
	return v
}

// MetaInt64 reads an int64 metadata key, returning def if absent.
func (l *Ledger) MetaInt64(key string, def int64) (int64, error) {
	db, err := openBolt(l.boltPath, true)
	if err != nil {
		return def, err
	}
	defer db.Close()

	val := def
	err = db.View(func(tx *bolt.Tx) error {
		val, _ = getMetaInt64(tx.Bucket(bucketMeta), key, def)
		return nil
	})
	return val, err
}

// MetaBool reads a bool metadata key, returning def if absent.
func (l *Ledger) MetaBool(key string, def bool) (bool, error) {
	db, err := openBolt(l.boltPath, true)
	if err != nil {
		return def, err
	}
	defer db.Close()

	val := def
	err = db.View(func(tx *bolt.Tx) error {
		val = getMetaBool(tx.Bucket(bucketMeta), key, def)
		return nil
	})
	return val, err
}

// MetaString reads a string metadata key, returning def if absent.
func (l *Ledger) MetaString(key, def string) (string, error) {
	db, err := openBolt(l.boltPath, true)
	if err != nil {
		return def, err
	}
	defer db.Close()

	val := def
	err = db.View(func(tx *bolt.Tx) error {
		val = getMetaString(tx.Bucket(bucketMeta), key, def)
		return nil
	})
	return val, err
}

// SetMeta atomically writes one or more metadata key-value pairs.
func (l *Ledger) SetMeta(values map[string]any) error {
	if len(values) == 0 {
		return nil
	}
	db, err := openBolt(l.boltPath, false)
	if err != nil {
		return err
	}
	defer db.Close()

	return db.Update(func(tx *bolt.Tx) error {
		meta := tx.Bucket(bucketMeta)
		for k, v := range values {
			if err := putMetaTx(meta, k, v); err != nil {
				return err
			}
		}
		return nil
	})
}

// Remember inserts new stats_key -> user_id alias mappings, rejecting any alias
// that already belongs to a different user_id.
func (l *Ledger) Remember(entries []AliasEntry) error {
	if len(entries) == 0 {
		return nil
	}
	db, err := openBolt(l.boltPath, false)
	if err != nil {
		return err
	}
	defer db.Close()

	return db.Update(func(tx *bolt.Tx) error {
		b := tx.Bucket(bucketAliases)
		for _, entry := range entries {
			if existing := b.Get([]byte(entry.StatsKey)); existing != nil {
				var old AliasEntry
				if err := json.Unmarshal(existing, &old); err != nil {
					return err
				}
				if old.UserID != entry.UserID {
					return ErrAliasConflict
				}
				continue
			}
			raw, err := CanonicalJSON(entry)
			if err != nil {
				return err
			}
			if err := b.Put([]byte(entry.StatsKey), raw); err != nil {
				return err
			}
		}
		return nil
	})
}

// Aliases returns all persisted alias entries.
func (l *Ledger) Aliases() ([]AliasEntry, error) {
	db, err := openBolt(l.boltPath, true)
	if err != nil {
		return nil, err
	}
	defer db.Close()

	var result []AliasEntry
	err = db.View(func(tx *bolt.Tx) error {
		b := tx.Bucket(bucketAliases)
		return b.ForEach(func(_, v []byte) error {
			var entry AliasEntry
			if err := json.Unmarshal(v, &entry); err != nil {
				return err
			}
			result = append(result, entry)
			return nil
		})
	})
	return result, err
}

func pendingUsageKey(ts int64, userID string) []byte {
	return []byte(fmt.Sprintf("%020d:%s", ts, userID))
}

func outboxKey(createdAt, seq int64, epoch string) []byte {
	return []byte(fmt.Sprintf("%020d:%020d:%s", createdAt, seq, epoch))
}

func outboxIDKey(epoch string, seq int64) []byte {
	return []byte(epoch + ":" + strconv.FormatInt(seq, 10))
}

// Record commits a sampled counter snapshot for coreEpoch, computing monotonic deltas
// and aggregating them into usage and 15-second pending_usage buckets.
func (l *Ledger) Record(coreEpoch string, counters map[string]Counter, sampledAt int64) (RecordResult, error) {
	db, err := openBolt(l.boltPath, false)
	if err != nil {
		return RecordResult{}, err
	}
	defer db.Close()

	var addedUp, addedDown int64
	err = db.Update(func(tx *bolt.Tx) error {
		bAliases := tx.Bucket(bucketAliases)
		bBaselines := tx.Bucket(bucketBaselines)
		bUsage := tx.Bucket(bucketUsage)
		bPending := tx.Bucket(bucketPendingUsage)
		bMeta := tx.Bucket(bucketMeta)

		var aliases []AliasEntry
		if err := bAliases.ForEach(func(_, v []byte) error {
			var a AliasEntry
			if err := json.Unmarshal(v, &a); err != nil {
				return err
			}
			aliases = append(aliases, a)
			return nil
		}); err != nil {
			return err
		}

		for _, alias := range aliases {
			c := counters[alias.StatsKey]
			up, down := c.Uplink, c.Downlink
			if up < 0 || down < 0 {
				return errors.New("negative traffic counter")
			}

			var hasOld bool
			var old baselineRecord
			if rawOld := bBaselines.Get([]byte(alias.StatsKey)); rawOld != nil {
				if err := json.Unmarshal(rawOld, &old); err != nil {
					return err
				}
				hasOld = true
			}

			var deltaUp, deltaDown int64
			switch {
			case hasOld && old.CoreEpoch == coreEpoch:
				if up < old.Up || down < old.Down {
					return ErrCounterDrop
				}
				deltaUp = up - old.Up
				deltaDown = down - old.Down
			case hasOld:
				deltaUp = up
				deltaDown = down
			case alias.BaselineRequired:
				deltaUp = 0
				deltaDown = 0
			default:
				deltaUp = up
				deltaDown = down
			}

			newBase := baselineRecord{
				StatsKey:  alias.StatsKey,
				CoreEpoch: coreEpoch,
				Up:        up,
				Down:      down,
				TS:        sampledAt,
			}
			rawBase, err := CanonicalJSON(newBase)
			if err != nil {
				return err
			}
			if err := bBaselines.Put([]byte(alias.StatsKey), rawBase); err != nil {
				return err
			}

			if deltaUp > 0 || deltaDown > 0 {
				var uRec UsageRecord
				if rawU := bUsage.Get([]byte(alias.UserID)); rawU != nil {
					if err := json.Unmarshal(rawU, &uRec); err != nil {
						return err
					}
				} else {
					uRec.UserID = alias.UserID
				}
				uRec.Up += deltaUp
				uRec.Down += deltaDown
				uRec.LastAt = sampledAt
				rawU, err := CanonicalJSON(uRec)
				if err != nil {
					return err
				}
				if err := bUsage.Put([]byte(alias.UserID), rawU); err != nil {
					return err
				}

				bucketTS := (sampledAt / BatchSeconds) * BatchSeconds
				pKey := pendingUsageKey(bucketTS, alias.UserID)
				var pRow UsageRow
				if rawP := bPending.Get(pKey); rawP != nil {
					if err := json.Unmarshal(rawP, &pRow); err != nil {
						return err
					}
				} else {
					pRow.UserID = alias.UserID
					pRow.TS = bucketTS
				}
				pRow.Up += deltaUp
				pRow.Down += deltaDown
				rawP, err := CanonicalJSON(pRow)
				if err != nil {
					return err
				}
				if err := bPending.Put(pKey, rawP); err != nil {
					return err
				}

				addedUp += deltaUp
				addedDown += deltaDown
			}
		}

		if err := putMetaTx(bMeta, "last_sample_at", sampledAt); err != nil {
			return err
		}
		if err := putMetaTx(bMeta, "collector_error", ""); err != nil {
			return err
		}
		if err := putMetaTx(bMeta, "core_epoch", coreEpoch); err != nil {
			return err
		}
		return putMetaTx(bMeta, "service_running", true)
	})
	if err != nil {
		return RecordResult{}, err
	}
	return RecordResult{
		SampledAt: sampledAt,
		Up:        addedUp,
		Down:      addedDown,
	}, nil
}

// Package moves up to 16 batches of up to 1000 pending_usage rows into the durable outbox.
func (l *Ledger) Package(now int64, force bool) (int, error) {
	if now == 0 {
		now = time.Now().Unix()
	}
	db, err := openBolt(l.boltPath, false)
	if err != nil {
		return 0, err
	}
	defer db.Close()

	packaged := 0
	err = db.Update(func(tx *bolt.Tx) error {
		bMeta := tx.Bucket(bucketMeta)
		bPending := tx.Bucket(bucketPendingUsage)
		bOutbox := tx.Bucket(bucketOutbox)
		bOutboxByID := tx.Bucket(bucketOutboxByID)

		lastPackaged, _ := getMetaInt64(bMeta, "last_packaged_at", 0)
		if !force && now-lastPackaged < BatchSeconds {
			return nil
		}

		epoch := getMetaString(bMeta, "epoch", "")
		seq, ok := getMetaInt64(bMeta, "next_seq", 1)
		if !ok || seq < 1 {
			return errors.New("invalid ledger batch sequence")
		}

		for i := 0; i < 16; i++ {
			var rows []UsageRow
			var keysToDelete [][]byte
			c := bPending.Cursor()
			for k, v := c.First(); k != nil && len(rows) < 1000; k, v = c.Next() {
				var row UsageRow
				if err := json.Unmarshal(v, &row); err != nil {
					return err
				}
				rows = append(rows, row)
				kc := make([]byte, len(k))
				copy(kc, k)
				keysToDelete = append(keysToDelete, kc)
			}
			if len(rows) == 0 {
				break
			}

			batch := Batch{
				Epoch: epoch,
				Seq:   seq,
				Rows:  rows,
			}
			payload, err := CanonicalJSON(batch)
			if err != nil {
				return err
			}
			oKey := outboxKey(now, seq, epoch)
			if err := bOutbox.Put(oKey, payload); err != nil {
				return err
			}
			if err := bOutboxByID.Put(outboxIDKey(epoch, seq), oKey); err != nil {
				return err
			}
			for _, dk := range keysToDelete {
				if err := bPending.Delete(dk); err != nil {
					return err
				}
			}
			seq++
			if err := putMetaTx(bMeta, "next_seq", seq); err != nil {
				return err
			}
			packaged++
		}

		return putMetaTx(bMeta, "last_packaged_at", now)
	})
	return packaged, err
}

// Batches returns up to 16 pending outbox batches bounded by MaxBody - 16384 bytes.
func (l *Ledger) Batches() ([]Batch, error) {
	db, err := openBolt(l.boltPath, true)
	if err != nil {
		return nil, err
	}
	defer db.Close()

	result := make([]Batch, 0)
	err = db.View(func(tx *bolt.Tx) error {
		b := tx.Bucket(bucketOutbox)
		size := 0
		c := b.Cursor()
		for k, v := c.First(); k != nil && len(result) < 16; k, v = c.Next() {
			size += len(v) + 1
			if size > MaxBody-16384 {
				break
			}
			var batch Batch
			if err := json.Unmarshal(v, &batch); err != nil {
				return err
			}
			result = append(result, batch)
		}
		return nil
	})
	return result, err
}

// Acknowledge validates that every acked (epoch, seq) was sent in this sync call and removes them from outbox.
func (l *Ledger) Acknowledge(acks []Ack, sent []Batch) (int, error) {
	allowed := make(map[Ack]struct{}, len(sent))
	for _, b := range sent {
		allowed[Ack{Epoch: b.Epoch, Seq: b.Seq}] = struct{}{}
	}
	accepted := make(map[Ack]struct{}, len(acks))
	for _, ack := range acks {
		if ack.Epoch == "" || ack.Seq < 1 {
			return 0, ErrInvalidAck
		}
		if _, ok := allowed[ack]; !ok {
			return 0, fmt.Errorf("%w: center acknowledged a batch that was not sent", ErrInvalidAck)
		}
		accepted[ack] = struct{}{}
	}
	if len(accepted) == 0 {
		return 0, nil
	}

	db, err := openBolt(l.boltPath, false)
	if err != nil {
		return 0, err
	}
	defer db.Close()

	err = db.Update(func(tx *bolt.Tx) error {
		bOutbox := tx.Bucket(bucketOutbox)
		bOutboxByID := tx.Bucket(bucketOutboxByID)
		for ack := range accepted {
			idKey := outboxIDKey(ack.Epoch, ack.Seq)
			if oKey := bOutboxByID.Get(idKey); oKey != nil {
				if err := bOutbox.Delete(oKey); err != nil {
					return err
				}
				if err := bOutboxByID.Delete(idKey); err != nil {
					return err
				}
			}
		}
		return nil
	})
	if err != nil {
		return 0, err
	}
	return len(accepted), nil
}

// Summary returns the full ledger status snapshot matching ysq-agent's schema.
func (l *Ledger) Summary() (Summary, error) {
	db, err := openBolt(l.boltPath, true)
	if err != nil {
		return Summary{}, err
	}
	defer db.Close()

	out := Summary{
		Usage: make([]UsageRecord, 0),
	}
	err = db.View(func(tx *bolt.Tx) error {
		bMeta := tx.Bucket(bucketMeta)
		bUsage := tx.Bucket(bucketUsage)
		bOutbox := tx.Bucket(bucketOutbox)
		bPending := tx.Bucket(bucketPendingUsage)

		out.LedgerEpoch = getMetaString(bMeta, "epoch", "")
		out.AppliedRevision, _ = getMetaInt64(bMeta, "applied_revision", 0)
		if v, ok := getMetaInt64(bMeta, "last_sample_at", 0); ok {
			out.LastSampleAt = &v
		}
		if v, ok := getMetaInt64(bMeta, "last_sync_at", 0); ok {
			out.LastSyncAt = &v
		}
		out.CollectorError = getMetaString(bMeta, "collector_error", "")
		out.ApplyError = getMetaString(bMeta, "apply_error", "")
		out.SyncError = getMetaString(bMeta, "sync_error", "")
		out.PendingBatches = bOutbox.Stats().KeyN
		out.UnpackagedRows = bPending.Stats().KeyN

		return bUsage.ForEach(func(_, v []byte) error {
			var u UsageRecord
			if err := json.Unmarshal(v, &u); err != nil {
				return err
			}
			out.Usage = append(out.Usage, u)
			return nil
		})
	})
	return out, err
}
