package cmd

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/bubbles/list"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/iksnerd/elixir-nexus/cli/ui"
)


// ── list items ────────────────────────────────────────────────────────────────

type menuItem struct {
	title, desc, argPrompt string
	noArg                  bool
}

func (i menuItem) Title() string       { return i.title }
func (i menuItem) Description() string { return i.desc }
func (i menuItem) FilterValue() string { return i.title }

var menuItems = []list.Item{
	menuItem{"search", "Hybrid semantic + keyword search", "Query: ", false},
	menuItem{"callers", "Who calls this function?", "Entity name: ", false},
	menuItem{"callees", "What does this function call?", "Entity name: ", false},
	menuItem{"impact", "Transitive blast radius of a change", "Entity name: ", false},
	menuItem{"hierarchy", "Module hierarchy for an entity", "Entity name: ", false},
	menuItem{"dead-code", "Exported functions with no callers", "", true},
	menuItem{"stats", "Call graph statistics", "", true},
	menuItem{"status", "Server status and project info", "", true},
	menuItem{"reindex", "Index or re-index a project directory", "Path (leave blank for default): ", false},
	menuItem{"update", "Update nexus to the latest release", "", true},
}

// ── model ────────────────────────────────────────────────────────────────────

type wizardStep int

const (
	stepMenu wizardStep = iota
	stepInput
	stepDone
)

type wizardModel struct {
	step      wizardStep
	list      list.Model
	input     textinput.Model
	chosen    menuItem
	result    string
	cancelled bool
}

func newWizardModel() wizardModel {
	delegate := list.NewDefaultDelegate()
	delegate.Styles.SelectedTitle = delegate.Styles.SelectedTitle.
		Foreground(lipgloss.Color("#FFFFFF")).
		Background(ui.Accent).
		Bold(true)
	delegate.Styles.SelectedDesc = delegate.Styles.SelectedDesc.
		Foreground(lipgloss.Color("#D8B4FE")).
		Background(ui.Accent)

	l := list.New(menuItems, delegate, 60, 20)
	l.Title = "What do you want to do?"
	l.Styles.Title = ui.AccentStyle.Copy().
		Background(ui.Accent).
		Foreground(lipgloss.Color("#FFFFFF")).
		Padding(0, 1)
	l.SetShowStatusBar(false)
	l.SetFilteringEnabled(false)

	ti := textinput.New()
	ti.CharLimit = 200
	ti.Width = 50

	return wizardModel{list: l, input: ti}
}

func (m wizardModel) Init() tea.Cmd {
	return nil
}

func (m wizardModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch m.step {
	case stepMenu:
		return m.updateMenu(msg)
	case stepInput:
		return m.updateInput(msg)
	}
	return m, tea.Quit
}

func (m wizardModel) updateMenu(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "q", "ctrl+c", "esc":
			m.cancelled = true
			return m, tea.Quit
		case "enter":
			item, ok := m.list.SelectedItem().(menuItem)
			if !ok {
				return m, nil
			}
			m.chosen = item
			if item.noArg {
				m.step = stepDone
				return m, tea.Quit
			}
			m.input.Placeholder = ""
			m.input.Prompt = ui.AccentStyle.Render("  › ")
			m.step = stepInput
			return m, textinput.Blink
		}
	}
	var cmd tea.Cmd
	m.list, cmd = m.list.Update(msg)
	return m, cmd
}

func (m wizardModel) updateInput(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "ctrl+c", "esc":
			m.cancelled = true
			return m, tea.Quit
		case "enter":
			m.result = strings.TrimSpace(m.input.Value())
			m.step = stepDone
			return m, tea.Quit
		}
	}
	var cmd tea.Cmd
	m.input, cmd = m.input.Update(msg)
	return m, cmd
}

func (m wizardModel) View() string {
	switch m.step {
	case stepMenu:
		return "\n" + m.list.View() + "\n\n" +
			ui.MutedStyle.Render("  ↑/↓ navigate  •  enter select  •  q quit") + "\n"
	case stepInput:
		label := ui.BoldStyle.Render("  " + m.chosen.argPrompt)
		return "\n" + label + "\n" + m.input.View() + "\n\n" +
			ui.MutedStyle.Render("  enter confirm  •  esc back") + "\n"
	}
	return ""
}

// ── entry point ───────────────────────────────────────────────────────────────

func runWizard() error {
	m := newWizardModel()
	p := tea.NewProgram(m)
	finalModel, err := p.Run()
	if err != nil {
		return err
	}

	result := finalModel.(wizardModel)
	if result.cancelled || result.step != stepDone {
		return nil
	}

	// Dispatch to the chosen cobra subcommand
	dispatchArgs := []string{result.chosen.title}
	if !result.chosen.noArg && result.result != "" {
		dispatchArgs = append(dispatchArgs, result.result)
	}

	fmt.Println()
	// mcpClient already set by PersistentPreRun
	subCmd, subArgs, findErr := rootCmd.Find(dispatchArgs)
	if findErr != nil || subCmd == nil || subCmd == rootCmd {
		fmt.Println("unknown command:", result.chosen.title)
		return nil
	}
	return subCmd.RunE(subCmd, subArgs)
}
