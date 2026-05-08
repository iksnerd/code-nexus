package cmd

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/iksnerd/elixir-nexus/cli/ui"
	"github.com/spf13/cobra"
)

var impactDepth int

var impactCmd = &cobra.Command{
	Use:   "impact <entity>",
	Short: "Analyze transitive callers — what breaks if this changes",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		var (
			result []byte
			err    error
		)
		ui.Spin("Analyzing impact…", func() {
			raw, e := mcpClient.CallTool("analyze_impact", map[string]any{
				"entity_name": args[0],
				"depth":       impactDepth,
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

		var report struct {
			Root          string   `json:"root"`
			Depth         int      `json:"depth"`
			TotalAffected int      `json:"total_affected"`
			AffectedFiles []string `json:"affected_files"`
			Impact        []struct {
				Name       string   `json:"name"`
				EntityType string   `json:"entity_type"`
				FilePath   string   `json:"file_path"`
				StartLine  int      `json:"start_line"`
				AffectedBy []string `json:"affected_by"`
			} `json:"impact"`
		}
		if err := json.Unmarshal(result, &report); err != nil {
			fmt.Println(string(result))
			return nil
		}

		fmt.Printf("  %s  %s  %s\n\n",
			ui.AccentStyle.Render("Impact analysis"),
			ui.MutedStyle.Render("for"),
			ui.BoldStyle.Render(report.Root),
		)
		fmt.Printf("  %s  depth %d  •  %s affected\n\n",
			ui.MutedStyle.Render("→"),
			report.Depth,
			ui.WarningStyle.Render(fmt.Sprintf("%d entities", report.TotalAffected)),
		)

		if len(report.AffectedFiles) > 0 {
			fmt.Println(ui.AccentStyle.Render("  Affected files"))
			for _, f := range report.AffectedFiles {
				fmt.Printf("  %s %s\n", ui.WarningStyle.Render("⚠"), ui.MutedStyle.Render(f))
			}
			fmt.Println()
		}

		if len(report.Impact) > 0 {
			fmt.Println(ui.AccentStyle.Render("  Affected entities"))
			seen := map[string]bool{}
			for _, e := range report.Impact {
				key := e.Name + e.FilePath
				if seen[key] {
					continue
				}
				seen[key] = true
				fmt.Printf("  %s %s\n     %s\n\n",
					ui.BoldStyle.Render(e.Name),
					ui.MutedStyle.Render("("+e.EntityType+")"),
					ui.MutedStyle.Render(fmt.Sprintf("%s:%d", e.FilePath, e.StartLine)),
				)
			}
		}
		return nil
	},
}

func init() {
	impactCmd.Flags().IntVar(&impactDepth, "depth", 3, "Transitive caller depth")
	rootCmd.AddCommand(impactCmd)
}
