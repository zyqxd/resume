# Company System Design Prep — Repeatable Workflow

This template generates a complete staff-level system design knowledge bank for a target company. The output mirrors the existing Shopify (`exercises/shopify/`) and Coinbase (`exercises/coinbase/`) structure: 8 numbered exercise folders (`01-...` through `08-...`), each with `PROMPT.md` + `WALKTHROUGH.md`, plus a `patterns.md` and `crash-course.md` at the company-folder root.

**Estimated total runtime:** 60-90 minutes wall clock, ~12-15 parallel agent invocations.

**How to use:**
1. Replace every `{{COMPANY}}` placeholder below with the target company name (lowercase, single word — `stripe`, `airbnb`, `anthropic`).
2. Paste the entire prompt below (everything between the `---` markers) into a fresh Claude Code conversation.
3. Approve agent dispatches as they're surfaced.

The instructions are written for the LLM, not for you. Treat the body as a self-contained brief.

---

## PROMPT TO PASTE (with `{{COMPANY}}` substituted)

You are running a multi-phase workflow to build a staff-level system design knowledge bank for **{{COMPANY}}** interviews. The output mirrors the existing Shopify and Coinbase exercise structure already in this repo.

**Working directory:** `/Users/david/Workspace/resume/knowledge/system-design/exercises/`

