package cmd

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/iksnerd/elixir-nexus/cli/client"
	"github.com/iksnerd/elixir-nexus/cli/ui"
	"github.com/spf13/cobra"
)

// Set at build time via: go build -ldflags "-X github.com/iksnerd/elixir-nexus/cli/cmd.Version=v1.2.3"
var Version = "dev"

var (
	serverURL string
	jsonOut   bool
	mcpClient *client.Client
)

var rootCmd = &cobra.Command{
	Use:   "nexus",
	Short: "CodeNexus CLI — query a running CodeNexus MCP server",
	PersistentPreRun: func(cmd *cobra.Command, args []string) {
		if cmd.Name() == "completion" {
			return
		}
		ui.PrintHeader(serverURL, Version)
		mcpClient = client.New(serverURL)
	},
}

func Execute() {
	if err := rootCmd.Execute(); err != nil {
		os.Exit(1)
	}
}

func init() {
	defaultURL := os.Getenv("NEXUS_URL")
	if defaultURL == "" {
		defaultURL = "http://localhost:3002"
	}

	rootCmd.PersistentFlags().StringVar(&serverURL, "server", defaultURL, "CodeNexus server URL (env: NEXUS_URL)")
	rootCmd.PersistentFlags().BoolVar(&jsonOut, "json", false, "Output raw JSON")

	// Wire wizard after rootCmd is fully initialised (breaks init cycle)
	rootCmd.RunE = func(cmd *cobra.Command, args []string) error {
		return runWizard()
	}
}

func printJSON(v any) {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		fmt.Fprintln(os.Stderr, "error marshaling output:", err)
		os.Exit(1)
	}
	fmt.Println(string(b))
}

func handleResult(raw json.RawMessage, format func(json.RawMessage)) {
	if jsonOut {
		fmt.Println(string(raw))
		return
	}
	format(raw)
}
