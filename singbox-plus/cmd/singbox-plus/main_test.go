package main

import (
	"path/filepath"
	"testing"
)

func TestRunSubcommands(t *testing.T) {
	if code := run([]string{"version"}); code != 0 {
		t.Fatalf("version exit = %d, want 0", code)
	}
	if code := run([]string{"--help"}); code != 0 {
		t.Fatalf("--help exit = %d, want 0", code)
	}
	if code := run(nil); code != 2 {
		t.Fatalf("no args exit = %d, want 2", code)
	}
	if code := run([]string{"nonexistent"}); code != 2 {
		t.Fatalf("unknown cmd exit = %d, want 2", code)
	}
	if code := run([]string{"wrap"}); code != 2 {
		t.Fatalf("wrap without args exit = %d, want 2", code)
	}
	if code := run([]string{"failover", "only-one-arg"}); code != 2 {
		t.Fatalf("failover with 1 arg exit = %d, want 2", code)
	}
	if code := run([]string{"failover", "--config", "a", "b", "c"}); code != 2 {
		t.Fatalf("failover mixing flags and positional args exit = %d, want 2", code)
	}

	missingCfg := filepath.Join(t.TempDir(), "nonexistent-ysq-agent.json")
	if code := run([]string{"agent", "status", "--config", missingCfg}); code != 0 {
		t.Fatalf("agent status (trailing --config) exit = %d, want 0", code)
	}
	if code := run([]string{"agent", "--config", missingCfg, "status"}); code != 0 {
		t.Fatalf("agent status (leading --config) exit = %d, want 0", code)
	}
	if code := run([]string{"agent", "join"}); code != 2 {
		t.Fatalf("agent join without --url/--code exit = %d, want 2", code)
	}
	if code := run([]string{"agent", "unknown"}); code != 2 {
		t.Fatalf("agent unknown subcommand exit = %d, want 2", code)
	}
}
