package ui

import "github.com/charmbracelet/lipgloss"

var (
	Accent  = lipgloss.Color("#7C3AED")
	Muted   = lipgloss.Color("#6B7280")
	Success = lipgloss.Color("#10B981")
	Warning = lipgloss.Color("#F59E0B")
	Danger  = lipgloss.Color("#EF4444")
	Subtle  = lipgloss.Color("#374151")

	AccentStyle = lipgloss.NewStyle().Foreground(Accent).Bold(true)
	MutedStyle  = lipgloss.NewStyle().Foreground(Muted)
	SuccessStyle = lipgloss.NewStyle().Foreground(Success)
	DangerStyle  = lipgloss.NewStyle().Foreground(Danger)
	WarningStyle = lipgloss.NewStyle().Foreground(Warning)
	BoldStyle    = lipgloss.NewStyle().Bold(true)

	HeaderBox = lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(Accent).
			Padding(0, 2)

	ResultBox = lipgloss.NewStyle().
			Border(lipgloss.NormalBorder(), false, false, false, true).
			BorderForeground(Accent).
			PaddingLeft(1)

	LabelStyle = lipgloss.NewStyle().
			Foreground(Muted).
			Width(12)

	IndexBadge = lipgloss.NewStyle().
			Foreground(lipgloss.Color("#FFFFFF")).
			Background(Accent).
			Padding(0, 1).
			Bold(true)
)
