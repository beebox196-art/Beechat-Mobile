# ADR-002: Team-Driven Development

**Date:** 2026-05-15
**Status:** Accepted
**Context:** BeeChat v5 development proved that multi-agent review catches issues single-agent work misses. Kieran's adversarial reviews identified bugs, logic gaps, and architectural concerns before they compounded. Adam wants BeeChat Mobile to use the full team from the start — not just Bee building alone.

**Decision:** All implementation work is delegated to specialist agents. Bee orchestrates and validates. No code is written by Bee directly unless it's a trivial single-line fix.

### Team Roles

| Role | Agent | Responsibility |
|---|---|---|
| **Coordinator** | Bee | Orchestrates gates, validates deliverables, updates STATUS, manages git |
| **Builder** | Q | All code implementation — Swift, SPM, iOS, UI wiring |
| **Reviewer** | Kieran | Adversarial review of every gate deliverable before it passes |
| **Designer** | Mel | UI/UX design decisions, visual polish, SwiftUI layout guidance |
| **Researcher** | Gav | Prior art, library evaluation, technical evidence gathering |

### Gate Workflow

For each gate:
1. **Bee** defines success criteria and delegates to Q with full context
2. **Q** implements, self-validates against criteria, commits
3. **Kieran** reviews Q's output — passes or fails with specific issues
4. **Q** fixes any issues Kieran raises
5. **Bee** validates the complete gate against exit criteria
6. **Adam** approves gate passage

### Review Rules

- **Every gate deliverable** gets a Kieran review before it's marked complete
- **Architecture decisions** (ADR-level) get Mel input on UX implications
- **Research gates** (like Gate 0) use Gav for evidence gathering
- **No gate passes** without explicit reviewer sign-off
- **Review failures** are logged in the gate report with specific issues

### Exception

Trivial fixes (typos, config, single-line changes) can be done directly by Bee without team delegation. Everything else goes through the team.

**Consequences:**
- Slower per-gate cycle, but higher quality output
- Issues caught at review stage, not after compound
- Clear accountability: Q owns code, Kieran owns quality, Bee owns coordination
- Adam gets honest assessment from independent reviewer (Kieran), not just builder self-assessment
- Team members can work in parallel on separable subtasks (capped at 2-3 concurrent)