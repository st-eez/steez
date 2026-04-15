package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/st-eez/steez/internal/config"
	"github.com/st-eez/steez/internal/installer"
)

func cmdInstall(args []string) int {
	fs := flag.NewFlagSet("install", flag.ContinueOnError)
	dryRun := fs.Bool("dry-run", false, "show planned symlinks without creating them")
	force := fs.Bool("force", false, "overwrite existing symlinks")
	browse := fs.Bool("browse", false, "build browse binary after install")
	repoFlag := fs.String("repo", "", "override repo path")

	if err := fs.Parse(args); err != nil {
		return 1
	}

	if fs.NArg() == 0 {
		fmt.Fprintln(os.Stderr, "Usage: steez install <starter|all|skill1 skill2 ...>")
		return 1
	}

	repoPath, err := resolveRepoPath(*repoFlag)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		return 1
	}

	// Check migration state.
	migResult, err := installer.DetectMigration()
	if err != nil {
		fmt.Fprintf(os.Stderr, "error detecting migration state: %v\n", err)
		return 1
	}
	if migResult.State == installer.StateStowFolded || migResult.State == installer.StateParentFolded {
		fmt.Fprintln(os.Stderr, "Migration required: ~/.claude/skills/ is a stow-folded symlink.")
		fmt.Fprintln(os.Stderr, "Run these commands first:")
		fmt.Fprintln(os.Stderr)
		for _, cmd := range migResult.Commands {
			fmt.Fprintf(os.Stderr, "  %s\n", cmd)
		}
		fmt.Fprintln(os.Stderr)
		fmt.Fprintln(os.Stderr, "Then re-run steez install.")
		return 1
	}

	manifest, err := installer.LoadManifest(filepath.Join(repoPath, "skills.json"))
	if err != nil {
		fmt.Fprintf(os.Stderr, "error loading manifest: %v\n", err)
		return 1
	}

	// Resolve which skills to install.
	skillNames, err := resolveSkillArgs(manifest, fs.Args())
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		return 1
	}

	home, err := os.UserHomeDir()
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		return 1
	}

	skillsTarget := filepath.Join(home, ".claude", "skills")
	codexSkillsTarget := filepath.Join(home, ".codex", "skills")

	// Ensure target directory exists (Case C: missing).
	if migResult.State == installer.StateMissing {
		if *dryRun {
			fmt.Printf("Would create directory: %s\n", skillsTarget)
		} else {
			if err := os.MkdirAll(skillsTarget, 0o755); err != nil {
				fmt.Fprintf(os.Stderr, "error creating skills directory: %v\n", err)
				return 1
			}
		}
	}

	// Load or create registry.
	reg, err := config.LoadRegistry()
	if err != nil {
		reg = &config.Registry{}
	}

	installed := 0
	failed := 0

	// Create ~/.steez/repo symlink pointing to checkout.
	steezHome := filepath.Join(home, ".steez")
	if !*dryRun {
		if err := os.MkdirAll(steezHome, 0o755); err != nil {
			fmt.Fprintf(os.Stderr, "error creating ~/.steez/: %v\n", err)
			return 1
		}
	}

	repoSymlink := filepath.Join(steezHome, "repo")
	if err := installer.CreateSymlink(repoPath, repoSymlink, *dryRun, *force); err != nil {
		fmt.Fprintf(os.Stderr, "  error: repo symlink: %v\n", err)
		failed++
	} else {
		installed++
	}

	// Create ~/.steez/bin/ directory with symlinks to shared runtime.
	binDir := filepath.Join(steezHome, "bin")
	if !*dryRun {
		if err := os.MkdirAll(binDir, 0o755); err != nil {
			fmt.Fprintf(os.Stderr, "error creating ~/.steez/bin/: %v\n", err)
			return 1
		}
	}

	// Remove old steez-prefixed bin symlinks from before the rename.
	if !*dryRun {
		for _, old := range installer.DeprecatedBinSymlinks() {
			_ = installer.RemoveSymlink(filepath.Join(binDir, old))
		}
	}
	for _, bs := range installer.SharedBinSymlinks() {
		source := filepath.Join(repoSymlink, bs.RelPath)
		target := filepath.Join(binDir, bs.Name)
		if err := installer.CreateSymlink(source, target, *dryRun, *force); err != nil {
			fmt.Fprintf(os.Stderr, "  error: bin/%s: %v\n", bs.Name, err)
			failed++
		} else {
			installed++
		}
	}

	// Hook symlinks (Claude Code hooks).
	hookDir := filepath.Join(home, ".claude", "hooks")
	if !*dryRun {
		if err := os.MkdirAll(hookDir, 0o755); err != nil {
			fmt.Fprintf(os.Stderr, "error creating ~/.claude/hooks/: %v\n", err)
			return 1
		}
	}

	for _, hs := range installer.SharedClaudeHookSymlinks() {
		source := filepath.Join(repoSymlink, hs.RelPath)
		target := filepath.Join(hookDir, hs.Name)
		if err := installer.CreateSymlink(source, target, *dryRun, *force); err != nil {
			fmt.Fprintf(os.Stderr, "  error: hooks/%s: %v\n", hs.Name, err)
			failed++
		} else {
			installed++
		}
	}

	// Codex hook symlinks (~/.codex/hooks/).
	codexHookDir := filepath.Join(home, ".codex", "hooks")
	if !*dryRun {
		if err := os.MkdirAll(codexHookDir, 0o755); err != nil {
			fmt.Fprintf(os.Stderr, "error creating ~/.codex/hooks/: %v\n", err)
			return 1
		}
	}

	for _, hs := range installer.SharedCodexHookSymlinks() {
		source := filepath.Join(repoSymlink, hs.RelPath)
		target := filepath.Join(codexHookDir, hs.Name)
		if err := installer.CreateSymlink(source, target, *dryRun, *force); err != nil {
			fmt.Fprintf(os.Stderr, "  error: codex-hooks/%s: %v\n", hs.Name, err)
			failed++
		} else {
			installed++
		}
	}

	needsCodexSkillsDir := false
	for _, name := range skillNames {
		if installer.InstallsGloballyInCodex(name) {
			needsCodexSkillsDir = true
			break
		}
	}
	if needsCodexSkillsDir {
		if *dryRun {
			fmt.Printf("Would create directory: %s\n", codexSkillsTarget)
		} else {
			if err := os.MkdirAll(codexSkillsTarget, 0o755); err != nil {
				fmt.Fprintf(os.Stderr, "error creating Codex skills directory: %v\n", err)
				return 1
			}
		}
	}

	// Install each skill.
	for _, name := range skillNames {
		source := filepath.Join(repoPath, "skills", name)
		target := filepath.Join(skillsTarget, name)

		// Remove old steez-prefixed skill symlink if it exists.
		if !*dryRun {
			oldTarget := filepath.Join(skillsTarget, "steez-"+name)
			_ = installer.RemoveSymlink(oldTarget)
			config.RemoveFromRegistry(reg, "steez-"+name)
		}

		if err := installer.CreateSymlink(source, target, *dryRun, *force); err != nil {
			fmt.Fprintf(os.Stderr, "  error: %s: %v\n", name, err)
			failed++
		} else {
			if !*dryRun {
				config.AddScopedToRegistry(reg, "claude-global", name, source, target)
			}
			installed++
		}

		if !installer.InstallsGloballyInCodex(name) {
			continue
		}

		codexTarget := filepath.Join(codexSkillsTarget, name)
		if !*dryRun {
			_ = installer.RemoveSymlink(filepath.Join(home, ".agents", "skills", name))
		}

		if err := installer.CreateSymlink(source, codexTarget, *dryRun, *force); err != nil {
			fmt.Fprintf(os.Stderr, "  error: codex/%s: %v\n", name, err)
			failed++
		} else {
			if !*dryRun {
				config.AddScopedToRegistry(reg, "codex-global", name, source, codexTarget)
			}
			installed++
		}
	}

	// Save registry and config.
	if !*dryRun {
		if err := config.EnsureDir(); err != nil {
			fmt.Fprintf(os.Stderr, "warning: could not create ~/.steez/: %v\n", err)
		}
		if err := config.SaveRegistry(reg); err != nil {
			fmt.Fprintf(os.Stderr, "warning: could not save registry: %v\n", err)
		}

		// Save repo path and first install time if not set.
		cfg, _ := config.Load()
		if cfg.RepoPath == "" {
			cfg.RepoPath = repoPath
		}
		if cfg.FirstInstall == "" {
			cfg.FirstInstall = time.Now().Format(time.RFC3339)
		}
		_ = config.Save(cfg)
	}

	// Summary.
	if *dryRun {
		fmt.Printf("\nDry run: %d skills would be installed.\n", installed)
	} else {
		fmt.Printf("\nInstalled %d skills.", installed)
		if failed > 0 {
			fmt.Printf(" %d failed.", failed)
		}
		fmt.Println(" Run steez doctor to verify.")
	}

	// Check if settings.json needs the Skill hook registered.
	if !*dryRun {
		installer.CheckHookRegistration(home)
		installer.CheckCodexHookRegistration(home)
	}

	// Build browse binary if requested.
	if *browse && !*dryRun {
		fmt.Println("\nBuilding browse binary...")
		fmt.Println("(browse build not yet implemented — see bead 8)")
	}

	if failed > 0 && installed > 0 {
		return 2 // Partial success.
	}
	if failed > 0 {
		return 1
	}
	return 0
}

