# Phase 0: Prior Art Survey Checklist

**Project:** [Project Name]  
**Feature/Phase:** [What we're researching]  
**Researcher:** [Name]  
**Date Started:** YYYY-MM-DD  
**Timebox:** [X hours/days]  
**Build Estimate:** [X days/weeks]

---

## Research Scope

**What are we researching?**
- [ ] Clear problem statement written
- [ ] Success criteria defined (what does "good research" look like?)
- [ ] Build scope estimated (to determine research timebox)

**Timebox Applied:**
- [ ] Small feature (<1 day build) → 1-2 hours research
- [ ] Medium feature (1-3 days build) → 4-6 hours research
- [ ] Large phase (>3 days build) → 1-2 days research

---

## Sources Searched

### Code Repositories
- [ ] GitHub (direct competitors, adjacent tools, ecosystem projects)
- [ ] GitLab / Bitbucket (if relevant)
- [ ] Package managers (npm, Swift Package Manager, PyPI, etc.)
- [ ] Other: _______________

### Technical Resources
- [ ] Stack Overflow (common pitfalls, accepted solutions)
- [ ] Official documentation (platforms we're integrating with)
- [ ] Technical blogs (Medium, Dev.to, personal blogs)
- [ ] Academic papers (if novel algorithms involved)
- [ ] Other: _______________

### UX/Product Research (if applicable)
- [ ] Existing apps in same category (iOS, Android, Web, Desktop)
- [ ] Design pattern libraries
- [ ] Competitor product teardowns
- [ ] User reviews (what do people love/hate?)
- [ ] Other: _______________

---

## Findings Log

### Top Implementation #1
**Name:** _______________  
**Link:** _______________  
**Relevant Files:** _______________  
**Approach:** _______________  
**Licence:** _______________  
**Pros:** _______________  
**Cons:** _______________  
**Adaptation Effort:** _______________

### Top Implementation #2
**Name:** _______________  
**Link:** _______________  
**Relevant Files:** _______________  
**Approach:** _______________  
**Licence:** _______________  
**Pros:** _______________  
**Cons:** _______________  
**Adaptation Effort:** _______________

### Top Implementation #3
**Name:** _______________  
**Link:** _______________  
**Relevant Files:** _______________  
**Approach:** _______________  
**Licence:** _______________  
**Pros:** _______________  
**Cons:** _______________  
**Adaptation Effort:** _______________

---

## Recommendation

**Adapt:** [Which implementation]  
**Why:** [Rationale - why this over others]  
**Adaptation Effort:** [X hours/days]  
**Licence OK:** [Yes/No - if no, escalate to Adam]  
**Risks/Gotchas:** [Known issues, edge cases]

---

## Approval Gate

**Researcher Sign-off:**
- [ ] I've searched the sources above
- [ ] I've documented findings honestly (including dead ends)
- [ ] I believe this recommendation is the best starting point
- [ ] I've checked licence compatibility

**Bee Review (Coordinator):**
- [ ] Research scope was appropriate
- [ ] Sources searched are sufficient
- [ ] Recommendation is sensible
- [ ] Approved to proceed to build

**Adam Approval (if build >1 day):**
- [ ] Research report reviewed
- [ ] Recommendation approved
- [ ] Build work authorised to start

**Date Approved:** YYYY-MM-DD

---

## Post-Research Actions

- [ ] Add validated repos to `knowledge/Operations/SHOULDERS-INDEX.md`
- [ ] Create attribution entry template in `knowledge/Operations/ATTRIBUTIONS.md`
- [ ] Link research report in project STATUS.md
- [ ] Brief team on findings (if multi-person project)

---

## Emergency Research Trigger

**If reinvention exceeds 2 days:**
1. STOP build work
2. Create emergency research task
3. Document what we tried and why it failed
4. Pivot to adaptation based on findings

**Emergency Research Log:**
- Triggered: [Date]
- Reason: [Why we hit the timebox]
- Findings: [What we found]
- Pivot Plan: [How we adapt]

---

*Template from RESEARCH-FIRST-FRAMEWORK.md — Use for every feature/phase*
