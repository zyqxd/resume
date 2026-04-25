# Company System Design Prep — Repeatable Workflow

This template generates a complete staff-level system design knowledge bank for a target company. The output mirrors the existing Shopify (`exercises/shopify/`) and Coinbase (`exercises/coinbase/`) structure: 8 numbered exercise folders (`01-...` through `08-...`), each with `PROMPT.md` + `WALKTHROUGH.md`, plus a `patterns.md` and `crash-course.md` at the company-folder root.

**Estimated total runtime:** 60-90 minutes wall clock, ~12-15 parallel agent invocations. Output: 19 files (8 PROMPT + 8 WALKTHROUGH + patterns + crash-course + interview-playbook).

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
    ├── crash-course.md                   # reference material, read early
    ├── interview-playbook.md             # delivery mechanics, read morning-of
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

1. **Gather role and prompt context from the user before research.** Ask in one message:
   - **Exact role title and sub-team** if known (e.g., "Staff SWE Backend, Consumer-Retail Cash" not just "Staff at {{COMPANY}}"). The sub-team biases which patterns matter — Coinbase Consumer-Retail Cash deemphasizes matching-engine internals; Coinbase Trading Infra would emphasize them.
   - **Interview prompt language if known.** Many companies publish or candidates leak the literal prompt (e.g., Coinbase: "Design a zero-to-one system based on a real-life scenario"). The prompt's *shape* drives the playbook — "zero-to-one" → worked openings should target user-familiar systems (Venmo, Robinhood) not company-internal exotica.
   - **Timeline.** Days vs. weeks matters. <1 week to interview means biasing late-phase output toward delivery mechanics over more architecture facts.
   - **Already-completed adjacent prep** (Shopify, other companies) so you can call out contrasts.
   If the user can't answer, proceed with sensible defaults but flag the assumption.
2. Read the existing exemplar files listed above to absorb the structure and depth target.
3. Use TaskCreate to set up tasks for each phase below.
4. Create the company folder: `mkdir -p knowledge/system-design/exercises/{{COMPANY}}`. Exercise subdirs are created in Phase 3 once you've picked the 8 exercises.

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

Write `knowledge/system-design/exercises/{{COMPANY}}/crash-course.md` mirroring `shopify/crash-course.md` / `coinbase/crash-course.md`. This is the reference study guide (read early, weeks before).

Required sections:
1. Opening — "How {{COMPANY}} Thinks About Architecture" (3 design constraints all decisions flow from). **Add a "role-specific lens" paragraph** if Phase 0 captured a sub-team — call out what to bias toward and what to deprioritize.
2. The {{COMPANY}} Interview Loop (loop structure, bar-raiser equivalent, top rejection cause)
3. Cultural Tenets That Show Up in Design Rounds (table mapping tenets → what they look like in interview)
4. **Domain primer (if applicable)** — "just enough X" for whatever specialized knowledge the company assumes (blockchain finality for Coinbase, payment rails for Stripe, LLM serving for Anthropic). 3 concepts max. Skip if the domain is generic web.
5. The Technology Stack — **3 picks per layer, no more.** Each pick: what it gets you, what you pay (the cost). Lead with a "how to make tech decisions on the whiteboard" paragraph (4 short bullets). Capacity reference numbers as a table with **numbers bolded.**
6. Architecture Patterns (10-15 patterns expanded with "How to describe this problem" framing). **Each pattern must have a cons / tradeoffs section** — what does this approach cost? Storage growth? Operational overhead? Latency?
7. Patterns for Specific Problem Domains (one section per major problem area mapping to the 8 exercises). For each: 90-second framing line + bulleted decision points. **Mark which are role-priority** based on Phase 0 input (e.g., "*highest priority for this role*", "*know-the-shape*", "*very low priority*").
8. Common Mistakes That Fail Candidates (numbered list, rank-ordered by frequency)
9. {{COMPANY}}-Specific Vocabulary (compact tables grouped by domain)
10. The 60-Second Mental Model (filters to run every design decision through)
11. Related Resources (wikilinks to all 8 exercises + patterns doc + interview-playbook + ranked external watching/reading list ~5 hours)

