package tui

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/st-eez/steez/internal/config"
	"github.com/st-eez/steez/internal/installer"
)

type step int

const (
	stepSplash    step = iota
	stepProfile
	stepPicker
	stepMigration
	stepPreflight
	stepInstall
)

type installResult struct {
	name    string
	ok      bool
	message string
}

type setupModel struct {
	step   step
	width  int
	height int
	styles Styles

	// Config.
	repoPath    string
	manifest    *installer.Manifest
	isReturning bool

	// Profile select (step 2).
	profileCursor int
	profileChoice string // "starter", "all", "custom"

	// Picker (step 3).
	picker pickerModel

	// Migration (step 4).
	migResult  *installer.MigrationResult
	migError   string
	migChecked bool

	// Preflight (step 5).
	skillNames []string

	// Install (step 6).
	results     []installResult
	installDone bool

	// Global.
	quitting bool
	err      error
}

// RunSetup launches the interactive TUI setup wizard.
func RunSetup(repoPath string) error {
	manifest, err := installer.LoadManifest(filepath.Join(repoPath, "skills.json"))
	if err != nil {
		return fmt.Errorf("loading manifest: %w", err)
	}

	cfg, _ := config.Load()
	isReturning := cfg.FirstInstall != ""

	m := setupModel{
		step:        stepSplash,
		repoPath:    repoPath,
		manifest:    manifest,
		isReturning: isReturning,
		styles:      NewStyles(),
		width:       80,
		height:      24,
	}

	// Skip splash for returning users.
	if isReturning {
		m.step = stepProfile
	}

	p := tea.NewProgram(m)
	finalModel, err := p.Run()
	if err != nil {
		return err
	}

	fm := finalModel.(setupModel)
	if fm.quitting {
		return nil
	}
	if fm.err != nil {
		return fm.err
	}
	return nil
}

func (m setupModel) Init() tea.Cmd { return nil }

func (m setupModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		return m, nil

	case tea.KeyMsg:
		// Global quit.
		if msg.String() == "ctrl+c" {
			m.quitting = true
			return m, tea.Quit
		}

		switch m.step {
		case stepSplash:
			return m.updateSplash(msg)
		case stepProfile:
			return m.updateProfile(msg)
		case stepPicker:
			return m.updatePicker(msg)
		case stepMigration:
			return m.updateMigration(msg)
		case stepPreflight:
			return m.updatePreflight(msg)
		case stepInstall:
			return m.updateInstall(msg)
		}
	}
	return m, nil
}

func (m setupModel) View() string {
	switch m.step {
	case stepSplash:
		return m.viewSplash()
	case stepProfile:
		return m.viewProfile()
	case stepPicker:
		return m.viewPicker()
	case stepMigration:
		return m.viewMigration()
	case stepPreflight:
		return m.viewPreflight()
	case stepInstall:
		return m.viewInstall()
	}
	return ""
}

// --- Step 1: Splash ---

func (m setupModel) updateSplash(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "enter":
		m.step = stepProfile
	case "q", "esc":
		m.quitting = true
		return m, tea.Quit
	}
	return m, nil
}

func (m setupModel) viewSplash() string {
	var b strings.Builder
	b.WriteString("\n")
	b.WriteString(m.styles.Title.Render("  steez"))
	b.WriteString("\n\n")
	b.WriteString("  Claude Code skill installer — symlinks workflow skills to ~/.claude/skills/\n\n")
	b.WriteString(m.styles.Muted.Render(fmt.Sprintf("  v1.0.0  %s/%s  %s", runtime.GOOS, runtime.GOARCH, runtime.Version())))
	b.WriteString("\n\n")
	b.WriteString(m.styles.Footer.Render("  Press enter to continue"))
	b.WriteString("\n")
	return b.String()
}

// --- Step 2: Profile Select ---

var profiles = []struct {
	key   string
	label string
	desc  string
}{
	{"starter", "Starter Kit (recommended)", "8 workflow skills — the sprint pipeline spine"},
	{"all", "All Skills", "Everything available"},
	{"custom", "Custom", "Pick exactly what you want"},
}

func (m setupModel) updateProfile(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "up", "k":
		if m.profileCursor > 0 {
			m.profileCursor--
		}
	case "down", "j":
		if m.profileCursor < len(profiles)-1 {
			m.profileCursor++
		}
	case "enter":
		m.profileChoice = profiles[m.profileCursor].key
		if m.profileChoice == "custom" {
			m.picker = newPicker(m.manifest, nil, m.styles, m.width)
			m.step = stepPicker
		} else {
			m.resolveSkills()
			m.step = stepMigration
			m.checkMigration()
		}
	case "q", "esc":
		m.quitting = true
		return m, tea.Quit
	}
	return m, nil
}

