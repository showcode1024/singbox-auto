package logrot

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	// DefaultName is the default active log filename.
	DefaultName = "sing-box.log"
	// DefaultMaxBytes is the default rotation threshold (4 MiB).
	DefaultMaxBytes int64 = 4 << 20
	// DefaultKeep is the default number of rotated files to retain.
	DefaultKeep = 2
	// MaxLineBytes caps a single unbroken line to bound memory usage (64 KiB).
	MaxLineBytes = 64 * 1024
)

// Options configures log rotation and child process wrapping.
type Options struct {
	Dir      string
	Name     string
	MaxBytes int64
	Keep     int
	Now      func() time.Time
}

// ParseSize parses a positive byte size with an optional K/KiB/M/MiB/G/GiB suffix.
func ParseSize(raw string) (int64, error) {
	s := strings.TrimSpace(raw)
	if s == "" {
		return 0, errors.New("size cannot be empty")
	}

	i := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		i++
	}
	if i == 0 {
		return 0, fmt.Errorf("invalid size %q", raw)
	}

	numPart := s[:i]
	unitPart := strings.ToLower(strings.TrimSpace(s[i:]))

	var mult int64
	switch unitPart {
	case "", "b":
		mult = 1
	case "k", "kb", "kib":
		mult = 1 << 10
	case "m", "mb", "mib":
		mult = 1 << 20
	case "g", "gb", "gib":
		mult = 1 << 30
	default:
		return 0, fmt.Errorf("unsupported size unit %q", s[i:])
	}

	n, err := strconv.ParseInt(numPart, 10, 64)
	if err != nil || n <= 0 {
		return 0, fmt.Errorf("invalid size %q", raw)
	}
	if n > math.MaxInt64/mult {
		return 0, fmt.Errorf("size %q overflows int64", raw)
	}
	return n * mult, nil
}

// Writer writes lines to an active log file and rotates it atomically when size >= MaxBytes.
type Writer struct {
	dir      string
	name     string
	base     string
	ext      string
	maxBytes int64
	keep     int
	now      func() time.Time

	file    *os.File
	size    int64
	lastTS  string
	lastSeq int
}

