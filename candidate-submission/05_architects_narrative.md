# Artifact 5: Architect's Narrative

*Author: Teddy Desta*

## 1. Maturity Assessment — Why Brickline Is at Level 1 Today

Three pieces of evidence, all straight from the scenario, no exaggeration needed:

**No shared identity between systems.** `D-12345` in the DMS and `CU_a7b3c9` in Commerce are the same person — James Patterson — and Brickline has no way to know that today. Not "a slow way." No way. The two customer tables were built independently, with independent ID formats, and nothing has ever connected them. That's not a data quality bug you patch with a script; it's what happens when two domains grow up with zero shared identity strategy from day one.

**No canonical reference data, anywhere.** VIN — the one thing that's supposed to be the universal key tying the whole company together — is spelled differently depending which system you're standing in (uppercase in the plants and the DMS, whatever-the-customer-typed in Commerce, usually lowercase). And that's before you even get to the two plants disagreeing on column names, date formats, and QC severity vocabulary for the exact same concepts. When your one universal key isn't actually universal, everything downstream of it inherits the crack.

**Governance is reactive, and point-to-point integration is already starting.** There's no catalog, no data product registry, no owner-of-record for cross-domain questions — which is the textbook definition of Level 1. But the more telling detail is Problem 10: as soon as someone wants to combine Manufacturing data with Parts data, they're already reaching for a direct extract job. Nobody planned that. Nobody's stopping it either. That's what "fix when broken" actually looks like in practice — not chaos, just nobody with the authority or tooling to say no.

Put those three together and you get exactly what the CEO ran into: a two-week spreadsheet exercise to answer a question that should be a same-day query.

---

## 2. Target State Justification — Why This Design Reaches Level 3

Level 3 means policies enforced through systems and processes, not through someone remembering to follow a wiki page. Here's where each of the four principles actually shows up, concretely, not just asserted:

**Domain Ownership.** Three Tier 1 domains, each with a named VP-level owner, in [01_domain_model.md](01_domain_model.md). No central data team sits between a domain and its own data — Manufacturing owns build truth, Dealer Network owns ownership truth, Parts owns commerce truth, full stop.

**Data as a Product.** Every table in [03_physical_model.sql](03_physical_model.sql) and every manifest in [04_catalog/](04_catalog/) has an owner, a schema with field-level classification, an SLA, and a defined access interface. `vehicle-master`, `vehicle-ownership`, and `parts-order` aren't just tables that happen to exist — they're published products someone is accountable for.

**Self-Serve Platform.** The governance plane in 01_domain_model.md — Catalog & Registry, Identity Resolution, VIN Normalization, Policy-as-Code + API Gateway — sits between the three domains and enables discovery and matching without ever becoming a fourth owner of business data. That boundary is the whole point; it's what keeps this from quietly turning back into a central data team with a rebrand.

**Federated Governance.** This is the one people usually get wrong by either centralizing everything or writing a policy doc nobody enforces. Here it's neither: [02_data_dictionary.md](02_data_dictionary.md) records definitions each domain already owns rather than inventing new ones, and every catalog manifest enumerates both `consumption_patterns` (approved) and `consumption_patterns_blocked` (denied) explicitly — so "no direct DB access" isn't a sentence in a doc, it's a declared, checkable rule sitting right next to the schema it applies to. And the VIN `CHECK` constraint in `vehicle_master` is the cleanest proof point I've got that this is Level 3 and not Level 2: a bad VIN doesn't get caught by a human reviewer noticing it later, it gets rejected by the database at write time. That's the actual difference between "we have a policy" and "policies enforced through systems."

---

## 3. Data Management

**Master data strategy is the center of this, not a bullet point.** Brickline has two entities that get created independently in more than one domain — Customer and, in a narrower sense, Vehicle once a trade-in enters the picture — and the tempting move is always to build one central "golden record" table and force every domain to write to it. I'm deliberately not doing that. The strategy here is **federated master data**: each domain keeps its own system-of-record (Dealer Customer stays in Dealer Network, Commerce Customer stays in Parts), and a platform-owned crosswalk — the Identity Resolution / Party Graph — maintains scored links between them without either domain ceding control of its own table. Same logic applies to VIN: Manufacturing owns build truth, a platform normalization service maintains the canonical spelling, and nobody's forced to rewrite their own primary key to participate.

**Ownership & stewardship** — every product has a named owning domain and role (VP-level accountable owner, named steward for day-to-day), visible directly in each catalog manifest.

**Lifecycle & retention** — modeled explicitly where it matters instead of assumed. `vehicle_ownership` is append-only with a `current`/`superseded` status specifically so "who owned this VIN when the recall was issued" stays answerable after a resale. `recall.status` moves `active` → `closed`. Deprecating a whole data product carries a 90-day notice window rather than just disappearing on registered consumers.

**Metadata management** — every manifest carries source system, lineage (upstream and downstream), classification, and SLA as first-class fields, closing a gap (Problem 7) that's currently just... absent. Nothing in Brickline's systems today carries provenance or a schema version. Everything in this design does.

**Access & distribution** — API and governed-view only, enumerated explicitly per product as approved vs. blocked channels. No exceptions carved out for "just this once."

---

