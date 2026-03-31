package installer

import (
	"os"
	"path/filepath"
	"testing"
)

func setupTestHome(t *testing.T) string {
	t.Helper()
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)
	return tmp
}

func TestDetectMigration_StowFolded(t *testing.T) {
	home := setupTestHome(t)

	// Create ~/.claude as a real dir, ~/.claude/skills as a symlink.
	claudeDir := filepath.Join(home, ".claude")
	os.MkdirAll(claudeDir, 0o755)

	skillsSource := filepath.Join(home, "dotfiles", "claude", ".claude", "skills")
	os.MkdirAll(skillsSource, 0o755)

	os.Symlink(skillsSource, filepath.Join(claudeDir, "skills"))

	result, err := DetectMigration()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.State != StateStowFolded {
		t.Errorf("state = %v, want StateStowFolded", result.State)
	}
	if len(result.Commands) == 0 {
		t.Error("expected migration commands")
	}
}

func TestDetectMigration_ParentFolded(t *testing.T) {
	home := setupTestHome(t)

	// Create ~/.claude as a symlink.
	claudeSource := filepath.Join(home, "dotfiles", "claude", ".claude")
	os.MkdirAll(claudeSource, 0o755)
	os.MkdirAll(filepath.Join(claudeSource, "skills"), 0o755)

	os.Symlink(claudeSource, filepath.Join(home, ".claude"))

	result, err := DetectMigration()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.State != StateParentFolded {
		t.Errorf("state = %v, want StateParentFolded", result.State)
	}
}

func TestDetectMigration_RealDirectory(t *testing.T) {
	home := setupTestHome(t)

	os.MkdirAll(filepath.Join(home, ".claude", "skills"), 0o755)

	result, err := DetectMigration()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.State != StateRealDirectory {
		t.Errorf("state = %v, want StateRealDirectory", result.State)
	}
}

func TestDetectMigration_Missing(t *testing.T) {
	_ = setupTestHome(t)
	// Don't create any .claude directory.

	result, err := DetectMigration()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.State != StateMissing {
		t.Errorf("state = %v, want StateMissing", result.State)
	}
}
