package store

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

func TestLegacySQLiteFallbackNonDestructive(t *testing.T) {
	dir := t.TempDir()
	sqlitePath := filepath.Join(dir, "agent.db")
	legacyData := append([]byte("SQLite format 3\x00"), bytes.Repeat([]byte("X"), 128)...)
	if err := os.WriteFile(sqlitePath, legacyData, 0o600); err != nil {
		t.Fatalf("seed legacy sqlite: %v", err)
	}

	l, err := OpenLedger(sqlitePath)
	if err != nil {
		t.Fatalf("OpenLedger: %v", err)
	}
	if l.Path() != sqlitePath+".bolt" {
		t.Fatalf("resolved path = %q, want %q", l.Path(), sqlitePath+".bolt")
	}
	if l.LogicalPath() != sqlitePath {
		t.Fatalf("logical path = %q, want %q", l.LogicalPath(), sqlitePath)
	}

	// Verify legacy SQLite file is completely untouched.
	after, err := os.ReadFile(sqlitePath)
	if err != nil {
		t.Fatalf("read legacy file: %v", err)
	}
	if !bytes.Equal(after, legacyData) {
		t.Fatal("legacy SQLite file was modified!")
	}
}

func TestLedgerRememberRecordPackageAck(t *testing.T) {
	dir := t.TempDir()
	l, err := OpenLedger(filepath.Join(dir, "agent.db"))
	if err != nil {
		t.Fatalf("OpenLedger: %v", err)
	}

	u1 := "u_11111111111111111111111111111111"
	u2 := "u_22222222222222222222222222222222"

	if err := l.Remember([]AliasEntry{
		{StatsKey: "alice", UserID: u1, BaselineRequired: true},
		{StatsKey: u2, UserID: u2, BaselineRequired: false},
	}); err != nil {
		t.Fatalf("Remember: %v", err)
	}

	// Conflicting user_id for same stats_key must fail.
	if err := l.Remember([]AliasEntry{{StatsKey: "alice", UserID: u2, BaselineRequired: false}}); !errors.Is(err, ErrAliasConflict) {
		t.Fatalf("expected ErrAliasConflict, got %v", err)
	}

	now := int64(1700000100)
	// First sample: alice requires baseline (0 delta), u2 does not (counts immediately).
	res, err := l.Record("epoch-1", map[string]Counter{
		"alice": {Uplink: 500, Downlink: 1000},
		u2:      {Uplink: 100, Downlink: 200},
	}, now)
	if err != nil {
		t.Fatalf("Record 1: %v", err)
	}
	if res.Up != 100 || res.Down != 200 {
		t.Fatalf("Record 1 delta = %+v, want up=100 down=200", res)
	}

	// Counter drop within same core_epoch must fail and preserve baseline!
	if _, err := l.Record("epoch-1", map[string]Counter{
		"alice": {Uplink: 400, Downlink: 1000},
		u2:      {Uplink: 100, Downlink: 200},
	}, now+10); !errors.Is(err, ErrCounterDrop) {
		t.Fatalf("expected ErrCounterDrop, got %v", err)
	}

	// Second sample in same core_epoch: monotonic increase.
	res, err = l.Record("epoch-1", map[string]Counter{
		"alice": {Uplink: 800, Downlink: 1500},
		u2:      {Uplink: 150, Downlink: 250},
	}, now+10)
	if err != nil {
		t.Fatalf("Record 2: %v", err)
	}
	if res.Up != 350 || res.Down != 550 {
		t.Fatalf("Record 2 delta = %+v, want up=350 down=550", res)
	}

	// Core restart (new epoch): counters start from 0, full values counted.
	res, err = l.Record("epoch-2", map[string]Counter{
		"alice": {Uplink: 50, Downlink: 60},
		u2:      {Uplink: 0, Downlink: 0},
	}, now+20)
	if err != nil {
		t.Fatalf("Record 3: %v", err)
	}
	if res.Up != 50 || res.Down != 60 {
		t.Fatalf("Record 3 delta = %+v, want up=50 down=60", res)
	}

	// Package into outbox.
	n, err := l.Package(now+30, false)
	if err != nil {
		t.Fatalf("Package: %v", err)
	}
	if n != 1 {
		t.Fatalf("packaged = %d, want 1", n)
	}

	batches, err := l.Batches()
	if err != nil {
		t.Fatalf("Batches: %v", err)
	}
	if len(batches) != 1 || batches[0].Seq != 1 || len(batches[0].Rows) == 0 {
		t.Fatalf("unexpected batches: %+v", batches)
	}

	// Reject unknown ack.
	if _, err := l.Acknowledge([]Ack{{Epoch: batches[0].Epoch, Seq: 999}}, batches); !errors.Is(err, ErrInvalidAck) {
		t.Fatalf("expected ErrInvalidAck, got %v", err)
	}

	// Accept valid ack.
	acked, err := l.Acknowledge([]Ack{{Epoch: batches[0].Epoch, Seq: batches[0].Seq}}, batches)
	if err != nil || acked != 1 {
		t.Fatalf("Acknowledge = (%d, %v), want (1, nil)", acked, err)
	}

	sum, err := l.Summary()
	if err != nil {
		t.Fatalf("Summary: %v", err)
	}
	if sum.PendingBatches != 0 || sum.UnpackagedRows != 0 || len(sum.Usage) != 2 {
		t.Fatalf("unexpected summary: %+v", sum)
	}
	if sum.LastSampleAt == nil || *sum.LastSampleAt != now+20 {
		t.Fatalf("LastSampleAt = %v", sum.LastSampleAt)
	}
	if sum.LastSyncAt != nil {
		t.Fatalf("expected nil LastSyncAt before sync, got %v", *sum.LastSyncAt)
	}
}

