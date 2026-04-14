package installer

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/st-eez/steez/internal/config"
)

// findRepoRoot walks up from the test file to find the steez repo root.
func findRepoRoot(t *testing.T) string {
	t.Helper()
	// The test runs from internal/installer/, so go up 2 levels.
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	root := filepath.Join(dir, "..", "..")
	if _, err := os.Stat(filepath.Join(root, "skills.json")); err != nil {
		t.Skipf("cannot find skills.json at %s — skipping integration test", root)
	}
	return root
}

func TestIntegration_CleanInstall(t *testing.T) {
	repoPath := findRepoRoot(t)
	home := setupTestHome(t)

	// Create empty .claude/skills/.
	skillsDir := filepath.Join(home, ".claude", "skills")
	os.MkdirAll(skillsDir, 0o755)
	steezHome := filepath.Join(home, ".steez")
	os.MkdirAll(steezHome, 0o755)

	// Load real manifest.
	manifest, err := LoadManifest(filepath.Join(repoPath, "skills.json"))
	if err != nil {
		t.Fatalf("loading manifest: %v", err)
	}

	// Resolve starter profile.
	skills, err := ResolveProfile(manifest, "starter")
	if err != nil {
		t.Fatalf("resolving profile: %v", err)
	}

	if len(skills) != 7 {
		t.Fatalf("starter profile has %d skills, want 7", len(skills))
	}

	// Create repo symlink.
	repoSymlink := filepath.Join(steezHome, "repo")
	if err := CreateSymlink(repoPath, repoSymlink, false, false); err != nil {
		t.Fatalf("repo symlink: %v", err)
	}

	// Create bin symlinks.
	binDir := filepath.Join(steezHome, "bin")
	os.MkdirAll(binDir, 0o755)
	for _, bs := range SharedBinSymlinks() {
		source := filepath.Join(repoSymlink, bs.RelPath)
		target := filepath.Join(binDir, bs.Name)
		CreateSymlink(source, target, false, false)
	}

	// Install each skill.
	reg := &config.Registry{}
	for _, name := range skills {
		source := filepath.Join(repoPath, "skills", name)
		target := filepath.Join(skillsDir, name)
		if err := CreateSymlink(source, target, false, false); err != nil {
			t.Fatalf("install %s: %v", name, err)
		}
		config.AddToRegistry(reg, name, source, target)
	}

	// Verify 7 entries (7 skills, repo/bin symlinks not in registry).
	if len(reg.Symlinks) != 7 {
		t.Errorf("registry has %d entries, want 7", len(reg.Symlinks))
	}

	// Save and reload registry to verify persistence.
	config.SaveRegistry(reg)
	loaded, err := config.LoadRegistry()
	if err != nil {
		t.Fatalf("loading registry: %v", err)
	}
	if len(loaded.Symlinks) != 7 {
		t.Errorf("loaded registry has %d entries, want 7", len(loaded.Symlinks))
	}

	// Verify all symlinks resolve.
	for _, entry := range reg.Symlinks {
		if err := ValidateSymlink(entry.Target); err != nil {
			t.Errorf("symlink %s broken: %v", entry.Name, err)
		}
	}
}

func TestIntegration_CaseBUpgrade(t *testing.T) {
	repoPath := findRepoRoot(t)
	home := setupTestHome(t)

	skillsDir := filepath.Join(home, ".claude", "skills")
	os.MkdirAll(skillsDir, 0o755)
	steezHome := filepath.Join(home, ".steez")
	os.MkdirAll(steezHome, 0o755)

	// Create a non-steez skill.
	nonSteez := filepath.Join(skillsDir, "my-custom-skill")
	os.MkdirAll(nonSteez, 0o755)
	os.WriteFile(filepath.Join(nonSteez, "SKILL.md"), []byte("custom"), 0o644)

	// Create repo symlink.
	CreateSymlink(repoPath, filepath.Join(steezHome, "repo"), false, false)

	// Install one skill.
	source := filepath.Join(repoPath, "skills", "office-hours")
	target := filepath.Join(skillsDir, "office-hours")
	CreateSymlink(source, target, false, false)

	// Verify non-steez skill is untouched.
	data, err := os.ReadFile(filepath.Join(nonSteez, "SKILL.md"))
	if err != nil || string(data) != "custom" {
		t.Error("non-steez skill was modified or deleted")
	}

	// Verify steez symlink works.
	if err := ValidateSymlink(target); err != nil {
		t.Errorf("steez symlink broken: %v", err)
	}
}

func TestIntegration_DoctorAfterInstall(t *testing.T) {
	repoPath := findRepoRoot(t)
	home := setupTestHome(t)

	skillsDir := filepath.Join(home, ".claude", "skills")
	os.MkdirAll(skillsDir, 0o755)
	os.MkdirAll(filepath.Join(home, ".agents", "skills"), 0o755)
	steezHome := filepath.Join(home, ".steez")
	os.MkdirAll(filepath.Join(steezHome, "analytics"), 0o755)

	// Create repo symlink.
	repoSymlink := filepath.Join(steezHome, "repo")
	CreateSymlink(repoPath, repoSymlink, false, false)

	// Create bin symlinks.
	binDir := filepath.Join(steezHome, "bin")
	os.MkdirAll(binDir, 0o755)
	for _, bs := range SharedBinSymlinks() {
		source := filepath.Join(repoSymlink, bs.RelPath)
		target := filepath.Join(binDir, bs.Name)
		CreateSymlink(source, target, false, false)
	}

	// Create hook symlinks.
	hookDir := filepath.Join(home, ".claude", "hooks")
	os.MkdirAll(hookDir, 0o755)
	for _, hs := range SharedClaudeHookSymlinks() {
		source := filepath.Join(repoSymlink, hs.RelPath)
		target := filepath.Join(hookDir, hs.Name)
		CreateSymlink(source, target, false, false)
	}

	// Install one skill.
	source := filepath.Join(repoPath, "skills", "spawn-agent")
	claudeTarget := filepath.Join(skillsDir, "spawn-agent")
	codexTarget := filepath.Join(home, ".codex", "skills", "spawn-agent")
	CreateSymlink(source, claudeTarget, false, false)
	CreateSymlink(source, codexTarget, false, false)

	// Write registry.
	reg := &config.Registry{
		Symlinks: []config.RegisteredSymlink{
			{Name: "spawn-agent", Scope: "claude-global", Source: source, Target: claudeTarget},
			{Name: "spawn-agent", Scope: "codex-global", Source: source, Target: codexTarget},
		},
	}
	data, _ := json.MarshalIndent(reg, "", "  ")
	os.WriteFile(filepath.Join(steezHome, "installed.json"), data, 0o644)

	// Write config.
	cfg := &config.Config{RepoPath: repoPath}
	cfgData, _ := json.MarshalIndent(cfg, "", "  ")
	os.WriteFile(filepath.Join(steezHome, "config.json"), cfgData, 0o644)

	// Run doctor.
	results, err := RunDoctor(repoPath, false)
	if err != nil {
		t.Fatalf("doctor error: %v", err)
	}

	code := ExitCode(results)
	if code != 0 {
		for _, r := range results {
			if r.Status != "pass" {
				t.Logf("  %s: %s — %s", r.Status, r.Name, r.Message)
			}
		}
		t.Errorf("doctor exit code = %d, want 0", code)
	}
}