func cmdUninstall(args []string) int {
	fs := flag.NewFlagSet("uninstall", flag.ContinueOnError)
	all := fs.Bool("all", false, "remove all steez-managed symlinks")

	if err := fs.Parse(args); err != nil {
		return 1
	}

	if !*all && fs.NArg() == 0 {
		fmt.Fprintln(os.Stderr, "Usage: steez uninstall <skill1 skill2 ...> or steez uninstall --all")
		return 1
	}

	reg, err := config.LoadRegistry()
	if err != nil {
		fmt.Fprintf(os.Stderr, "error loading registry: %v\n", err)
		return 1
	}

	var toRemove []string
	if *all {
		seen := make(map[string]bool)
		for _, s := range reg.Symlinks {
			if seen[s.Name] {
				continue
			}
			seen[s.Name] = true
			toRemove = append(toRemove, s.Name)
		}
	} else {
		for _, arg := range fs.Args() {
			toRemove = append(toRemove, arg)
		}
	}

	if len(toRemove) == 0 {
		fmt.Println("No skills to uninstall.")
		return 0
	}

	removed := 0
	for _, name := range toRemove {
		var entries []config.RegisteredSymlink
		for _, entry := range reg.Symlinks {
			if entry.Name == name {
				entries = append(entries, entry)
			}
		}

		if len(entries) == 0 {
			fmt.Fprintf(os.Stderr, "  %s: not in registry (skipped)\n", name)
			continue
		}

		failed := false
		for _, entry := range entries {
			if err := installer.RemoveSymlink(entry.Target); err != nil {
				fmt.Fprintf(os.Stderr, "  %s (%s): %v\n", name, entry.Target, err)
				failed = true
			}
		}
		if failed {
			continue
		}

		config.RemoveFromRegistry(reg, name)
		removed++
	}

	if err := config.SaveRegistry(reg); err != nil {
		fmt.Fprintf(os.Stderr, "warning: could not save registry: %v\n", err)
	}

	fmt.Printf("Removed %d skills.\n", removed)
	return 0
}

// resolveSkillArgs converts CLI args into a flat list of skill names.
// Handles profile names (starter, all) and individual skill names.
func resolveSkillArgs(m *installer.Manifest, args []string) ([]string, error) {
	var skills []string
	seen := make(map[string]bool)

	for _, arg := range args {
		// Check if it's a profile name.
		if _, ok := m.Profiles[arg]; ok {
			resolved, err := installer.ResolveProfile(m, arg)
			if err != nil {
				return nil, err
			}
			for _, s := range resolved {
				if !seen[s] {
					skills = append(skills, s)
					seen[s] = true
				}
			}
			continue
		}

		// Try as a skill name.
		skill, err := installer.FindSkill(m, arg)
		if err != nil {
			return nil, err
		}
		if !seen[skill.Name] {
			skills = append(skills, skill.Name)
			seen[skill.Name] = true
		}
	}

	return skills, nil
}
