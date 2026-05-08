package cmd

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/iksnerd/elixir-nexus/cli/ui"
	"github.com/spf13/cobra"
)

var deadCodePrefix string

var deadCodeCmd = &cobra.Command{
	Use:   "dead-code",
	Short: "Find exported functions with no callers",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		toolArgs := map[string]any{}
		if deadCodePrefix != "" {
			toolArgs["file_prefix"] = deadCodePrefix
		}

		var (
			result []byte
			err    error
		)
		ui.Spin("Scanning for dead code…", func() {
			raw, e := mcpClient.CallTool("find_dead_code", toolArgs)
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
			DeadFunctions []struct {
				Name       string `json:"name"`
				EntityType string `json:"entity_type"`
				FilePath   string `json:"file_path"`
				StartLine  int    `json:"start_line"`
			} `json:"dead_functions"`
			TotalPublic int    `json:"total_public"`
			DeadCount   int    `json:"dead_count"`
			Warning     string `json:"warning"`
		}
		if err := json.Unmarshal(result, &report); err != nil {
			fmt.Println(string(result))
			return nil
		}

		deadCount := report.DeadCount
		if deadCount == 0 {
			deadCount = len(report.DeadFunctions)
		}

		pct := 0.0
		if report.TotalPublic > 0 {
			pct = float64(deadCount) / float64(report.TotalPublic) * 100
		}

		fmt.Printf("  %s  %s\n\n",
			ui.WarningStyle.Render(fmt.Sprintf("%d / %d", deadCount, report.TotalPublic)),
			ui.MutedStyle.Render(fmt.Sprintf("public functions unreachable (%.0f%%)", pct)),
		)

		for i, fn := range report.DeadFunctions {
			fmt.Printf("  %s  %s %s\n     %s\n\n",
				ui.MutedStyle.Render(fmt.Sprintf("%3d.", i+1)),
				ui.BoldStyle.Render(fn.Name),
				ui.MutedStyle.Render("("+fn.EntityType+")"),
				ui.MutedStyle.Render(fmt.Sprintf("%s:%d", fn.FilePath, fn.StartLine)),
			)
		}

		if report.Warning != "" {
			fmt.Println(ui.WarningStyle.Render("  ⚠  " + report.Warning))
			fmt.Println()
		}
		return nil
	},
}

func init() {
	deadCodeCmd.Flags().StringVar(&deadCodePrefix, "prefix", "", "Filter by file path prefix")
	rootCmd.AddCommand(deadCodeCmd)
}
