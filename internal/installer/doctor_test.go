package installer

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/st-eez/steez/internal/config"
)

func setupDoctorHome(t *testing.T, repoPath string) string {
	t.Helper()
	home := setupTestHome(t)

	// Create ~/.claude/skills/ as a real directory.
	skillsDir := filepath.Join(home, ".claude", "skills")
	os.MkdirAll(skillsDir, 0o755)

	// Create ~/.steez/ with repo symlink, bin symlinks, and analytics.
	steezDir := filepath.Join(home, ".steez")
	os.MkdirAll(steezDir, 0o755)
	os.MkdirAll(filepath.Join(steezDir, "analytics"), 0o755)

	// Repo symlink.
	os.Symlink(repoPath, filepath.Join(steezDir, "repo"))

	// Bin symlinks (chained through repo symlink).
	binDir := filepath.Join(steezDir, "bin")
	os.MkdirAll(binDir, 0o755)
	repoSymlink := filepath.Join(steezDir, "repo")
	for _, bs := range []struct{ name, relPath string }{
		{"steez-config", "shared/steez/bin/steez-config"},
		{"steez-slug", "shared/steez/bin/steez-slug"},
		{"steez-diff-scope", "shared/steez/bin/steez-diff-scope"},
		{"steez-review-log", "shared/steez/bin/steez-review-log"},
		{"steez-review-read", "shared/steez/bin/steez-review-read"},
		{"steez-bd", "shared/steez/bin/steez-bd"},
		{"browse", "shared/steez/browse/dist/browse"},
	} {
		os.Symlink(filepath.Join(repoSymlink, bs.relPath), filepath.Join(binDir, bs.name))
	}

	return home
}

func writeRegistry(t *testing.T, home string, reg *config.Registry) {
	t.Helper()
	data, _ := json.MarshalIndent(reg, "", "  ")
	os.WriteFile(filepath.Join(home, ".steez", "installed.json"), data, 0o644)
}

func TestDoctor_AllPass(t *testing.T) {
	tmp := t.TempDir()
	repoPath := filepath.Join(tmp, "repo")
	// Create shared runtime structure so bin symlinks resolve.
	os.MkdirAll(filepath.Join(repoPath, "shared", "steez", "bin"), 0o755)
	for _, name := range []string{"steez-config", "steez-slug", "steez-diff-scope", "steez-review-log", "steez-review-read", "steez-bd"} {
		os.WriteFile(filepath.Join(repoPath, "shared", "steez", "bin", name), []byte("#!/bin/sh"), 0o755)
	}
	// Create browse binary so that symlink resolves.
	os.MkdirAll(filepath.Join(repoPath, "shared", "steez", "browse", "dist"), 0o755)
	os.WriteFile(filepath.Join(repoPath, "shared", "steez", "browse", "dist", "browse"), []byte("fake"), 0o755)

	home := setupDoctorHome(t, repoPath)

	// Create a valid skill symlink.
	skillSource := filepath.Join(repoPath, "skills", "alpha")
	os.MkdirAll(skillSource, 0o755)
	skillTarget := filepath.Join(home, ".claude", "skills", "steez-alpha")
	os.Symlink(skillSource, skillTarget)

	reg := &config.Registry{
		Symlinks: []config.RegisteredSymlink{
			{Name: "steez-alpha", Source: skillSource, Target: skillTarget},
		},
	}
	writeRegistry(t, home, reg)

	results, err := RunDoctor(repoPath, false)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	for _, r := range results {
		if r.Status == "fail" {
			t.Errorf("check %q failed: %s", r.Name, r.Message)
		}
	}
}

func TestDoctor_DanglingSymlink(t *testing.T) {
	tmp := t.TempDir()
	repoPath := filepath.Join(tmp, "repo")
	createSharedRuntime(t, repoPath)

	home := setupDoctorHome(t, repoPath)

	// Create a dangling symlink.
	skillTarget := filepath.Join(home, ".claude", "skills", "steez-missing")
	os.Symlink(filepath.Join(repoPath, "skills", "nonexistent"), skillTarget)

	reg := &config.Registry{
		Symlinks: []config.RegisteredSymlink{
			{Name: "steez-missing", Source: filepath.Join(repoPath, "skills", "nonexistent"), Target: skillTarget},
		},
	}
	writeRegistry(t, home, reg)

	results, err := RunDoctor(repoPath, false)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	found := false
	for _, r := range results {
		if r.Name == "steez-missing" && r.Status == "fail" {
			found = true
		}
	}
	if !found {
		t.Error("expected steez-missing to be detected as dangling")
	}
}

func TestDoctor_MissingRepoSymlink(t *testing.T) {
	tmp := t.TempDir()
	repoPath := filepath.Join(tmp, "repo")
	os.MkdirAll(repoPath, 0o755)

	home := setupTestHome(t)
	os.MkdirAll(filepath.Join(home, ".claude", "skills"), 0o755)
	os.MkdirAll(filepath.Join(home, ".steez"), 0o755)

	results, err := RunDoctor(repoPath, false)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Should fail-fast: only one result.
	if len(results) != 1 {
		t.Errorf("expected 1 result (fail-fast), got %d", len(results))
	}
	if results[0].Status != "fail" {
		t.Errorf("repo symlink check status = %s, want fail", results[0].Status)
	}
}

func TestDoctor_FixMode(t *testing.T) {
	tmp := t.TempDir()
	repoPath := filepath.Join(tmp, "repo")
	createSharedRuntime(t, repoPath)

	home := setupDoctorHome(t, repoPath)

	// Create dangling symlink.
	skillTarget := filepath.Join(home, ".claude", "skills", "steez-broken")
	os.Symlink(filepath.Join(repoPath, "skills", "nonexistent"), skillTarget)

	reg := &config.Registry{
		Symlinks: []config.RegisteredSymlink{
			{Name: "steez-broken", Source: filepath.Join(repoPath, "skills", "nonexistent"), Target: skillTarget},
		},
	}
	writeRegistry(t, home, reg)

	results, err := RunDoctor(repoPath, true)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Verify the dangling symlink was removed.
	if _, err := os.Lstat(skillTarget); !os.IsNotExist(err) {
		t.Error("expected dangling symlink to be removed by --fix")
	}

	// Check that the fix was reported.
	found := false
	for _, r := range results {
		if r.Name == "steez-broken" && r.Status == "pass" {
			found = true
		}
	}
	if !found {
		t.Error("expected steez-broken to be reported as fixed")
	}
}

// createSharedRuntime creates the shared runtime directory structure in a test repo.
func createSharedRuntime(t *testing.T, repoPath string) {
	t.Helper()
	os.MkdirAll(filepath.Join(repoPath, "shared", "steez", "bin"), 0o755)
	for _, name := range []string{"steez-config", "steez-slug", "steez-diff-scope", "steez-review-log", "steez-review-read", "steez-bd"} {
		os.WriteFile(filepath.Join(repoPath, "shared", "steez", "bin", name), []byte("#!/bin/sh"), 0o755)
	}
	os.MkdirAll(filepath.Join(repoPath, "shared", "steez", "browse", "dist"), 0o755)
	os.WriteFile(filepath.Join(repoPath, "shared", "steez", "browse", "dist", "browse"), []byte("fake"), 0o755)
}
