package installer

import "testing"

func TestInstallsGloballyInCodex(t *testing.T) {
	if !InstallsGloballyInCodex("spawn-agent") {
		t.Fatal("spawn-agent should install globally in Codex")
	}

	if !InstallsGloballyInCodex("spec") {
		t.Fatal("spec should install globally in Codex")
	}

	if InstallsGloballyInCodex("investigate") {
		t.Fatal("investigate should not install globally in Codex")
	}
}
