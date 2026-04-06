package installer

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/st-eez/steez/internal/config"
)

// CheckResult represents a single doctor check outcome.
type CheckResult struct {
	Name    string // e.g. "steez-office-hours symlink"
	Status  string // "pass", "fail", "warn"
	Message string // human-readable detail
	FixCmd  string // command to fix (for --fix mode), empty if n/a
}

// RunDoctor validates the health of a steez installation.
// If fix is true, it auto-repairs what it can (dangling symlinks, missing dirs).
func RunDoctor(repoPath string, fix bool) ([]CheckResult, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, fmt.Errorf("resolving home directory: %w", err)
	}

	var results []CheckResult

	// 1. Repo symlink (fail-fast).
	steezHome := filepath.Join(home, ".steez")
	repoSymlink := filepath.Join(steezHome, "repo")
	r := checkRepoSymlink(repoSymlink, repoPath)
	results = append(results, r)
	if r.Status == "fail" {
		// Everything else depends on repo symlink.
		return results, nil
	}

	// 1b. Bin symlinks.
	results = append(results, checkBinSymlinks(steezHome)...)

	// 1c. Hook symlinks.
	results = append(results, checkHookSymlinks(home)...)

	// 2. Runtime directory.
	results = append(results, checkRuntimeDirs(home, fix)...)

	// 3. Registered symlinks.
	reg, err := config.LoadRegistry()
	if err != nil {
		results = append(results, CheckResult{
			Name:    "Install registry",
			Status:  "fail",
			Message: fmt.Sprintf("Could not load installed.json: %v", err),
		})
		return results, nil
	}
	results = append(results, checkRegisteredSymlinks(reg, fix)...)

	// 4. Non-registered steez symlinks.
	skillsDir := filepath.Join(home, ".claude", "skills")
	results = append(results, checkUnregisteredSymlinks(skillsDir, reg)...)

	// 5. Browse binary (only if browse-dependent skills installed).
	results = append(results, checkBrowseBinary(repoPath, reg)...)

	return results, nil
}

// ExitCode returns the appropriate exit code for a set of doctor results.
// 0 = all pass, 1 = any failure, 2 = warnings only.
func ExitCode(results []CheckResult) int {
	hasFail := false
	hasWarn := false
	for _, r := range results {
		switch r.Status {
		case "fail":
			hasFail = true
		case "warn":
			hasWarn = true
		}
	}
	if hasFail {
		return 1
	}
	if hasWarn {
		return 2
	}
	return 0
}

func checkRepoSymlink(repoSymlink, repoPath string) CheckResult {
	isSym, resolved, err := IsSymlink(repoSymlink)
	if err != nil {
		return CheckResult{
			Name:    "Repo symlink",
			Status:  "fail",
			Message: fmt.Sprintf("Error checking %s: %v", repoSymlink, err),
			FixCmd:  "steez install",
		}
	}
	if !isSym {
		if _, err := os.Stat(repoSymlink); os.IsNotExist(err) {
			return CheckResult{
				Name:    "Repo symlink",
				Status:  "fail",
				Message: "Missing: ~/.steez/repo — all bin symlinks depend on this",
				FixCmd:  "steez install",
			}
		}
		return CheckResult{
			Name:    "Repo symlink",
			Status:  "warn",
			Message: "~/.steez/repo is a real directory, not a symlink — re-pointing won't work",
		}
	}

	if err := ValidateSymlink(repoSymlink); err != nil {
		return CheckResult{
			Name:    "Repo symlink",
			Status:  "fail",
			Message: fmt.Sprintf("Dangling symlink: %s → %s", repoSymlink, resolved),
			FixCmd:  "steez install",
		}
	}

	return CheckResult{
		Name:    "Repo symlink",
		Status:  "pass",
		Message: fmt.Sprintf("~/.steez/repo → %s", resolved),
	}
}

func checkBinSymlinks(steezHome string) []CheckResult {
	binDir := filepath.Join(steezHome, "bin")
	expected := []string{
		"steez-config", "steez-slug", "steez-diff-scope",
		"steez-review-log", "steez-review-read", "steez-bd",
		"steez-agent-state", "steez-agent-history", "browse",
	}

	var results []CheckResult

	if _, err := os.Stat(binDir); os.IsNotExist(err) {
		results = append(results, CheckResult{
			Name:    "Bin directory",
			Status:  "fail",
			Message: "Missing: ~/.steez/bin/ — run steez install",
			FixCmd:  "steez install",
		})
		return results
	}

	for _, name := range expected {
		path := filepath.Join(binDir, name)
		isSym, resolved, err := IsSymlink(path)
		if err != nil || !isSym {
			if _, statErr := os.Stat(path); os.IsNotExist(statErr) {
				results = append(results, CheckResult{
					Name:    fmt.Sprintf("bin/%s", name),
					Status:  "warn",
					Message: fmt.Sprintf("Missing: ~/.steez/bin/%s", name),
					FixCmd:  "steez install",
				})
			} else {
				results = append(results, CheckResult{
					Name:    fmt.Sprintf("bin/%s", name),
					Status:  "warn",
					Message: fmt.Sprintf("~/.steez/bin/%s is not a symlink", name),
				})
			}
			continue
		}

		if err := ValidateSymlink(path); err != nil {
			results = append(results, CheckResult{
				Name:    fmt.Sprintf("bin/%s", name),
				Status:  "fail",
				Message: fmt.Sprintf("Dangling: ~/.steez/bin/%s → %s", name, resolved),
				FixCmd:  "steez install",
			})
			continue
		}

		results = append(results, CheckResult{
			Name:    fmt.Sprintf("bin/%s", name),
			Status:  "pass",
			Message: fmt.Sprintf("~/.steez/bin/%s → %s", name, resolved),
		})
	}

	return results
}

