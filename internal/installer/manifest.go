package installer

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"
)

// Manifest represents the parsed skills.json file.
type Manifest struct {
	Version     string              `json:"version"`
	Skills      map[string]*Skill   `json:"-"` // resolved from rawManifest
	Categories  map[string]Category `json:"-"` // resolved from rawManifest
	Profiles    map[string]Profile  `json:"profiles"`
	SharedInfra SharedInfra         `json:"shared_infra"`
}

// Category groups related skills under a label.
type Category struct {
	Label       string  `json:"label"`
	Description string  `json:"description"`
	Skills      []Skill `json:"-"` // resolved from skill names
}

// Skill represents a single installable Claude Code skill.
type Skill struct {
	Name        string   `json:"name"`
	Description string   `json:"description"`
	Requires    []string `json:"requires,omitempty"`
}

// Profile defines a named set of categories to install.
type Profile struct {
	Label             string   `json:"label"`
	Description       string   `json:"description"`
	Categories        []string `json:"categories,omitempty"`
	ExcludeCategories []string `json:"exclude_categories,omitempty"`
}

// SharedInfra describes shared binaries and runtime paths.
type SharedInfra struct {
	Bin          []string `json:"bin"`
	RuntimeDir   string   `json:"runtime_dir"`
	BrowseBinary string   `json:"browse_binary"`
}

// rawManifest mirrors the JSON structure of skills.json for initial parsing.
type rawManifest struct {
	Version    string                       `json:"version"`
	Skills     map[string]rawSkill          `json:"skills"`
	Categories map[string]rawCategory       `json:"categories"`
	Profiles   map[string]Profile           `json:"profiles"`
	SharedInfra SharedInfra                 `json:"shared_infra"`
}

type rawSkill struct {
	Description string   `json:"description"`
	Requires    []string `json:"requires,omitempty"`
}

type rawCategory struct {
	Label       string   `json:"label"`
	Description string   `json:"description"`
	Skills      []string `json:"skills"`
}

// LoadManifest reads and validates skills.json from the given path.
func LoadManifest(path string) (*Manifest, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading manifest: %w", err)
	}

	var raw rawManifest
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, fmt.Errorf("parsing manifest JSON: %w", err)
	}

	// Build the skill map with names set from keys.
	skills := make(map[string]*Skill, len(raw.Skills))
	for name, rs := range raw.Skills {
		if rs.Description == "" {
			return nil, fmt.Errorf("skill %q has no description", name)
		}
		skills[name] = &Skill{
			Name:        name,
			Description: rs.Description,
			Requires:    rs.Requires,
		}
	}

	// Resolve categories: replace string skill names with Skill objects.
	categories := make(map[string]Category, len(raw.Categories))
	for catName, rc := range raw.Categories {
		resolved := make([]Skill, 0, len(rc.Skills))
		for _, skillName := range rc.Skills {
			s, ok := skills[skillName]
			if !ok {
				return nil, fmt.Errorf("category %q references unknown skill %q", catName, skillName)
			}
			resolved = append(resolved, *s)
		}
		categories[catName] = Category{
			Label:       rc.Label,
			Description: rc.Description,
			Skills:      resolved,
		}
	}

	// Validate profiles reference existing categories.
	for profName, prof := range raw.Profiles {
		for _, catRef := range prof.Categories {
			if _, ok := categories[catRef]; !ok {
				return nil, fmt.Errorf("profile %q references unknown category %q", profName, catRef)
			}
		}
		for _, catRef := range prof.ExcludeCategories {
			if _, ok := categories[catRef]; !ok {
				return nil, fmt.Errorf("profile %q excludes unknown category %q", profName, catRef)
			}
		}
	}

	return &Manifest{
		Version:     raw.Version,
		Skills:      skills,
		Categories:  categories,
		Profiles:    raw.Profiles,
		SharedInfra: raw.SharedInfra,
	}, nil
}

// ResolveProfile returns the list of skill names for a given profile.
func ResolveProfile(m *Manifest, profileName string) ([]string, error) {
	prof, ok := m.Profiles[profileName]
	if !ok {
		available := make([]string, 0, len(m.Profiles))
		for name := range m.Profiles {
			available = append(available, name)
		}
		sort.Strings(available)
		return nil, fmt.Errorf("unknown profile %q (available: %s)", profileName, strings.Join(available, ", "))
	}

	// Build the exclude set.
	excluded := make(map[string]bool, len(prof.ExcludeCategories))
	for _, cat := range prof.ExcludeCategories {
		excluded[cat] = true
	}

	var skills []string

	if len(prof.Categories) > 0 {
		// Include only the listed categories.
		for _, catName := range prof.Categories {
			cat := m.Categories[catName]
			for _, s := range cat.Skills {
				skills = append(skills, s.Name)
			}
		}
	} else {
		// Include all categories not excluded.
		// Sort category names for deterministic output.
		catNames := make([]string, 0, len(m.Categories))
		for name := range m.Categories {
			catNames = append(catNames, name)
		}
		sort.Strings(catNames)

		for _, catName := range catNames {
			if excluded[catName] {
				continue
			}
			cat := m.Categories[catName]
			for _, s := range cat.Skills {
				skills = append(skills, s.Name)
			}
		}
	}

	return skills, nil
}

// FindSkill looks up a skill by name with fuzzy matching. On exact match it
// returns the skill. On close match (Levenshtein distance <= 2) it returns
// an error with "did you mean" suggestions. On no match it lists all skills.
func FindSkill(m *Manifest, name string) (*Skill, error) {
	// Exact match.
	if s, ok := m.Skills[name]; ok {
		return s, nil
	}

	// Fuzzy match: collect close names.
	var suggestions []string
	allNames := make([]string, 0, len(m.Skills))
	for skillName := range m.Skills {
		allNames = append(allNames, skillName)
		if levenshtein(name, skillName) <= 2 {
			suggestions = append(suggestions, skillName)
		}
	}
	sort.Strings(allNames)

	if len(suggestions) > 0 {
		sort.Strings(suggestions)
		if len(suggestions) > 3 {
			suggestions = suggestions[:3]
		}
		return nil, fmt.Errorf("unknown skill %q — did you mean: %s?", name, strings.Join(suggestions, ", "))
	}

	return nil, fmt.Errorf("unknown skill %q\navailable skills: %s", name, strings.Join(allNames, ", "))
}

// levenshtein computes the edit distance between two strings.
func levenshtein(a, b string) int {
	la, lb := len(a), len(b)
	if la == 0 {
		return lb
	}
	if lb == 0 {
		return la
	}

	// Use a single row for space efficiency.
	prev := make([]int, lb+1)
	for j := range prev {
		prev[j] = j
	}

	for i := 1; i <= la; i++ {
		curr := make([]int, lb+1)
		curr[0] = i
		for j := 1; j <= lb; j++ {
			cost := 1
			if a[i-1] == b[j-1] {
				cost = 0
			}
			curr[j] = min(
				prev[j]+1,      // deletion
				curr[j-1]+1,    // insertion
				prev[j-1]+cost, // substitution
			)
		}
		prev = curr
	}
	return prev[lb]
}
