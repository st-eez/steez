package installer

import (
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
)

func TestSharedBinSymlinksCoverAgentRuntimeDeps(t *testing.T) {
	repoPath := findRepoRoot(t)

	manifestBins := make(map[string]struct{}, len(SharedBinSymlinks()))
	for _, bin := range SharedBinSymlinks() {
		manifestBins[bin.Name] = struct{}{}
	}

	agentScripts, err := filepath.Glob(filepath.Join(repoPath, "shared", "steez", "bin", "agent-*"))
	if err != nil {
		t.Fatalf("glob agent scripts: %v", err)
	}
	if len(agentScripts) == 0 {
		t.Fatal("no agent scripts found")
	}

	depPattern := regexp.MustCompile(`\$HOME/\.steez/bin/([A-Za-z0-9._-]+)`)
	missing := map[string][]string{}
	depCount := 0

	for _, scriptPath := range agentScripts {
		content, err := os.ReadFile(scriptPath)
		if err != nil {
			t.Fatalf("read %s: %v", scriptPath, err)
		}

		for _, match := range depPattern.FindAllStringSubmatch(string(content), -1) {
			dep := match[1]
			depCount++
			if _, ok := manifestBins[dep]; ok {
				continue
			}
			missing[dep] = append(missing[dep], filepath.Base(scriptPath))
		}
	}

	if depCount == 0 {
		t.Fatal("no $HOME/.steez/bin deps found in agent-* scripts")
	}

	if len(missing) == 0 {
		return
	}

	var failures []string
	for dep, scripts := range missing {
		slices.Sort(scripts)
		scripts = slices.Compact(scripts)
		failures = append(failures, dep+" <- "+strings.Join(scripts, ", "))
	}
	slices.Sort(failures)
	t.Fatalf("shared bin manifest missing agent runtime deps: %s", strings.Join(failures, "; "))
}