func checkHookSymlinks(home string) []CheckResult {
	hookDir := filepath.Join(home, ".claude", "hooks")
	expected := []string{
		"steez-skill-analytics.sh",
		"steez-session-start.sh",
	}

	var results []CheckResult

	if _, err := os.Stat(hookDir); os.IsNotExist(err) {
		results = append(results, CheckResult{
			Name:    "Hooks directory",
			Status:  "warn",
			Message: "Missing: ~/.claude/hooks/ — run steez install",
			FixCmd:  "steez install",
		})
		return results
	}

	for _, name := range expected {
		path := filepath.Join(hookDir, name)
		isSym, resolved, err := IsSymlink(path)
		if err != nil || !isSym {
			if _, statErr := os.Stat(path); os.IsNotExist(statErr) {
				results = append(results, CheckResult{
					Name:    fmt.Sprintf("hooks/%s", name),
					Status:  "warn",
					Message: fmt.Sprintf("Missing: ~/.claude/hooks/%s", name),
					FixCmd:  "steez install",
				})
			} else {
				results = append(results, CheckResult{
					Name:    fmt.Sprintf("hooks/%s", name),
					Status:  "warn",
					Message: fmt.Sprintf("~/.claude/hooks/%s is not a symlink", name),
				})
			}
			continue
		}

		if err := ValidateSymlink(path); err != nil {
			results = append(results, CheckResult{
				Name:    fmt.Sprintf("hooks/%s", name),
				Status:  "fail",
				Message: fmt.Sprintf("Dangling: ~/.claude/hooks/%s → %s", name, resolved),
				FixCmd:  "steez install",
			})
			continue
		}

		results = append(results, CheckResult{
			Name:    fmt.Sprintf("hooks/%s", name),
			Status:  "pass",
			Message: fmt.Sprintf("~/.claude/hooks/%s → %s", name, resolved),
		})
	}

	return results
}

func checkRuntimeDirs(home string, fix bool) []CheckResult {
	steezDir := filepath.Join(home, ".steez")
	dirs := []struct {
		path string
		name string
	}{
		{steezDir, "Runtime directory (~/.steez/)"},
		{filepath.Join(steezDir, "analytics"), "Analytics directory"},
	}

	var results []CheckResult
	for _, d := range dirs {
		info, err := os.Stat(d.path)
		if os.IsNotExist(err) {
			if fix {
				if mkErr := os.MkdirAll(d.path, 0o755); mkErr != nil {
					results = append(results, CheckResult{
						Name:    d.name,
						Status:  "fail",
						Message: fmt.Sprintf("Could not create %s: %v", d.path, mkErr),
					})
				} else {
					results = append(results, CheckResult{
						Name:    d.name,
						Status:  "pass",
						Message: fmt.Sprintf("Fixed: created %s", d.path),
					})
				}
			} else {
				results = append(results, CheckResult{
					Name:    d.name,
					Status:  "warn",
					Message: fmt.Sprintf("Missing: %s", d.path),
					FixCmd:  fmt.Sprintf("mkdir -p %s", d.path),
				})
			}
		} else if err != nil {
			results = append(results, CheckResult{
				Name:   d.name,
				Status: "fail",
				Message: fmt.Sprintf("Error checking %s: %v", d.path, err),
			})
		} else if !info.IsDir() {
			results = append(results, CheckResult{
				Name:   d.name,
				Status: "fail",
				Message: fmt.Sprintf("%s exists but is not a directory", d.path),
			})
		} else {
			results = append(results, CheckResult{
				Name:    d.name,
				Status:  "pass",
				Message: d.path,
			})
		}
	}

	// Also check config file.
	cfgPath := filepath.Join(steezDir, "config.json")
	if _, err := os.Stat(cfgPath); os.IsNotExist(err) {
		results = append(results, CheckResult{
			Name:    "Config file",
			Status:  "warn",
			Message: "Missing: ~/.steez/config.json (will be created on first install)",
		})
	} else if err == nil {
		results = append(results, CheckResult{
			Name:    "Config file",
			Status:  "pass",
			Message: cfgPath,
		})
	}

	return results
}