// NewWriter initializes the log directory, rotates an already oversized active file,
// and opens the active log file for appending.
func NewWriter(opts Options) (*Writer, error) {
	if strings.TrimSpace(opts.Dir) == "" {
		return nil, errors.New("log directory is required")
	}
	name := opts.Name
	if name == "" {
		name = DefaultName
	}
	if name == "." || name == ".." || filepath.Base(name) != name || strings.ContainsAny(name, `/\`) {
		return nil, fmt.Errorf("invalid log filename %q", name)
	}
	maxBytes := opts.MaxBytes
	if maxBytes == 0 {
		maxBytes = DefaultMaxBytes
	}
	if maxBytes < 0 {
		return nil, errors.New("max size must be positive")
	}
	if opts.Keep < 0 {
		return nil, errors.New("keep count cannot be negative")
	}
	nowFn := opts.Now
	if nowFn == nil {
		nowFn = time.Now
	}

	ext := filepath.Ext(name)
	base := strings.TrimSuffix(name, ext)
	if base == "" {
		base = name
		ext = ""
	}

	if err := os.MkdirAll(opts.Dir, 0o755); err != nil {
		return nil, fmt.Errorf("create log dir: %w", err)
	}

	w := &Writer{
		dir:      opts.Dir,
		name:     name,
		base:     base,
		ext:      ext,
		maxBytes: maxBytes,
		keep:     opts.Keep,
		now:      nowFn,
	}

	activePath := w.activePath()
	if fi, err := os.Stat(activePath); err == nil {
		if fi.IsDir() {
			return nil, fmt.Errorf("log path %q is a directory", activePath)
		}
		if fi.Size() >= w.maxBytes {
			if err := w.renameActive(); err != nil {
				return nil, err
			}
			if err := w.prune(); err != nil {
				return nil, err
			}
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("stat active log: %w", err)
	}

	if err := w.openActive(); err != nil {
		return nil, err
	}
	return w, nil
}

func (w *Writer) activePath() string {
	return filepath.Join(w.dir, w.name)
}

func (w *Writer) openActive() error {
	f, err := os.OpenFile(w.activePath(), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o640)
	if err != nil {
		return fmt.Errorf("open active log: %w", err)
	}
	fi, err := f.Stat()
	if err != nil {
		_ = f.Close()
		return fmt.Errorf("stat opened log: %w", err)
	}
	w.file = f
	w.size = fi.Size()
	return nil
}

func (w *Writer) nextRotatedPath() (string, error) {
	ts := w.now().UTC().Format("20060102-150405")
	seq := 1
	if ts == w.lastTS {
		seq = w.lastSeq + 1
	}

	prefix := w.base + "." + ts + "-"
	entries, err := os.ReadDir(w.dir)
	if err != nil {
		return "", fmt.Errorf("read log dir: %w", err)
	}
	for _, entry := range entries {
		ename := entry.Name()
		if !strings.HasPrefix(ename, prefix) || !strings.HasSuffix(ename, w.ext) {
			continue
		}
		numStr := strings.TrimSuffix(strings.TrimPrefix(ename, prefix), w.ext)
		if n, convErr := strconv.Atoi(numStr); convErr == nil && n >= seq {
			seq = n + 1
		}
	}

	for {
		candidateName := fmt.Sprintf("%s.%s-%04d%s", w.base, ts, seq, w.ext)
		candidatePath := filepath.Join(w.dir, candidateName)
		if _, err := os.Lstat(candidatePath); errors.Is(err, os.ErrNotExist) {
			w.lastTS = ts
			w.lastSeq = seq
			return candidatePath, nil
		}
		seq++
	}
}

func (w *Writer) renameActive() error {
	target, err := w.nextRotatedPath()
	if err != nil {
		return err
	}
	if err := os.Rename(w.activePath(), target); err != nil {
		return fmt.Errorf("rotate log: %w", err)
	}
	return nil
}

func (w *Writer) rotate() error {
	if w.file != nil {
		if err := w.file.Sync(); err != nil {
			_ = w.file.Close()
			w.file = nil
			return fmt.Errorf("sync active log: %w", err)
		}
		if err := w.file.Close(); err != nil {
			w.file = nil
			return fmt.Errorf("close active log: %w", err)
		}
		w.file = nil
	}
	if err := w.renameActive(); err != nil {
		return err
	}
	if err := w.prune(); err != nil {
		return err
	}
	return w.openActive()
}

func (w *Writer) prune() error {
	entries, err := os.ReadDir(w.dir)
	if err != nil {
		return fmt.Errorf("read log dir for prune: %w", err)
	}

	prefix := w.base + "."
	minLen := len(prefix) + len(w.ext) + 1
	var rotated []string
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		ename := entry.Name()
		if ename == w.name || len(ename) < minLen {
			continue
		}
		if strings.HasPrefix(ename, prefix) && strings.HasSuffix(ename, w.ext) {
			rotated = append(rotated, ename)
		}
	}
	if len(rotated) <= w.keep {
		return nil
	}
	sort.Strings(rotated)
	toDelete := rotated[:len(rotated)-w.keep]
	for _, ename := range toDelete {
		if err := os.Remove(filepath.Join(w.dir, ename)); err != nil && !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("remove rotated log %s: %w", ename, err)
		}
	}
	return nil
}

func (w *Writer) writeBytes(p []byte) error {
	if len(p) == 0 {
		return nil
	}
	n, err := w.file.Write(p)
	w.size += int64(n)
	return err
}

// WriteLine writes a line (or final partial line) and rotates after any newline-terminated line
// that brings the active file size to or above MaxBytes.
func (w *Writer) WriteLine(line []byte) error {
	if len(line) == 0 {
		return nil
	}
	if err := w.writeBytes(line); err != nil {
		return err
	}
	if line[len(line)-1] == '\n' && w.size >= w.maxBytes {
		return w.rotate()
	}
	return nil
}

// CopyLines copies all lines from r into w, capping any unbroken line at MaxLineBytes (64 KiB)
// by flushing it with a trailing newline so memory stays bounded.
func (w *Writer) CopyLines(r io.Reader) error {
	br := bufio.NewReaderSize(r, MaxLineBytes)
	nl := []byte{'\n'}
	for {
		line, err := br.ReadSlice('\n')
		switch {
		case err == nil:
			if werr := w.WriteLine(line); werr != nil {
				return werr
			}
		case errors.Is(err, bufio.ErrBufferFull):
			if werr := w.writeBytes(line); werr != nil {
				return werr
			}
			if werr := w.writeBytes(nl); werr != nil {
				return werr
			}
			if w.size >= w.maxBytes {
				if rerr := w.rotate(); rerr != nil {
					return rerr
				}
			}
		case errors.Is(err, io.EOF):
			if len(line) > 0 {
				if werr := w.writeBytes(line); werr != nil {
					return werr
				}
				if line[len(line)-1] != '\n' {
					if werr := w.writeBytes(nl); werr != nil {
						return werr
					}
				}
				if w.size >= w.maxBytes {
					if rerr := w.rotate(); rerr != nil {
						return rerr
					}
				}
			}
			return nil
		default:
			if len(line) > 0 {
				_ = w.WriteLine(line)
			}
			return err
		}
	}
}

// Close syncs and closes the active log file.
func (w *Writer) Close() error {
	if w.file == nil {
		return nil
	}
	f := w.file
	w.file = nil
	syncErr := f.Sync()
	closeErr := f.Close()
	if syncErr != nil {
		return syncErr
	}
	return closeErr
}

// Run spawns args[0] with args[1:], merges its stdout and stderr into a rotating log file,
// forwards termination signals, drains all output on exit, and returns the child's exit code.
func Run(opts Options, args []string) (int, error) {
	if len(args) == 0 {
		return 2, errors.New("command is required")
	}

	w, err := NewWriter(opts)
	if err != nil {
		return 1, err
	}

	pr, pw, err := os.Pipe()
	if err != nil {
		_ = w.Close()
		return 1, fmt.Errorf("create pipe: %w", err)
	}

	cmd := exec.Command(args[0], args[1:]...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = pw
	cmd.Stderr = pw

	if err := cmd.Start(); err != nil {
		_ = pw.Close()
		_ = pr.Close()
		_ = w.Close()
		return 1, fmt.Errorf("start command: %w", err)
	}
	// Close parent's write end so pr receives EOF once child exits.
	_ = pw.Close()

	stopSignals := forwardSignals(cmd.Process)
	if copyErr := w.CopyLines(pr); copyErr != nil {
		fmt.Fprintf(os.Stderr, "wrap: log write failed, draining remaining output: %v\n", copyErr)
		_, _ = io.Copy(io.Discard, pr)
	}
	_ = pr.Close()

	waitErr := cmd.Wait()
	stopSignals()

	if closeErr := w.Close(); closeErr != nil {
		fmt.Fprintf(os.Stderr, "wrap: close log failed: %v\n", closeErr)
	}
	if waitErr != nil {
		var exitErr *exec.ExitError
		if errors.As(waitErr, &exitErr) {
			return exitCodeFromError(exitErr), nil
		}
		return 1, waitErr
	}
	return 0, nil
}
