package cmd

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"github.com/iksnerd/elixir-nexus/cli/ui"
	"github.com/spf13/cobra"
)

var communityLimit int

var communityCmd = &cobra.Command{
	Use:   "community <file>",
	Short: "Show files structurally coupled to a given file",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		var (
			result []byte
			err    error
		)
		ui.Spin("Finding coupled files…", func() {
			raw, e := mcpClient.CallTool("get_community_context", map[string]any{
				"file_path": args[0],
				"limit":     communityLimit,
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
		printCommunityContext(result, args[0])
		return nil
	},
}

func printCommunityContext(raw []byte, filePath string) {
	var ctx struct {
		File           string `json:"file"`
		EntitiesInFile int    `json:"entities_in_file"`
		CoupledFiles   []struct {
			FilePath      string `json:"file_path"`
			CouplingScore int    `json:"coupling_score"`
			Connections   []struct {
				From      string `json:"from"`
				To        string `json:"to"`
				Direction string `json:"direction"`
			} `json:"connections"`
		} `json:"coupled_files"`
	}
	if err := json.Unmarshal(raw, &ctx); err != nil {
		fmt.Println(string(raw))
		return
	}

	fmt.Printf("  %s  %s\n",
		ui.AccentStyle.Render("Community context"),
		ui.BoldStyle.Render(filepath.Base(filePath)),
	)
	fmt.Printf("  %s  %s\n\n",
		ui.MutedStyle.Render(filePath),
		ui.MutedStyle.Render(fmt.Sprintf("%d entities", ctx.EntitiesInFile)),
	)

	if len(ctx.CoupledFiles) == 0 {
		fmt.Println(ui.WarningStyle.Render("  No coupled files found."))
		return
	}

	fmt.Printf("  %s\n\n", ui.AccentStyle.Render(fmt.Sprintf("%d coupled files", len(ctx.CoupledFiles))))

	directionLabel := map[string]string{
		"incoming":    "calls us",
		"outgoing":    "we call",
		"imports":     "imports us",
		"imported_by": "we import",
	}

	for i, f := range ctx.CoupledFiles {
		fmt.Printf("  %s  %s  %s\n",
			ui.MutedStyle.Render(fmt.Sprintf("%3d.", i+1)),
			ui.BoldStyle.Render(fmt.Sprintf("score %-3d", f.CouplingScore)),
			ui.MutedStyle.Render(f.FilePath),
		)
		// Summarise connections by direction
		byDir := map[string][]string{}
		for _, c := range f.Connections {
			label, ok := directionLabel[c.Direction]
			if !ok {
				label = c.Direction
			}
			byDir[label] = append(byDir[label], fmt.Sprintf("%s → %s", c.From, c.To))
		}
		for label, edges := range byDir {
			shown := edges
			if len(shown) > 3 {
				shown = shown[:3]
			}
			for _, e := range shown {
				fmt.Printf("       %s  %s\n",
					ui.MutedStyle.Render(label+":"),
					ui.MutedStyle.Render(e),
				)
			}
			if len(edges) > 3 {
				fmt.Printf("       %s\n", ui.MutedStyle.Render(fmt.Sprintf("… and %d more", len(edges)-3)))
			}
		}
		fmt.Println()
	}
}

func init() {
	communityCmd.Flags().IntVar(&communityLimit, "limit", 10, "Max coupled files")
	rootCmd.AddCommand(communityCmd)
}
