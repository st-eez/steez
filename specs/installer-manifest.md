# installer-manifest

**Paths:**
- `skills.json`
- `internal/installer/manifest.go`

Documents the shipped install surface for skill categories and named profiles.

## Inputs

- `skills.json`
- `internal/installer/ResolveProfile`

## Outputs

- Resolved category membership
- Resolved install profiles such as `starter`

## Behavioral Contracts

1. The `workflow` category is the implementation workflow only: `spec`, then `tdd`.
2. The `operations` category owns daily planning and ticket operations: `agenda` and `jira`.
3. The `starter` profile installs the `workflow` category only.
4. The starter install surface is `spec` and `tdd`, not `agenda` or `jira`.
