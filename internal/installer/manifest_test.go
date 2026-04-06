package installer

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const validManifest = `{
  "version": "1.0.0",
  "skills": {
    "alpha": {"description": "Alpha skill"},
    "beta":  {"description": "Beta skill", "requires": ["browse-binary"]},
    "gamma": {"description": "Gamma skill"}
  },
  "categories": {
    "core": {
      "label": "Core",
      "description": "Core skills",
      "skills": ["alpha", "beta"]
    },
    "extra": {
      "label": "Extra",
      "description": "Extra skills",
      "skills": ["gamma"]
    }
  },
  "profiles": {
    "starter": {
      "label": "Starter",
      "description": "Core only",
      "categories": ["core"]
    },
    "all": {
      "label": "All",
      "description": "Everything",
      "exclude_categories": []
    }
  },
  "shared_infra": {
    "bin": ["steez-bd", "config", "slug"],
    "runtime_dir": "~/.steez",
    "browse_binary": "skills/browse/dist/browse"
  }
}`

func writeManifest(t *testing.T, content string) string {
	t.Helper()
	tmp := t.TempDir()
	path := filepath.Join(tmp, "skills.json")
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestLoadManifest_Valid(t *testing.T) {
	path := writeManifest(t, validManifest)
	m, err := LoadManifest(path)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if m.Version != "1.0.0" {
		t.Errorf("version = %s, want 1.0.0", m.Version)
	}
	if len(m.Skills) != 3 {
		t.Errorf("skills count = %d, want 3", len(m.Skills))
	}
	if len(m.Categories) != 2 {
		t.Errorf("categories count = %d, want 2", len(m.Categories))
	}
	if len(m.Categories["core"].Skills) != 2 {
		t.Errorf("core skills count = %d, want 2", len(m.Categories["core"].Skills))
	}
	if m.Skills["beta"].Requires[0] != "browse-binary" {
		t.Errorf("beta requires = %v, want [browse-binary]", m.Skills["beta"].Requires)
	}
}

func TestLoadManifest_MissingFile(t *testing.T) {
	_, err := LoadManifest("/nonexistent/skills.json")
	if err == nil {
		t.Error("expected error for missing file")
	}
}

func TestLoadManifest_MalformedJSON(t *testing.T) {
	path := writeManifest(t, `{invalid json}`)
	_, err := LoadManifest(path)
	if err == nil {
		t.Error("expected error for malformed JSON")
	}
}

func TestLoadManifest_ProfileReferencesMissingCategory(t *testing.T) {
	manifest := `{
		"version": "1.0.0",
		"skills": {"a": {"description": "A"}},
		"categories": {"core": {"label": "Core", "description": "Core", "skills": ["a"]}},
		"profiles": {"bad": {"label": "Bad", "description": "Bad", "categories": ["nonexistent"]}},
		"shared_infra": {"bin": [], "runtime_dir": "~/.steez", "browse_binary": ""}
	}`
	path := writeManifest(t, manifest)
	_, err := LoadManifest(path)
	if err == nil || !strings.Contains(err.Error(), "nonexistent") {
		t.Errorf("expected error about missing category, got: %v", err)
	}
}

func TestLoadManifest_SkillMissingDescription(t *testing.T) {
	manifest := `{
		"version": "1.0.0",
		"skills": {"a": {"description": ""}},
		"categories": {"core": {"label": "Core", "description": "Core", "skills": ["a"]}},
		"profiles": {},
		"shared_infra": {"bin": [], "runtime_dir": "~/.steez", "browse_binary": ""}
	}`
	path := writeManifest(t, manifest)
	_, err := LoadManifest(path)
	if err == nil || !strings.Contains(err.Error(), "no description") {
		t.Errorf("expected error about missing description, got: %v", err)
	}
}

func TestResolveProfile_Starter(t *testing.T) {
	path := writeManifest(t, validManifest)
	m, _ := LoadManifest(path)

	skills, err := ResolveProfile(m, "starter")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(skills) != 2 {
		t.Errorf("starter skills = %d, want 2", len(skills))
	}
}

func TestResolveProfile_All(t *testing.T) {
	path := writeManifest(t, validManifest)
	m, _ := LoadManifest(path)

	skills, err := ResolveProfile(m, "all")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(skills) != 3 {
		t.Errorf("all skills = %d, want 3", len(skills))
	}
}

func TestResolveProfile_Unknown(t *testing.T) {
	path := writeManifest(t, validManifest)
	m, _ := LoadManifest(path)

	_, err := ResolveProfile(m, "nonexistent")
	if err == nil || !strings.Contains(err.Error(), "unknown profile") {
		t.Errorf("expected error about unknown profile, got: %v", err)
	}
}

func TestFindSkill_FuzzyMatch(t *testing.T) {
	path := writeManifest(t, validManifest)
	m, _ := LoadManifest(path)

	_, err := FindSkill(m, "alph")
	if err == nil || !strings.Contains(err.Error(), "did you mean") {
		t.Errorf("expected fuzzy match suggestion, got: %v", err)
	}
}
