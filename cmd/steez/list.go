package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"github.com/st-eez/steez/internal/config"
	"github.com/st-eez/steez/internal/installer"
)

func cmdList(_ []string) int {
	reg, err := config.LoadRegistry()
	if err != nil {
		fmt.Fprintf(os.Stderr, "error loading registry: %v\n", err)
		return 1
	}

	if len(reg.Symlinks) == 0 {
		fmt.Println("No skills installed. Run steez install <profile> to get started.")
		return 0
	}

	fmt.Printf("%-28s %-8s %s\n", "SKILL", "STATUS", "TARGET")
	for _, entry := range reg.Symlinks {
		status := "valid"
		if err := installer.ValidateSymlink(entry.Target); err != nil {
			status = "broken"
		}
		fmt.Printf("%-28s %-8s %s\n", entry.Name, status, entry.Target)
	}

	fmt.Printf("\n%d skills installed.\n", len(reg.Symlinks))
	return 0
}

func cmdInfo(args []string) int {
	fs := flag.NewFlagSet("info", flag.ContinueOnError)
	repoFlag := fs.String("repo", "", "override repo path")

	if err := fs.Parse(args); err != nil {
		return 1
	}

	if fs.NArg() == 0 {
		fmt.Fprintln(os.Stderr, "Usage: steez info <skill>")
		return 1
	}

	repoPath, err := resolveRepoPath(*repoFlag)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		return 1
	}

	manifest, err := installer.LoadManifest(filepath.Join(repoPath, "skills.json"))
	if err != nil {
		fmt.Fprintf(os.Stderr, "error loading manifest: %v\n", err)
		return 1
	}

	skill, err := installer.FindSkill(manifest, fs.Arg(0))
	if err != nil {
		fmt.Fprintf(os.Stderr, "%v\n", err)
		return 1
	}

	// Find which category this skill belongs to.
	category := ""
	for catName, cat := range manifest.Categories {
		for _, s := range cat.Skills {
			if s.Name == skill.Name {
				category = cat.Label + " (" + catName + ")"
				break
			}
		}
	}

	// Check installed status.
	reg, _ := config.LoadRegistry()
	installedStatus := "not installed"
	for _, s := range reg.Symlinks {
		if s.Name == skill.Name {
			if err := installer.ValidateSymlink(s.Target); err != nil {
				installedStatus = "installed (broken symlink)"
			} else {
				installedStatus = "installed"
			}
			break
		}
	}

	fmt.Printf("Name:        %s\n", skill.Name)
	fmt.Printf("Description: %s\n", skill.Description)
	if category != "" {
		fmt.Printf("Category:    %s\n", category)
	}
	if len(skill.Requires) > 0 {
		fmt.Printf("Requires:    %s\n", fmt.Sprintf("%v", skill.Requires))
	}
	fmt.Printf("Status:      %s\n", installedStatus)

	return 0
}