func (m setupModel) viewProfile() string {
	var b strings.Builder
	b.WriteString("\n")
	b.WriteString(m.styles.Title.Render("  Choose a profile"))
	b.WriteString("\n\n")

	for i, p := range profiles {
		cursor := "  "
		if i == m.profileCursor {
			cursor = m.styles.Cursor.Render("> ")
		}
		label := p.label
		if i == m.profileCursor {
			label = m.styles.Bold.Render(label)
		}
		b.WriteString(fmt.Sprintf("  %s%s\n", cursor, label))
		b.WriteString(fmt.Sprintf("      %s\n", m.styles.Description.Render(p.desc)))
	}

	b.WriteString(m.styles.Footer.Render("\n  j/k or arrows to navigate, enter to select, q to quit"))
	b.WriteString("\n")
	return b.String()
}

// --- Step 3: Picker ---

func (m setupModel) updatePicker(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	m.picker, _ = m.picker.Update(msg)
	if m.picker.quitting {
		m.quitting = true
		return m, tea.Quit
	}
	if m.picker.done {
		m.skillNames = m.picker.SelectedSkills()
		m.step = stepMigration
		m.checkMigration()
	}
	return m, nil
}

func (m setupModel) viewPicker() string {
	return m.picker.View()
}

// --- Step 4: Migration Gate ---

func (m *setupModel) checkMigration() {
	result, err := installer.DetectMigration()
	if err != nil {
		m.migError = err.Error()
		return
	}
	m.migResult = result
	m.migChecked = true

	// Skip if no migration needed.
	if result.State == installer.StateRealDirectory || result.State == installer.StateMissing {
		m.step = stepPreflight
	}
}

func (m setupModel) updateMigration(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "enter":
		// Re-check migration state.
		result, err := installer.DetectMigration()
		if err != nil {
			m.migError = err.Error()
			return m, nil
		}
		m.migResult = result
		if result.State == installer.StateRealDirectory || result.State == installer.StateMissing {
			m.step = stepPreflight
		} else {
			m.migError = "Migration not complete. Please run the commands above."
		}
	case "q", "esc":
		m.quitting = true
		return m, tea.Quit
	}
	return m, nil
}

func (m setupModel) viewMigration() string {
	var b strings.Builder
	b.WriteString("\n")
	b.WriteString(m.styles.Warning.Render("  Migration Required"))
	b.WriteString("\n\n")

	if m.migResult != nil {
		b.WriteString(fmt.Sprintf("  Detected: %s\n", m.migResult.State))
		if m.migResult.SymlinkPath != "" {
			b.WriteString(fmt.Sprintf("  Points to: %s\n", m.migResult.SymlinkPath))
		}
		b.WriteString("\n")
		b.WriteString("  Run these commands in another terminal:\n\n")
		for _, cmd := range m.migResult.Commands {
			b.WriteString(m.styles.Bold.Render(fmt.Sprintf("    %s\n", cmd)))
		}
	}

	if m.migError != "" {
		b.WriteString("\n")
		b.WriteString(m.styles.Error.Render("  " + m.migError))
	}

	b.WriteString("\n\n")
	b.WriteString(m.styles.Footer.Render("  Press enter after running the commands, q to quit"))
	b.WriteString("\n")
	return b.String()
}

// --- Step 5: Preflight ---

func (m setupModel) updatePreflight(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "enter":
		m.step = stepInstall
		m.runInstall()
	case "q", "esc":
		m.quitting = true
		return m, tea.Quit
	}
	return m, nil
}

func (m setupModel) viewPreflight() string {
	var b strings.Builder
	b.WriteString("\n")
	b.WriteString(m.styles.Title.Render("  Ready to install"))
	b.WriteString("\n\n")

	home, _ := os.UserHomeDir()
	b.WriteString(fmt.Sprintf("  Location:  %s\n", filepath.Join(home, ".claude", "skills")))
	b.WriteString(fmt.Sprintf("  Runtime:   %s\n", filepath.Join(home, ".steez")))
	b.WriteString(fmt.Sprintf("  Profile:   %s\n", m.profileChoice))
	b.WriteString(fmt.Sprintf("  Skills:    %d\n", len(m.skillNames)))
	b.WriteString("\n")

	for _, name := range m.skillNames {
		b.WriteString(fmt.Sprintf("    steez-%s\n", name))
	}

	// Check for browse-dependent skills.
	hasBrowseDep := false
	for _, name := range m.skillNames {
		if s, ok := m.manifest.Skills[name]; ok && len(s.Requires) > 0 {
			hasBrowseDep = true
			break
		}
	}
	if hasBrowseDep {
		browseBin := filepath.Join(m.repoPath, "shared", "steez", "browse", "dist", "browse")
		if _, err := os.Stat(browseBin); os.IsNotExist(err) {
			b.WriteString("\n")
			b.WriteString(m.styles.Warning.Render("  Note: Some skills require the browse binary (not built)."))
			b.WriteString("\n")
			b.WriteString(m.styles.Muted.Render("  Build later with: steez setup --browse"))
		}
	}

	b.WriteString("\n\n")
	b.WriteString(m.styles.Footer.Render("  Press enter to install, q to cancel"))
	b.WriteString("\n")
	return b.String()
}

// --- Step 6: Install ---

