package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const (
	beginMarker = "<!-- BEGIN MANAGED PREAMBLE -->"
	endMarker   = "<!-- END MANAGED PREAMBLE -->"
)

// Known preamble section headings used during first-run migration to identify
// where hand-maintained preamble ends and skill-specific content begins.
var preambleHeadings = map[string]bool{
	"## Preamble (run first)":                true,
	"## Beads Context":                       true,
	"## Voice":                               true,
	"## Writing Rules":                       true,
	"## AskUserQuestion Format":              true,
	"## Completeness Principle — Boil the Lake": true,
	"## Search Before Building":              true,
	"## Skill Self-Report":                   true,
	"## Completion Status Protocol":          true,
	"### Escalation":                         true,
	"## Telemetry (run last)":                true,
	"## Plan Status Footer":                  true,
}

func cmdSync(args []string) int {
	checkMode := false
	verbose := false
	var filterSkills []string

	for _, a := range args {
		switch a {
		case "--check":
			checkMode = true
		case "--verbose", "-v":
			verbose = true
		default:
			if !strings.HasPrefix(a, "-") {
				filterSkills = append(filterSkills, a)
			}
		}
	}

	repoPath, err := resolveRepoPath("")
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		return 1
	}

	// Load tier config.
	tiersPath := filepath.Join(repoPath, "preamble", "tiers.json")
	tiers, err := loadTiers(tiersPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error loading tiers: %v\n", err)
		return 1
	}

	// Enumerate skill directories.
	skillsDir := filepath.Join(repoPath, "skills")
	entries, err := os.ReadDir(skillsDir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error reading skills dir: %v\n", err)
		return 1
	}

	synced, stale, skipped, current := 0, 0, 0, 0
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		dirName := entry.Name()

		// Filter to specific skills if requested.
		if len(filterSkills) > 0 && !containsStr(filterSkills, dirName) {
			continue
		}

		skillFile := filepath.Join(skillsDir, dirName, "SKILL.md")
		if _, err := os.Stat(skillFile); err != nil {
			continue
		}

		content, err := os.ReadFile(skillFile)
		if err != nil {
			fmt.Fprintf(os.Stderr, "error reading %s: %v\n", skillFile, err)
			continue
		}
		fileContent := string(content)

		name, tier := parsePreambleFrontmatter(fileContent)
		if tier == 0 {
			if verbose {
				fmt.Printf("  SKIP  %s (no preamble-tier)\n", dirName)
			}
			skipped++
			continue
		}

		sections, ok := tiers[tier]
		if !ok {
			fmt.Fprintf(os.Stderr, "  WARN  %s has unknown tier %d\n", name, tier)
			skipped++
			continue
		}

		// Assemble the managed preamble from section templates.
		managed, err := assemblePreamble(repoPath, sections, name)
		if err != nil {
			fmt.Fprintf(os.Stderr, "error assembling preamble for %s: %v\n", name, err)
			continue
		}

		managedBlock := beginMarker + "\n" + managed + "\n" + endMarker

		if checkMode {
			if !hasManagedBlock(fileContent) {
				fmt.Printf("  STALE %s (tier %d) — no managed block\n", dirName, tier)
				stale++
			} else if extractManagedContent(fileContent) != managed {
				fmt.Printf("  STALE %s (tier %d)\n", dirName, tier)
				stale++
			} else {
				if verbose {
					fmt.Printf("  OK    %s (tier %d)\n", dirName, tier)
				}
				current++
			}
		} else {
			updated := syncManagedBlock(fileContent, managedBlock)
			if updated != fileContent {
				if err := os.WriteFile(skillFile, []byte(updated), 0644); err != nil {
					fmt.Fprintf(os.Stderr, "error writing %s: %v\n", skillFile, err)
					continue
				}
				fmt.Printf("  SYNC  %s (tier %d)\n", dirName, tier)
				synced++
			} else {
				if verbose {
					fmt.Printf("  OK    %s (tier %d)\n", dirName, tier)
				}
				current++
			}
		}
	}

	// Old-path guardrail: scan skill files for stale ~/.claude/skills/steez/ references.
	oldPathHits := 0
	if checkMode {
		for _, entry := range entries {
			if !entry.IsDir() {
				continue
			}
			dirName := entry.Name()
			skillDir := filepath.Join(skillsDir, dirName)
			files, err := os.ReadDir(skillDir)
			if err != nil {
				continue
			}
			for _, f := range files {
				if f.IsDir() {
					continue
				}
				fpath := filepath.Join(skillDir, f.Name())
				data, err := os.ReadFile(fpath)
				if err != nil {
					continue
				}
				content := string(data)
				// Check for old paths outside managed preamble blocks.
				toScan := content
				if hasManagedBlock(content) {
					// Remove managed block before scanning.
					before := strings.SplitN(toScan, beginMarker, 2)
					after := strings.SplitN(toScan, endMarker, 2)
					toScan = before[0]
					if len(after) > 1 {
						toScan += after[1]
					}
				}
				if strings.Contains(toScan, "/.claude/skills/steez/") {
					fmt.Printf("  OLD   %s/%s — contains ~/.claude/skills/steez/ reference\n", dirName, f.Name())
					oldPathHits++
				}
				if strings.Contains(toScan, "STEEZ_BIN") {
					fmt.Printf("  OLD   %s/%s — contains STEEZ_BIN reference (removed variable)\n", dirName, f.Name())
					oldPathHits++
				}
			}
		}
	}

	fmt.Println()
	if checkMode {
		fmt.Printf("%d stale, %d current, %d skipped\n", stale, current, skipped)
		if oldPathHits > 0 {
			fmt.Printf("%d files contain old ~/.claude/skills/steez/ paths\n", oldPathHits)
		}
		if stale > 0 || oldPathHits > 0 {
			if stale > 0 {
				fmt.Println("Run `steez sync` to update preambles.")
			}
			if oldPathHits > 0 {
				fmt.Println("Update old paths manually (see steez-z78).")
			}
			return 1
		}
		return 0
	}

	fmt.Printf("%d synced, %d current, %d skipped\n", synced, current, skipped)
	return 0
}