## 4. Data Quality

Worth saying up front because it's easy to accidentally undo: quality here is **federated, per-domain**, not something a central data-quality team owns. Handing quality to a central team is the same mistake as a central master-data team — it just re-centralizes power under a different name.

- **Validity** — enforced at the domain's own table, at write time. The VIN format `CHECK` constraint lives in `manufacturing.vehicle_master`, owned by Manufacturing, not bolted on downstream by whoever happens to consume it.
- **Accuracy & consistency** — each domain normalizes its own known quirks at its own boundary before publishing. Plant 2's date format, Plant 2's severity vocabulary, Commerce's lowercase VINs — all get resolved by the domain that produced the mess, not by a central cleanup job nobody's ever fully staffed.
- **Completeness** — each product declares its own completeness target because each domain actually knows what "complete" means for its own data (100% of vehicles within an hour of build completion; 100% of completed checkouts, abandoned carts don't count). A central team guessing at these numbers would just be worse at it.
- **Timeliness** — freshness SLAs set per product, matched to actual need (`parts-order` near-real-time because checkout can't lag; `vehicle-master` daily batch because build events aren't that frequent). Not a single blanket freshness rule imposed company-wide.
- **Monitoring & remediation** — the platform's Lineage & Observability capability watches SLA compliance across every domain from one place, so there's a single pane of glass for "what's breaching right now." But it only flags. The owning domain is who investigates and fixes, because only that domain actually understands its own source system well enough to know why a plant's ERP suddenly started sending malformed dates. Central visibility, federated remediation — that split is deliberate.

---

## 5. Path to Level 4 / Level 5

**Level 4 (Integrated/Productized).** Right now, governance is enforced *at* each domain by an external platform gate — the Policy-as-Code engine checks a product before it can publish. That's still Level 3: the check happens to you. Level 4 is when the check happens *because of* you — a domain scaffolds a new data product from a platform-provided template that bakes in PII tagging, schema validation, and catalog registration as the domain's own CI steps, generated from schema annotations rather than hand-typed. Honest confession: the three YAML manifests in `04_catalog/` were written by hand for this challenge. That's the Level 3 reality. At Level 4, those get generated automatically from the DDL and never drift out of sync with it, because a human retyping the same information twice is exactly where drift comes from.

**Level 5 (Optimized/Predictive).** Layer prediction on top of the Lineage & Observability data that Level 3 is already collecting — catch a VIN-format drift in a new plant ERP release before it corrupts `vehicle-master`, not after; flag when Identity Resolution's match-confidence is silently degrading for a customer segment before the CEO's dashboard number quietly goes wrong; forecast an SLA breach from trend data instead of alerting after the SLA's already blown. None of that is buildable without a couple years of the Level 3 telemetry feeding it first — which is fine, that's the natural order here, not a shortcut anyone should try to skip.

**Where I'd actually point AI at this, concretely, rather than just gesturing at "ML/AI" as a Level 5 buzzword.** The two most tedious, error-prone jobs in this whole design are exactly the kind of thing a model is good at and a human is bad at repeating consistently at scale. First: keeping the catalog manifests and data dictionary in sync with the real schema. I hand-typed the classification tag on every field across three YAML files for this submission — a human doing that across dozens of products will eventually mislabel something Restricted as Internal, and nobody notices until it's a problem. An LLM reading the DDL and drafting a first-pass classification and definition for a new field, for a human steward to confirm rather than write from scratch, closes that gap early instead of relying on someone remembering to update three places at once every time a schema changes. Second: Identity Resolution itself. The deterministic pass I'd ship Day 1 (match on email, hand off the rest) is a starting point, not the end state — a model trained on the human-confirmed matches over time should get better specifically at the ambiguous cases, the ones that don't share an email but probably are the same person, which is exactly where a fixed if-this-then-that rule runs out of room. Both of these are narrow, supervised uses tied to a specific artifact already in this design, not a general "sprinkle on some AI" wave of the hand — and both still keep a human confirming the model's suggestion rather than letting it write straight to a governed product.

---

## 6. Day 1 Priorities

If I started tomorrow, in order:

**1. Ship Vehicle Ownership and Recall Issuance first — even ugly, even manual-entry.** Everything else in this design is plumbing around a hole until these two exist as real, queryable things. A recall tracked in a spreadsheet with a person manually re-typing it into a `recall` table beats no recall table at all. Perfect data products with no data in them answer nothing.

**2. Stand up Identity Resolution as a lightweight matching job, before the rest of the platform is built out.** This is the single highest-leverage piece of work available, because it's not a new-data-collection problem — both customer datasets already exist today. It's purely a matching problem, and even a rough deterministic pass (match on email, hand off the ambiguous cases) gets Brickline most of the way to answering the CEO's question, well before the full governance plane is production-ready.

**3. Get catalog registration into the habit immediately, even manually, even before the CI gate exists.** Problem 10 says point-to-point integration is already starting. Every week without at least *some* friction in front of "just write a script that pulls from both systems" is another direct pipe getting built that'll need tearing out later, with someone's dashboard depending on it by the time anyone notices. A pre-commit check, a Slack bot that nags, a spreadsheet someone has to update manually — any of it beats the current zero.
