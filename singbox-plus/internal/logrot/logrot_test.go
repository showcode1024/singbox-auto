package logrot

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestParseSize(t *testing.T) {
	cases := []struct {
		in      string
		want    int64
		wantErr bool
	}{
		{"1024", 1024, false},
		{"1024B", 1024, false},
		{"64K", 64 << 10, false},
		{"64kib", 64 << 10, false},
		{"4M", 4 << 20, false},
		{"4MiB", 4 << 20, false},
		{"2g", 2 << 30, false},
		{"1GiB", 1 << 30, false},
		{"", 0, true},
		{"0", 0, true},
		{"-4M", 0, true},
		{"4T", 0, true},
		{"abc", 0, true},
		{"99999999999999999G", 0, true},
	}

	for _, tc := range cases {
		got, err := ParseSize(tc.in)
		if tc.wantErr {
			if err == nil {
				t.Errorf("ParseSize(%q) expected error, got %d", tc.in, got)
			}
			continue
		}
		if err != nil {
			t.Errorf("ParseSize(%q) unexpected error: %v", tc.in, err)
			continue
		}
		if got != tc.want {
			t.Errorf("ParseSize(%q) = %d, want %d", tc.in, got, tc.want)
		}
	}
}

func TestRotationLineBoundaryAndSameSecondCollision(t *testing.T) {
	dir := t.TempDir()
	fixedTime := time.Date(2026, 11, 26, 10, 55, 0, 0, time.UTC)

	w, err := NewWriter(Options{
		Dir:      dir,
		Name:     "sing-box.log",
		MaxBytes: 20,
		Keep:     5,
		Now:      func() time.Time { return fixedTime },
	})
	if err != nil {
		t.Fatalf("NewWriter: %v", err)
	}

	input := strings.Join([]string{
		"line-00001", // 11 bytes (below 20)
		"line-00002", // +11 = 22 bytes >= 20 -> rotate #1
		"line-00003", // 11 bytes
		"line-00004", // +11 = 22 bytes >= 20 -> rotate #2 (same second!)
		"line-00005", // 11 bytes (remains in active)
	}, "\n") + "\n"

	if err := w.CopyLines(strings.NewReader(input)); err != nil {
		t.Fatalf("CopyLines: %v", err)
	}
	if err := w.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	r1 := filepath.Join(dir, "sing-box.20261126-105500-0001.log")
	r2 := filepath.Join(dir, "sing-box.20261126-105500-0002.log")
	active := filepath.Join(dir, "sing-box.log")

	b1, err := os.ReadFile(r1)
	if err != nil {
		t.Fatalf("read first rotated file: %v", err)
	}
	if string(b1) != "line-00001\nline-00002\n" {
		t.Errorf("r1 content = %q", string(b1))
	}

	b2, err := os.ReadFile(r2)
	if err != nil {
		t.Fatalf("read second rotated file: %v", err)
	}
	if string(b2) != "line-00003\nline-00004\n" {
		t.Errorf("r2 content = %q", string(b2))
	}

	ba, err := os.ReadFile(active)
	if err != nil {
		t.Fatalf("read active file: %v", err)
	}
	if string(ba) != "line-00005\n" {
		t.Errorf("active content = %q", string(ba))
	}
}

func TestPruningToKeep(t *testing.T) {
	dir := t.TempDir()
	fixedTime := time.Date(2026, 11, 26, 10, 55, 0, 0, time.UTC)

	w, err := NewWriter(Options{
		Dir:      dir,
		Name:     "sing-box.log",
		MaxBytes: 10,
		Keep:     2,
		Now:      func() time.Time { return fixedTime },
	})
	if err != nil {
		t.Fatalf("NewWriter: %v", err)
	}

	for i := 1; i <= 5; i++ {
		line := fmt.Sprintf("entry-%04d\n", i) // 11 bytes >= 10 -> rotates every line
		if err := w.WriteLine([]byte(line)); err != nil {
			t.Fatalf("WriteLine %d: %v", i, err)
		}
	}
	if err := w.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("ReadDir: %v", err)
	}
	var names []string
	for _, e := range entries {
		names = append(names, e.Name())
	}
	sort.Strings(names)

	want := []string{
		"sing-box.20261126-105500-0004.log",
		"sing-box.20261126-105500-0005.log",
		"sing-box.log",
	}
	if strings.Join(names, ",") != strings.Join(want, ",") {
		t.Fatalf("files = %v, want %v", names, want)
	}
}

