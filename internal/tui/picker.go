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
	isCategory   bool
	categoryName string
	skill        installer.Skill
	selected     bool
	disabled     bool // skills with unmet requirements
}

// pickerModel is a Bubble Tea model for category-grouped skill multi-select.
type pickerModel struct {
	items        []pickerItem
	cursor       int
	scrollOffset int
	width        int
	height       int // terminal height — viewport is height minus chrome lines
	styles       Styles
	done         bool
	quitting     bool
}

// viewportHeight returns how many item lines fit in the visible area.
// Reserves lines for: title, keybinds hint, footer status, blank lines.
const chromeLines = 5

func (p pickerModel) viewportHeight() int {
	h := p.height - chromeLines
	if h < 5 {
		h = 5
	}
	return h
}

// newPicker creates a picker from a manifest, pre-selecting skills by name.
func newPicker(m *installer.Manifest, preselected map[string]bool, styles Styles, width int) pickerModel {
	// Build items in category order.
	categoryOrder := []string{"workflow", "operations", "qa", "infrastructure", "design", "meta"}

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
		height: 24, // default, updated by WindowSizeMsg
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
		p.height = msg.Height
		p.clampScroll()
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

	// Render all items into lines first, then window them.
	var lines []string
	for i, item := range p.items {
		if item.isCategory {
			lines = append(lines, p.styles.Category.Render(item.categoryName))
			continue
		}

		cursor := "  "
		if i == p.cursor {
			cursor = p.styles.Cursor.Render("> ")
		}

		var check string
		if item.disabled {
			check = p.styles.Disabled.Render("[!]")
		} else if item.selected {
			check = p.styles.Selected.Render("[x]")
		} else {
			check = "[ ]"
		}

		name := item.skill.Name
		desc := item.skill.Description
		if len(desc) > maxDescWidth {
			desc = desc[:maxDescWidth-1] + "…"
		}

		lines = append(lines, fmt.Sprintf("%s%s %-22s %s", cursor, check, name, p.styles.Description.Render(desc)))
	}

	// Window the lines to the viewport.
	vpHeight := p.viewportHeight()
	start := p.scrollOffset
	end := start + vpHeight
	if end > len(lines) {
		end = len(lines)
	}

	// Scroll indicators.
	if start > 0 {
		b.WriteString(p.styles.Muted.Render(fmt.Sprintf("  ↑ %d more above", start)))
		b.WriteString("\n")
	}

	for _, line := range lines[start:end] {
		b.WriteString(line)
		b.WriteString("\n")
	}

	if end < len(lines) {
		b.WriteString(p.styles.Muted.Render(fmt.Sprintf("  ↓ %d more below", len(lines)-end)))
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

// moveCursor moves the cursor by delta, skipping category headers,
// and adjusts scroll to keep the cursor visible.
func (p *pickerModel) moveCursor(delta int) {
	for {
		p.cursor += delta
		if p.cursor < 0 {
			p.cursor = 0
			break
		}
		if p.cursor >= len(p.items) {
			p.cursor = len(p.items) - 1
			break
		}
		// Skip category headers.
		if !p.items[p.cursor].isCategory {
			break
		}
	}
	p.clampScroll()
}

// clampScroll adjusts scrollOffset so the cursor is always visible.
func (p *pickerModel) clampScroll() {
	vpHeight := p.viewportHeight()

	// Cursor above viewport — scroll up.
	if p.cursor < p.scrollOffset {
		p.scrollOffset = p.cursor
	}
	// Cursor below viewport — scroll down.
	if p.cursor >= p.scrollOffset+vpHeight {
		p.scrollOffset = p.cursor - vpHeight + 1
	}

	// Clamp to valid range.
	maxOffset := len(p.items) - vpHeight
	if maxOffset < 0 {
		maxOffset = 0
	}
	if p.scrollOffset > maxOffset {
		p.scrollOffset = maxOffset
	}
	if p.scrollOffset < 0 {
		p.scrollOffset = 0
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
