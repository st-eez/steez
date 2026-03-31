package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/st-eez/steez/internal/installer"
)

func cmdDoctor(args []string) int {
	fs := flag.NewFlagSet("doctor", flag.ContinueOnError)
	fix := fs.Bool("fix", false, "auto-repair what it can")

	if err := fs.Parse(args); err != nil {
		return 1
	}

	repoPath, err := resolveRepoPath("")
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		return 1
	}

	results, err := installer.RunDoctor(repoPath, *fix)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error running doctor: %v\n", err)
		return 1
	}

	passes, fails, warns := 0, 0, 0
	for _, r := range results {
		var icon string
		switch r.Status {
		case "pass":
			icon = "  \u2713"
			passes++
		case "fail":
			icon = "  \u2717"
			fails++
		case "warn":
			icon = "  !"
			warns++
		}
		fmt.Printf("%s %-28s %s\n", icon, r.Name, r.Message)
	}

	fmt.Printf("\n%d passed, %d failed, %d warnings\n", passes, fails, warns)

	return installer.ExitCode(results)
}
