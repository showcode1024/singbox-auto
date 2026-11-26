//go:build unix

package agent

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

type coreProbeCache struct {
	mu     sync.Mutex
	config string
	pid    string
	epoch  string
	hits   int
}

var defaultCoreCache coreProbeCache

func probePID(procDir, bootID, pidStr, coreConfig string) string {
	entry := filepath.Join(procDir, pidStr)
	cmdBytes, err := os.ReadFile(filepath.Join(entry, "cmdline"))
	if err != nil || len(cmdBytes) == 0 {
		return ""
	}
	rawParts := bytes.Split(cmdBytes, []byte{0})
	var args []string
	for _, p := range rawParts {
		if len(p) > 0 {
			args = append(args, string(p))
		}
	}
	if len(args) == 0 || filepath.Base(args[0]) != "sing-box" {
		return ""
	}
	hasRun := false
	hasConfig := false
	for i, a := range args {
		if a == "run" {
			hasRun = true
		}
		if (a == "-c" || a == "--config") && i+1 < len(args) && args[i+1] == coreConfig {
			hasConfig = true
		}
	}
	if !hasRun || !hasConfig {
		return ""
	}

	statBytes, err := os.ReadFile(filepath.Join(entry, "stat"))
	if err != nil {
		return ""
	}
	rawStat := string(statBytes)
	closeParen := strings.LastIndexByte(rawStat, ')')
	if closeParen < 0 || closeParen+2 >= len(rawStat) {
		return ""
	}
	fields := strings.Fields(rawStat[closeParen+2:])
	if len(fields) <= 19 || fields[0] == "Z" {
		return ""
	}
	// Field 22 in /proc/<pid>/stat; fields starts at field 3 (state).
	starttime := fields[19]
	return bootID + ":" + pidStr + ":" + starttime
}

// ProbeCore identifies the running Linux sing-box process matching the configured state directory's config.json.
func ProbeCore(cfg map[string]any, verifyOnly bool) (string, error) {
	const procDir = "/proc"
	bootBytes, err := os.ReadFile(filepath.Join(procDir, "sys/kernel/random/boot_id"))
	if err != nil {
		return "", collectorErr("cannot read Linux boot identity")
	}
	bootID := strings.TrimSpace(string(bootBytes))
	statePath := mapString(cfg, "state_path", DefaultStatePath())
	coreConfig := filepath.Join(filepath.Dir(statePath), "config.json")

	defaultCoreCache.mu.Lock()
	cCfg, cPID, cEpoch, cHits := defaultCoreCache.config, defaultCoreCache.pid, defaultCoreCache.epoch, defaultCoreCache.hits
	defaultCoreCache.mu.Unlock()

	if cCfg == coreConfig && cPID != "" && cEpoch != "" && (verifyOnly || cHits < 10) {
		if epoch := probePID(procDir, bootID, cPID, coreConfig); epoch == cEpoch {
			if !verifyOnly {
				defaultCoreCache.mu.Lock()
				if defaultCoreCache.config == coreConfig && defaultCoreCache.pid == cPID && defaultCoreCache.epoch == cEpoch {
					defaultCoreCache.hits++
				}
				defaultCoreCache.mu.Unlock()
			}
			return epoch, nil
		}
	}

	entries, err := os.ReadDir(procDir)
	if err != nil {
		return "", collectorErr("cannot scan /proc")
	}
	type candidate struct {
		pid   string
		epoch string
	}
	var candidates []candidate
	for _, entry := range entries {
		name := entry.Name()
		if !isAllDigits(name) {
			continue
		}
		if epoch := probePID(procDir, bootID, name, coreConfig); epoch != "" {
			candidates = append(candidates, candidate{pid: name, epoch: epoch})
		}
	}

	if len(candidates) == 0 {
		defaultCoreCache.mu.Lock()
		if defaultCoreCache.config == coreConfig {
			defaultCoreCache.config, defaultCoreCache.pid, defaultCoreCache.epoch, defaultCoreCache.hits = "", "", "", 0
		}
		defaultCoreCache.mu.Unlock()
		return "", collectorErr("sing-box is not running with the expected configuration")
	}
	if len(candidates) != 1 {
		defaultCoreCache.mu.Lock()
		if defaultCoreCache.config == coreConfig {
			defaultCoreCache.config, defaultCoreCache.pid, defaultCoreCache.epoch, defaultCoreCache.hits = "", "", "", 0
		}
		defaultCoreCache.mu.Unlock()
		return "", collectorErr("multiple sing-box processes use the expected configuration")
	}

	chosen := candidates[0]
	defaultCoreCache.mu.Lock()
	defaultCoreCache.config = coreConfig
	defaultCoreCache.pid = chosen.pid
	defaultCoreCache.epoch = chosen.epoch
	defaultCoreCache.hits = 0
	defaultCoreCache.mu.Unlock()
	return chosen.epoch, nil
}

func isAllDigits(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}
