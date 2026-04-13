// Package updater handles git-based updates for the steez repo and CLI binary.
package updater

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/st-eez/steez/internal/config"
	"github.com/st-eez/steez/internal/installer"
)

// RunUpdate pulls the latest changes and re-validates symlinks.
func RunUpdate() error {
	cfg, err := config.Load()
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}
	if cfg.RepoPath == "" {
		return fmt.Errorf("repo path not configured. Run steez setup first")
	}

	repoPath := cfg.RepoPath

	// Verify it's a valid steez repo.
	if _, err := os.Stat(filepath.Join(repoPath, "skills.json")); err != nil {
		return fmt.Errorf("no skills.json at %s — is this the steez repo?", repoPath)
	}

	// 1. Check for dirty working tree.
	if err := checkClean(repoPath); err != nil {
		return err
	}

	// 2. Save current HEAD.
	oldHead, err := gitOutput(repoPath, "rev-parse", "HEAD")
	if err != nil {
		return fmt.Errorf("reading HEAD: %w", err)
	}

	// 3. Pull --ff-only.
	fmt.Println("Pulling latest changes...")
	if err := gitRun(repoPath, "pull", "--ff-only"); err != nil {
		return fmt.Errorf("pull failed — local and remote may have diverged.\nResolve manually: git -C %s pull --rebase", repoPath)
	}

	// 4. Compare HEAD.
	newHead, err := gitOutput(repoPath, "rev-parse", "HEAD")
	if err != nil {
		return fmt.Errorf("reading HEAD after pull: %w", err)
	}

	if oldHead == newHead {
		fmt.Println("Already up to date.")
		return nil
	}

	fmt.Printf("Updated %s..%s\n", oldHead[:8], newHead[:8])

	home, err := os.UserHomeDir()
	if err != nil {
		return fmt.Errorf("resolving home directory: %w", err)
	}

	steezHome := filepath.Join(home, ".steez")
	if err := os.MkdirAll(steezHome, 0o755); err != nil {
		return fmt.Errorf("creating %s: %w", steezHome, err)
	}

	repoSymlink := filepath.Join(steezHome, "repo")
	if err := installer.CreateSymlink(repoPath, repoSymlink, false, true); err != nil {
		fmt.Fprintf(os.Stderr, "warning: could not refresh repo symlink: %v\n", err)
	}

	binDir := filepath.Join(steezHome, "bin")
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		return fmt.Errorf("creating %s: %w", binDir, err)
	}
	for _, old := range installer.DeprecatedBinSymlinks() {
		_ = installer.RemoveSymlink(filepath.Join(binDir, old))
	}
	for _, bin := range installer.SharedBinSymlinks() {
		source := filepath.Join(repoSymlink, bin.RelPath)
		target := filepath.Join(binDir, bin.Name)
		if err := installer.CreateSymlink(source, target, false, true); err != nil {
			fmt.Fprintf(os.Stderr, "warning: could not refresh ~/.steez/bin/%s: %v\n", bin.Name, err)
		}
	}

	hookDir := filepath.Join(home, ".claude", "hooks")
	if err := os.MkdirAll(hookDir, 0o755); err != nil {
		return fmt.Errorf("creating %s: %w", hookDir, err)
	}
	for _, hook := range installer.SharedClaudeHookSymlinks() {
		source := filepath.Join(repoSymlink, hook.RelPath)
		target := filepath.Join(hookDir, hook.Name)
		if err := installer.CreateSymlink(source, target, false, true); err != nil {
			fmt.Fprintf(os.Stderr, "warning: could not refresh ~/.claude/hooks/%s: %v\n", hook.Name, err)
		}
	}

	codexHookDir := filepath.Join(home, ".codex", "hooks")
	if err := os.MkdirAll(codexHookDir, 0o755); err != nil {
		return fmt.Errorf("creating %s: %w", codexHookDir, err)
	}
	for _, hook := range installer.SharedCodexHookSymlinks() {
		source := filepath.Join(repoSymlink, hook.RelPath)
		target := filepath.Join(codexHookDir, hook.Name)
		if err := installer.CreateSymlink(source, target, false, true); err != nil {
			fmt.Fprintf(os.Stderr, "warning: could not refresh ~/.codex/hooks/%s: %v\n", hook.Name, err)
		}
	}

	// 5. Re-validate symlinks.
	reg, err := config.LoadRegistry()
	if err != nil {
		return fmt.Errorf("loading registry: %w", err)
	}

	relinked := 0
	for _, entry := range reg.Symlinks {
		if err := installer.ValidateSymlink(entry.Target); err != nil {
			// Try to re-create the symlink.
			if err := installer.CreateSymlink(entry.Source, entry.Target, false, true); err != nil {
				fmt.Fprintf(os.Stderr, "  warning: could not re-link %s: %v\n", entry.Name, err)
			} else {
				relinked++
			}
		}
	}
	if relinked > 0 {
		fmt.Printf("Re-linked %d symlinks.\n", relinked)
	}

	// 6. Check if Go source changed — rebuild binary if so.
	diff, _ := gitOutput(repoPath, "diff", "--name-only", oldHead, newHead)
	if containsGoChanges(diff) {
		if err := rebuildBinary(repoPath); err != nil {
			fmt.Fprintf(os.Stderr, "warning: binary rebuild failed: %v\n", err)
		}
	}

	// 7. Run doctor.
	results, err := installer.RunDoctor(repoPath, false)
	if err != nil {
		fmt.Fprintf(os.Stderr, "warning: doctor failed: %v\n", err)
		return nil
	}

	passes, fails, warns := 0, 0, 0
	for _, r := range results {
		switch r.Status {
		case "pass":
			passes++
		case "fail":
			fails++
		case "warn":
			warns++
		}
	}

	fmt.Printf("\nDoctor: %d passed, %d failed, %d warnings\n", passes, fails, warns)
	return nil
}