// loadTiers reads the tier-to-sections mapping from tiers.json.
func loadTiers(path string) (map[int][]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var raw map[string][]string
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, err
	}
	tiers := make(map[int][]string)
	for k, v := range raw {
		n, err := strconv.Atoi(k)
		if err != nil {
			return nil, fmt.Errorf("invalid tier key %q", k)
		}
		tiers[n] = v
	}
	return tiers, nil
}

// parsePreambleFrontmatter extracts name and preamble-tier from YAML frontmatter.
func parsePreambleFrontmatter(content string) (name string, tier int) {
	lines := strings.Split(content, "\n")
	inFM := false
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == "---" {
			if inFM {
				break
			}
			inFM = true
			continue
		}
		if !inFM {
			continue
		}
		if strings.HasPrefix(trimmed, "name:") {
			name = strings.TrimSpace(strings.TrimPrefix(trimmed, "name:"))
		}
		if strings.HasPrefix(trimmed, "preamble-tier:") {
			t := strings.TrimSpace(strings.TrimPrefix(trimmed, "preamble-tier:"))
			tier, _ = strconv.Atoi(t)
		}
	}
	return
}

// assemblePreamble loads section templates, substitutes {{SKILL_NAME}}, and joins them.
func assemblePreamble(repoPath string, sections []string, skillName string) (string, error) {
	sectionsDir := filepath.Join(repoPath, "preamble", "sections")
	var parts []string
	for _, section := range sections {
		sectionFile := filepath.Join(sectionsDir, section+".md")
		data, err := os.ReadFile(sectionFile)
		if err != nil {
			return "", fmt.Errorf("section %q: %w", section, err)
		}
		content := strings.ReplaceAll(string(data), "{{SKILL_NAME}}", skillName)
		parts = append(parts, strings.TrimRight(content, "\n"))
	}
	return strings.Join(parts, "\n\n"), nil
}

// hasManagedBlock checks if the file already contains managed preamble markers.
func hasManagedBlock(content string) bool {
	return strings.Contains(content, beginMarker) && strings.Contains(content, endMarker)
}

// extractManagedContent returns the content between the managed preamble markers.
func extractManagedContent(content string) string {
	start := strings.Index(content, beginMarker)
	end := strings.Index(content, endMarker)
	if start < 0 || end < 0 || end <= start {
		return ""
	}
	inner := content[start+len(beginMarker) : end]
	return strings.TrimPrefix(strings.TrimSuffix(inner, "\n"), "\n")
}

// syncManagedBlock inserts or replaces the managed preamble block in the file content.
func syncManagedBlock(content, managedBlock string) string {
	if hasManagedBlock(content) {
		// Replace existing managed block.
		start := strings.Index(content, beginMarker)
		end := strings.Index(content, endMarker) + len(endMarker)
		return content[:start] + managedBlock + content[end:]
	}

	// First-time sync: split frontmatter from body, find skill-specific content.
	fm, rest := splitAtFrontmatter(content)
	_, skillContent := splitPreambleFromSkill(rest)

	if skillContent == "" {
		// Entire file after frontmatter is preamble (or empty).
		return fm + "\n\n" + managedBlock + "\n"
	}
	return fm + "\n\n" + managedBlock + "\n\n" + skillContent
}

// splitAtFrontmatter splits content into frontmatter (including delimiters) and the rest.
func splitAtFrontmatter(content string) (frontmatter, rest string) {
	lines := strings.Split(content, "\n")
	fmEnd := -1
	foundFirst := false
	for i, line := range lines {
		if strings.TrimSpace(line) == "---" {
			if !foundFirst {
				foundFirst = true
				continue
			}
			fmEnd = i
			break
		}
	}
	if fmEnd < 0 {
		return content, ""
	}
	fmLines := lines[:fmEnd+1]
	restLines := lines[fmEnd+1:]
	return strings.Join(fmLines, "\n"), strings.Join(restLines, "\n")
}

// splitPreambleFromSkill separates hand-maintained preamble content from skill-specific
// content by finding the first markdown heading that isn't a known preamble section
// heading. Lines inside fenced code blocks (``` markers) are ignored.
func splitPreambleFromSkill(rest string) (preamble, skillContent string) {
	lines := strings.Split(rest, "\n")
	inCodeBlock := false
	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		// Track fenced code blocks (real and escaped) to avoid treating
		// code comments or example content as headings.
		if strings.HasPrefix(trimmed, "```") || strings.HasPrefix(trimmed, "\\`\\`\\`") {
			inCodeBlock = !inCodeBlock
			continue
		}
		if inCodeBlock {
			continue
		}
		if !strings.HasPrefix(trimmed, "#") {
			continue
		}
		if isPreambleHeading(trimmed) {
			continue
		}
		// Found a heading that isn't a preamble section — skill content starts here.
		preambleStr := strings.Join(lines[:i], "\n")
		skillStr := strings.Join(lines[i:], "\n")
		return strings.TrimRight(preambleStr, "\n"), skillStr
	}
	// No skill-specific heading found.
	return rest, ""
}

// isPreambleHeading checks if a line matches a known preamble section heading.
func isPreambleHeading(line string) bool {
	return preambleHeadings[strings.TrimSpace(line)]
}

func containsStr(slice []string, s string) bool {
	for _, v := range slice {
		if v == s {
			return true
		}
	}
	return false
}
