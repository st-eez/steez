package installer

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// BuildBrowse compiles the browse binary from TypeScript source using Bun.
func BuildBrowse(repoPath string) error {
	browseDir := filepath.Join(repoPath, "shared", "steez", "browse")

	// Verify source exists.
	if _, err := os.Stat(filepath.Join(browseDir, "src")); err != nil {
		return fmt.Errorf("browse source not found at %s/src", browseDir)
	}

	// Check Bun.
	if err := CheckBunVersion("1.0.0"); err != nil {
		return err
	}

	// Wipe partial node_modules if it looks incomplete.
	nmDir := filepath.Join(browseDir, "node_modules")
	if info, err := os.Stat(nmDir); err == nil && info.IsDir() {
		lockFile := filepath.Join(browseDir, "bun.lock")
		if _, err := os.Stat(lockFile); os.IsNotExist(err) {
			fmt.Println("Wiping incomplete node_modules/...")
			os.RemoveAll(nmDir)
		}
	}

	// Install dependencies.
	fmt.Println("Installing browse dependencies...")
	install := exec.Command("bun", "install")
	install.Dir = browseDir
	install.Stdout = os.Stdout
	install.Stderr = os.Stderr
	if err := install.Run(); err != nil {
		return fmt.Errorf("bun install failed: %w", err)
	}

	// Build.
	fmt.Println("Building browse binary...")
	build := exec.Command("bun", "run", "build")
	build.Dir = browseDir
	build.Stdout = os.Stdout
	build.Stderr = os.Stderr
	if err := build.Run(); err != nil {
		return fmt.Errorf("bun run build failed: %w", err)
	}

	// Verify output.
	distBin := filepath.Join(browseDir, "dist", "browse")
	info, err := os.Stat(distBin)
	if err != nil {
		return fmt.Errorf("browse build failed — %s not found. Check output above", distBin)
	}
	if info.Mode()&0o111 == 0 {
		// Make executable.
		if err := os.Chmod(distBin, info.Mode()|0o755); err != nil {
			return fmt.Errorf("could not make browse binary executable: %w", err)
		}
	}

	fmt.Println("Browse binary built successfully.")
	return nil
}

// CheckBunVersion verifies Bun is installed and meets the minimum version.
func CheckBunVersion(minVersion string) error {
	bunPath, err := exec.LookPath("bun")
	if err != nil {
		return fmt.Errorf("bun not installed. Install: curl -fsSL https://bun.sh/install | bash")
	}

	out, err := exec.Command(bunPath, "--version").Output()
	if err != nil {
		return fmt.Errorf("could not check bun version: %w", err)
	}

	ver := strings.TrimSpace(string(out))
	if !versionAtLeast(ver, minVersion) {
		return fmt.Errorf("bun %s found, minimum %s required", ver, minVersion)
	}

	return nil
}

// versionAtLeast does a simple semver comparison (major.minor.patch).
func versionAtLeast(have, want string) bool {
	h := parseVersion(have)
	w := parseVersion(want)
	for i := 0; i < 3; i++ {
		if h[i] > w[i] {
			return true
		}
		if h[i] < w[i] {
			return false
		}
	}
	return true // equal
}

func parseVersion(v string) [3]int {
	v = strings.TrimPrefix(v, "v")
	var parts [3]int
	fmt.Sscanf(v, "%d.%d.%d", &parts[0], &parts[1], &parts[2])
	return parts
}
