package cmd

import (
	"archive/tar"
	"compress/gzip"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"

	"github.com/iksnerd/elixir-nexus/cli/ui"
	"github.com/spf13/cobra"
)

const releaseBase = "https://github.com/iksnerd/code-nexus/releases/latest/download"

var updateCmd = &cobra.Command{
	Use:   "update",
	Short: "Update nexus to the latest release",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		goos := runtime.GOOS
		goarch := runtime.GOARCH

		archiveName := fmt.Sprintf("nexus_%s_%s.tar.gz", goos, goarch)
		url := fmt.Sprintf("%s/%s", releaseBase, archiveName)

		fmt.Printf("  %s %s\n\n", ui.MutedStyle.Render("Downloading"), ui.AccentStyle.Render(url))

		var (
			tmpFile string
			dlErr   error
		)

		ui.Spin("Downloading latest release…", func() {
			tmpFile, dlErr = download(url)
		})

		if dlErr != nil {
			fmt.Fprintln(os.Stderr, ui.DangerStyle.Render("✗ Download failed: "+dlErr.Error()))
			os.Exit(1)
		}
		defer os.Remove(tmpFile)

		binary, err := extract(tmpFile)
		if err != nil {
			fmt.Fprintln(os.Stderr, ui.DangerStyle.Render("✗ Extract failed: "+err.Error()))
			os.Exit(1)
		}
		defer os.Remove(binary)

		dest, err := os.Executable()
		if err != nil {
			fmt.Fprintln(os.Stderr, ui.DangerStyle.Render("✗ Could not locate current binary: "+err.Error()))
			os.Exit(1)
		}
		dest, _ = filepath.EvalSymlinks(dest)

		if err := replace(binary, dest); err != nil {
			fmt.Fprintln(os.Stderr, ui.DangerStyle.Render("✗ Could not replace binary (try with sudo): "+err.Error()))
			os.Exit(1)
		}

		fmt.Println(ui.SuccessStyle.Render("  ✓ nexus updated — restart to use the new version"))
		return nil
	},
}

func download(url string) (string, error) {
	resp, err := http.Get(url)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return "", fmt.Errorf("HTTP %d — platform may not be supported: %s", resp.StatusCode, url)
	}

	tmp, err := os.CreateTemp("", "nexus-update-*.tar.gz")
	if err != nil {
		return "", err
	}
	defer tmp.Close()

	if _, err := io.Copy(tmp, resp.Body); err != nil {
		return "", err
	}
	return tmp.Name(), nil
}

func extract(archivePath string) (string, error) {
	f, err := os.Open(archivePath)
	if err != nil {
		return "", err
	}
	defer f.Close()

	gz, err := gzip.NewReader(f)
	if err != nil {
		return "", err
	}
	defer gz.Close()

	tr := tar.NewReader(gz)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return "", err
		}
		if hdr.Name != "nexus" {
			continue
		}

		tmp, err := os.CreateTemp("", "nexus-new-*")
		if err != nil {
			return "", err
		}
		if _, err := io.Copy(tmp, tr); err != nil {
			tmp.Close()
			return "", err
		}
		tmp.Close()
		if err := os.Chmod(tmp.Name(), 0755); err != nil {
			return "", err
		}
		return tmp.Name(), nil
	}
	return "", fmt.Errorf("nexus binary not found in archive")
}

func replace(src, dest string) error {
	// Rename is atomic on the same filesystem; fallback to copy if cross-device.
	if err := os.Rename(src, dest); err == nil {
		return nil
	}

	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	out, err := os.OpenFile(dest, os.O_WRONLY|os.O_TRUNC, 0755)
	if err != nil {
		return err
	}
	defer out.Close()

	_, err = io.Copy(out, in)
	return err
}

func init() {
	rootCmd.AddCommand(updateCmd)
}
