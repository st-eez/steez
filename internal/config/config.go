// Package config manages steez configuration and the install registry at
// ~/.steez/.
package config

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// Config stores steez installer configuration.
type Config struct {
	RepoPath     string `json:"repo_path"`
	FirstInstall string `json:"first_install"`
}

// Registry tracks which symlinks steez has created, so it only manages its own.
type Registry struct {
	Symlinks []RegisteredSymlink `json:"symlinks"`
}

// RegisteredSymlink records a single steez-managed symlink.
type RegisteredSymlink struct {
	Name   string `json:"name"`            // e.g. "office-hours"
	Scope  string `json:"scope,omitempty"` // e.g. "claude-global", "codex-global"
	Source string `json:"source"`          // repo skill directory
	Target string `json:"target"`          // ~/.claude/skills/office-hours
}

// Dir returns the steez config directory (~/.steez/).
func Dir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolving home directory: %w", err)
	}
	return filepath.Join(home, ".steez"), nil
}

// EnsureDir creates ~/.steez/ if it does not exist.
func EnsureDir() error {
	dir, err := Dir()
	if err != nil {
		return err
	}
	return os.MkdirAll(dir, 0o755)
}

// configPath returns the path to ~/.steez/config.json.
func configPath() (string, error) {
	dir, err := Dir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "config.json"), nil
}

// registryPath returns the path to ~/.steez/installed.json.
func registryPath() (string, error) {
	dir, err := Dir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "installed.json"), nil
}

// Load reads the steez config from ~/.steez/config.json. If the file does not
// exist, it returns a zero-value Config (not an error).
func Load() (*Config, error) {
	path, err := configPath()
	if err != nil {
		return nil, err
	}

	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return &Config{}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("reading config: %w", err)
	}

	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parsing config: %w", err)
	}
	return &cfg, nil
}

// Save writes the steez config to ~/.steez/config.json.
func Save(cfg *Config) error {
	if err := EnsureDir(); err != nil {
		return err
	}

	path, err := configPath()
	if err != nil {
		return err
	}

	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return fmt.Errorf("marshaling config: %w", err)
	}
	data = append(data, '\n')

	return os.WriteFile(path, data, 0o644)
}

// LoadRegistry reads the install registry from ~/.steez/installed.json. If the
// file does not exist, it returns an empty registry.
func LoadRegistry() (*Registry, error) {
	path, err := registryPath()
	if err != nil {
		return nil, err
	}

	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return &Registry{}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("reading registry: %w", err)
	}

	var reg Registry
	if err := json.Unmarshal(data, &reg); err != nil {
		return nil, fmt.Errorf("parsing registry: %w", err)
	}
	return &reg, nil
}

// SaveRegistry writes the install registry to ~/.steez/installed.json.
func SaveRegistry(reg *Registry) error {
	if err := EnsureDir(); err != nil {
		return err
	}

	path, err := registryPath()
	if err != nil {
		return err
	}

	data, err := json.MarshalIndent(reg, "", "  ")
	if err != nil {
		return fmt.Errorf("marshaling registry: %w", err)
	}
	data = append(data, '\n')

	return os.WriteFile(path, data, 0o644)
}

// AddToRegistry appends a symlink entry to the registry. If an entry with the
// same name already exists, it is updated in place.
func AddToRegistry(reg *Registry, name, source, target string) *Registry {
	return AddScopedToRegistry(reg, "", name, source, target)
}

// AddScopedToRegistry appends a scoped symlink entry to the registry. If an
// entry with the same scope+name or target already exists, it is updated.
func AddScopedToRegistry(reg *Registry, scope, name, source, target string) *Registry {
	for i, s := range reg.Symlinks {
		if (s.Scope == scope && s.Name == name) || s.Target == target {
			reg.Symlinks[i] = RegisteredSymlink{Name: name, Scope: scope, Source: source, Target: target}
			return reg
		}
	}
	reg.Symlinks = append(reg.Symlinks, RegisteredSymlink{
		Name:   name,
		Scope:  scope,
		Source: source,
		Target: target,
	})
	return reg
}

// RemoveFromRegistry removes a symlink entry by name. If the name is not found,
// the registry is returned unchanged. It removes all entries for that skill.
func RemoveFromRegistry(reg *Registry, name string) *Registry {
	filtered := reg.Symlinks[:0]
	for _, s := range reg.Symlinks {
		if s.Name != name {
			filtered = append(filtered, s)
		}
	}
	reg.Symlinks = filtered
	return reg
}

// RemoveFromRegistryTarget removes a symlink entry by its target path.
func RemoveFromRegistryTarget(reg *Registry, target string) *Registry {
	filtered := reg.Symlinks[:0]
	for _, s := range reg.Symlinks {
		if s.Target != target {
			filtered = append(filtered, s)
		}
	}
	reg.Symlinks = filtered
	return reg
}
