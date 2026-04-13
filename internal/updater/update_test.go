package updater

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/st-eez/steez/internal/config"
	"github.com/st-eez/steez/internal/installer"
)

// createTestRepo initializes a minimal git repo with one commit.
func createTestRepo(t *testing.T) string {
	t.Helper()
	tmp := t.TempDir()

	// Create a skills.json so it looks like a steez repo.
	os.WriteFile(filepath.Join(tmp, "skills.json"), []byte(`{"version":"1.0.0","skills":{},"categories":{},"profiles":{},"shared_infra":{"bin":[],"runtime_dir":"","browse_binary":""}}`), 0o644)

	run := func(args ...string) {
		t.Helper()
		cmd := exec.Command("git", append([]string{"-C", tmp}, args...)...)
		cmd.Env = append(os.Environ(),
			"GIT_AUTHOR_NAME=test",
			"GIT_AUTHOR_EMAIL=test@test.com",
			"GIT_COMMITTER_NAME=test",
			"GIT_COMMITTER_EMAIL=test@test.com",
		)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %s: %v", args, out, err)
		}
	}

	run("init")
	run("add", "-A")
	run("commit", "-m", "init")

	return tmp
}

func TestCheckClean_CleanRepo(t *testing.T) {
	repo := createTestRepo(t)
	if err := checkClean(repo); err != nil {
		t.Errorf("clean repo should pass: %v", err)
	}
}

func TestCheckClean_DirtyRepo(t *testing.T) {
	repo := createTestRepo(t)

	// Create an untracked file to make it dirty.
	os.WriteFile(filepath.Join(repo, "dirty.txt"), []byte("dirty"), 0o644)

	err := checkClean(repo)
	if err == nil {
		t.Error("dirty repo should fail")
	}
}

func TestContainsGoChanges(t *testing.T) {
	tests := []struct {
		diff string
		want bool
	}{
		{"cmd/steez/main.go\ninternal/tui/setup.go", true},
		{"skills.json\nREADME.md", false},
		{"internal/config/config.go", true},
		{"", false},
	}

	for _, tt := range tests {
		got := containsGoChanges(tt.diff)
		if got != tt.want {
			t.Errorf("containsGoChanges(%q) = %v, want %v", tt.diff, got, tt.want)
		}
	}
}

func TestGitOutput(t *testing.T) {
	repo := createTestRepo(t)

	head, err := gitOutput(repo, "rev-parse", "HEAD")
	if err != nil {
		t.Fatalf("gitOutput failed: %v", err)
	}
	if len(head) != 40 {
		t.Errorf("HEAD hash length = %d, want 40", len(head))
	}
}

func TestRunUpdate_RefreshesRuntimeAssetsWhenRepoAlreadyUpToDate(t *testing.T) {
	root := t.TempDir()
	seed := filepath.Join(root, "seed")
	remote := filepath.Join(root, "remote.git")
	clone := filepath.Join(root, "clone")
	home := filepath.Join(root, "home")

	mustMkdirAll(t, seed)
	mustMkdirAll(t, home)

	runGit := func(dir string, args ...string) string {
		t.Helper()
		cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
		cmd.Env = append(os.Environ(),
			"GIT_AUTHOR_NAME=test",
			"GIT_AUTHOR_EMAIL=test@test.com",
			"GIT_COMMITTER_NAME=test",
			"GIT_COMMITTER_EMAIL=test@test.com",
		)
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("git -C %s %v: %s: %v", dir, args, out, err)
		}
		return string(out)
	}

	runGit(seed, "init")
	branch := trimTrailingNewline(runGit(seed, "symbolic-ref", "--short", "HEAD"))

	os.WriteFile(filepath.Join(seed, "skills.json"), []byte(`{"version":"1.0.0","skills":{},"categories":{},"profiles":{},"shared_infra":{"bin":[],"runtime_dir":"","browse_binary":""}}`), 0o644)
	createRuntimeAssets(t, seed)
	runGit(seed, "add", "-A")
	runGit(seed, "commit", "-m", "init")

	runGit(root, "init", "--bare", remote)
	runGit(seed, "remote", "add", "origin", remote)
	runGit(seed, "push", "-u", "origin", branch)
	runGit(root, "clone", remote, clone)

	t.Setenv("HOME", home)
	if err := config.Save(&config.Config{RepoPath: clone}); err != nil {
		t.Fatalf("config.Save: %v", err)
	}

	if err := RunUpdate(); err != nil {
		t.Fatalf("RunUpdate: %v", err)
	}

	repoSymlink := filepath.Join(home, ".steez", "repo")
	assertSymlinkTarget(t, repoSymlink, clone)

	agentWatch := filepath.Join(home, ".steez", "bin", "agent-watch")
	assertSymlinkTarget(t, agentWatch, filepath.Join(repoSymlink, "shared", "steez", "bin", "agent-watch"))
}

func createRuntimeAssets(t *testing.T, repo string) {
	t.Helper()

	for _, bin := range installer.SharedBinSymlinks() {
		path := filepath.Join(repo, bin.RelPath)
		mustMkdirAll(t, filepath.Dir(path))
		os.WriteFile(path, []byte("#!/bin/sh\nexit 0\n"), 0o755)
	}
	for _, hook := range append(installer.SharedClaudeHookSymlinks(), installer.SharedCodexHookSymlinks()...) {
		path := filepath.Join(repo, hook.RelPath)
		mustMkdirAll(t, filepath.Dir(path))
		os.WriteFile(path, []byte("#!/bin/sh\nexit 0\n"), 0o755)
	}
}

func assertSymlinkTarget(t *testing.T, path, want string) {
	t.Helper()
	got, err := os.Readlink(path)
	if err != nil {
		t.Fatalf("Readlink(%s): %v", path, err)
	}
	if got != want {
		t.Fatalf("Readlink(%s) = %s, want %s", path, got, want)
	}
}

func mustMkdirAll(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatalf("MkdirAll(%s): %v", path, err)
	}
}

func trimTrailingNewline(s string) string {
	for len(s) > 0 && s[len(s)-1] == '\n' {
		s = s[:len(s)-1]
	}
	return s
}
