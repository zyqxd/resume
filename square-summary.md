# David Zhang - Square/Block Work Summary (Nov 2023 - Feb 2026)

## Overview

- **Promoted to Senior Software Engineer (L6)** in Dec 2025 review cycle
- **Rated "exceptional performance, delivering outsized impact"** in 2025 review
- **All 3 peer reviewers**: "strongly support promotion"
- **Repos contributed to**: 20+ repositories across Square and Cash App
- **Primary repos**: cash-server (475 commits), postoffice (253 commits)
- **#1 contributor** in Postoffice (19% of all repo activity, ahead of 30+ contributors)
- **Net lines added**: 17,717+ in Postoffice alone
- **Sustained velocity**: Committed code every single month for 24 months

---

## Promotion Details (Dec 2025)

- **From**: L5 (Software Engineer) **To**: L6 (Senior Software Engineer)
- **Specialization**: Server, IC
- **Organization**: Neighborhoods
- **Promoting Manager**: David Leung
- **Former Manager (feedback)**: Karen Wang (EM L7) - "I observed him consistently operate at L6 level—owning complex, ambiguous initiatives end-to-end"

### Key Themes from Promotion Packet

1. **Technical leadership**: Go-to person for Postoffice (flagship service), top contributor in PRs and net lines over 2 years, #2 in PR reviews
2. **Cross-org coordination**: Led projects spanning Marketing, Cash Local, Directory, Cash Messages, Design, Data Science, Legal, Customer Platform, Product ML
3. **DRI on critical initiatives**: FARM v2, Neighborhoods Winback, Franchise Marketing GA, Omni Promotions
4. **Operational excellence**: Transformed team's operational posture — Rails upgrades, Temporal migration (zero SEVs), oncall improvements, automated testing framework
5. **Team multiplier**: Thorough PR reviews as teaching moments, documentation-first culture, created and maintained team tech backlog

### Quantified Impact from Promo Packet & Feedback

- **FARM v2 ML model**: 11% increase in customer win-backs, 35% lift in buyer engagement
- **Rails upgrade**: 25% reduction in p95 latency, 70% improvement in deploy time
- **N+1 query pattern**: Halved API response times on test endpoint
- **Temporal migration**: Zero SEVs since migration (previously high oncall burden + significant SEVs)
- **Spam false positive fix**: 67% reduction in erroneous spam warnings
- **CE Automated Tests**: Framework adopted by other teams, showcased at CE org offsite, integrated into square-web
- **Neighborhoods Winback**: First-ever integration between Marketing and Cash App, delivered on schedule
- **Franchise Marketing**: Shifted operational ownership to sales via self-service onboarding, sustained reduction in oncall overhead

### Peer Feedback Highlights

**Karen Wang (EM L7, former manager)**: "David proactively identifies gaps, implements scalable solutions, and influences team direction through strategic thinking and knowledge sharing."

**Maesen Churchill (IC L6, peer)**: "As FARM DRI, David's work ensured this automation was the top text message marketing experience adopted by new F&D sellers." / "As Cash App Winback DRI, David oversaw the launch of the premier marketing product for Neighborhood Networks sellers."

**Ish Marwaha (IC L6, peer)**: "David led the successful delivery of the first-ever integration between Marketing and Cash App... David effectively negotiated scope and legal requirements while ensuring sellers received a compelling and usable product."

**Darya Kishylau (Marketing PM)**: "David has made exceptional contributions to the Local Marketing project as its founding engineer. He established the push channel foundations from zero, navigating significant organizational challenges."

**Gaurav Torka (Customer Platform eng-DRI)**: "Grateful for your partnership... your collaboration has been incredible."

---

## Major Projects

### 1. Continuous Deployment System for Cash App (cash-server, ~126 commits)

Built an automated continuous delivery/deployment system from scratch for Cash App's frontend service:

- Designed database schema (rollouts, ramp events, deployment events, CD settings, CD queue)
- Built rollout, rollback, and ramp event APIs
- Integrated Datadog monitors for automated rollback decisions
- Built a background agent that monitors deployments and automatically ramps or rolls back
- Built Slack notification system with commit diffs, author info, and formatted messages
- Built ramp configurations and bake duration support
- Built admin UI and namespace management
- Built monitor search/details APIs with grouping and split-by-version support

