// Package main is a thin process wrapper for the zero-token agent fakes.
//
// Why a binary at all: agent-state's process-tree walk identifies the agent
// by the basename of the third whitespace field of `ps -eo pid,ppid,command`
// for the pane PID (or its first child). That field is argv[0] of the
// running process, and macOS `ps -E -p <pid>` only exposes the env when the
// process was launched as a real binary with a stable argv layout. A bash
// shebang script ends up showing as `bash /path/to/script` (basename "bash")
// and `exec -a NAME ...` from inside bash hides the env from `ps -E` on
// recent macOS. A small compiled binary named `claude` (or `codex`) sidesteps
// both: `ps` shows it under its real name, `ps -E -p` shows the inherited
// env (including REN_SESSION=1 for ren variants).
//
// The binary itself is intentionally minimal — it forks /bin/bash with the
// impl script alongside it (`impl.sh` next to the binary, overrideable via
// FAKE_AGENT_IMPL) and waits. All fake-agent behavior lives in bash.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"syscall"
)

func main() {
	impl := os.Getenv("FAKE_AGENT_IMPL")
	if impl == "" {
		self, err := os.Executable()
		if err != nil {
			fmt.Fprintln(os.Stderr, "fake-agent: cannot resolve own path:", err)
			os.Exit(1)
		}
		impl = filepath.Join(filepath.Dir(self), "impl.sh")
	}

	args := append([]string{impl}, os.Args[1:]...)
	cmd := exec.Command("/bin/bash", args...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Env = os.Environ()

	if err := cmd.Start(); err != nil {
		fmt.Fprintln(os.Stderr, "fake-agent: exec failed:", err)
		os.Exit(1)
	}

	// Forward terminal-ish signals to the bash child so SIGHUP from a
	// closing pane shuts the impl down cleanly.
	sigCh := make(chan os.Signal, 4)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP, syscall.SIGQUIT)
	go func() {
		for sig := range sigCh {
			_ = cmd.Process.Signal(sig)
		}
	}()

	if err := cmd.Wait(); err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			os.Exit(exitErr.ExitCode())
		}
		fmt.Fprintln(os.Stderr, "fake-agent: wait:", err)
		os.Exit(1)
	}
}
