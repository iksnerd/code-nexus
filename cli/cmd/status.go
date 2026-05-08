package cmd

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/iksnerd/elixir-nexus/cli/ui"
	"github.com/spf13/cobra"
)

var statusCmd = &cobra.Command{
	Use:   "status",
	Short: "Show indexing status and project info",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		var (
			result []byte
			err    error
		)

		ui.Spin("Fetching status…", func() {
			raw, e := mcpClient.CallTool("get_status", map[string]any{})
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

		var s struct {
			CurrentProject  string   `json:"current_project"`
			Indexed         bool     `json:"indexed"`
			FileCount       int      `json:"file_count"`
			EmbeddingModel  string   `json:"embedding_model"`
			OllamaURL       string   `json:"ollama_url"`
			Qdrant          string   `json:"qdrant"`
			Collections     []string `json:"collections"`
			WorkspaceProjects []string `json:"workspace_projects"`
		}
		if err := json.Unmarshal(result, &s); err != nil {
			fmt.Println(string(result))
			return nil
		}

		indexedStr := ui.SuccessStyle.Render("✓ indexed")
		if !s.Indexed {
			indexedStr = ui.WarningStyle.Render("✗ not indexed")
		}

		qdrantStr := ui.SuccessStyle.Render("✓ ok")
		if s.Qdrant != "ok" {
			qdrantStr = ui.DangerStyle.Render("✗ " + s.Qdrant)
		}

		row := func(label, val string) string {
			return ui.LabelStyle.Render(label) + val
		}

		fmt.Println(ui.AccentStyle.Render("  Project"))
		fmt.Println(ui.ResultBox.Render(strings.Join([]string{
			row("name", ui.BoldStyle.Render(s.CurrentProject)),
			row("status", indexedStr),
			row("files", ui.BoldStyle.Render(fmt.Sprintf("%d", s.FileCount))),
			row("model", s.EmbeddingModel),
			row("ollama", ui.MutedStyle.Render(s.OllamaURL)),
			row("qdrant", qdrantStr),
		}, "\n")))

		fmt.Println()
		fmt.Println(ui.AccentStyle.Render("  Collections  ") + ui.MutedStyle.Render(fmt.Sprintf("(%d)", len(s.Collections))))
		for _, c := range s.Collections {
			active := "  "
			name := strings.TrimPrefix(c, "nexus_")
			if name == strings.ReplaceAll(s.CurrentProject, "-", "_") {
				active = ui.AccentStyle.Render("▶ ")
			}
			fmt.Printf("  %s%s\n", active, ui.MutedStyle.Render(name))
		}

		if len(s.WorkspaceProjects) > 0 {
			fmt.Println()
			fmt.Println(ui.AccentStyle.Render("  Workspace projects  ") + ui.MutedStyle.Render(fmt.Sprintf("(%d)", len(s.WorkspaceProjects))))
			for _, p := range s.WorkspaceProjects {
				fmt.Printf("  %s %s\n", ui.MutedStyle.Render("·"), p)
			}
		}
		fmt.Println()
		return nil
	},
}

func init() {
	rootCmd.AddCommand(statusCmd)
}
