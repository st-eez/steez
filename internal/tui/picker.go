package tui

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/st-eez/steez/internal/installer"
)

// pickerItem represents a row in the skill picker — either a category header
// or a selectable skill.
type pickerItem struct {
	isCategory  bool
	categoryName string
	skill       installer.Skill
	selected    bool
	disabled    bool // skills with unmet requirements
}

// pickerModel is a Bubble Tea model for category-grouped skill multi-select.
type pickerModel struct {
	items    []pickerItem
	cursor   int
	width    int
	styles   Styles
	done     bool
	quitting bool
}

// newPicker creates a picker from a manifest, pre-selecting skills by name.
func newPicker(m *installer.Manifest, preselected map[string]bool, styles Styles, width int) pickerModel {
	// Build items in category order.
	categoryOrder := []string{"workflow", "qa", "infrastructure", "design", "meta"}

	var items []pickerItem
	for _, catName := range categoryOrder {
		cat, ok := m.Categories[catName]
		if !ok {
			continue
		}
		items = append(items, pickerItem{
			isCategory:   true,
			categoryName: cat.Label,
		})
		for _, skill := range cat.Skills {
			items = append(items, pickerItem{
				skill:    skill,
				selected: preselected[skill.Name],
			})
		}
	}

	// Start cursor on the first selectable item.
	cursor := 0
	for i, item := range items {
		if !item.isCategory {
			cursor = i
			break
		}
	}

	return pickerModel{
		items:  items,
		cursor: cursor,
		width:  width,
		styles: styles,
	}
}

func (p pickerModel) Init() tea.Cmd { return nil }

func (p pickerModel) Update(msg tea.Msg) (pickerModel, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "q", "esc":
			p.quitting = true
			return p, nil
		case "enter":
			if p.selectedCount() > 0 {
				p.done = true
			}
			return p, nil
		case "up", "k":
			p.moveCursor(-1)
		case "down", "j":
			p.moveCursor(1)
		case " ":
			if p.cursor < len(p.items) && !p.items[p.cursor].isCategory && !p.items[p.cursor].disabled {
				p.items[p.cursor].selected = !p.items[p.cursor].selected
			}
		case "a":
			// Toggle all.
			allSelected := p.selectedCount() == p.selectableCount()
			for i := range p.items {
				if !p.items[i].isCategory && !p.items[i].disabled {
					p.items[i].selected = !allSelected
				}
			}
		}
	case tea.WindowSizeMsg:
		p.width = msg.Width
	}
	return p, nil
}

func (p pickerModel) View() string {
	var b strings.Builder

	b.WriteString(p.styles.Title.Render("Select Skills"))
	b.WriteString("\n")
	b.WriteString(p.styles.Muted.Render("space: toggle  a: toggle all  enter: confirm  q: cancel"))
	b.WriteString("\n")

	maxDescWidth := p.width - 30
	if maxDescWidth < 20 {
		maxDescWidth = 20
	}

	for i, item := range p.items {
		if item.isCategory {
			b.WriteString(p.styles.Category.Render(item.categoryName))
			b.WriteString("\n")
			continue
		}

		// Cursor.
		cursor := "  "
		if i == p.cursor {
			cursor = p.styles.Cursor.Render("> ")
		}

		// Checkbox.
		var check string
		if item.disabled {
			check = p.styles.Disabled.Render("[!]")
		} else if item.selected {
			check = p.styles.Selected.Render("[x]")
		} else {
			check = "[ ]"
		}

		// Name and description.
		name := item.skill.Name
		desc := item.skill.Description
		if len(desc) > maxDescWidth {
			desc = desc[:maxDescWidth-1] + "…"
		}

		line := fmt.Sprintf("%s%s %-22s %s", cursor, check, name, p.styles.Description.Render(desc))
		b.WriteString(line)
		b.WriteString("\n")
	}

	// Footer.
	count := p.selectedCount()
	if count == 0 {
		b.WriteString(p.styles.Error.Render("\n  Select at least one skill to continue."))
	} else {
		b.WriteString(p.styles.Muted.Render(fmt.Sprintf("\n  %d skills selected", count)))
	}
	b.WriteString("\n")

	return b.String()
}

func (p *pickerModel) moveCursor(delta int) {
	for {
		p.cursor += delta
		if p.cursor < 0 {
			p.cursor = 0
			return
		}
		if p.cursor >= len(p.items) {
			p.cursor = len(p.items) - 1
			return
		}
		// Skip category headers.
		if !p.items[p.cursor].isCategory {
			return
		}
	}
}

func (p pickerModel) selectedCount() int {
	n := 0
	for _, item := range p.items {
		if item.selected {
			n++
		}
	}
	return n
}

func (p pickerModel) selectableCount() int {
	n := 0
	for _, item := range p.items {
		if !item.isCategory && !item.disabled {
			n++
		}
	}
	return n
}

// SelectedSkills returns the names of all selected skills.
func (p pickerModel) SelectedSkills() []string {
	var names []string
	for _, item := range p.items {
		if item.selected {
			names = append(names, item.skill.Name)
		}
	}
	return names
}
