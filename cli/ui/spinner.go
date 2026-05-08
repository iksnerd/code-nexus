package ui

import (
	"fmt"
	"os"
	"time"
)

var frames = []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}

// Spin runs fn in the background, showing a spinner until it returns.
func Spin(label string, fn func()) {
	if !isTerminal() {
		fn()
		return
	}

	done := make(chan struct{})
	go func() {
		defer close(done)
		fn()
	}()

	i := 0
	ticker := time.NewTicker(80 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-done:
			fmt.Fprintf(os.Stderr, "\r\033[K") // clear line
			return
		case <-ticker.C:
			frame := AccentStyle.Render(frames[i%len(frames)])
			fmt.Fprintf(os.Stderr, "\r  %s  %s", frame, MutedStyle.Render(label))
			i++
		}
	}
}

func isTerminal() bool {
	fi, err := os.Stderr.Stat()
	if err != nil {
		return false
	}
	return fi.Mode()&os.ModeCharDevice != 0
}
