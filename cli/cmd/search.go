package cmd

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/charmbracelet/lipgloss"
	"github.com/iksnerd/elixir-nexus/cli/ui"
	"github.com/spf13/cobra"
)

var searchLimit int

var searchCmd = &cobra.Command{
	Use:   "search <query>",
	Short: "Hybrid semantic + keyword search across indexed code",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		var (
			result []byte
			err    error
		)

		ui.Spin("Searching…", func() {
			raw, e := mcpClient.CallTool("search_code", map[string]any{
				"query": args[0],
				"limit": searchLimit,
			})
			result, err = raw, e
		})

		if err != nil {
			fmt.Fprintln(os.Stderr, ui.DangerStyle.Render("✗ "+err.Error()))
			os.Exit(1)
		}

		if jsonOut {
			fmt.Println(string(result))
			return nil
		}

		var hits []struct {
			Score  float64 `json:"score"`
			Entity struct {
				Name       string `json:"name"`
				EntityType string `json:"entity_type"`
				FilePath   string `json:"file_path"`
				StartLine  int    `json:"start_line"`
				EndLine    int    `json:"end_line"`
			} `json:"entity"`
		}
		if err := json.Unmarshal(result, &hits); err != nil {
			fmt.Println(string(result))
			return nil
		}

		if len(hits) == 0 {
			fmt.Println(ui.WarningStyle.Render("  ⚠  No results. Run: nexus reindex"))
			return nil
		}

		fmt.Printf("  %s  %s\n\n",
			ui.AccentStyle.Render(fmt.Sprintf("%d results", len(hits))),
			ui.MutedStyle.Render("for "+`"`+args[0]+`"`),
		)

		for i, h := range hits {
			badge := lipgloss.NewStyle().
				Foreground(lipgloss.Color("#FFFFFF")).
				Background(entityColor(h.Entity.EntityType)).
				Padding(0, 1).
				Render(h.Entity.EntityType)

			score := ui.MutedStyle.Render(fmt.Sprintf("%.0f%%", h.Score*100))
			name := ui.BoldStyle.Render(h.Entity.Name)
			loc := ui.MutedStyle.Render(fmt.Sprintf("%s:%d-%d", h.Entity.FilePath, h.Entity.StartLine, h.Entity.EndLine))

			fmt.Printf("  %s  %s %s  %s\n     %s\n\n",
				ui.MutedStyle.Render(fmt.Sprintf("%2d.", i+1)),
				badge, name, score, loc,
			)
		}
		return nil
	},
}

func entityColor(t string) lipgloss.Color {
	switch t {
	case "function":
		return lipgloss.Color("#7C3AED")
	case "module", "class":
		return lipgloss.Color("#0891B2")
	case "interface":
		return lipgloss.Color("#059669")
	default:
		return lipgloss.Color("#6B7280")
	}
}

func init() {
	searchCmd.Flags().IntVar(&searchLimit, "limit", 10, "Max results")
	rootCmd.AddCommand(searchCmd)
}