### 2. FARM v2 - Fully Automated Recurring Marketing (postoffice, ~27 commits) — Engineering DRI

Square Marketing's AI-powered platform that delivers personalized messages at optimal times to re-engage lapsed customers. David evolved from key contributor in FARM v1 to overall Engineering DRI for v2.

**v1 (contributor):**
- Created Snowflake data integration for ML-driven product recommendations
- Built product recommendation engine: catalog processing, item-level caching, variant selection, SMS delivery
- Built SmsDeliveryBuilder, VariantsRenderer for personalized SMS content
- Added coupon exposure risk controls to prevent over-discounting

**v2 (Engineering DRI):**
- Orchestrated planning and execution across all 3 workstreams: ML integration, expansion beyond F&B, infrastructure modernization
- Replaced v1's heuristic algorithm with covariance-based ML model (partnership with Product ML): **11% increase in customer win-backs, 35% lift in buyer engagement**
- Leveraged Snowflake to accelerate data sharing between Postoffice and ML model, optimized test setup to expedite validation
- Analyzed data quality gaps across verticals (Health & Beauty, Retail) to guide rollout decisions
- Migrated risk evaluation to Temporal (benefits extending beyond FARM)
- FARM was the marquee initiative for the CE Org in 2024-2025; TMM GA was on track to ship ahead of schedule before being paused due to strategic priority shift

### 3. Omni Promotions API (postoffice, ~27 commits)

Architected and built the new public Omni Promotions API from scratch in under 3 months:

- Full CRUD operations (INDEX, SHOW, CREATE, UPDATE)
- State management and lifecycle (cancel, finish transitions)
- Member stats endpoint
- Coupon attachment integration
- Pagination and edge-caching
- StandardizedErrors module for consistent error handling
- Presenters::Loadable pattern to resolve N+1 query problems

### 4. Neighborhoods Winback Campaigns (postoffice + cash-server, ~38 commits) — DRI

Square's first marketing integration into Cash App, enabling targeted winback campaigns for Neighborhood Network sellers. David was the founding engineer and DRI.

- Led a team of 5 backend engineers and 1 frontend engineer through the entire project lifecycle
- Coordinated across 7 partner teams: Marketing, Cash Local, Directory, Cash Messages, Design, Data Science, Legal
- Championed MVP-focused approach, collaborating with product and design to articulate technical complexities, identify risks, and provide accurate estimates
- Advocated for phased release strategy that uncovered critical data issues early enough to resolve without jeopardizing the October 2025 deadline
- Established push channel foundations from zero, navigating pushback from Cash Messaging team on the project's core premise
- Built Cash App local client and Promoter client for push notifications
- Created ActivateAutomation and ActivateCashAppWinback RPCs
- Automated seller onboarding to eliminate oncall overhead (sales now solely own onboarding via button click)
- Delivered on schedule despite aggressive timeline; framework now reused for Marketing Messages and Omnichannel Marketing

### 5. CDA Web Deployment Migration (cash-server, ~78 commits)

Migrated web deployment infrastructure from CFS to Cash Dot App (CDA) service:

- Built backfill APIs and sync handlers
- Implemented dual-write cutover strategy

### 6. CDN Migration for cash.app (tf-external-dns + cash-server, ~46 commits)

Managed traffic splitting between Fastly and Cloudflare for cash.app and cashstaging.app.

### 7. Platform Reliability & Operational Excellence (postoffice, ~27+ commits)

Drove Postoffice through three major Rails version upgrades and transformed the team's operational posture:

**Rails Upgrades:**
- Rails 6.1 → 7.0 → 7.1 → 7.2 over 18 months
- **25% reduction in p95 latency, 70% improvement in deploy time** from the initial 6.1.7 upgrade
- Upgraded Sidekiq to 7.3.9 (removing legacy dependencies: sqeduler, sidekiq-job_locks)

