package cmd

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/iksnerd/elixir-nexus/cli/ui"
	"github.com/spf13/cobra"
)

var deadCodePrefix string

var deadCodeCmd = &cobra.Command{
	Use:   "dead-code",
	Short: "Find exported functions with no callers",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		var (
			result []byte
			err    error
		)
		ui.Spin("Scanning for dead code…", func() {
			raw, e := mcpClient.CallTool("find_dead_code", deadCodeArgs(deadCodePrefix))
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
		renderDeadCode(os.Stdout, result)
		return nil
	},
}

// deadCodeArgs builds the find_dead_code arguments. The server's parameter is
// path_prefix; the CLI used to send file_prefix, which the server ignored.
func deadCodeArgs(prefix string) map[string]any {
	args := map[string]any{}
	if prefix != "" {
		args["path_prefix"] = prefix
	}
	return args
}

type deadEntry struct {
	Name          string   `json:"name"`
	QualifiedName string   `json:"qualified_name"`
	EntityType    string   `json:"entity_type"`
	FilePath      string   `json:"file_path"`
	StartLine     int      `json:"start_line"`
	Chain         []string `json:"chain"`
	Reason        string   `json:"reason"`
}

func (e deadEntry) label() string {
	if e.QualifiedName != "" {
		return e.QualifiedName
	}
	return e.Name
}

// renderDeadCode prints the find_dead_code report: the directly dead functions,
// those only dead code calls (with the chain that reaches them), and the ones
// the graph cannot judge (with the reason). Unparseable output is printed as is.
func renderDeadCode(w io.Writer, raw []byte) {
	var report struct {
		DeadFunctions []deadEntry `json:"dead_functions"`
		ViaDead       []deadEntry `json:"dead_via_dead_callers"`
		Unsure        []deadEntry `json:"unsure"`
		TotalPublic   int         `json:"total_public"`
		DeadCount     int         `json:"dead_count"`
		Warning       string      `json:"warning"`
	}
	if err := json.Unmarshal(raw, &report); err != nil {
		fmt.Fprintln(w, string(raw))
		return
	}

	deadCount := report.DeadCount
	if deadCount == 0 {
		deadCount = len(report.DeadFunctions)
	}

	pct := 0.0
	if report.TotalPublic > 0 {
		pct = float64(deadCount) / float64(report.TotalPublic) * 100
	}

	fmt.Fprintf(w, "  %s  %s\n\n",
		ui.WarningStyle.Render(fmt.Sprintf("%d / %d", deadCount, report.TotalPublic)),
		ui.MutedStyle.Render(fmt.Sprintf("public functions unreachable (%.0f%%)", pct)),
	)

	for i, fn := range report.DeadFunctions {
		printDeadEntry(w, i, fn, "")
	}

	if len(report.ViaDead) > 0 {
		fmt.Fprintf(w, "  %s\n\n", ui.BoldStyle.Render(fmt.Sprintf("Called only by dead code (%d)", len(report.ViaDead))))
		for i, fn := range report.ViaDead {
			printDeadEntry(w, i, fn, strings.Join(fn.Chain, " → "))
		}
	}

	if len(report.Unsure) > 0 {
		fmt.Fprintf(w, "  %s\n\n", ui.BoldStyle.Render(fmt.Sprintf("Unsure: reached only dynamically (%d)", len(report.Unsure))))
		for i, fn := range report.Unsure {
			printDeadEntry(w, i, fn, fn.Reason)
		}
	}

	if report.Warning != "" {
		fmt.Fprintln(w, ui.WarningStyle.Render("  ⚠  "+report.Warning))
		fmt.Fprintln(w)
	}
}

func printDeadEntry(w io.Writer, i int, fn deadEntry, detail string) {
	fmt.Fprintf(w, "  %s  %s %s\n     %s\n",
		ui.MutedStyle.Render(fmt.Sprintf("%3d.", i+1)),
		ui.BoldStyle.Render(fn.label()),
		ui.MutedStyle.Render("("+fn.EntityType+")"),
		ui.MutedStyle.Render(fmt.Sprintf("%s:%d", fn.FilePath, fn.StartLine)),
	)
	if detail != "" {
		fmt.Fprintf(w, "     %s\n", ui.MutedStyle.Render(detail))
	}
	fmt.Fprintln(w)
}

func init() {
	deadCodeCmd.Flags().StringVar(&deadCodePrefix, "prefix", "", "Filter by file path prefix")
	rootCmd.AddCommand(deadCodeCmd)
}