**Style discipline (do not skip — the Coinbase v1 generation broke all of these and required a full rewrite):**
- **Mermaid diagrams, never ASCII.** ASCII boxes-and-arrows are unmaintainable and ugly to read.
- **Bold numbers in tables and lists** (`**~98%**`, `**5–10K writes/sec**`). Inline numbers in prose get lost.
- **3 picks per tech layer max.** Listing 7 databases is reference dump, not study guide. The user can't memorize 7; they'll memorize 3.
- **Cons sections on every pattern.** Every architectural choice has a cost; name it.
- **Human language, not academic.** *"Multi-chain ingestion is a derived-view problem with normalized event schema as abstraction"* is unspeakable. Rewrite to: *"the chain is source of truth, a normalized event schema is the abstraction layer."* Read every paragraph aloud — if it doesn't sound like something a staff engineer would say at a whiteboard, rewrite.
- **State machines: shape, not specifics.** Show start states, terminal success/failure, intermediate gates. Note "derive specifics with the interviewer." Memorizing 30 states is not the bar.
- **No PhD phrasing.** No "fundamentally", no "by construction" as filler, no over-nominalized prose.

**Target length: 350-500 lines.** Denser than the original 600-800 target. Length is not the goal — *recall under pressure* is. The Coinbase v1 at 750 lines was unusable; the v2 rewrite at 370 lines was actually studyable.

### Phase 6.5: Interview Playbook

Write `knowledge/system-design/exercises/{{COMPANY}}/interview-playbook.md`. **This is a separate file from crash-course.md** with a different purpose and lifecycle:

| File                  | Purpose                  | When to read                  |
| --------------------- | ------------------------ | ----------------------------- |
| `crash-course.md`     | Reference / patterns     | Weeks before, repeated review |
| `interview-playbook.md` | Delivery mechanics      | Morning of, single read       |

Required sections:
1. **What the prompt is testing.** If Phase 0 captured the literal prompt language, parse it. Words like "zero-to-one", "real-life scenario", "depth and breadth" each have specific implications. State them.
2. **The first 5 minutes** — clarifying questions checklist (functional scope, scale, non-functional priorities). Include explicit scripts the candidate can echo: *"I'll design for X and Y; I'll mention Z but not draw it. Push back if that's the wrong cut."*
3. **Time budget table** — minute-by-minute for 60/75/90-min slots. Phases: requirements, API+model, breadth architecture, depth deep-dive, wrap (failure modes + scaling story).
4. **The T-shape announcement** — a literal script the candidate says out loud when transitioning from breadth to depth, ranking 2-3 deep-dive candidates and pre-committing to the highest-stakes one.
5. **Driving the conversation** — the "lead with rejected alternative" pattern with 2-3 example phrasings. How to handle pushback gracefully (companies vary; calibrate to the cultural tenets).
6. **Whiteboard mechanics** — practical tips for the specific tool the company uses (CodeSignal, Excalidraw, etc.). Layout discipline, labels-on-arrows, one-canvas-per-component.
7. **Failure-mode probe table** — the 6-10 "what if X breaks" questions the company is most likely to ask, with one-line answer shapes pre-loaded.
8. **Recovery moves** — what to say when stuck on a tradeoff, when realizing the design has a flaw, when out of time, when asked something you don't know. Anti-bluff scripts.
9. **Closing checklist** — 4 one-sentence hits for the last 5 minutes (failure modes, scale story, what to build next, what to monitor).
10. **Behavioral signal during the round** — do/don't list calibrated to the company's cultural tenets.
11. **Practice prompts (worked openings)** — 2-3 likely "real-life scenario" prompts. **Calibrate the prompts to what was learned in Phase 0:** if the company's interview prompt is generic ("design a real-life system"), target user-familiar systems (Venmo, Robinhood, a digital wallet) over company-internal exotica. For each prompt: clarifying questions, scope-commitment script, mermaid breadth sketch, ranked deep-dive candidates with rationale, tradeoffs to surface explicitly, expected probes.
12. **Closing note on rehearsal** — the worked openings are answer keys for *moves*, not content. Drill on adjacent prompts, not these.

