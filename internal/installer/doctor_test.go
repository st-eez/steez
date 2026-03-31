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

	// Create shared home symlink.
	steezSource := filepath.Join(repoPath, "skills", "steez")
	os.MkdirAll(steezSource, 0o755)
	os.Symlink(steezSource, filepath.Join(skillsDir, "steez"))

	// Create ~/.steez/ with empty registry.
	steezDir := filepath.Join(home, ".steez")
	os.MkdirAll(steezDir, 0o755)
	os.MkdirAll(filepath.Join(steezDir, "analytics"), 0o755)

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
	os.MkdirAll(filepath.Join(repoPath, "skills", "steez"), 0o755)

	home := setupDoctorHome(t, repoPath)

	// Create a valid skill symlink.
	skillSource := filepath.Join(repoPath, "skills", "alpha")
	os.MkdirAll(skillSource, 0o755)
	skillTarget := filepath.Join(home, ".claude", "skills", "steez-alpha")
	os.Symlink(skillSource, skillTarget)

	reg := &config.Registry{
		Symlinks: []config.RegisteredSymlink{
			{Name: "steez", Source: filepath.Join(repoPath, "skills", "steez"), Target: filepath.Join(home, ".claude", "skills", "steez")},
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
	os.MkdirAll(filepath.Join(repoPath, "skills", "steez"), 0o755)

	home := setupDoctorHome(t, repoPath)

	// Create a dangling symlink.
	skillTarget := filepath.Join(home, ".claude", "skills", "steez-missing")
	os.Symlink(filepath.Join(repoPath, "skills", "nonexistent"), skillTarget)

	reg := &config.Registry{
		Symlinks: []config.RegisteredSymlink{
			{Name: "steez", Source: filepath.Join(repoPath, "skills", "steez"), Target: filepath.Join(home, ".claude", "skills", "steez")},
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

func TestDoctor_MissingSharedHome(t *testing.T) {
	tmp := t.TempDir()
	repoPath := filepath.Join(tmp, "repo")
	os.MkdirAll(repoPath, 0o755)

	home := setupTestHome(t)
	os.MkdirAll(filepath.Join(home, ".claude", "skills"), 0o755)

	results, err := RunDoctor(repoPath, false)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Should fail-fast: only one result.
	if len(results) != 1 {
		t.Errorf("expected 1 result (fail-fast), got %d", len(results))
	}
	if results[0].Status != "fail" {
		t.Errorf("shared home check status = %s, want fail", results[0].Status)
	}
}

func TestDoctor_FixMode(t *testing.T) {
	tmp := t.TempDir()
	repoPath := filepath.Join(tmp, "repo")
	os.MkdirAll(filepath.Join(repoPath, "skills", "steez"), 0o755)

	home := setupDoctorHome(t, repoPath)

	// Create dangling symlink.
	skillTarget := filepath.Join(home, ".claude", "skills", "steez-broken")
	os.Symlink(filepath.Join(repoPath, "skills", "nonexistent"), skillTarget)

	reg := &config.Registry{
		Symlinks: []config.RegisteredSymlink{
			{Name: "steez", Source: filepath.Join(repoPath, "skills", "steez"), Target: filepath.Join(home, ".claude", "skills", "steez")},
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
