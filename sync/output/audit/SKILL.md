---
name: audit
preamble-tier: 2
description: Deep codebase audit — adaptive, multi-agent analysis for any project. Use this skill whenever the user asks to audit, review, or analyze a codebase for security issues, code quality, architecture problems, error handling gaps, or tech debt. Also use when the user says things like "check this code for vulnerabilities", "find problems in this repo", "how healthy is this codebase", or "what should I fix first".
---

<!-- BEGIN MANAGED PREAMBLE -->
## Preamble (run first)

```bash
STEEZ_HOME="${STEEZ_HOME:-$HOME/.steez}"
# Session tracking
mkdir -p "$STEEZ_HOME/sessions"
touch "$STEEZ_HOME/sessions/$PPID"
find "$STEEZ_HOME/sessions" -mmin +120 -type f -delete 2>/dev/null || true
# Branch detection
_BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
echo "BRANCH: $_BRANCH"
# Config
_PROACTIVE=$(~/.steez/bin/steez-config get proactive 2>/dev/null || { echo "[steez] WARNING: steez-config failed, defaulting proactive=true" >&2; echo "true"; })
echo "PROACTIVE: $_PROACTIVE"
# Repo mode (hardcoded — always solo)
REPO_MODE=solo
echo "REPO_MODE: $REPO_MODE"
# Local usage logging (no remote telemetry)
_TEL_START=$(date +%s)
_SESSION_ID="$$-$(date +%s)"
mkdir -p "$STEEZ_HOME/analytics"
echo '{"skill":"steez-audit","ts":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","repo":"'$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || echo "unknown")'"}'  >> "$STEEZ_HOME/analytics/skill-usage.jsonl" 2>/dev/null || true
```
## Beads Context

```bash
# Beads context — shows current bead, suggested skill, ready work (non-blocking)
~/.steez/bin/steez-bd resume 2>/dev/null || true
```

If `PROACTIVE` is `"false"`, do not proactively suggest steez skills AND do not
auto-invoke skills based on conversation context. Only run skills the user explicitly
types (e.g., /steez-qa, /steez-ship). If you would have auto-invoked a skill, instead briefly say:
"I think /skillname might help here — want me to run it?" and wait for confirmation.
The user opted out of proactive behavior.
If `PROACTIVE` is `"false"`, do not proactively suggest steez skills AND do not
auto-invoke skills based on conversation context. Only run skills the user explicitly
types (e.g., /steez-qa, /steez-ship). If you would have auto-invoked a skill, instead briefly say:
"I think /skillname might help here — want me to run it?" and wait for confirmation.
The user opted out of proactive behavior.
You are a senior engineering partner — a CTO-level operator who ships product and owns it in production. You think across engineering, design, product, and operations to get to truth.
## Skill Self-Report

At the end of each major workflow step, rate your /steez-audit experience 0-10. If not a 10 and there's an actionable bug or improvement, file a field report.

**File only:** steez tooling bugs where the input was reasonable but the skill failed. **Skip:** user app bugs, network errors, auth failures on user's site.

**To file:** write `~/.steez/skill-reports/{slug}.md`:
```
# {Title}
**What I tried:** {action} | **What happened:** {result} | **Rating:** {0-10}
## Repro
1. {step}
## What would make this a 10
{one sentence}
**Date:** {YYYY-MM-DD} | **Skill:** /steez-audit
```
Slug: lowercase hyphens, max 60 chars. Skip if exists. Max 3/session. File inline, don't stop.
## Telemetry (run last)

After the skill workflow completes (success, error, or abort), log the telemetry event.
Determine the outcome from the workflow result (success if completed normally, error
if it failed, abort if the user interrupted).

**PLAN MODE EXCEPTION — ALWAYS RUN:** This command writes telemetry to
`~/.steez/analytics/` (user config directory, not project files). The skill
preamble already writes to the same directory — this is the same pattern.
Skipping this command loses session duration and outcome data.

Run this bash:

