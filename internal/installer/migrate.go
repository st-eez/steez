package installer

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// MigrationState describes the current state of ~/.claude/skills/.
type MigrationState int

const (
	// StateStowFolded means ~/.claude/skills/ is a stow-folded symlink (Case A).
	StateStowFolded MigrationState = iota

	// StateParentFolded means ~/.claude/ itself is a symlink (Case A2).
	StateParentFolded

	// StateRealDirectory means ~/.claude/skills/ is a real directory (Case B).
	StateRealDirectory

	// StateMissing means ~/.claude/skills/ does not exist (Case C).
	StateMissing
)

// String returns a human-readable label for the migration state.
func (s MigrationState) String() string {
	switch s {
	case StateStowFolded:
		return "stow-folded (~/.claude/skills/ is a symlink)"
	case StateParentFolded:
		return "parent-folded (~/.claude/ is a symlink)"
	case StateRealDirectory:
		return "real directory (ready for install)"
	case StateMissing:
		return "missing (~/.claude/skills/ does not exist)"
	default:
		return "unknown"
	}
}

// MigrationResult holds the detection result and any commands needed.
type MigrationResult struct {
	State       MigrationState
	SymlinkPath string   // resolved symlink target (Case A/A2 only)
	Commands    []string // shell commands the user needs to run
}

// DetectMigration checks the state of ~/.claude/skills/ and returns
// migration instructions if the stow fold needs to be broken.
func DetectMigration() (*MigrationResult, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, fmt.Errorf("resolving home directory: %w", err)
	}

	claudeDir := filepath.Join(home, ".claude")
	skillsDir := filepath.Join(claudeDir, "skills")

	// Case A2: check if ~/.claude/ itself is a symlink.
	isSym, resolved, err := IsSymlink(claudeDir)
	if err != nil {
		return nil, fmt.Errorf("checking %s: %w", claudeDir, err)
	}
	if isSym {
		cmds := deriveUnfoldCommands(claudeDir, resolved, home)
		return &MigrationResult{
			State:       StateParentFolded,
			SymlinkPath: resolved,
			Commands:    cmds,
		}, nil
	}

	// Case A: check if ~/.claude/skills/ is a symlink.
	isSym, resolved, err = IsSymlink(skillsDir)
	if err != nil {
		return nil, fmt.Errorf("checking %s: %w", skillsDir, err)
	}
	if isSym {
		cmds := deriveUnfoldCommands(skillsDir, resolved, home)
		return &MigrationResult{
			State:       StateStowFolded,
			SymlinkPath: resolved,
			Commands:    cmds,
		}, nil
	}

	// Case B: check if it's a real directory.
	info, err := os.Stat(skillsDir)
	if err == nil && info.IsDir() {
		return &MigrationResult{
			State: StateRealDirectory,
		}, nil
	}

	// Case C: does not exist.
	if os.IsNotExist(err) || err == nil {
		return &MigrationResult{
			State: StateMissing,
		}, nil
	}

	return nil, fmt.Errorf("unexpected state at %s: %w", skillsDir, err)
}

// deriveUnfoldCommands generates the shell commands to break a stow fold.
// It derives the stow --dir and package name from the resolved symlink target.
//
// Given symlink at ~/.claude/skills/ resolving to
// /Users/x/dotfiles/claude/.claude/skills/, the function walks up the resolved
// path by the relative depth to find the stow dir and package name.
func deriveUnfoldCommands(symlinkPath, resolvedTarget, home string) []string {
	var cmds []string

	// Use $HOME in the displayed commands for portability.
	displayPath := homeRelative(symlinkPath, home)

	cmds = append(cmds, fmt.Sprintf("unlink %s", displayPath))
	cmds = append(cmds, fmt.Sprintf("mkdir -p %s", displayPath))

	// Derive stow --dir and package from the resolved path.
	stowDir, pkg := deriveStowPaths(symlinkPath, resolvedTarget, home)
	if stowDir != "" && pkg != "" {
		cmds = append(cmds, fmt.Sprintf(
			`stow --dir="%s" --target="$HOME" --no-folding --restow %s`,
			stowDir, pkg,
		))
	}

	return cmds
}

// deriveStowPaths extracts the stow directory and package name from a resolved
// symlink. If ~/.claude/skills/ resolves to <stowdir>/claude/.claude/skills/,
// it returns (<stowdir>, "claude").
func deriveStowPaths(symlinkPath, resolvedTarget, home string) (stowDir, pkg string) {
	// Calculate relative depth from home to the symlink.
	// ~/.claude/skills → relative to home is .claude/skills → depth 2
	rel, err := filepath.Rel(home, symlinkPath)
	if err != nil {
		return "", ""
	}
	depth := len(strings.Split(filepath.Clean(rel), string(filepath.Separator)))

	// Resolve the target to absolute if it's relative (stow uses relative symlinks).
	resolved := resolvedTarget
	if !filepath.IsAbs(resolved) {
		resolved = filepath.Join(filepath.Dir(symlinkPath), resolved)
	}
	resolved = filepath.Clean(resolved)

	// Walk up the resolved path by (depth) to get the package directory,
	// then one more to get the stow directory.
	pkgDir := resolved
	for range depth {
		pkgDir = filepath.Dir(pkgDir)
	}
	// pkgDir is now <stowdir>/<package>

	stowDir = filepath.Dir(pkgDir)
	pkg = filepath.Base(pkgDir)

	// Use $HOME prefix if stow dir is under home.
	stowDir = homeRelative(stowDir, home)

	return stowDir, pkg
}

// homeRelative replaces the home directory prefix with $HOME for display.
func homeRelative(path, home string) string {
	if strings.HasPrefix(path, home) {
		return "$HOME" + path[len(home):]
	}
	return path
}
