# DOC-REORG-MOBILE: BeeChat-Mobile Documentation Reorganisation Plan

**Created:** 2026-06-19
**Author:** Bee (coordinator)
**Status:** PENDING — awaiting Adam go-ahead
**Priority:** Medium — admin cleanup, no code impact

## Problem

BeeChat-Mobile has 94 markdown docs with no consistent organisation. The bulk (78) are in `Docs/Architecture/`, mostly iterative Gate 2B5 review versions. There are also:
- 7 review files in `Docs/Architecture/REVIEWS/` (a subfolder that shouldn't exist inside Architecture)
- 3 BugFix docs with no clear review status
- 5 loose `Docs/Reviews/` files
- 3 ADR docs (good structure, keep as-is)
- Root has `DEBUG.md` (placeholder, never used) and `VISION.md`

No naming convention. No Active/Archive split. No way to see what's current.

## Current State

```
Docs/
├── Architecture/          78 files (60+ are Gate 2B5 iterative reviews)
│   └── REVIEWS/           7 files (should be in Reviews/Cycles/)
├── BugFix/                3 files
├── Decisions/             3 files (ADRs — good structure)
├── History/               1 file (README)
├── Reviews/               5 files (loose, no cycles)
├── Vision/                2 files
├── GATE-2B-ROLLBACK.md   (loose in Docs/)
└── PHASE0-CHECKLIST.md   (loose in Docs/)

Root:
├── README.md              ✅ keep
├── STATUS.md              ✅ keep
├── VISION.md              → Docs/Vision/
├── DEBUG.md               (placeholder — delete or move)
```

## Proposed Target Structure

```
BeeChat-Mobile/
├── README.md                          # KEEP
├── STATUS.md                          # KEEP
│
├── Docs/
│   ├── Architecture/                  # KEEP — but only CURRENT architecture docs
│   │   ├── README.md                  # New: index of current architecture docs
│   │   ├── COMPONENT-1-PERSISTENCE-SPEC.md
│   │   ├── COMPONENT-2-GATEWAY-SPEC.md
│   │   ├── COMPONENT-3-SYNC-BRIDGE-SPEC.md
│   │   ├── CROSS-STREAM-SAFEGUARDS.md
│   │   ├── GATE-2B-DEVICE-FAMILY-FIX.md
│   │   ├── GATE-2B5-TOPIC-ARCHITECTURE-v2.md    # latest version only
│   │   ├── GATE-2B5-PHASE2-SPEC-v3.1.md         # latest version only
│   │   ├── GATE-2B5-PHASE2-UI-LAYER-v3.md       # latest version only
│   │   ├── GATE-2B5-PHASE2-IMPLEMENTATION-BRIEF.md
│   │   ├── GATE-2B5-PHASE2-BUILD-SUMMARY.md
│   │   ├── GATE-2F-MAC-APP-WIRING.md
│   │   ├── GATE-2F-PERSISTENT-TOPIC-LINKING.md
│   │   ├── GATE-2E-TAILSCALE-REAL-DEVICE.md
│   │   ├── GATE2-SPEC.md
│   │   ├── GATE0-AUDIT-REPORT.md
│   │   ├── GATE0-FIXES.md
│   │   ├── GATE1-SPIKE-REPORT.md
│   │   └── SCROLL-POSITION-FIX-V2-SPEC.md
│   │
│   ├── Architecture/Archive/          # All superseded versions
│   │   └── README.md                  # Index of archived versions
│   │   └── (all GATE-2B5 v1/v2/v3 drafts, superseded reviews, etc.)
│   │
│   ├── BugFix/                        # KEEP — but add INDEX.md
│   │   └── INDEX.md
│   │
│   ├── Decisions/                     # KEEP AS-IS (ADRs are well-structured)
│   │
│   ├── Reviews/                        # Reorganise into cycles
│   │   ├── INDEX.md
│   │   ├── Cycles/
│   │   │   ├── gate-2b5-phase1/        # All Phase 1 review iterations
│   │   │   ├── gate-2b5-phase2/        # All Phase 2 review iterations
│   │   │   ├── gate-2f/               # Gate 2F spec reviews
│   │   │   ├── hotfix-2/              # Hotfix 2 reviews
│   │   │   └── p2-bugfix/             # P2 bugfix reviews
│   │   └── Final/
│   │       └── (Gav + Q final reviews)
│   │
│   ├── Specs/                          # NEW: active specs
│   │   └── Active/
│   │       └── (future feature specs go here)
│   │
│   ├── Vision/                          # KEEP (add VISION.md from root)
│   │   ├── README.md
│   │   ├── PHASE0-RESEARCH-REPORT.md
│   │   └── VISION.md                  # Moved from root
│   │
│   └── Status/                          # NEW: status documents
│       └── PHASE0-CHECKLIST.md         # Moved from Docs/
│
└── (DEBUG.md deleted if placeholder, or moved to Docs/Status/)
```

## Detailed File Mapping

### ROOT → Move
| File | Target | Notes |
|------|--------|-------|
| `VISION.md` | `Docs/Vision/VISION.md` | Product vision, belongs with research |
| `DEBUG.md` | Delete (it's an empty placeholder) | No real content, template only |

### Docs/ LOOSE → Move
| File | Target | Notes |
|------|--------|-------|
| `Docs/GATE-2B-ROLLBACK.md` | `Docs/Architecture/` | Architecture decision |
| `Docs/PHASE0-CHECKLIST.md` | `Docs/Status/` | Checklist = status document |

### Docs/Architecture/ — KEEP (Current)
These are the latest/canonical versions that stay in `Docs/Architecture/`:

| File | Reason |
|------|--------|
| `COMPONENT-1-PERSISTENCE-SPEC.md` | Current component spec |
| `COMPONENT-2-GATEWAY-SPEC.md` | Current component spec |
| `COMPONENT-3-SYNC-BRIDGE-SPEC.md` | Current component spec |
| `CROSS-STREAM-SAFEGUARDS.md` | Current architecture doc |
| `GATE-2B-DEVICE-FAMILY-FIX.md` | Current fix doc |
| `GATE-2B5-TOPIC-ARCHITECTURE-v2.md` | Latest version (v2 supersedes v1) |
| `GATE-2B5-PHASE2-SPEC-v3.1.md` | Latest version |
| `GATE-2B5-PHASE2-UI-LAYER-v3.md` | Latest version (v3, not v1 or v2 or v3-DELTA) |
| `GATE-2B5-PHASE2-UI-LAYER-v3-DELTA.md` | Keep — delta to v3 |
| `GATE-2B5-PHASE2-IMPLEMENTATION-BRIEF.md` | Implementation brief |
| `GATE-2B5-PHASE2-BUILD-SUMMARY.md` | Build record |
| `GATE-2F-MAC-APP-WIRING.md` | Current architecture |
| `GATE-2F-PERSISTENT-TOPIC-LINKING.md` | Current architecture |
| `GATE-2E-TAILSCALE-REAL-DEVICE.md` | Current setup doc |
| `GATE2-SPEC.md` | Master spec |
| `GATE0-AUDIT-REPORT.md` | Audit record |
| `GATE0-FIXES.md` | Fixes record |
| `GATE1-SPIKE-REPORT.md` | Spike record |
| `SCROLL-POSITION-FIX-V2-SPEC.md` | Current fix spec |
| `README.md` | Architecture index |
| `RECOVERY-Q-findings.md` | Recovery findings |
| `HOTFIX-2-USER-MESSAGES-NOT-APPEARING.md` | Hotfix description |
| `HOTFIX-2-KIERAN-REVIEW.md` | Keep with hotfix (or move to reviews) |
| `HOTFIX-2-REVIEW-BRIEF.md` | Keep with hotfix |
| `GATE-2B5-PHASE1-V4-KIERAN-CODE-REVIEW.md` | Final phase 1 code review — canonical |
| `GATE-2B5-PHASE1-V4-BUILD-REPORT.md` | Final phase 1 build report — canonical |
| `GATE-2B5-PHASE1-V4-KIERAN-CONFIRM.md` | Final phase 1 confirmation |
| `GATE-2B5-PHASE1-V4-KIERAN-REVIEW.md` | Final phase 1 review |
| `GATE-2B5-PHASE1-V4-MEL-REVIEW.md` | Final phase 1 review |

### Docs/Architecture/ — ARCHIVE (Superseded Iterations)
All v1/v2/v3 drafts that have been superseded by later versions:

| Pattern | Files | Move to |
|---------|-------|---------|
| Gate 2B5 Phase 1 data layer v1-v3 | `PHASE1-DATA-LAYER.md`, `PHASE1-DATA-LAYER-v2.md`, `PHASE1-DATA-LAYER-v3.2.md` | `Docs/Architecture/Archive/` |
| Gate 2B5 Phase 1 reviews (non-final) | `PHASE1-KIERAN-REVIEW.md`, `PHASE1-KIERAN-V3-REVIEW.md`, `PHASE1-KIERAN-REVIEW-V31.md`, `PHASE1-MEL-REVIEW.md`, `PHASE1-MEL-V3-REVIEW.md`, `PHASE1-MEL-REVIEW-V31.md`, `PHASE1-Q-REVIEW.md`, `PHASE1-Q-REVIEW-V2.md`, `PHASE1-Q-REVIEW-V31.md`, `PHASE1-V32-KIERAN-REVIEW.md`, `PHASE1-V32-MEL-REVIEW.md`, `PHASE1-V32-Q-REVIEW.md`, `PHASE1-CONSOLIDATED-REVIEW.md`, `PHASE1-CONSOLIDATED-V2.md` | `Docs/Architecture/Archive/` |
| Gate 2B5 Phase 2 reviews (non-final) | `PHASE2-KIERAN-REVIEW.md`, `PHASE2-KIERAN-REVIEW-v2.md`, `PHASE2-MEL-REVIEW.md`, `PHASE2-MEL-REVIEW-v2.md`, `PHASE2-Q-REVIEW.md`, `PHASE2-Q-REVIEW-v2.md`, `PHASE2-CONSOLIDATED-REVIEW.md`, `PHASE2-CONSOLIDATED-REVIEW-v2.md`, `PHASE2-KIERAN-CODE-REVIEW.md` | `Docs/Architecture/Archive/` |
| Gate 2B5 earlier versions | `KIERAN-REVIEW-V2.md`, `KIERAN-REVIEW-PASS2.md`, `MEL-REVIEW-V2.md`, `MEL-REVIEW-PASS2.md`, `Q-REVIEW.md`, `TOPIC-ARCHITECTURE.md` (v1) | `Docs/Architecture/Archive/` |
| Gate 2B5 Phase 2 spec/UI earlier versions | `PHASE2-SPEC-v3.md`, `PHASE2-UI-LAYER-v1.md`, `PHASE2-UI-LAYER-v2.md`, `PHASE2-HOTFIX1.md`, `PHASE2-HOTFIX1-KIERAN-REVIEW.md` | `Docs/Architecture/Archive/` |
| Gav/Mel consolidated reviews | `PHASE2-MEL-REVIEW-v3.md`, `PHASE2-Q-REVIEW-v3.md` (these are in REVIEWS/ too — dedup) | `Docs/Architecture/Archive/` |

### Docs/Architecture/REVIEWS/ — Move
All 7 files → `Docs/Reviews/Cycles/gate-2b5-phase2/` (they're Phase 2 review confirmations)

### Docs/Reviews/ — Organise into Cycles
| File | Target Cycle |
|------|-------------|
| `KIERAN-PHASE2-HOTFIX1-REVIEW.md` | `Cycles/gate-2b5-phase2/` |
| `kieran-gate2f-spec-review.md` | `Cycles/gate-2f/` |
| `kieran-gate2f-v2-review.md` | `Cycles/gate-2f/` |
| `q-gate2f-spec-review.md` | `Cycles/gate-2f/` |
| `q-gate2f-v2-review.md` | `Cycles/gate-2f/` |

### Docs/Reviews/Final/ — Create
| File | Target |
|------|--------|
| `REVIEW-Q-FINAL.md` (from Architecture/) | `Docs/Reviews/Final/` |
| `REVIEW-GAV-FINAL.md` (from Architecture/) | `Docs/Reviews/Final/` |

### Docs/BugFix/ — Keep, add INDEX.md
Create `INDEX.md` listing the 3 bugfix docs with status.

## Naming Convention (Both Repos)

Going forward, new docs should follow these conventions:

| Type | Pattern | Example |
|------|---------|---------|
| Feature spec | `FR-NNN-kebab-case.md` | `FR-002-tap-to-reconnect.md` |
| Fix spec | `FIX-NNN-kebab-case.md` | `FIX-001-dedup-guard.md` |
| Diagnostic | `DIAG-NNN-kebab-case.md` | `DIAG-001-delete-topic.md` |
| Gate spec | `GATE-NN-kebab-case.md` | `GATE-2F-mac-app-wiring.md` |
| Review (by person) | `kieran-review-topic.md` | `kieran-review-fr-002.md` |
| Review (final) | `review-final-topic.md` | `review-final-session-reset.md` |
| Consensus | `consensus-topic.md` | `consensus-session-reset.md` |
| ADR | `ADR-NNN-kebab-case.md` | `ADR-002-team-driven-development.md` |

**Active vs Archive:** When a spec is implemented and verified → move to `Docs/Specs/Archive/` with a one-line superseded-by note at the top.

**No version numbers in filenames.** Latest version gets the canonical name. Old versions go to Archive with version suffix: `FR-002-v1.md`, `FR-002-v2-draft.md`.

## Execution Phases

### Phase 1: Verify & Create Structure (Bee)
- Verify which Architecture docs are latest versions
- Create target folders: `Archive/`, `Reviews/Cycles/`, `Reviews/Final/`, `Specs/Active/`, `Status/`
- Create template INDEX.md files

### Phase 2: Move Files (Bee) — MUST USE `git mv`
- Execute all moves per mapping
- Dedup the REVIEWS/ subfolder files (same content appears in both Architecture/REVIEWS/ and Docs/Reviews/)

### Phase 3: Create Indexes (Bee)
- `Docs/Architecture/README.md` — list of current architecture docs
- `Docs/Architecture/Archive/README.md` — index of archived versions
- `Docs/Reviews/INDEX.md` — cycles and authors
- `Docs/BugFix/INDEX.md` — status of each bugfix
- `Docs/Specs/Active/INDEX.md` — active specs with one-line summaries

### Phase 4: Verify (Kieran)
- Spot-check all moves
- Verify no broken cross-references
- Sign off

### Phase 5: Commit (Bee)
- Single commit: `chore: reorganise BeeChat-Mobile documentation`
- No code changes

## Principles

Same as DOC-REORG-001:
1. No content deleted — everything moves, nothing removed
2. Kieran decides Active vs Archive for architecture docs
3. Use `git mv` to preserve history
4. Latest version gets canonical filename; old versions go to Archive with version suffix
5. No version numbers in active filenames