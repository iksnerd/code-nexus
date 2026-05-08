package cmd

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/iksnerd/elixir-nexus/cli/ui"
	"github.com/spf13/cobra"
)

var reindexCmd = &cobra.Command{
	Use:   "reindex [path]",
	Short: "Index or re-index a project directory",
	Args:  cobra.MaximumNArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		toolArgs := map[string]any{}
		if len(args) == 1 && args[0] != "" {
			toolArgs["path"] = args[0]
		}

		var (
			result []byte
			err    error
		)

		label := "Indexing…"
		if len(args) == 1 && args[0] != "" {
			label = "Indexing " + args[0] + "…"
		}

		ui.Spin(label, func() {
			raw, e := mcpClient.CallTool("reindex", toolArgs)
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

		var msg any
		if err := json.Unmarshal(result, &msg); err != nil {
			fmt.Println(string(result))
			return nil
		}

		fmt.Println(ui.SuccessStyle.Render("  ✓ Indexing complete"))
		fmt.Println()
		printJSON(msg)
		return nil
	},
}

func init() {
	rootCmd.AddCommand(reindexCmd)
}
