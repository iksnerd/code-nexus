package cmd

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/iksnerd/elixir-nexus/cli/ui"
	"github.com/spf13/cobra"
)

var statsCmd = &cobra.Command{
	Use:   "stats",
	Short: "Show call graph statistics and key metrics",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		var (
			result []byte
			err    error
		)
		ui.Spin("Loading graph stats…", func() {
			raw, e := mcpClient.CallTool("get_graph_stats", map[string]any{})
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

		var stats struct {
			EdgeCounts struct {
				Calls    int `json:"calls"`
				Contains int `json:"contains"`
				Imports  int `json:"imports"`
			} `json:"edge_counts"`
			EntityTypes []struct {
				Type  string `json:"type"`
				Count int    `json:"count"`
			} `json:"entity_types"`
			CriticalFiles []struct {
				FilePath        string `json:"file_path"`
				CentralityScore int    `json:"centrality_score"`
			} `json:"critical_files"`
		}
		if err := json.Unmarshal(result, &stats); err != nil {
			fmt.Println(string(result))
			return nil
		}

		fmt.Println(ui.AccentStyle.Render("  Graph edges"))
		fmt.Printf("  %s calls  %s contains  %s imports\n\n",
			ui.BoldStyle.Render(fmt.Sprintf("%d", stats.EdgeCounts.Calls)),
			ui.BoldStyle.Render(fmt.Sprintf("%d", stats.EdgeCounts.Contains)),
			ui.BoldStyle.Render(fmt.Sprintf("%d", stats.EdgeCounts.Imports)),
		)

		if len(stats.EntityTypes) > 0 {
			fmt.Println(ui.AccentStyle.Render("  Entity types"))
			for _, e := range stats.EntityTypes {
				fmt.Printf("  %-14s %s\n",
					ui.MutedStyle.Render(e.Type),
					ui.BoldStyle.Render(fmt.Sprintf("%d", e.Count)),
				)
			}
			fmt.Println()
		}

		if len(stats.CriticalFiles) > 0 {
			fmt.Println(ui.AccentStyle.Render("  Most connected files"))
			for i, f := range stats.CriticalFiles {
				fmt.Printf("  %s  %s  %s\n",
					ui.MutedStyle.Render(fmt.Sprintf("%2d.", i+1)),
					ui.BoldStyle.Render(fmt.Sprintf("score %-4d", f.CentralityScore)),
					ui.MutedStyle.Render(f.FilePath),
				)
			}
			fmt.Println()
		}
		return nil
	},
}

var hierarchyCmd = &cobra.Command{
	Use:   "hierarchy <entity>",
	Short: "Show module hierarchy for an entity",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		var (
			result []byte
			err    error
		)
		ui.Spin("Resolving hierarchy…", func() {
			raw, e := mcpClient.CallTool("find_module_hierarchy", map[string]any{
				"entity_name": args[0],
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
		var msg any
		if err := json.Unmarshal(result, &msg); err != nil {
			fmt.Println(string(result))
			return nil
		}
		printJSON(msg)
		return nil
	},
}

func init() {
	rootCmd.AddCommand(statsCmd)
	rootCmd.AddCommand(hierarchyCmd)
}
