package store

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	bolt "go.etcd.io/bbolt"
)

const (
	// MaxBody is the maximum agent HTTP payload size (2 MiB).
	MaxBody = 2 * 1024 * 1024
	// BatchSeconds is the aggregation/packaging bucket interval (15 seconds).
	BatchSeconds int64 = 15
	// DefaultOpenTimeout is how long bbolt waits to acquire the file lock.
	DefaultOpenTimeout = 4 * time.Second
)

var sqliteMagic = []byte("SQLite format 3\x00")

// Error types returned by store operations so callers can classify them cleanly.
var (
	ErrAliasConflict = errors.New("a statistics alias belongs to another user; manual reconciliation is required")
	ErrCounterDrop   = errors.New("counter disappeared or moved backwards without a core restart; baseline preserved; check other reset=true collectors")
	ErrInvalidAck    = errors.New("invalid center acknowledgement")
)

// EnsurePrivateDir ensures the parent directory of path exists (mode 0700) and is not a symlink.
func EnsurePrivateDir(path string) (string, error) {
	parent := filepath.Dir(path)
	if fi, err := os.Lstat(parent); err == nil {
		if fi.Mode()&os.ModeSymlink != 0 {
			return "", errors.New("private data directory must not be a symlink")
		}
		if !fi.IsDir() {
			return "", errors.New("private data directory path is not a directory")
		}
	} else if errors.Is(err, os.ErrNotExist) {
		if err := os.MkdirAll(parent, 0o700); err != nil {
			return "", err
		}
	} else {
		return "", err
	}
	if fi, err := os.Lstat(parent); err != nil {
		return "", err
	} else if fi.Mode()&os.ModeSymlink != 0 {
		return "", errors.New("private data directory must not be a symlink")
	}
	return parent, nil
}

// RejectSymlink returns an error if path exists and is a symbolic link.
func RejectSymlink(path string) error {
	fi, err := os.Lstat(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	if fi.Mode()&os.ModeSymlink != 0 {
		return errors.New("ledger must not be a symlink")
	}
	return nil
}

// ResolveBoltPath returns the bbolt file path for dbPath.
// If dbPath already exists and begins with the SQLite 3 header, it transparently
// selects dbPath + ".bolt" without touching the legacy SQLite database.
func ResolveBoltPath(dbPath string) (string, error) {
	if dbPath == "" {
		return "", errors.New("database path is required")
	}
	if _, err := EnsurePrivateDir(dbPath); err != nil {
		return "", err
	}
	if err := RejectSymlink(dbPath); err != nil {
		return "", err
	}

	if isSQLiteFile(dbPath) {
		boltPath := dbPath + ".bolt"
		if err := RejectSymlink(boltPath); err != nil {
			return "", err
		}
		return boltPath, nil
	}
	return dbPath, nil
}

func isSQLiteFile(path string) bool {
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()
	buf := make([]byte, len(sqliteMagic))
	n, err := io.ReadFull(f, buf)
	if err != nil && !errors.Is(err, io.ErrUnexpectedEOF) {
		return false
	}
	return n == len(sqliteMagic) && bytes.Equal(buf, sqliteMagic)
}

// ActivityBoltPath computes the scoped activity bbolt path from a resolved ledger path and scope.
func ActivityBoltPath(resolvedLedgerPath, scope string) string {
	sum := sha256.Sum256([]byte(scope))
	suffix := hex.EncodeToString(sum[:])[:12]
	return resolvedLedgerPath + ".activity-" + suffix + ".bolt"
}

func openBolt(path string, readOnly bool) (*bolt.DB, error) {
	if err := RejectSymlink(path); err != nil {
		return nil, err
	}
	opts := &bolt.Options{
		Timeout:  DefaultOpenTimeout,
		ReadOnly: readOnly,
	}
	db, err := bolt.Open(path, 0o600, opts)
	if err != nil {
		return nil, err
	}
	return db, nil
}

// CanonicalJSON serializes value as compact UTF-8 JSON with recursively sorted keys
// and HTML escaping disabled, matching Python's json.dumps(..., sort_keys=True, separators=(",",":"), ensure_ascii=False).
func CanonicalJSON(v any) ([]byte, error) {
	raw, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	var normalized any
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&normalized); err != nil {
		return nil, err
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(normalized); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(buf.Bytes(), []byte("\n")), nil
}

// NewUUIDv4 generates a canonical lowercase RFC 4122 v4 UUID string.
func NewUUIDv4() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x",
		b[0:4], b[4:6], b[6:8], b[8:10], b[10:16]), nil
}

// NewRandomHex64 generates 32 cryptographically random bytes encoded as 64 lowercase hex chars.
func NewRandomHex64() (string, error) {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(b[:]), nil
}
