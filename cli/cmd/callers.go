package cmd

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/iksnerd/elixir-nexus/cli/ui"
	"github.com/spf13/cobra"
)

var callersLimit int

var callersCmd = &cobra.Command{
	Use:   "callers <entity>",
	Short: "Find all callers of a function or module",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		var (
			result []byte
			err    error
		)
		ui.Spin("Finding callers…", func() {
			raw, e := mcpClient.CallTool("find_all_callers", map[string]any{
				"entity_name": args[0],
				"limit":       callersLimit,
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
		printCallerList(result, args[0], "callers")
		return nil
	},
}

var calleesCmd = &cobra.Command{
	Use:   "callees <entity>",
	Short: "Find all functions called by an entity",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		var (
			result []byte
			err    error
		)
		ui.Spin("Finding callees…", func() {
			raw, e := mcpClient.CallTool("find_all_callees", map[string]any{
				"entity_name": args[0],
				"limit":       callersLimit,
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

		var items []struct {
			Name     string `json:"name"`
			Resolved bool   `json:"resolved"`
		}
		if err := json.Unmarshal(result, &items); err != nil {
			fmt.Println(string(result))
			return nil
		}
		if len(items) == 0 {
			fmt.Println(ui.WarningStyle.Render("  No callees found."))
			return nil
		}
		fmt.Printf("  %s  %s\n\n",
			ui.AccentStyle.Render(fmt.Sprintf("%d callees", len(items))),
			ui.MutedStyle.Render("of "+args[0]),
		)
		for i, item := range items {
			resolved := ui.SuccessStyle.Render("✓")
			if !item.Resolved {
				resolved = ui.MutedStyle.Render("·")
			}
			fmt.Printf("  %s  %s %s\n",
				ui.MutedStyle.Render(fmt.Sprintf("%3d.", i+1)),
				resolved,
				item.Name,
			)
		}
		fmt.Println()
		return nil
	},
}

func printCallerList(raw []byte, entity, label string) {
	var items []struct {
		Entity struct {
			Name     string `json:"name"`
			FilePath string `json:"file_path"`
			Line     int    `json:"start_line"`
		} `json:"entity"`
	}
	if err := json.Unmarshal(raw, &items); err != nil {
		fmt.Println(string(raw))
		return
	}
	if len(items) == 0 {
		fmt.Println(ui.WarningStyle.Render("  No " + label + " found."))
		return
	}
	fmt.Printf("  %s  %s\n\n",
		ui.AccentStyle.Render(fmt.Sprintf("%d %s", len(items), label)),
		ui.MutedStyle.Render("of "+entity),
	)
	for i, item := range items {
		fmt.Printf("  %s  %s\n     %s\n\n",
			ui.MutedStyle.Render(fmt.Sprintf("%3d.", i+1)),
			ui.BoldStyle.Render(item.Entity.Name),
			ui.MutedStyle.Render(fmt.Sprintf("%s:%d", item.Entity.FilePath, item.Entity.Line)),
		)
	}
}

func init() {
	callersCmd.Flags().IntVar(&callersLimit, "limit", 20, "Max results")
	calleesCmd.Flags().IntVar(&callersLimit, "limit", 20, "Max results")
	rootCmd.AddCommand(callersCmd)
	rootCmd.AddCommand(calleesCmd)
}
