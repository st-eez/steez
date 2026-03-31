package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParsePreambleFrontmatter(t *testing.T) {
	tests := []struct {
		name     string
		content  string
		wantName string
		wantTier int
	}{
		{
			name:     "standard frontmatter",
			content:  "---\nname: steez-qa\npreamble-tier: 4\nversion: 1.0.0\n---\n# Content",
			wantName: "steez-qa",
			wantTier: 4,
		},
		{
			name:     "no preamble tier",
			content:  "---\nname: tmux\ndescription: test\n---\n# Content",
			wantName: "tmux",
			wantTier: 0,
		},
		{
			name:     "tier 1",
			content:  "---\nname: tmux\npreamble-tier: 1\n---\n# Content",
			wantName: "tmux",
			wantTier: 1,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			name, tier := parsePreambleFrontmatter(tt.content)
			if name != tt.wantName {
				t.Errorf("name = %q, want %q", name, tt.wantName)
			}
			if tier != tt.wantTier {
				t.Errorf("tier = %d, want %d", tier, tt.wantTier)
			}
		})
	}
}

func TestSplitAtFrontmatter(t *testing.T) {
	content := "---\nname: test\ntier: 1\n---\n\n# Skill Content"
	fm, rest := splitAtFrontmatter(content)
	if !strings.HasSuffix(fm, "---") {
		t.Errorf("frontmatter should end with ---: %q", fm)
	}
	if !strings.Contains(rest, "# Skill Content") {
		t.Errorf("rest should contain skill content: %q", rest)
	}
}

func TestSplitPreambleFromSkill(t *testing.T) {
	tests := []struct {
		name        string
		rest        string
		wantSkill   string
		wantNoSkill bool
	}{
		{
			name:      "finds skill heading",
			rest:      "\n## Preamble (run first)\nsome content\n\n# My Skill\nskill content",
			wantSkill: "# My Skill\nskill content",
		},
		{
			name:      "skips code block comments",
			rest:      "\n## Preamble (run first)\n```bash\n# this is a comment\n```\n\n# My Skill\nskill content",
			wantSkill: "# My Skill\nskill content",
		},
		{
			name:      "skips escaped code block content",
			rest:      "\n## Plan Status Footer\n\\`\\`\\`markdown\n## STEEZ REVIEW REPORT\n\\`\\`\\`\n\n# My Skill\nskill content",
			wantSkill: "# My Skill\nskill content",
		},
		{
			name:        "no skill content",
			rest:        "\n## Preamble (run first)\nsome content\n## Voice\nvoice content",
			wantNoSkill: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, skill := splitPreambleFromSkill(tt.rest)
			if tt.wantNoSkill {
				if skill != "" {
					t.Errorf("expected no skill content, got %q", skill)
				}
				return
			}
			if skill != tt.wantSkill {
				t.Errorf("skill content = %q, want %q", skill, tt.wantSkill)
			}
		})
	}
}

func TestSyncManagedBlock(t *testing.T) {
	t.Run("insert new managed block", func(t *testing.T) {
		content := "---\nname: test\npreamble-tier: 1\n---\n\n# My Skill\nskill content"
		managed := beginMarker + "\npreamble content\n" + endMarker
		result := syncManagedBlock(content, managed)

		if !strings.Contains(result, beginMarker) {
			t.Error("result should contain begin marker")
		}
		if !strings.Contains(result, endMarker) {
			t.Error("result should contain end marker")
		}
		if !strings.Contains(result, "# My Skill") {
			t.Error("result should preserve skill content")
		}
		// Managed block should come before skill content.
		beginIdx := strings.Index(result, beginMarker)
		skillIdx := strings.Index(result, "# My Skill")
		if beginIdx > skillIdx {
			t.Error("managed block should come before skill content")
		}
	})

	t.Run("replace existing managed block", func(t *testing.T) {
		content := "---\nname: test\n---\n\n" + beginMarker + "\nold content\n" + endMarker + "\n\n# My Skill"
		managed := beginMarker + "\nnew content\n" + endMarker
		result := syncManagedBlock(content, managed)

		if strings.Contains(result, "old content") {
			t.Error("old content should be replaced")
		}
		if !strings.Contains(result, "new content") {
			t.Error("new content should be present")
		}
		if !strings.Contains(result, "# My Skill") {
			t.Error("skill content should be preserved")
		}
	})
}

func TestAssemblePreamble(t *testing.T) {
	// Create a temp dir with section templates.
	tmpDir := t.TempDir()
	sectionsDir := filepath.Join(tmpDir, "preamble", "sections")
	if err := os.MkdirAll(sectionsDir, 0755); err != nil {
		t.Fatal(err)
	}

	os.WriteFile(filepath.Join(sectionsDir, "section-a.md"), []byte("## Section A\n\nContent for {{SKILL_NAME}}"), 0644)
	os.WriteFile(filepath.Join(sectionsDir, "section-b.md"), []byte("## Section B\n\nMore content"), 0644)

	result, err := assemblePreamble(tmpDir, []string{"section-a", "section-b"}, "steez-test")
	if err != nil {
		t.Fatalf("assemblePreamble error: %v", err)
	}

	if !strings.Contains(result, "Content for steez-test") {
		t.Error("should substitute {{SKILL_NAME}}")
	}
	if !strings.Contains(result, "## Section A") {
		t.Error("should contain section A")
	}
	if !strings.Contains(result, "## Section B") {
		t.Error("should contain section B")
	}
}

func TestLoadTiers(t *testing.T) {
	tmpDir := t.TempDir()
	tiersFile := filepath.Join(tmpDir, "tiers.json")
	os.WriteFile(tiersFile, []byte(`{"1": ["a", "b"], "2": ["a", "b", "c"]}`), 0644)

	tiers, err := loadTiers(tiersFile)
	if err != nil {
		t.Fatalf("loadTiers error: %v", err)
	}
	if len(tiers[1]) != 2 {
		t.Errorf("tier 1 should have 2 sections, got %d", len(tiers[1]))
	}
	if len(tiers[2]) != 3 {
		t.Errorf("tier 2 should have 3 sections, got %d", len(tiers[2]))
	}
}