**Target length: 250-400 lines.** Optimize for "rereadable in 30 minutes the morning of."

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
   - {{COMPANY}}/crash-course.md (reference)
   - {{COMPANY}}/interview-playbook.md (delivery mechanics + worked openings)

   **Confirmed prompt (if known):** {literal prompt language from Phase 0}.

   **Role focus:** {sub-team and what to bias toward, from Phase 0}.

   **Why:** {one sentence on the job context — why {{COMPANY}}, what role}.
   
   **How to apply:** {2-3 sentences on when this prep is relevant in future conversations}
   
   **Key {{COMPANY}}-specific moves to emphasize:**
   - {3-5 bullets distilling the highest-signal architectural moves for {{COMPANY}}}
   ```
2. Append a one-line entry to `/Users/david/.claude/projects/-Users-david-Workspace-resume/memory/MEMORY.md` under the project section.
3. Update `knowledge/system-design/index.md` to add a new "{{COMPANY}} System Design Exercises" section linking to all 8 exercises + the crash course + interview-playbook + patterns doc. Mirror the existing Shopify/Coinbase sections.
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

## Lessons learned from the Coinbase v2 iteration (2026-04-25) — apply on future runs

The Coinbase v1 generation followed the original template and produced a 750-line crash course that had to be substantially rewritten when the user actually started studying it. These lessons cause the next run to land closer to a usable v1:

9. **Ask for role sub-team and prompt language *before* generation, not after.** Coinbase v1 was generic; the user is on Consumer-Retail Cash, which means matching-engine and ML-platform depth was wasted. The new Phase 0 step prevents this. If the user has the literal interview prompt, that's the highest-signal input — it shapes the playbook decisively.

10. **Crash course = reference. Playbook = morning-of.** These are different files with different lifecycles. Don't conflate them. The crash course is for repeated review weeks before; the playbook is for one read the morning of, and contains delivery scripts, time budgets, and worked openings — material that has no place in a reference doc.

11. **3 picks per tech layer beats listing every option.** Listing 7 databases looks thorough but is unstudyable. The user can hold 3 things in working memory and articulate the rejected alternatives for them. More than 3 is reference-dump theater.

12. **Cons / tradeoffs on every pattern.** The original template emphasized "why this wins" without "what it costs." Staff candidates are scored on tradeoff awareness. Every pattern needs a cons section.

13. **Mermaid not ASCII.** ASCII boxes-and-arrows worked in 2015. They're unmaintainable now and signal effort, not clarity. Mermaid renders, diffs cleanly, and is faster to write.

14. **Bold the numbers.** Inline numbers in prose disappear. Bold them in tables and lists. The user scans for numbers when reviewing — make them findable.

15. **Read every paragraph aloud.** If it sounds like a dissertation, rewrite. *"Multi-chain ingestion is a derived-view problem with a normalized event schema as the abstraction"* is unspeakable. Staff engineers don't talk like that at whiteboards.

16. **State machines: shape, not specifics.** Showing a 30-state diagram tells the candidate to memorize 30 states. They won't, and they shouldn't. Show the shape (start / terminal-success / terminal-failure / intermediate gates) and note "derive specifics with the interviewer." That matches reality.

17. **Length target: 350-500 lines for crash course, 250-400 for playbook.** The original 600-800 target was wrong. Density beats volume; recall under pressure is the metric.

18. **Domain primer if needed.** Some companies require domain knowledge the candidate may not have (blockchain finality, payment rails, GPU economics). Include a "just enough X" section with 3 concepts max. Skip if generic web.

19. **Worked openings target user-familiar systems** when the prompt is generic ("zero-to-one", "real-life scenario"). Not company-internal exotica. The user knows Venmo, Robinhood, Cash App from the consumer side; they don't know Coinbase's internal Aeron Cluster from the inside. The interviewer is testing structure-from-blank-slate, not insider knowledge.