func TestStartupRotationOfOversizedFile(t *testing.T) {
	dir := t.TempDir()
	fixedTime := time.Date(2026, 11, 26, 10, 55, 0, 0, time.UTC)

	active := filepath.Join(dir, "sing-box.log")
	// Pre-seed an oversized active file and a same-second rotated file to verify collision avoidance across restarts.
	existingRotated := filepath.Join(dir, "sing-box.20261126-105500-0001.log")
	if err := os.WriteFile(existingRotated, []byte("older\n"), 0o640); err != nil {
		t.Fatalf("seed rotated: %v", err)
	}
	if err := os.WriteFile(active, []byte("already-oversized-content\n"), 0o640); err != nil {
		t.Fatalf("seed active: %v", err)
	}

	w, err := NewWriter(Options{
		Dir:      dir,
		Name:     "sing-box.log",
		MaxBytes: 10,
		Keep:     2,
		Now:      func() time.Time { return fixedTime },
	})
	if err != nil {
		t.Fatalf("NewWriter: %v", err)
	}
	if err := w.WriteLine([]byte("new\n")); err != nil {
		t.Fatalf("WriteLine: %v", err)
	}
	if err := w.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	rotated2 := filepath.Join(dir, "sing-box.20261126-105500-0002.log")
	gotRotated, err := os.ReadFile(rotated2)
	if err != nil {
		t.Fatalf("expected startup-rotated file %s: %v", rotated2, err)
	}
	if string(gotRotated) != "already-oversized-content\n" {
		t.Errorf("rotated content = %q", string(gotRotated))
	}

	gotActive, err := os.ReadFile(active)
	if err != nil {
		t.Fatalf("read active: %v", err)
	}
	if string(gotActive) != "new\n" {
		t.Errorf("active content = %q, want %q", string(gotActive), "new\n")
	}
}

func TestLongLineTruncationAt64KiB(t *testing.T) {
	dir := t.TempDir()
	w, err := NewWriter(Options{
		Dir:      dir,
		Name:     "sing-box.log",
		MaxBytes: 1 << 20,
		Keep:     2,
	})
	if err != nil {
		t.Fatalf("NewWriter: %v", err)
	}

	longPayload := append(bytes.Repeat([]byte("A"), MaxLineBytes+100), '\n')
	if err := w.CopyLines(bytes.NewReader(longPayload)); err != nil {
		t.Fatalf("CopyLines: %v", err)
	}
	if err := w.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	got, err := os.ReadFile(filepath.Join(dir, "sing-box.log"))
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	lines := bytes.Split(bytes.TrimSuffix(got, []byte("\n")), []byte("\n"))
	if len(lines) != 2 {
		t.Fatalf("expected 2 flushed lines for >64KiB unbroken line, got %d", len(lines))
	}
	if len(lines[0]) != MaxLineBytes {
		t.Errorf("first line len = %d, want %d", len(lines[0]), MaxLineBytes)
	}
	if len(lines[1]) != 100 {
		t.Errorf("second line len = %d, want 100", len(lines[1]))
	}
}

func TestPartialLineEOFAppendsNewline(t *testing.T) {
	dir := t.TempDir()
	w1, err := NewWriter(Options{
		Dir:      dir,
		Name:     "sing-box.log",
		MaxBytes: 1024,
		Keep:     2,
	})
	if err != nil {
		t.Fatalf("NewWriter 1: %v", err)
	}
	if err := w1.CopyLines(strings.NewReader("line1\npartial-without-newline")); err != nil {
		t.Fatalf("CopyLines 1: %v", err)
	}
	if err := w1.Close(); err != nil {
		t.Fatalf("Close 1: %v", err)
	}

	// Simulate restart appending a new line to the same active log file.
	w2, err := NewWriter(Options{
		Dir:      dir,
		Name:     "sing-box.log",
		MaxBytes: 1024,
		Keep:     2,
	})
	if err != nil {
		t.Fatalf("NewWriter 2: %v", err)
	}
	if err := w2.CopyLines(strings.NewReader("after-restart\n")); err != nil {
		t.Fatalf("CopyLines 2: %v", err)
	}
	if err := w2.Close(); err != nil {
		t.Fatalf("Close 2: %v", err)
	}

	got, err := os.ReadFile(filepath.Join(dir, "sing-box.log"))
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	want := "line1\npartial-without-newline\nafter-restart\n"
	if string(got) != want {
		t.Fatalf("content = %q, want %q", string(got), want)
	}
}

func TestRunExitCodePropagationAndMergedStreams(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("GO_WANT_LOGROT_HELPER", "1")
	t.Setenv("GO_LOGROT_EXIT_CODE", "42")

	code, err := Run(Options{
		Dir:      dir,
		Name:     "sing-box.log",
		MaxBytes: 1024,
		Keep:     2,
	}, []string{os.Args[0], "-test.run=TestHelperProcessLogrot"})
	if err != nil {
		t.Fatalf("Run returned unexpected error: %v", err)
	}
	if code != 42 {
		t.Fatalf("exit code = %d, want 42", code)
	}

	got, err := os.ReadFile(filepath.Join(dir, "sing-box.log"))
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	s := string(got)
	if !strings.Contains(s, "helper-stdout-line") || !strings.Contains(s, "helper-stderr-line") {
		t.Fatalf("expected both stdout and stderr in log, got %q", s)
	}
}

func TestHelperProcessLogrot(t *testing.T) {
	if os.Getenv("GO_WANT_LOGROT_HELPER") != "1" {
		return
	}
	_, _ = fmt.Fprintln(os.Stdout, "helper-stdout-line")
	_, _ = fmt.Fprintln(os.Stderr, "helper-stderr-line")
	code, _ := strconv.Atoi(os.Getenv("GO_LOGROT_EXIT_CODE"))
	os.Exit(code)
}
