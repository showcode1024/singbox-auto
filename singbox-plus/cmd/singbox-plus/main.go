package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"time"

	"github.com/showcode1024/singbox-auto/singbox-plus/internal/agent"
	"github.com/showcode1024/singbox-auto/singbox-plus/internal/failover"
	"github.com/showcode1024/singbox-auto/singbox-plus/internal/landing"
	"github.com/showcode1024/singbox-auto/singbox-plus/internal/logrot"
	"github.com/showcode1024/singbox-auto/singbox-plus/internal/store"
	"github.com/showcode1024/singbox-auto/singbox-plus/internal/v2stats"
)

// Version is overridden at build time via -ldflags "-X main.Version=...".
var Version = "dev"

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	if len(args) == 0 {
		printUsage(os.Stderr)
		return 2
	}

	switch args[0] {
	case "-h", "--help", "help":
		printUsage(os.Stdout)
		return 0
	case "version":
		fmt.Printf("singbox-plus %s\n", Version)
		return 0
	case "wrap":
		return runWrap(args[1:])
	case "stats":
		return runStats(args[1:])
	case "parse-landing":
		return runParseLanding(args[1:])
	case "failover":
		return runFailover(args[1:])
	case "agent":
		return runAgent(args[1:])
	default:
		fmt.Fprintf(os.Stderr, "unknown subcommand: %s\n\n", args[0])
		printUsage(os.Stderr)
		return 2
	}
}

func printUsage(w io.Writer) {
	fmt.Fprintf(w, `Usage: singbox-plus <command> [options]

Commands:
  version                                 Print binary version
  wrap --dir <dir> [opts] -- <cmd> [...]  Wrap a child process with line-boundary log rotation
  stats [opts]                            Query sing-box V2Ray StatsService via plaintext h2c gRPC
  parse-landing [--json]                  Parse and validate landing share URI or JSON from stdin
  failover [opts] | <config> <status>     Run primary/backup landing failover monitor
  agent [opts] <subcommand> [sub-flags]   Run or manage the YSQ HTTPS center node agent

Run "singbox-plus <command> -h" for command-specific options.
`)
}

func runWrap(args []string) int {
	fs := flag.NewFlagSet("wrap", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	dir := fs.String("dir", "", "log output directory (required)")
	name := fs.String("name", logrot.DefaultName, "active log filename")
	maxStr := fs.String("max", "4M", "rotate active file at or above this size (e.g. 64K, 4M)")
	keep := fs.Int("keep", logrot.DefaultKeep, "maximum number of rotated log files to retain")

	if err := fs.Parse(args); err != nil {
		if err == flag.ErrHelp {
			return 0
		}
		return 2
	}
	cmdArgs := fs.Args()
	if *dir == "" || len(cmdArgs) == 0 {
		fmt.Fprintln(os.Stderr, "wrap requires --dir <dir> and a command after --")
		fs.Usage()
		return 2
	}
	maxBytes, err := logrot.ParseSize(*maxStr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "invalid --max value: %v\n", err)
		return 2
	}
	if *keep < 0 {
		fmt.Fprintln(os.Stderr, "--keep must be >= 0")
		return 2
	}

	code, err := logrot.Run(logrot.Options{
		Dir:      *dir,
		Name:     *name,
		MaxBytes: maxBytes,
		Keep:     *keep,
	}, cmdArgs)
	if err != nil {
		fmt.Fprintf(os.Stderr, "wrap: %v\n", err)
	}
	return code
}

func runStats(args []string) int {
	fs := flag.NewFlagSet("stats", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	addr := fs.String("addr", v2stats.DefaultAddr, "V2Ray API host:port")
	timeout := fs.Duration("timeout", 5*time.Second, "gRPC request timeout")

	if err := fs.Parse(args); err != nil {
		if err == flag.ErrHelp {
			return 0
		}
		return 2
	}
	if fs.NArg() != 0 {
		fmt.Fprintln(os.Stderr, "stats accepts no positional arguments")
		return 2
	}
	if *timeout <= 0 {
		fmt.Fprintln(os.Stderr, "--timeout must be positive")
		return 2
	}

	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()

	resp, err := v2stats.Query(ctx, *addr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "stats: %v\n", err)
		return 1
	}
	raw, err := resp.MarshalJSONBytes()
	if err != nil {
		fmt.Fprintf(os.Stderr, "stats: encode json: %v\n", err)
		return 1
	}
	fmt.Println(string(raw))
	return 0
}