func checkClean(repoPath string) error {
	out, err := gitOutput(repoPath, "status", "--porcelain")
	if err != nil {
		return fmt.Errorf("checking repo status: %w", err)
	}
	if strings.TrimSpace(out) != "" {
		return fmt.Errorf("working tree is dirty (uncommitted or untracked files).\nStash or commit them first: git -C %s stash", repoPath)
	}
	return nil
}

func containsGoChanges(diffOutput string) bool {
	for _, line := range strings.Split(diffOutput, "\n") {
		if strings.HasSuffix(strings.TrimSpace(line), ".go") {
			return true
		}
	}
	return false
}

func rebuildBinary(repoPath string) error {
	fmt.Println("Go source changed — rebuilding steez CLI...")

	tmpBin := filepath.Join(repoPath, "steez.new")

	// Build to temp file.
	cmd := exec.Command("go", "build", "-o", tmpBin, "./cmd/steez")
	cmd.Dir = repoPath
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("build failed: %w", err)
	}

	// Validate.
	validate := exec.Command(tmpBin, "version")
	if out, err := validate.Output(); err != nil {
		os.Remove(tmpBin)
		return fmt.Errorf("validation failed: %w", err)
	} else {
		fmt.Printf("  Built: %s", string(out))
	}

	// Clean up temp binary (go install handles the real install).
	os.Remove(tmpBin)

	// Install to ~/go/bin/steez.
	install := exec.Command("go", "install", "./cmd/steez")
	install.Dir = repoPath
	install.Stdout = os.Stdout
	install.Stderr = os.Stderr
	if err := install.Run(); err != nil {
		return fmt.Errorf("go install failed: %w", err)
	}

	fmt.Println("steez CLI updated. You're now running the new version.")
	return nil
}

func gitOutput(repoPath string, args ...string) (string, error) {
	fullArgs := append([]string{"-C", repoPath}, args...)
	out, err := exec.Command("git", fullArgs...).Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

func gitRun(repoPath string, args ...string) error {
	fullArgs := append([]string{"-C", repoPath}, args...)
	cmd := exec.Command("git", fullArgs...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}