func checkRegisteredSymlinks(reg *config.Registry, fix bool) []CheckResult {
	var results []CheckResult

	for _, entry := range reg.Symlinks {
		isSym, resolved, err := IsSymlink(entry.Target)
		if err != nil {
			results = append(results, CheckResult{
				Name:   entry.Name,
				Status: "fail",
				Message: fmt.Sprintf("Error checking %s: %v", entry.Target, err),
			})
			continue
		}

		if !isSym {
			// Missing symlink (removed manually).
			if _, statErr := os.Stat(entry.Target); os.IsNotExist(statErr) {
				results = append(results, CheckResult{
					Name:    entry.Name,
					Status:  "warn",
					Message: fmt.Sprintf("Missing symlink: %s", entry.Target),
					FixCmd:  fmt.Sprintf("steez install %s", strings.TrimPrefix(entry.Name, "steez-")),
				})
			} else {
				// Exists as a real dir/file.
				results = append(results, CheckResult{
					Name:    entry.Name,
					Status:  "warn",
					Message: fmt.Sprintf("Expected symlink but found real path: %s", entry.Target),
				})
			}
			continue
		}

		// It's a symlink — check if it resolves.
		if err := ValidateSymlink(entry.Target); err != nil {
			// Dangling symlink.
			if fix {
				if rmErr := os.Remove(entry.Target); rmErr != nil {
					results = append(results, CheckResult{
						Name:   entry.Name,
						Status: "fail",
						Message: fmt.Sprintf("Dangling symlink → %s (could not remove: %v)", resolved, rmErr),
					})
				} else {
					config.RemoveFromRegistry(reg, entry.Name)
					results = append(results, CheckResult{
						Name:    entry.Name,
						Status:  "pass",
						Message: fmt.Sprintf("Fixed: removed dangling symlink %s", entry.Target),
					})
				}
			} else {
				results = append(results, CheckResult{
					Name:    entry.Name,
					Status:  "fail",
					Message: fmt.Sprintf("Dangling symlink: %s → %s", entry.Target, resolved),
					FixCmd:  "steez doctor --fix",
				})
			}
			continue
		}

		results = append(results, CheckResult{
			Name:    entry.Name,
			Status:  "pass",
			Message: fmt.Sprintf("%s → %s", entry.Target, resolved),
		})
	}

	// If we fixed anything, save the registry.
	if fix {
		_ = config.SaveRegistry(reg)
	}

	return results
}

func checkUnregisteredSymlinks(skillsDir string, reg *config.Registry) []CheckResult {
	var results []CheckResult

	// Build a set of registered target paths for fast lookup.
	registered := make(map[string]bool, len(reg.Symlinks))
	for _, s := range reg.Symlinks {
		registered[s.Target] = true
	}

	entries, err := os.ReadDir(skillsDir)
	if err != nil {
		return nil // Skills dir might not exist yet.
	}

	for _, entry := range entries {
		name := entry.Name()
		if !strings.HasPrefix(name, "steez-") {
			continue
		}

		fullPath := filepath.Join(skillsDir, name)
		if registered[fullPath] {
			continue
		}

		isSym, _, _ := IsSymlink(fullPath)
		if isSym {
			skillName := strings.TrimPrefix(name, "steez-")
			results = append(results, CheckResult{
				Name:    name,
				Status:  "warn",
				Message: fmt.Sprintf("Unregistered steez symlink. Run: steez install %s", skillName),
			})
		}
	}

	return results
}

func checkBrowseBinary(repoPath string, reg *config.Registry) []CheckResult {
	// Check if any browse-dependent skills are installed.
	browseSkills := []string{"steez-browse", "steez-qa", "steez-qa-only",
		"steez-design-review", "steez-canary", "steez-benchmark",
		"steez-connect-chrome", "steez-setup-browser-cookies"}

	hasBrowseSkill := false
	for _, s := range reg.Symlinks {
		for _, bs := range browseSkills {
			if s.Name == bs {
				hasBrowseSkill = true
				break
			}
		}
		if hasBrowseSkill {
			break
		}
	}

	if !hasBrowseSkill {
		return nil
	}

	browseBin := filepath.Join(repoPath, "shared", "steez", "browse", "dist", "browse")
	info, err := os.Stat(browseBin)
	if os.IsNotExist(err) {
		return []CheckResult{{
			Name:    "Browse binary",
			Status:  "warn",
			Message: "Not built. Run: steez setup --browse",
		}}
	}
	if err != nil {
		return []CheckResult{{
			Name:   "Browse binary",
			Status: "fail",
			Message: fmt.Sprintf("Error checking browse binary: %v", err),
		}}
	}
	if info.Mode()&0o111 == 0 {
		return []CheckResult{{
			Name:    "Browse binary",
			Status:  "warn",
			Message: "Browse binary exists but is not executable",
			FixCmd:  fmt.Sprintf("chmod +x %s", browseBin),
		}}
	}

	return []CheckResult{{
		Name:    "Browse binary",
		Status:  "pass",
		Message: browseBin,
	}}
}
