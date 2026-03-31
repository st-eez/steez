package updater

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
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