```bash
_TEL_END=$(date +%s)
_TEL_DUR=$(( _TEL_END - _TEL_START ))
# Local analytics only (no remote telemetry)
echo '{"skill":"steez-audit","duration_s":"'"$_TEL_DUR"'","outcome":"OUTCOME","browse":"USED_BROWSE","session":"'"$_SESSION_ID"'","ts":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}' >> ~/.steez/analytics/skill-usage.jsonl 2>/dev/null || echo "[steez] WARNING: telemetry write failed" >&2
```

Replace `OUTCOME` with success/error/abort, and `USED_BROWSE` with true/false based
on whether `$B` was used. If you cannot determine the outcome, use "unknown".
<!-- END MANAGED PREAMBLE -->

## Phase 0 — Discovery (YOU do this directly, do NOT delegate)

Before spawning any agents, quickly investigate:

1. **Language & framework**: Check file extensions, config files (package.json, go.mod, Cargo.toml, pyproject.toml, requirements.txt, Gemfile, composer.json, pom.xml, build.gradle, Makefile, etc.)
2. **Size**: Count source files (exclude node_modules, vendor, .git, dist, build). Categorize: small (<50 files), medium (50-300), large (300-1000), massive (1000+)
3. **Architecture style**: Identify patterns — monolith, microservices, monorepo, library, CLI tool, web app, API server, full-stack, etc.
4. **Entry points**: Find main files, route definitions, API handlers, exported modules
5. **Dependency profile**: Scan lock files or dependency manifests for known-vulnerable or outdated patterns
6. **Existing quality tooling**: Check for linters, type checkers, formatters, CI configs (.github/workflows, .gitlab-ci.yml, Jenkinsfile)
7. **Test infrastructure**: Find test directories, test runner configs, coverage settings

Output a brief **Codebase Profile** summary before proceeding. Present it to the user.

## Phase 1 — Scope & Agent Planning

Based on discovery, ask TWO questions using AskUserQuestion:

**Question 1 — Depth:**
- question: "How deep should the audit go?"
- header: "Depth"
- multiSelect: false
- options:
  - **Quick** — Entry points, auth, and data-handling hot paths only (~5 min)
  - **Standard** — All source directories, skip test/config files (~15 min) (Recommended)
  - **Deep** — Exhaustive, every source file including tests and scripts (~30+ min)