**Folder structure (this is what you're building):**
```
exercises/
├── general/                              # company-agnostic problems (don't touch)
├── shopify/                              # existing exemplar
│   ├── 01-checkout-system/{PROMPT,WALKTHROUGH}.md
│   ├── ...08-payment-processing/
│   ├── crash-course.md
│   ├── patterns.md
│   └── (other shopify-specific support docs)
├── coinbase/                             # existing exemplar
│   ├── 01-trading-engine/{PROMPT,WALKTHROUGH}.md
│   ├── ...08-kyc-onboarding/
│   ├── crash-course.md
│   └── patterns.md
└── {{COMPANY}}/                          # what you'll create
    ├── 01-{slug}/{PROMPT,WALKTHROUGH}.md
    ├── ...08-{slug}/
    ├── crash-course.md
    └── patterns.md
```

**Existing exemplars to study first (read these before doing anything else):**
- `shopify/01-checkout-system/PROMPT.md` — PROMPT.md template (~45 lines). Sections: Prompt, Functional Requirements, Non-Functional Requirements, Out of Scope, Constraints, Key Topics Tested with [[wikilinks]] to system-design subdirs (paths use `[[../../../<topic>/index|...]]`).
- `shopify/03-inventory-management/WALKTHROUGH.md` — WALKTHROUGH.md template (~520 lines). Sections: Step 1 Clarify, Step 2 High-Level Architecture with ASCII diagram, Step 3 Data Model with SQL, Steps 4-N each major subsystem deep-dive, then Failure Modes, Tradeoffs Summary, Common Mistakes, Follow-up Questions.
- `shopify/patterns.md` — cross-cutting patterns/gotchas/vocabulary template.
- `shopify/crash-course.md` — comprehensive study guide template (~700 lines). Read at least the first 200 lines for tone calibration.
- `coinbase/patterns.md` and `coinbase/crash-course.md` — second exemplar, useful for seeing how the template adapts to a different industry.
- `coinbase/01-trading-engine/WALKTHROUGH.md` — exemplar walkthrough that hits the staff-level depth target (780 lines).

The {{COMPANY}} run should produce 18 files inside `exercises/{{COMPANY}}/`.

### Phase 0: Setup (do this immediately)

1. Read the existing exemplar files listed above to absorb the structure and depth target.
2. Use TaskCreate to set up tasks for each phase below.
3. Create the company folder: `mkdir -p knowledge/system-design/exercises/{{COMPANY}}`. Exercise subdirs are created in Phase 3 once you've picked the 8 exercises.

### Phase 1: Parallel Research (4 agents concurrent)

Dispatch **4 parallel research agents** in a single message. Filter aggressively by recency: today's date is in the system context — anything older than 2 years is off-limits unless multiply corroborated and explicitly noted as foundational.

**Agent A — Glassdoor / Blind / candidate write-ups:**
> Research recent {{COMPANY}} system design interview questions from the last 2 years. Sources: Glassdoor for "{{COMPANY}} Staff Software Engineer", "{{COMPANY}} Senior Software Engineer", Blind/Teamblind threads, Reddit r/cscareerquestions and r/leetcode, Levels.fyi, Jointaro, Prepfully, interviewing.io, Hello Interview community posts. For each question found, capture: the prompt summary, approximate date, source URL, level (E5/E6/Staff/etc) if mentioned, follow-up scope hints. Skip coding questions and behavioral. Output a structured markdown report grouped by question, with a frequency table at the end. Aim for 30+ minutes of search effort and 6-15 distinct questions.

**Agent B — Engineering blogs / Medium / company tech writing:**
> Find blog posts, Medium articles, Substack posts, and personal interview write-ups from candidates who interviewed at {{COMPANY}} recently (last 2 years). ALSO scan {{COMPANY}}'s own engineering blog — what they've publicly built is what they interview on. Capture each system they've described in detail (with date and URL). End with a "high-confidence interview questions" list inferred from what they've publicly written about. Aim for 20+ sources scanned. Group output by topic area relevant to {{COMPANY}}.

**Agent C — YouTube / podcasts / conference talks:**
> Find YouTube videos, podcasts, conference talks (QCon, InfoQ, SREcon, AWS re:Invent, GopherCon, etc.) from the last 2 years covering {{COMPANY}}-style system design questions OR talks given by {{COMPANY}} engineers describing their production systems. Channels to check: Hello Interview, Exponent, ByteByteGo, Jordan Has No Life, Tech Dummies, NeetCode. Output sections: (1) Mock interviews on relevant problems, (2) {{COMPANY}} engineer talks, (3) Industry context. End with a "10-hour watchlist": 5 videos in priority order with what each teaches.

**Agent D — Interview process / loop meta:**
> Research {{COMPANY}}'s interview loop structure for Staff/Senior SWE roles (last 2 years): how many rounds, how many system design rounds, bar-raiser equivalent, virtual vs onsite. Also: their cultural tenets / engineering principles that show up in technical rounds, what signals they look for at staff level vs senior, common rejection patterns from candidate write-ups, and cross-product technical tenets that show up across products. Sources: company careers page, engineering blog, Glassdoor process descriptions, LinkedIn posts by recruiters. Output 6 sections: loop structure, cultural tenets, staff-vs-senior signals, common rejection patterns, cross-product technical tenets, "what this means for system design prep" with 5-10 actionable takeaways.

Wait for all 4 to complete before proceeding. They run in foreground because their output drives the next phase.

### Phase 2: Synthesize the Exercise List

Combine the 4 research outputs. Pick **{{NUM_EXERCISES}} (default 8)** exercises that:
- Span the company's problem space (don't pick 8 variants of the same question)
- Are corroborated by multiple recent sources (prefer questions with 3+ source citations from 2024+)
- Map to publicly-known production systems the company has written about (highest signal — they interview on what they've built)
- Cover the company's "signature" problem (e.g., Shopify=BFCM/multi-tenancy, Coinbase=custody/ledger). The first one or two exercises should hit the signature.

Show the proposed list to the user and get a quick OK before dispatching solver agents. Skip approval only if the list is obvious from research.

### Phase 3: Parallel Solver Wave (8 Opus agents, dispatched in two batches of 4)

Create the 8 exercise directories first:
```
mkdir -p knowledge/system-design/exercises/{{COMPANY}}/01-{slug1} \
         knowledge/system-design/exercises/{{COMPANY}}/02-{slug2} \
         ... knowledge/system-design/exercises/{{COMPANY}}/08-{slug8}
```

Slugs are kebab-case short names. The company prefix is implicit in the parent folder — don't repeat it (i.e., `01-trading-engine`, not `01-coinbase-trading-engine`).

Then dispatch **4 background Opus agents in one message, then 4 more in a second message** (8 in parallel total). Each agent writes `PROMPT.md` + `WALKTHROUGH.md` for one exercise.

Use `subagent_type: "general-purpose"` with `model: "opus"` and `run_in_background: true`. The model parameter forces the higher-tier model for thinking; background mode lets you continue while they work.

**Solver agent prompt template (customize per exercise):**

> You are writing a staff-level system design walkthrough for {{COMPANY}} interview prep. Mirror the existing Shopify/Coinbase exercise format exactly.
>
> **The exercise:** {ONE-SENTENCE PROBLEM STATEMENT WITH KEY CONSTRAINTS}.
>
> **Write two files:**
> 1. `/Users/david/Workspace/resume/knowledge/system-design/exercises/{{COMPANY}}/{NN}-{slug}/PROMPT.md`
> 2. `/Users/david/Workspace/resume/knowledge/system-design/exercises/{{COMPANY}}/{NN}-{slug}/WALKTHROUGH.md`
>
> **Reference these existing files for tone and structure:**
> - PROMPT template: `/Users/david/Workspace/resume/knowledge/system-design/exercises/shopify/01-checkout-system/PROMPT.md` (~45 lines). Note: the [[wikilink]] paths in the Key Topics section use `[[../../../<topic>/index|...]]` (three levels up — exercise dirs are now nested under company folders).
> - WALKTHROUGH template: `/Users/david/Workspace/resume/knowledge/system-design/exercises/shopify/03-inventory-management/WALKTHROUGH.md` (~520 lines, very detailed). READ THIS FULLY before writing — match its depth.
> - Coinbase walkthrough exemplar (for staff-level depth + signature framing): `/Users/david/Workspace/resume/knowledge/system-design/exercises/coinbase/01-trading-engine/WALKTHROUGH.md` (780 lines).
> - Crash course tone: `/Users/david/Workspace/resume/knowledge/system-design/exercises/shopify/crash-course.md` first 200 lines.
>
> **{{COMPANY}}-specific context (use this to ground the answer in their real architecture):**
> {3-8 BULLETS OF SPECIFIC TECH/PATTERNS/PRODUCTION-NUMBERS PULLED FROM RESEARCH PHASE — these are the highest-leverage facts the agent will use to make the answer feel insider-grade. Include real numbers, internal tool names, published architecture choices, regulatory/scale constraints.}
>
> **Staff-level signals to demonstrate:**
> {5-8 BULLETS OF WHAT THE ANSWER MUST DEMONSTRATE — leading framings, explicit tradeoffs, failure modes, real numbers, etc.}
>
> **Required walkthrough sections (mirror Shopify/Coinbase, deep-dive each):**
> {NUMBERED LIST OF 14-17 SECTIONS — start with Clarify Requirements, end with Tradeoffs Summary, Common Mistakes, Follow-up Questions. Tailor middle sections to the specific problem.}
>
> **Length target:** WALKTHROUGH 600-750 lines. PROMPT ~50 lines.
>
> **Style:**
> - No emojis.
> - Use {{COMPANY}} vocabulary once each (list the proper-noun internal/public names) then explain the underlying industry pattern.
> - Tables for tradeoffs and matrix decisions. ASCII diagrams. SQL or pseudocode where it earns its place.
> - Staff-level voice: confident, cite real numbers, name the alternatives you rejected.
>
> Begin.

**Critical:** the per-exercise context bullets are what differentiate a great walkthrough from a generic one. Spend extra effort here pulling 5+ specific facts from research per exercise — production architecture details, real published numbers, internal tool names, regulatory constraints, scale targets.

### Phase 4: Wait, Spot-Check, Verify

As background agent completion notifications arrive, acknowledge each briefly. After all 8 complete:
1. Run `wc -l` on all 16 files to verify they hit the size targets (PROMPT ~50, WALKTHROUGH 600-800).
2. Read the first 60-80 lines of 2 walkthroughs to verify quality (look for: clear two-path or signature framing in Step 1, ASCII diagram in Step 2, real production numbers, named alternatives).
3. If a walkthrough is sub-500 lines or feels generic, send the agent back via SendMessage with specific feedback to expand.

### Phase 5: Cross-Cutting Patterns Document

Write `knowledge/system-design/exercises/{{COMPANY}}/patterns.md` mirroring the structure of `shopify/patterns.md` / `coinbase/patterns.md`:

1. Opening framing (1 paragraph) — what is the {{COMPANY}} mental model that all patterns flow from?
2. **Recurring Architecture Patterns** (10-15 numbered patterns). For each: which exercises it appears in, "How to describe this problem" framing line, why it matters, interview signal.
3. **Top Gotchas Across All Exercises** (10-15 numbered). Each pulls a recurring failure mode candidates make.
4. **{{COMPANY}}-Specific Vocabulary** (grouped tables). Internal terms / proper nouns → industry pattern they map to. Cover: tech infrastructure, data, ML, compliance/regulatory, internal/cultural.
5. **How {{COMPANY}} Patterns Differ from Shopify/Coinbase** (comparison table — useful contrast since the user has already done those preps).
6. **Related Exercises** (wikilinks to all 8).

You can write this directly from your accumulated research context + the patterns embedded in the walkthrough designs you dispatched. You don't need to re-read all 8 walkthroughs in full; sample the Tradeoffs Summary and Common Mistakes sections of 2-3 if you need confirmation.

Target length: 350-450 lines.

### Phase 6: Crash Course Document

Write `knowledge/system-design/exercises/{{COMPANY}}/crash-course.md` mirroring `shopify/crash-course.md` / `coinbase/crash-course.md`. This is the master study guide.

Required sections:
1. Opening — "How {{COMPANY}} Thinks About Architecture" (3 design constraints all decisions flow from)
2. The {{COMPANY}} Interview Loop (loop structure, bar-raiser equivalent, top rejection cause)
3. Cultural Tenets That Show Up in Design Rounds (table mapping tenets → what they look like in interview)
4. The Technology Stack (databases, queues/streaming, caching/edge, with capacity reference numbers as a table)
5. Architecture Patterns (the 10-15 patterns from the patterns doc, expanded with "How to describe this problem" framing)
6. Patterns for Specific Problem Domains (one section per major problem area: trading, custody, ledger, etc. — whatever maps to the 8 exercises)
7. Common Mistakes That Fail Candidates (numbered list)
8. {{COMPANY}}-Specific Vocabulary (compact tables grouped by domain)
9. The 60-Second Mental Model (10 filters to run every design decision through)
10. Related Resources (wikilinks to all 8 exercises + patterns doc + relevant talks/blog posts from research)

Target length: 600-800 lines. This is dense reference material — every paragraph earns its place.

### Phase 7: Save Memory and Wrap Up

1. Write a project memory file at `/Users/david/.claude/projects/-Users-david-Workspace-resume/memory/project_{{COMPANY}}_interview.md`:
   ```markdown
   ---
   name: {{COMPANY}} Interview Prep
   description: {{COMPANY}} system design knowledge bank built {YYYY-MM-DD} — 8 exercises + patterns + crash course
   type: project
   ---
   
   {{COMPANY}} prep is fully built out under `knowledge/system-design/exercises/{{COMPANY}}/`.
   
   **8 exercises (01-08)** with PROMPT.md + WALKTHROUGH.md each:
   - {list with one-line summary each}
   
   **Cross-cutting:**
   - {{COMPANY}}/patterns.md
   - {{COMPANY}}/crash-course.md
   
   **Why:** {one sentence on the job context — why {{COMPANY}}, what role}.
   
   **How to apply:** {2-3 sentences on when this prep is relevant in future conversations}
   
   **Key {{COMPANY}}-specific moves to emphasize:**
   - {3-5 bullets distilling the highest-signal architectural moves for {{COMPANY}}}
   ```
2. Append a one-line entry to `/Users/david/.claude/projects/-Users-david-Workspace-resume/memory/MEMORY.md` under the project section.
3. Update `knowledge/system-design/index.md` to add a new "{{COMPANY}} System Design Exercises" section linking to all 8 exercises + the crash course + patterns doc. Mirror the existing Shopify/Coinbase sections.
4. Print a final summary to the user: file count, line count totals, the 8 exercise titles, the single biggest "mental shift" insight (e.g., for Coinbase it was "fail-closed for money, fail-open for browse — inverse of Shopify").

---

## Lessons learned from the Coinbase run (2026-04-25) — apply on future runs

These optimizations make the workflow ~30% faster:

1. **Use the company's open Staff job listings as a research signal.** They tell you which teams interview on what (e.g., Coinbase has an open Staff Backend role on FinHub-Ledger — confirms ledger is interviewed on at staff level).

2. **The company's own engineering blog is the highest-signal source.** What they've publicly built is what they interview on. Spend disproportionate research effort there. Pull specific numbers, internal tool names, scale targets — these become the per-exercise context bullets that make walkthroughs feel insider-grade.

3. **Pick exercises that span the problem space, not 8 variants.** For Coinbase: trading + custody + ledger + chain ingestion + market data + fraud + deposit/withdrawal + KYC covers different muscles. Don't pick 8 variants of "design a trading engine."

4. **The first sentence of each walkthrough must establish the signature framing.** Two-path split for trading. Double-entry for ledger. Multi-tier custody for wallet. Force the agent to write this in Step 1 — it's the highest-leverage staff-level move.

5. **Write per-exercise context bullets aggressively.** For each solver agent, give 5-8 concrete facts (real numbers, internal tool names, production architecture choices). Generic prompts produce generic walkthroughs. The Coinbase walkthroughs were strong specifically because each had 5+ Coinbase-specific facts injected.

6. **Run solver agents in two waves of 4 (not all 8 at once).** Background mode handles all 8, but staggering by ~30s lets you adjust the second batch's prompts based on any pattern in the first batch's responses (or correct an over/under-spec'd brief).

7. **Don't re-read all 8 walkthroughs to write patterns/crash course.** The walkthrough briefs you wrote in Phase 3 already encode the patterns. Use accumulated research + brief context. Sample 2-3 Tradeoffs Summary / Common Mistakes sections if you need to verify a specific claim.

8. **Always save a project memory entry at the end.** Future sessions will reference it.
