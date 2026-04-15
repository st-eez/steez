package main

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/st-eez/steez/internal/config"
	"github.com/st-eez/steez/internal/installer"
)

func findRepoRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	repoPath := filepath.Clean(filepath.Join(dir, "..", ".."))
	if _, err := os.Stat(filepath.Join(repoPath, "skills.json")); err != nil {
		t.Fatalf("cannot find skills.json at %s: %v", repoPath, err)
	}
	return repoPath
}

func TestInstallSpecInstallsClaudeAndCodexSkills(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	repoPath := findRepoRoot(t)
	if code := cmdInstall([]string{"--repo", repoPath, "spec"}); code != 0 {
		t.Fatalf("cmdInstall exit code = %d, want 0", code)
	}

	claudeTarget := filepath.Join(home, ".claude", "skills", "spec")
	codexTarget := filepath.Join(home, ".codex", "skills", "spec")
	for _, target := range []string{claudeTarget, codexTarget} {
		if err := installer.ValidateSymlink(target); err != nil {
			t.Fatalf("validate symlink %s: %v", target, err)
		}

		resolved, err := os.Readlink(target)
		if err != nil {
			t.Fatalf("readlink %s: %v", target, err)
		}
		if resolved != filepath.Join(repoPath, "skills", "spec") {
			t.Fatalf("symlink %s -> %s, want %s", target, resolved, filepath.Join(repoPath, "skills", "spec"))
		}
	}

	reg, err := config.LoadRegistry()
	if err != nil {
		t.Fatalf("load registry: %v", err)
	}

	var foundClaude, foundCodex bool
	for _, entry := range reg.Symlinks {
		if entry.Name != "spec" {
			continue
		}
		if entry.Scope == "claude-global" && entry.Target == claudeTarget {
			foundClaude = true
		}
		if entry.Scope == "codex-global" && entry.Target == codexTarget {
			foundCodex = true
		}
	}

	if !foundClaude {
		t.Fatal("registry missing claude-global spec entry")
	}
	if !foundCodex {
		t.Fatal("registry missing codex-global spec entry")
	}
}