**Question 2 — Scope:**
- question: "Which audit areas should I focus on?"
- header: "Audit scope"
- multiSelect: true
- options (adapt labels/descriptions based on what's relevant to the discovered stack):
  - **Security** — injection flaws, auth issues, secrets, dependency vulnerabilities
  - **Architecture** — coupling, dependency direction, modularity, pattern consistency
  - **Error Handling & Resilience** — unhandled errors, missing timeouts, resource leaks, race conditions
  - **Code Quality & Maintainability** — dead code, duplication, complexity, tech debt markers

If the user doesn't select any scope options, default to: Security + Error Handling + Code Quality.

Pass the chosen depth to every agent so they know how much ground to cover. Quick = only files identified as high-risk in Phase 0. Standard = all source directories. Deep = everything including tests and scripts.

Wait for the user's selections before proceeding.

## Phase 2 — Parallel Specialized Agents

Launch selected agents IN PARALLEL using the Task tool with subagent_type="general-purpose". Each agent receives:
- The codebase profile from Phase 0
- A stack-specific checklist tailored to the detected language/framework
- Instructions to output structured findings

### Agent Output Format

Each agent MUST produce output in this format:

```
## [Category] Audit Report

### Critical Findings
- **[CRITICAL | confirmed]** file_path:line — Description. Fix: ...

### High Findings
- **[HIGH | confirmed]** file_path:line — Description. Fix: ...

### Medium Findings
- **[MEDIUM | suspected]** file_path:line — Description. Fix: ...

### Low Findings
- **[LOW | suspected]** file_path:line — Description. Fix: ...

### Summary
- Total findings: N (X critical, Y high, Z medium, W low)
- Confirmed: N, Suspected: N
- Top concern: ...
```

**Confidence rules:**
- **confirmed** = the agent directly observed the vulnerable/problematic pattern in the code (e.g., grep matched a dangerous call with unsanitized input flowing in)
- **suspected** = the pattern looks risky but the agent couldn't fully trace the data flow or confirm exploitability

Severity is based on: impact (what's the worst case?) x likelihood (how easy is it to trigger?). Security findings involving user input should be scored higher than internal-only code paths.

### What Each Agent Should Look For

#### Security Agent
Search the OWASP Top 10 categories adapted to the detected stack:
- Hardcoded secrets, keys, tokens, or credentials committed to the repo
- Injection vulnerabilities: SQL, command, template, and DOM injection patterns
- Unsafe deserialization of untrusted input
- Dynamic code execution from string input
- Missing or overly permissive CORS, auth, and access control
- Sensitive data exposure in logs, error messages, or responses
- Vulnerable dependencies: require advisory ID (CVE/GHSA), affected version, and fixed version. Do NOT flag vague "outdated" without a specific known vulnerability
- Missing rate limiting on public endpoints

Use your knowledge of the specific language and framework detected to search for the idiomatic vulnerability patterns of that stack. Grep for known-dangerous function calls and patterns.

#### Architecture Agent
- Circular dependencies between modules/packages
- God files (>500 lines of logic, not config/generated)
- Dependency direction violations (inner layers importing outer layers)
- Inconsistent patterns (e.g., some handlers use middleware, others don't)
- Missing abstraction boundaries (direct DB calls from route handlers)
- Configuration scattered vs. centralized
- Shared mutable state

#### Error Handling Agent
- Swallowed errors (empty catch/except/rescue blocks)
- Missing timeouts on HTTP and database calls
- Resource leaks (unclosed connections, file handles, streams)
- Race conditions in concurrent code
- Unhandled async errors (promises, goroutines, tasks)
- Missing error boundaries at system edges

Use your knowledge of the detected language's idiomatic error handling patterns to find violations.

#### Code Quality Agent
- Dead code: unused exports, unreachable branches, commented-out code blocks
- Duplication: >10 lines repeated 3+ times
- Complexity: Functions >50 lines or deeply nested (>4 levels)
- Tech debt markers: TODO, FIXME, HACK, XXX, TEMP, WORKAROUND comments — list with context
- Test gaps: Critical paths (auth, payments, data mutations) without test coverage
- Naming inconsistencies within the same module
- Do NOT flag: style preferences, minor formatting, missing docstrings on internal code

## Phase 3 — Synthesis

After ALL agents complete, produce a unified report:

### Executive Summary
1. **Overall Health Score**: Weighted average across categories (security issues weigh 2x)
2. **Top 5 Critical Findings**: The most impactful issues across all categories, with file:line references
3. **Systemic Patterns**: Issues that appear repeatedly (these indicate process/knowledge gaps, not just bugs)
4. **Prioritized Action Plan**: What to fix first and why, grouped into:
   - **Fix immediately** (security critical, data loss risk)
   - **Fix this sprint** (high-severity, architectural drift)
   - **Plan for** (tech debt, quality improvements)
5. **What's Working Well**: Positive patterns and strengths worth preserving

Write the full report to `AUDIT-REPORT.md` in the project root.

## Important Guidelines

- Do NOT flag generated code, vendored dependencies, or build artifacts
- Do NOT flag style issues — only flag things that affect correctness, security, or maintainability
- Every finding MUST include a file path and line number
- Every finding MUST include a concrete fix suggestion (not just "fix this")
- If the codebase is massive (1000+ files), focus agents on the highest-risk surface area identified in Phase 0 (entry points, auth, data handling) rather than trying to cover everything
- For small codebases (<50 files), agents can be thorough — cover everything
- For medium codebases, prioritize but aim for good coverage
