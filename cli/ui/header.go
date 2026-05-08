package ui

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

const logo = `
  ███╗   ██╗███████╗██╗  ██╗██╗   ██╗███████╗
  ████╗  ██║██╔════╝╚██╗██╔╝██║   ██║██╔════╝
  ██╔██╗ ██║█████╗   ╚███╔╝ ██║   ██║███████╗
  ██║╚██╗██║██╔══╝   ██╔██╗ ██║   ██║╚════██║
  ██║ ╚████║███████╗██╔╝ ██╗╚██████╔╝███████║
  ╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝`

func PrintHeader(serverURL, version string) {
	logoStyled := lipgloss.NewStyle().Foreground(Accent).Bold(true).Render(logo)

	tagline := MutedStyle.Render("  Graph-powered code intelligence · MCP server client")
	versionBadge := lipgloss.NewStyle().
		Foreground(lipgloss.Color("#FFFFFF")).
		Background(Accent).
		Padding(0, 1).
		Render(version)

	serverLine := fmt.Sprintf("  %s  %s  %s",
		versionBadge,
		MutedStyle.Render("→"),
		AccentStyle.Render(serverURL),
	)

	divider := MutedStyle.Render("  " + strings.Repeat("─", 50))

	fmt.Println(logoStyled)
	fmt.Println(tagline)
	fmt.Println(serverLine)
	fmt.Println(divider)
	fmt.Println()
}