func runParseLanding(args []string) int {
	fs := flag.NewFlagSet("parse-landing", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	asJSON := fs.Bool("json", false, "parse stdin as landing JSON object instead of share URI")

	if err := fs.Parse(args); err != nil {
		if err == flag.ErrHelp {
			return 0
		}
		return 2
	}
	if fs.NArg() != 0 {
		fmt.Fprintln(os.Stderr, "parse-landing accepts no positional arguments")
		return 2
	}
	return landing.Run(os.Stdin, os.Stdout, os.Stderr, *asJSON)
}

func runFailover(args []string) int {
	fs := flag.NewFlagSet("failover", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	cfgFlag := fs.String("config", failover.DefaultConfigPath, "sing-box config.json path")
	statusFlag := fs.String("status", failover.DefaultStatusPath, "failover status.json output path")

	if err := fs.Parse(args); err != nil {
		if err == flag.ErrHelp {
			return 0
		}
		return 2
	}

	setFlags := map[string]bool{}
	fs.Visit(func(f *flag.Flag) {
		setFlags[f.Name] = true
	})

	cfgPath := *cfgFlag
	statusPath := *statusFlag

	switch fs.NArg() {
	case 0:
	case 2:
		if setFlags["config"] || setFlags["status"] {
			fmt.Fprintln(os.Stderr, "failover: do not mix --config/--status flags with positional arguments")
			return 2
		}
		cfgPath = fs.Arg(0)
		statusPath = fs.Arg(1)
	default:
		fmt.Fprintln(os.Stderr, "failover accepts either --config/--status flags or 2 positional arguments <config> <status>")
		fs.Usage()
		return 2
	}

	ctx, stop := signal.NotifyContext(context.Background(), shutdownSignals()...)
	defer stop()

	mon := failover.NewMonitor(cfgPath, statusPath)
	if err := mon.Run(ctx); err != nil {
		fmt.Fprintf(os.Stderr, "failover: %v\n", err)
		return 1
	}
	return 0
}

func runAgent(args []string) int {
	setPrivateUmask()

	fs := flag.NewFlagSet("agent", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	cfgPath := agent.DefaultConfigPath()
	allowLoopback := false
	var timeout time.Duration

	fs.StringVar(&cfgPath, "config", cfgPath, "agent config.json path")
	fs.BoolVar(&allowLoopback, "allow-loopback-http", false, "test-only: allow HTTP on loopback")
	fs.DurationVar(&timeout, "timeout", 0, "optional overall timeout for one-shot commands")
	fs.Usage = func() {
		fmt.Fprintf(os.Stderr, `Usage: singbox-plus agent [--config <path>] [--allow-loopback-http] [--timeout <dur>] <subcommand> [sub-flags]

Subcommands:
  run                           Run the continuous agent daemon
  status                        Print agent & ledger status JSON
  sync-once                     Run one forced-package sync round
  sample-once                   Collect one traffic counter sample
  join --url <u..> --code <c..> Enroll node with center server
  detach [--force]              Detach node from center server
`)
	}

	if err := fs.Parse(args); err != nil {
		if err == flag.ErrHelp {
			return 0
		}
		return 2
	}
	rem := fs.Args()
	if len(rem) == 0 {
		fs.Usage()
		return 2
	}

	subcmd := rem[0]
	subArgs := rem[1:]

	// Also allow global agent flags after the subcommand (e.g. "agent status --config ...").
	subFS := flag.NewFlagSet("agent "+subcmd, flag.ContinueOnError)
	subFS.SetOutput(os.Stderr)
	subFS.StringVar(&cfgPath, "config", cfgPath, "agent config.json path")
	subFS.BoolVar(&allowLoopback, "allow-loopback-http", allowLoopback, "test-only: allow HTTP on loopback")
	subFS.DurationVar(&timeout, "timeout", timeout, "optional overall timeout for one-shot commands")

	var joinURL, joinCode, joinName, joinScript string
	var detachForce bool
	switch subcmd {
	case "run", "status", "sync-once", "sample-once":
	case "join":
		subFS.StringVar(&joinURL, "url", "", "center HTTPS origin URL (required)")
		subFS.StringVar(&joinCode, "code", "", "one-time join code (required)")
		subFS.StringVar(&joinName, "name", "", "optional node display/host name")
		subFS.StringVar(&joinScript, "script", "", "optional installer script path")
	case "detach":
		subFS.BoolVar(&detachForce, "force", false, "force local detachment even if center cannot confirm")
	default:
		fmt.Fprintf(os.Stderr, "unknown agent subcommand: %s\n", subcmd)
		fs.Usage()
		return 2
	}

	if err := subFS.Parse(subArgs); err != nil {
		if err == flag.ErrHelp {
			return 0
		}
		return 2
	}
	if subFS.NArg() != 0 {
		fmt.Fprintf(os.Stderr, "agent %s accepts no positional arguments\n", subcmd)
		return 2
	}
	if timeout < 0 {
		fmt.Fprintln(os.Stderr, "--timeout cannot be negative")
		return 2
	}
	if subcmd == "join" && (joinURL == "" || joinCode == "") {
		fmt.Fprintln(os.Stderr, "agent join requires --url and --code")
		return 2
	}

	baseCtx := context.Background()
	var cancel context.CancelFunc
	if subcmd == "run" {
		baseCtx, cancel = signal.NotifyContext(baseCtx, shutdownSignals()...)
	} else if timeout > 0 {
		baseCtx, cancel = context.WithTimeout(baseCtx, timeout)
	} else {
		baseCtx, cancel = context.WithCancel(baseCtx)
	}
	defer cancel()

	opts := agent.Options{
		AllowLoopbackHTTP: allowLoopback,
		Version:           Version,
		Stderr:            os.Stderr,
	}

	logErr := func(err error) int {
		cfg, _ := agent.ReadJSONMap(cfgPath)
		agent.Log(os.Stderr, err.Error(), cfg)
		return 1
	}

	var result any
	var err error

	switch subcmd {
	case "join":
		result, err = agent.Join(baseCtx, cfgPath, joinURL, joinCode, joinName, joinScript, opts)
	case "status":
		if _, statErr := os.Stat(cfgPath); errors.Is(statErr, os.ErrNotExist) {
			result = map[string]any{
				"configured": false,
				"status":     "standalone",
				"version":    Version,
			}
		} else {
			var ag *agent.Agent
			ag, err = agent.New(cfgPath, opts)
			if err == nil {
				result, err = ag.Status()
			}
		}
	case "run":
		var ag *agent.Agent
		ag, err = agent.New(cfgPath, opts)
		if err != nil {
			return logErr(err)
		}
		if err := ag.Run(baseCtx); err != nil {
			return logErr(err)
		}
		return 0
	case "sample-once":
		var ag *agent.Agent
		ag, err = agent.New(cfgPath, opts)
		if err == nil {
			result, err = ag.SampleOnce(baseCtx, false)
		}
	case "sync-once":
		var ag *agent.Agent
		ag, err = agent.New(cfgPath, opts)
		if err == nil {
			result, err = ag.SyncOnce(baseCtx, true, true)
		}
	case "detach":
		var ag *agent.Agent
		ag, err = agent.New(cfgPath, opts)
		if err == nil {
			result, err = ag.Detach(baseCtx, detachForce)
		}
	}

	if err != nil {
		return logErr(err)
	}

	raw, err := store.CanonicalJSON(result)
	if err != nil {
		return logErr(err)
	}
	fmt.Println(string(raw))
	return 0
}
