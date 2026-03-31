// Package tui implements the Bubble Tea interactive setup flow for steez.
package tui

import (
	"os"

	"github.com/charmbracelet/lipgloss"
)

// noColor returns true if the NO_COLOR env var is set.
func noColor() bool {
	return os.Getenv("NO_COLOR") != ""
}

// Styles holds all Lip Gloss styles used in the TUI.
type Styles struct {
	Title       lipgloss.Style
	Subtitle    lipgloss.Style
	Category    lipgloss.Style
	Selected    lipgloss.Style
	Unselected  lipgloss.Style
	Disabled    lipgloss.Style
	Cursor      lipgloss.Style
	Description lipgloss.Style
	Success     lipgloss.Style
	Warning     lipgloss.Style
	Error       lipgloss.Style
	Muted       lipgloss.Style
	Bold        lipgloss.Style
	Footer      lipgloss.Style
}

// NewStyles creates the TUI style set. If NO_COLOR is set, returns plain styles.
func NewStyles() Styles {
	if noColor() {
		return Styles{
			Title:       lipgloss.NewStyle(),
			Subtitle:    lipgloss.NewStyle(),
			Category:    lipgloss.NewStyle(),
			Selected:    lipgloss.NewStyle(),
			Unselected:  lipgloss.NewStyle(),
			Disabled:    lipgloss.NewStyle(),
			Cursor:      lipgloss.NewStyle(),
			Description: lipgloss.NewStyle(),
			Success:     lipgloss.NewStyle(),
			Warning:     lipgloss.NewStyle(),
			Error:       lipgloss.NewStyle(),
			Muted:       lipgloss.NewStyle(),
			Bold:        lipgloss.NewStyle(),
			Footer:      lipgloss.NewStyle(),
		}
	}

	// ANSI colors that respect terminal themes.
	blue := lipgloss.Color("4")
	cyan := lipgloss.Color("6")
	magenta := lipgloss.Color("5")
	green := lipgloss.Color("2")
	yellow := lipgloss.Color("3")
	red := lipgloss.Color("1")

	return Styles{
		Title:       lipgloss.NewStyle().Bold(true).Foreground(blue),
		Subtitle:    lipgloss.NewStyle().Foreground(cyan),
		Category:    lipgloss.NewStyle().Bold(true).Foreground(magenta).MarginTop(1),
		Selected:    lipgloss.NewStyle().Foreground(green),
		Unselected:  lipgloss.NewStyle(),
		Disabled:    lipgloss.NewStyle().Foreground(yellow),
		Cursor:      lipgloss.NewStyle().Bold(true).Foreground(blue),
		Description: lipgloss.NewStyle().Foreground(lipgloss.Color("8")),
		Success:     lipgloss.NewStyle().Foreground(green),
		Warning:     lipgloss.NewStyle().Foreground(yellow),
		Error:       lipgloss.NewStyle().Foreground(red).Bold(true),
		Muted:       lipgloss.NewStyle().Foreground(lipgloss.Color("8")),
		Bold:        lipgloss.NewStyle().Bold(true),
		Footer:      lipgloss.NewStyle().Foreground(lipgloss.Color("8")).MarginTop(1),
	}
}
