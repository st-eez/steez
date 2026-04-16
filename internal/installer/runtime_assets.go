package installer

// RuntimeSymlink describes one shared runtime symlink installed under ~/.steez.
type RuntimeSymlink struct {
	Name    string
	RelPath string
}

func SharedBinSymlinks() []RuntimeSymlink {
	return []RuntimeSymlink{
		{Name: "config", RelPath: "shared/steez/bin/config"},
		{Name: "slug", RelPath: "shared/steez/bin/slug"},
		{Name: "diff-scope", RelPath: "shared/steez/bin/diff-scope"},
		{Name: "review-log", RelPath: "shared/steez/bin/review-log"},
		{Name: "review-read", RelPath: "shared/steez/bin/review-read"},
		{Name: "steez-bd", RelPath: "shared/steez/bin/steez-bd"},
		{Name: "agent-state", RelPath: "shared/steez/bin/agent-state"},
		{Name: "agent-history", RelPath: "shared/steez/bin/agent-history"},
		{Name: "agent-send", RelPath: "shared/steez/bin/agent-send"},
		{Name: "agent-deliver", RelPath: "shared/steez/bin/agent-deliver"},
		{Name: "agent-watch", RelPath: "shared/steez/bin/agent-watch"},
		{Name: "agent-eventsd", RelPath: "shared/steez/bin/agent-eventsd"},
		{Name: "browse", RelPath: "shared/steez/browse/dist/browse"},
	}
}

func DeprecatedBinSymlinks() []string {
	return []string{
		"steez-config",
		"steez-slug",
		"steez-diff-scope",
		"steez-review-log",
		"steez-review-read",
		"steez-agent-state",
		"steez-agent-history",
	}
}

func SharedClaudeHookSymlinks() []RuntimeSymlink {
	return []RuntimeSymlink{
		{Name: "steez-permission-state.sh", RelPath: "shared/steez/hooks/permission-state.sh"},
		{Name: "steez-skill-analytics.sh", RelPath: "shared/steez/hooks/skill-analytics.sh"},
		{Name: "steez-session-start.sh", RelPath: "shared/steez/hooks/session-start.sh"},
	}
}

func SharedCodexHookSymlinks() []RuntimeSymlink {
	return []RuntimeSymlink{
		{Name: "session-start.sh", RelPath: "shared/steez/hooks/codex-session-start.sh"},
		{Name: "codex-stop.sh", RelPath: "shared/steez/hooks/codex-stop.sh"},
	}
}