**Architecture Improvements:**
- Designed declarative N+1 query resolution pattern (Presenters::Loadable), **halving API response times**
- Introduced redis-based batching for database counters, reducing row-lock waits during peak traffic
- Migrated risk evaluation from legacy Sidekiq/RiskArbiter to Temporal: **zero SEVs since migration**

**Oncall Improvements:**
- Replaced ODS monitor with effective on-call review process, eliminating unactionable alerting
- Fixed Outlook spam false positives: **67% reduction** in erroneous warnings
- Led team-wide pairing event to investigate SMS delivery times, identified database bottleneck
- Led Thanksgiving/Black Friday performance analysis, contributing to SEV-free peak season

**Testing & Quality:**
- Built CE Automated Tests framework for end-to-end testing (adopted by other CE teams, showcased at CE org offsite, integrated into square-web)
- Multiple security patches (XSS, CSRF, Rack)

### 8. SMS Opt-in / Consent System (postoffice, ~19 commits)

Built SMS subscription management and consent flows for legal compliance:

- SMS Subscription Service endpoints
- Pre-receipt and text-receipt opt-in experiments (M2, M3)
- Multiple rounds of consent/legal copy updates for TMM

### 9. Franchise Marketing GA (postoffice, ~11 commits) — DRI

Took over as DRI after senior engineer departure with minimal knowledge transfer during period of significant team attrition:

- Redesigned rollout strategy, shifting operational ownership to sales through self-service onboarding model
- Introduced legally compliant subscription management across Organization Operators and members
- Enabled one-click access for Account Managers, eliminating manual engineering work
- Built LaunchDarkly feature flag integration, Kafka consumer for organization events
- Built franchise onboarding admin interface with country-based access controls
- Delivered at end of Q4 2024 with sustained reduction in oncall overhead

### 10. GitHub Proxy API (cash-server, ~18 commits)

Built a GitHub proxy API layer including JWT token generation, installation access tokens, commit/PR/file content APIs.

### 11. CDP Data Endpoint Normalization (cash-server, ~26 commits)

Migrated and normalized customer data platform endpoints with Amplitude integration and signature validation.

### 12. ManagerBot AI Campaign Tools (square-web + cash-server, recent)

Built omni-channel campaign creation tools with coupon support for the AI-powered ManagerBot.

### 13. Cash App Local Offers (cashbacker + local-offers-fe, ~47 commits)

Built bonus features across backend and frontend:

- Transaction bonus and first-purchase bonus features
- Cash App $pay bonus integration
- Merchant storefront location scoping

---

## Infrastructure & Platform Work

- **Terraform**: DNS management, Datadog monitors, IAM roles, Kafka topic ACLs
- **Kubernetes**: Scaling operations, holiday traffic management, memory rightsizing
- **Monitoring**: Datadog monitor setup across multiple services
- **Traffic routing**: Postoffice access to promoter services

---

## Technologies

Ruby on Rails (6.1-7.2), Java/Kotlin, TypeScript, Sidekiq, MySQL, Kafka, Protobuf/gRPC,
Snowflake, Redis, AWS S3, Datadog, Sentry, LaunchDarkly, Terraform, Kubernetes,
Elasticsearch, GraphQL, Ember.js, React, Fastly, Cloudflare

---

## Supporting Repos

| Repo | Commits | Purpose |
|------|---------|---------|
| cashbacker | 36 | Cash App local offers backend |
| local-offers-fe | 11 | Cash App local offers frontend |
| ce-intelligence | 21 | Customer engagement intelligence service |
| square-web | 18 | Square web monorepo (ManagerBot, ce-automated-tests) |
| automatron | 12 | Customer engagement automation service |
| tf-external-dns | 42 | DNS/CDN management |
| tf-postoffice | 31 | Postoffice Datadog monitors |
| ccd-postoffice | 11 | Postoffice Kubernetes config |
| dashboard | 6 | Square Dashboard (FARM metrics, omni errors) |
| mcp | 12 | AI-assisted development MCP server |
| tf-coupons | 7 | Coupons service monitors |
| tf-automatron | 8 | Automatron IAM/Terraform |
| ce-automated-tests | 9 | End-to-end test framework |
| And 10+ more smaller repos... | | |