func TestActivityStoreCapacityExpiryAndAck(t *testing.T) {
	dir := t.TempDir()
	s, err := OpenActivityStore(filepath.Join(dir, "act.bolt"))
	if err != nil {
		t.Fatalf("OpenActivityStore: %v", err)
	}
	s.SetLimits(5, MaxActivityQueueBytes)

	baseTS := int64(1700000000)
	err = s.Update(func(tx *ActivityTx) error {
		for i := 0; i < 8; i++ {
			id := fmt.Sprintf("%064x", i+1)
			ok, err := tx.Enqueue(ActivityEvent{
				ID:      id,
				TS:      baseTS + int64(i),
				Kind:    "connection",
				Target:  "example.com\x00\n",
				Inbound: "vless-in",
			})
			if err != nil {
				return err
			}
			if !ok {
				t.Fatalf("expected enqueue %d to succeed", i)
			}
		}
		// Duplicate ID must be ignored.
		dup, err := tx.Enqueue(ActivityEvent{
			ID:   fmt.Sprintf("%064x", 1),
			TS:   baseTS,
			Kind: "connection",
		})
		if err != nil || dup {
			t.Fatalf("expected duplicate to be ignored: (%v, %v)", dup, err)
		}
		return tx.EnforceCapacity(baseTS + 10)
	})
	if err != nil {
		t.Fatalf("Update: %v", err)
	}

	st, err := s.Status()
	if err != nil {
		t.Fatalf("Status: %v", err)
	}
	// Limit 5: evicted down to 4, then 1 gap event added = 5 pending, 4 dropped, 1 gap!
	if st.Dropped != 4 || st.Gaps != 1 || st.Pending != 5 {
		t.Fatalf("unexpected status after capacity eviction: %+v", st)
	}

	rawEvents, ids, err := s.PeekBatch(10)
	if err != nil {
		t.Fatalf("PeekBatch: %v", err)
	}
	if len(rawEvents) != 5 || len(ids) != 5 {
		t.Fatalf("PeekBatch len = (%d, %d), want 5", len(rawEvents), len(ids))
	}
	var first ActivityEvent
	if err := json.Unmarshal(rawEvents[0], &first); err != nil {
		t.Fatalf("unmarshal event: %v", err)
	}
	if first.Target != "example.com" {
		t.Errorf("control chars were not sanitized: %q", first.Target)
	}

	// Ack first 3 events.
	if err := s.Ack(ids[:3]); err != nil {
		t.Fatalf("Ack: %v", err)
	}
	st, err = s.Status()
	if err != nil {
		t.Fatalf("Status after ack: %v", err)
	}
	if st.Pending != 2 {
		t.Fatalf("pending after ack = %d, want 2", st.Pending)
	}

	// Test 7-day expiry cleanup.
	err = s.Update(func(tx *ActivityTx) error {
		return tx.CleanupExpired(baseTS + ActivityRetentionSeconds + 100)
	})
	if err != nil {
		t.Fatalf("CleanupExpired: %v", err)
	}
	st, err = s.Status()
	if err != nil {
		t.Fatalf("Status after expiry: %v", err)
	}
	// 2 old events expired + 1 fresh gap event enqueued.
	if st.Dropped != 6 || st.Gaps != 2 || st.Pending != 1 {
		t.Fatalf("unexpected status after expiry: %+v", st)
	}
}

func TestLedgerConcurrentOpenPerOp(t *testing.T) {
	dir := t.TempDir()
	l, err := OpenLedger(filepath.Join(dir, "concurrent.db"))
	if err != nil {
		t.Fatalf("OpenLedger: %v", err)
	}

	var wg sync.WaitGroup
	errs := make(chan error, 16)
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			for j := 0; j < 5; j++ {
				if err := l.SetMeta(map[string]any{"worker": fmt.Sprintf("%d-%d", id, j)}); err != nil {
					errs <- err
					return
				}
				if _, err := l.Summary(); err != nil {
					errs <- err
					return
				}
				time.Sleep(time.Millisecond)
			}
		}(i)
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Fatalf("concurrent op failed: %v", err)
	}
}
