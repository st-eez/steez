package main

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"

	"github.com/st-eez/steez/internal/config"
)

const version = "1.0.0"

func main() {
	if len(os.Args) < 2 {
		printHelp()
		os.Exit(0)
	}

	cmd := os.Args[1]
	args := os.Args[2:]

	switch cmd {
	case "setup":
		cmdSetup(args)
	case "install":
		os.Exit(cmdInstall(args))
	case "uninstall":
		os.Exit(cmdUninstall(args))
	case "list":
		os.Exit(cmdList(args))
	case "info":
		os.Exit(cmdInfo(args))
	case "doctor":
		os.Exit(cmdDoctor(args))
	case "update":
		cmdUpdate(args)
	case "version":
		cmdVersion()
	case "help":
		if len(args) > 0 {
			printCommandHelp(args[0])
		} else {
			printHelp()
		}
	default:
		fmt.Fprintf(os.Stderr, "Unknown command %q. Run steez help for usage.\n", cmd)
		os.Exit(1)
	}
}

func printHelp() {
	fmt.Print(`steez — Claude Code skill installer

Usage: steez <command> [flags] [args]

Commands:
  setup       Launch interactive TUI setup flow
  install     Install skills (by name or profile)
  uninstall   Remove installed skills
  list        Show installed skills
  info        Show skill details from manifest
  doctor      Validate install health
  update      Update steez (git pull + re-link)
  version     Print version info
  help        Show this help (or help <command>)

Run steez help <command> for detailed usage.
`)
}

func printCommandHelp(cmd string) {
	switch cmd {
	case "install":
		fmt.Print(`steez install — install skills

Usage:
  steez install starter                    Install Starter Kit profile
  steez install all                        Install all skills
  steez install office-hours ship review   Install specific skills

Flags:
  --dry-run   Show what would be created without making changes
  --force     Overwrite existing symlinks
  --browse    Also build the browse binary after install
  --repo      Override repo path (default: from config or ~/Projects/Personal/steez)
`)
	case "uninstall":
		fmt.Print(`steez uninstall — remove installed skills

Usage:
  steez uninstall qa benchmark    Remove specific skills
  steez uninstall --all           Remove ALL steez-managed symlinks

Only removes symlinks tracked in installed.json.
`)
	case "doctor":
		fmt.Print(`steez doctor — validate install health

Usage:
  steez doctor         Check all symlinks, dirs, and registry
  steez doctor --fix   Auto-repair what it can

Exit codes: 0 = all pass, 1 = failures, 2 = warnings only
`)
	case "info":
		fmt.Print(`steez info — show skill details

Usage:
  steez info <skill>   Show name, category, description, requirements

Supports fuzzy matching: if no exact match, suggests close names.
`)
	case "list":
		fmt.Print(`steez list — show installed skills

Usage:
  steez list   Show all skills from installed.json with status
`)
	case "setup":
		fmt.Print(`steez setup — interactive TUI setup

Usage:
  steez setup   Launch Bubble Tea TUI for guided installation
`)
	case "update":
		fmt.Print(`steez update — update steez

Usage:
  steez update   Pull latest from git and re-link symlinks
`)
	case "version":
		fmt.Print(`steez version — print version info

Shows steez version, Go version, OS/arch, and repo path.
`)
	default:
		fmt.Fprintf(os.Stderr, "Unknown command %q. Run steez help for usage.\n", cmd)
	}
}

func cmdVersion() {
	fmt.Printf("steez v%s\n", version)
	fmt.Printf("go     %s\n", runtime.Version())
	fmt.Printf("os     %s/%s\n", runtime.GOOS, runtime.GOARCH)

	cfg, err := config.Load()
	if err == nil && cfg.RepoPath != "" {
		fmt.Printf("repo   %s\n", cfg.RepoPath)
	}
}

func cmdSetup(_ []string) {
	// Stub — wired in bead 7 (TUI).
	fmt.Println("steez setup: TUI not yet implemented. Use steez install <profile> instead.")
}

func cmdUpdate(_ []string) {
	// Stub — wired in bead 8 (updater).
	fmt.Println("steez update: updater not yet implemented.")
}

// resolveRepoPath finds the steez repo using the flag value, config, or default.
func resolveRepoPath(flagValue string) (string, error) {
	// 1. Explicit flag.
	if flagValue != "" {
		return verifyRepoPath(flagValue)
	}

	// 2. Config file.
	cfg, err := config.Load()
	if err == nil && cfg.RepoPath != "" {
		p, err := verifyRepoPath(cfg.RepoPath)
		if err == nil {
			return p, nil
		}
	}

	// 3. Default location.
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("cannot resolve home directory: %w", err)
	}
	defaultPath := filepath.Join(home, "Projects", "Personal", "steez")
	p, err := verifyRepoPath(defaultPath)
	if err == nil {
		// Save it for next time.
		_ = config.EnsureDir()
		_ = config.Save(&config.Config{RepoPath: defaultPath})
		return p, nil
	}

	return "", fmt.Errorf("steez repo not found. Run steez setup or pass --repo=<path>")
}

func verifyRepoPath(path string) (string, error) {
	manifest := filepath.Join(path, "skills.json")
	if _, err := os.Stat(manifest); err != nil {
		return "", fmt.Errorf("no skills.json at %s", path)
	}
	return path, nil
}
