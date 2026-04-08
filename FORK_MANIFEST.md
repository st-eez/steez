# Fork Manifest
Upstream: https://github.com/garrytan/gstack.git
Forked at: 2026-03-29
Upstream version: 0.13.0.0

## Scripts (from gstack bin/)
| File | Upstream source | Patches |
|------|----------------|---------|
| config | bin/gstack-config | Renamed, STATE_DIR → ~/.steez/ |
| slug | bin/gstack-slug | Renamed, added empty slug fallback |
| review-log | bin/gstack-review-log | Renamed, GSTACK_HOME → ~/.steez/, internal calls renamed |
| review-read | bin/gstack-review-read | Renamed, GSTACK_HOME → ~/.steez/, internal calls renamed |
| diff-scope | bin/gstack-diff-scope | Renamed only |

## Skills (from gstack skill dirs/)
| File | Upstream source | Patches |
|------|----------------|---------|
| steez-autoplan/SKILL.md | autoplan/SKILL.md | Steez porting recipe (see ARCHITECTURE.md) |
| steez-browse/SKILL.md | browse/SKILL.md | Rebuilt: merged gstack-browse + playwright-cli into single Bun binary |
| steez-codex/SKILL.md | codex/SKILL.md | Same pattern |
| steez-cso/SKILL.md | cso/SKILL.md | Same pattern |
| steez-design-consultation/SKILL.md | design-consultation/SKILL.md | Same pattern |
| steez-design-review/SKILL.md | design-review/SKILL.md | Same pattern |
| steez-investigate/SKILL.md | investigate/SKILL.md | Same pattern |
| steez-office-hours/SKILL.md | office-hours/SKILL.md | Voice identity, path refs, dead code stripped, Skill Self-Report |
| steez-plan-ceo-review/SKILL.md | plan-ceo-review/SKILL.md | Same pattern |
| steez-plan-design-review/SKILL.md | plan-design-review/SKILL.md | Same pattern |
| steez-plan-eng-review/SKILL.md | plan-eng-review/SKILL.md | Same pattern |
| steez-qa/SKILL.md | qa/SKILL.md | Same pattern, plus added `steez-` prefix to avoid /q autocomplete collision with /quit (diverges from gstack bare-name convention) |
| steez-qa-only/SKILL.md | qa-only/SKILL.md | Same pattern, plus added `steez-` prefix to avoid /q autocomplete collision with /quit (diverges from gstack bare-name convention) |

## Removed Skills (available for re-port from gstack)
| Skill | Upstream source | Removed | Reason |
|-------|----------------|---------|--------|
| benchmark | benchmark/SKILL.md | 2026-04-02 | Zero usage |
| canary | canary/SKILL.md | 2026-04-02 | No deploy pipeline |
| connect-chrome | connect-chrome/SKILL.md | 2026-04-02 | Superseded by browse |
| design-html | design-html/SKILL.md | 2026-04-02 | Zero usage |
| design-shotgun | design-shotgun/SKILL.md | 2026-04-02 | Zero usage |
| document-release | document-release/SKILL.md | 2026-04-02 | Zero usage |
| land-and-deploy | land-and-deploy/SKILL.md | 2026-04-02 | No deploy pipeline |
| retro | retro/SKILL.md | 2026-04-02 | Zero usage |
| review | review/SKILL.md | 2026-04-02 | Replaced by project-specific netsuite-pr-review |
| setup-browser-cookies | setup-browser-cookies/SKILL.md | 2026-04-02 | Zero usage |
| setup-deploy | setup-deploy/SKILL.md | 2026-04-02 | Dead without land-and-deploy |
| ship | ship/SKILL.md | 2026-04-02 | Replaced by project-specific weekly-release |

## Other
| File | Source | Notes |
|------|--------|-------|
| ETHOS.md | gstack/ETHOS.md | Unmodified copy |