func (m *setupModel) runInstall() {
	home, err := os.UserHomeDir()
	if err != nil {
		m.err = err
		return
	}

	skillsTarget := filepath.Join(home, ".claude", "skills")

	// Ensure skills directory.
	os.MkdirAll(skillsTarget, 0o755)

	reg, _ := config.LoadRegistry()

	// Create ~/.steez/repo symlink pointing to checkout.
	steezHome := filepath.Join(home, ".steez")
	if err := os.MkdirAll(steezHome, 0o755); err != nil {
		m.results = append(m.results, installResult{"~/.steez/", false, err.Error()})
		return
	}

	repoSymlink := filepath.Join(steezHome, "repo")
	if err := installer.CreateSymlink(m.repoPath, repoSymlink, false, true); err != nil {
		m.results = append(m.results, installResult{"repo symlink", false, err.Error()})
	} else {
		m.results = append(m.results, installResult{"repo symlink", true, ""})
	}

	// Create ~/.steez/bin/ directory with symlinks to shared runtime.
	binDir := filepath.Join(steezHome, "bin")
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		m.results = append(m.results, installResult{"~/.steez/bin/", false, err.Error()})
		return
	}

	binSymlinks := []struct{ name, relPath string }{
		{"steez-config", "shared/steez/bin/steez-config"},
		{"steez-slug", "shared/steez/bin/steez-slug"},
		{"steez-diff-scope", "shared/steez/bin/steez-diff-scope"},
		{"steez-review-log", "shared/steez/bin/steez-review-log"},
		{"steez-review-read", "shared/steez/bin/steez-review-read"},
		{"steez-bd", "shared/steez/bin/steez-bd"},
		{"browse", "shared/steez/browse/dist/browse"},
	}
	for _, bs := range binSymlinks {
		source := filepath.Join(repoSymlink, bs.relPath)
		target := filepath.Join(binDir, bs.name)
		if err := installer.CreateSymlink(source, target, false, true); err != nil {
			m.results = append(m.results, installResult{"bin/" + bs.name, false, err.Error()})
		} else {
			m.results = append(m.results, installResult{"bin/" + bs.name, true, ""})
		}
	}

	// Each skill.
	for _, name := range m.skillNames {
		source := filepath.Join(m.repoPath, "skills", name)
		target := filepath.Join(skillsTarget, "steez-"+name)
		symlinkName := "steez-" + name

		if err := installer.CreateSymlink(source, target, false, true); err != nil {
			m.results = append(m.results, installResult{name, false, err.Error()})
		} else {
			config.AddToRegistry(reg, symlinkName, source, target)
			m.results = append(m.results, installResult{name, true, ""})
		}
	}

	// Save registry and config.
	config.EnsureDir()
	config.SaveRegistry(reg)

	cfg, _ := config.Load()
	if cfg.RepoPath == "" {
		cfg.RepoPath = m.repoPath
	}
	if cfg.FirstInstall == "" {
		cfg.FirstInstall = time.Now().Format(time.RFC3339)
	}
	config.Save(cfg)

	m.installDone = true
}

func (m setupModel) updateInstall(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "enter", "q", "esc":
		return m, tea.Quit
	}
	return m, nil
}

func (m setupModel) viewInstall() string {
	var b strings.Builder
	b.WriteString("\n")

	succeeded := 0
	failed := 0
	noop := 0

	for _, r := range m.results {
		if r.ok {
			b.WriteString(m.styles.Success.Render(fmt.Sprintf("  ✓ %s", r.name)))
			succeeded++
		} else {
			b.WriteString(m.styles.Error.Render(fmt.Sprintf("  ✗ %s: %s", r.name, r.message)))
			failed++
		}
		b.WriteString("\n")
	}

	b.WriteString("\n")

	// Summary with 3 states.
	totalSkills := len(m.skillNames)
	if failed == 0 && succeeded > 0 {
		b.WriteString(m.styles.Success.Render(fmt.Sprintf("  Installed %d skills. All checks pass.", totalSkills)))
		b.WriteString("\n")
		if len(m.skillNames) > 0 {
			b.WriteString(m.styles.Muted.Render(fmt.Sprintf("  Try: /steez-%s", m.skillNames[0])))
		}
	} else if failed > 0 && succeeded > 0 {
		b.WriteString(m.styles.Warning.Render(fmt.Sprintf("  Installed %d of %d skills. %d failed.", succeeded-1, totalSkills, failed)))
		b.WriteString("\n")
		b.WriteString(m.styles.Muted.Render("  Run steez doctor for details."))
	} else if succeeded == 0 && failed == 0 {
		_ = noop
		b.WriteString(m.styles.Muted.Render("  All selected skills already installed."))
		b.WriteString("\n")
		b.WriteString(m.styles.Muted.Render("  Run steez list to see them."))
	}

	b.WriteString("\n\n")
	b.WriteString(m.styles.Footer.Render("  Press any key to exit"))
	b.WriteString("\n")
	return b.String()
}

// --- Helpers ---

func (m *setupModel) resolveSkills() {
	if m.profileChoice == "custom" {
		return // Already set from picker.
	}
	skills, err := installer.ResolveProfile(m.manifest, m.profileChoice)
	if err != nil {
		m.err = err
		return
	}
	m.skillNames = skills
}
