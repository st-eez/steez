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

	binSymlinks := []struct{ name, relPath string }{
		{"config", "shared/steez/bin/config"},
		{"slug", "shared/steez/bin/slug"},
		{"diff-scope", "shared/steez/bin/diff-scope"},
		{"review-log", "shared/steez/bin/review-log"},
		{"review-read", "shared/steez/bin/review-read"},
		{"steez-bd", "shared/steez/bin/steez-bd"},
		{"agent-state", "shared/steez/bin/agent-state"},
		{"agent-history", "shared/steez/bin/agent-history"},
		{"browse", "shared/steez/browse/dist/browse"},
	}
	// Remove old steez-prefixed bin symlinks from before the rename.
	if !*dryRun {
		oldBinNames := []string{
			"steez-config", "steez-slug", "steez-diff-scope",
			"steez-review-log", "steez-review-read",
			"steez-agent-state", "steez-agent-history",
		}
		for _, old := range oldBinNames {
			_ = installer.RemoveSymlink(filepath.Join(binDir, old))
		}
	}
	for _, bs := range binSymlinks {
		source := filepath.Join(repoSymlink, bs.relPath)
		target := filepath.Join(binDir, bs.name)
		if err := installer.CreateSymlink(source, target, *dryRun, *force); err != nil {
			fmt.Fprintf(os.Stderr, "  error: bin/%s: %v\n", bs.name, err)
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

	hookSymlinks := []struct{ name, relPath string }{
		{"steez-skill-analytics.sh", "shared/steez/hooks/skill-analytics.sh"},
		{"steez-session-start.sh", "shared/steez/hooks/session-start.sh"},
	}
	for _, hs := range hookSymlinks {
		source := filepath.Join(repoSymlink, hs.relPath)
		target := filepath.Join(hookDir, hs.name)
		if err := installer.CreateSymlink(source, target, *dryRun, *force); err != nil {
			fmt.Fprintf(os.Stderr, "  error: hooks/%s: %v\n", hs.name, err)
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

	codexHookSymlinks := []struct{ name, relPath string }{
		{"session-start.sh", "shared/steez/hooks/codex-session-start.sh"},
	}
	for _, hs := range codexHookSymlinks {
		source := filepath.Join(repoSymlink, hs.relPath)
		target := filepath.Join(codexHookDir, hs.name)
		if err := installer.CreateSymlink(source, target, *dryRun, *force); err != nil {
			fmt.Fprintf(os.Stderr, "  error: codex-hooks/%s: %v\n", hs.name, err)
			failed++
		} else {
			installed++
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
				config.AddToRegistry(reg, name, source, target)
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
		for _, s := range reg.Symlinks {
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
		// Find in registry.
		var entry *config.RegisteredSymlink
		for i := range reg.Symlinks {
			if reg.Symlinks[i].Name == name {
				entry = &reg.Symlinks[i]
				break
			}
		}

		if entry == nil {
			fmt.Fprintf(os.Stderr, "  %s: not in registry (skipped)\n", name)
			continue
		}

		if err := installer.RemoveSymlink(entry.Target); err != nil {
			fmt.Fprintf(os.Stderr, "  %s: %v\n", name, err)
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
