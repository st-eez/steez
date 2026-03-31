package main

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/st-eez/steez/internal/installer"
)

func main() {
	// Find skills.json relative to the binary's source repo.
	// For now, use the working directory.
	manifestPath := filepath.Join(".", "skills.json")
	if len(os.Args) > 1 {
		manifestPath = os.Args[1]
	}

	m, err := installer.LoadManifest(manifestPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("steez v%s — %d skills loaded\n", m.Version, len(m.Skills))
}
