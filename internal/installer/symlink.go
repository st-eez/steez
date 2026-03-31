// Package installer provides symlink management and manifest parsing for the
// steez skill installer.
package installer

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

// Sentinel errors for symlink operations.
var (
	// ErrSymlinkExists is returned when a symlink already points to a different target.
	ErrSymlinkExists = errors.New("symlink exists with different target")

	// ErrTargetExists is returned when the target path is a regular file or directory.
	ErrTargetExists = errors.New("target exists and is not a symlink")

	// ErrSourceMissing is returned when the source directory does not exist.
	ErrSourceMissing = errors.New("source directory does not exist")

	// ErrPermission is returned when the operation lacks filesystem permissions.
	ErrPermission = errors.New("permission denied")

	// ErrNotSymlink is returned when attempting to remove a non-symlink path.
	ErrNotSymlink = errors.New("target is not a symlink")
)

// CreateSymlink creates a symlink at target pointing to source.
// If dryRun is true, it prints what would happen without making changes.
// If force is true, it replaces an existing symlink that points elsewhere.
func CreateSymlink(source, target string, dryRun bool, force bool) error {
	source = expandHome(source)
	target = expandHome(target)

	// Verify source exists.
	if _, err := os.Stat(source); os.IsNotExist(err) {
		return fmt.Errorf("%w: %s", ErrSourceMissing, source)
	} else if err != nil {
		return fmt.Errorf("%w: %s", ErrPermission, source)
	}

	if dryRun {
		fmt.Printf("Would create symlink: %s → %s\n", target, source)
		return nil
	}

	// Check if target already exists.
	linfo, err := os.Lstat(target)
	if err == nil {
		// Target exists — check what it is.
		if linfo.Mode()&os.ModeSymlink != 0 {
			// It's a symlink — check where it points.
			resolved, err := os.Readlink(target)
			if err != nil {
				return fmt.Errorf("%w: %s", ErrPermission, target)
			}
			if resolved == source {
				return nil // Idempotent: already correct.
			}
			if !force {
				return fmt.Errorf("%w: %s → %s (use --force to replace)", ErrSymlinkExists, target, resolved)
			}
			if err := os.Remove(target); err != nil {
				return fmt.Errorf("%w: %s", ErrPermission, target)
			}
		} else {
			// Regular file or directory — refuse.
			return fmt.Errorf("%w: %s", ErrTargetExists, target)
		}
	} else if !os.IsNotExist(err) {
		return fmt.Errorf("%w: %s", ErrPermission, target)
	}

	// Ensure parent directory exists.
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return fmt.Errorf("%w: %s", ErrPermission, filepath.Dir(target))
	}

	if err := os.Symlink(source, target); err != nil {
		return fmt.Errorf("%w: %s", ErrPermission, target)
	}
	return nil
}

// RemoveSymlink removes a symlink at target. It refuses to delete regular files
// or directories. It is idempotent — removing a non-existent target returns nil.
func RemoveSymlink(target string) error {
	target = expandHome(target)

	linfo, err := os.Lstat(target)
	if os.IsNotExist(err) {
		return nil // Idempotent.
	}
	if err != nil {
		return fmt.Errorf("%w: %s", ErrPermission, target)
	}

	if linfo.Mode()&os.ModeSymlink == 0 {
		return fmt.Errorf("%w: %s (refusing to delete real content)", ErrNotSymlink, target)
	}

	if err := os.Remove(target); err != nil {
		return fmt.Errorf("%w: %s", ErrPermission, target)
	}
	return nil
}

// IsSymlink checks whether path is a symlink and returns its resolved target.
func IsSymlink(path string) (bool, string, error) {
	path = expandHome(path)

	linfo, err := os.Lstat(path)
	if os.IsNotExist(err) {
		return false, "", nil
	}
	if err != nil {
		return false, "", fmt.Errorf("%w: %s", ErrPermission, path)
	}

	if linfo.Mode()&os.ModeSymlink == 0 {
		return false, "", nil
	}

	resolved, err := os.Readlink(path)
	if err != nil {
		return false, "", fmt.Errorf("%w: %s", ErrPermission, path)
	}
	return true, resolved, nil
}

// ValidateSymlink checks that path is a symlink and that its target directory
// actually exists on disk.
func ValidateSymlink(target string) error {
	target = expandHome(target)

	isSym, resolved, err := IsSymlink(target)
	if err != nil {
		return err
	}
	if !isSym {
		return fmt.Errorf("%w: %s", ErrNotSymlink, target)
	}

	if _, err := os.Stat(resolved); os.IsNotExist(err) {
		return fmt.Errorf("symlink %s points to missing directory: %s", target, resolved)
	} else if err != nil {
		return fmt.Errorf("%w: %s", ErrPermission, resolved)
	}
	return nil
}

// expandHome replaces a leading ~ with the user's home directory.
func expandHome(path string) string {
	if len(path) == 0 || path[0] != '~' {
		return path
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return path
	}
	return filepath.Join(home, path[1:])
}
