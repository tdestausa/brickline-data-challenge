# Brickline Motors — Candidate Submission

*Candidate: Teddy Desta*

Scenario chosen: **Brickline Motors** (not Meridian).

---

## How to read this

Recommended order is the file numbering, and it's not arbitrary — each file leans on the one before it:

1. **[01_domain_model.md](01_domain_model.md)** — the domain boundaries, the governance plane, and how the cross-domain entities (Customer, Vehicle/VIN, Order) get handled. Everything else assumes this.
2. **[02_data_dictionary.md](02_data_dictionary.md)** — shared vocabulary, and specifically the terms that mean different things depending which domain you're standing in.
3. **[03_physical_model.sql](03_physical_model.sql)** — the physical shape of three specific data products named in 01, plus the actual SQL that answers the CEO's question at the bottom of the file.
4. **[04_catalog/](04_catalog/)** — the same three products (`vehicle-master`, `vehicle-ownership`, `parts-order`) as registered, governed manifests. This is what a consumer actually sees before they're allowed to touch the data.
5. **[05_architects_narrative.md](05_architects_narrative.md)** — ties all of it back to the maturity model and the four mesh principles, and explains the *why*, not just the artifacts.

If you only have time for two of these, read 01 and 05 — 01 sets up every decision, 05 explains why they add up to something coherent.

---

## Key design decisions and tradeoffs
- **Starting point** My starting point was to model Brickline around the work the business performs, not around the systems it happens to use today. The two plant ERPs, the dealer management system, and the e-commerce platform are source systems.
I also wanted the governance plane to be visible in the model. In this design, cross-domain data moves through registered data products and governed interfaces.
- **Two-tier domain model, not flat.** Splitting each Tier 1 domain into named workflows is what makes Recall Issuance and Vehicle Ownership show up as *specific missing sub-domains* instead of a vague "governance gap" footnote. Tradeoff: more surface area to keep consistent across five files than a one-page flat map would've needed.
- **Federated master data, no golden record, for Customer and VIN.** Each domain keeps its own key and table; a platform-owned crosswalk links across them (Party/Identity Graph for Customer, normalization + crosswalk for VIN). Tradeoff, and a real one: this accepts some duplication and an eventual-consistency window between `D-XXXXX` and `CU_xxxxxx` records, in exchange for not making any domain rewrite its own primary key or cede control to a central team.
- **Physical model spent 3 of its 5-table budget on Manufacturing alone** (`vehicle_master`, `recall`, `vehicle_recall`), for a proper many-to-many junction instead of an array column. Tradeoff: less balanced across domains on paper, but recall correctness was worth it — a denormalized array would've made "how many vehicles does this recall affect" an unnesting query instead of a plain join.
- **No foreign key from `vehicle_ownership.vin` or `parts_order.vehicle_vin_provided` back to `vehicle_master`.** Deliberately loose. Tradeoff: accepted "some VINs just won't resolve, and that's fine" over a hard constraint that would make a legitimate trade-in or an unverified customer-typed VIN fail at the database layer.
- **Catalog manifests picked the three products that actually answer the CEO's question**, not one manifest per domain "for symmetry" or whichever was easiest to write. Tradeoff: Dealer Onboarding, Customer Account, and Product Catalog have zero manifests in this submission — a real gap if a reviewer expected full domain coverage rather than a worked example.

---

## What I'd change with more time

- Actually write the `manufacturing-recall` catalog manifest. It's referenced from `vehicle-master`'s lineage as "related product, not written yet" — I flagged it and never circled back.
- A couple more data dictionary terms (Warranty, Service History) would round it out, but neither has anything backing it in the sample data pack, and I'd rather leave that gap stated than invent a canonical definition for data that doesn't exist yet.
- The Dealer ↔ Commerce B2B identity gap I called out in the dictionary — a dealer's own parts department has a completely disconnected identity between Dealer Network and Commerce — got a note, not a plan. Would want an actual design for that with more time.
- A federated governance rule table (rule / layer / enforcement mechanism / consequence) — I worked through this as prep and folded pieces of it into 02's classification logic and 04's `consumption_patterns_blocked` fields, but never wrote it up as its own standalone artifact.
- A migration/decommission plan for whatever shadow extracts and point-to-point pipes are *already* running today (the data pack says this is already starting, Problem 10). This submission designs the target state; it doesn't say how to turn off what's currently live.

---

## What I skipped, and why

- **QC / defect data as its own product.** Real, has sample data behind it, genuinely useful — but it's not in the direct chain that answers the CEO's question, so it didn't make the cut for either the 5-table physical model or a catalog manifest.
- **Supplier/vendor master data reconciliation** (`SUP-001` vs `S_a7b3`, Problem 3). Flagged as a real gap in the data dictionary, but building out a supplier crosswalk has nothing to do with the CEO's question, and I didn't want to pad the submission with a product nobody asked about.
- **A Customer Account catalog manifest for Commerce.** It's a named Tier 2 sub-domain in 01, but I picked `parts-order` as Commerce's flagship manifest instead — specifically because Customer Account has the B2B/B2C modeling problem I flagged in the dictionary, and I didn't want to paper over real design work in a one-page YAML file just to check a box.
- **Conceptual and logical ER diagrams.** The brief is explicit that only the physical layer is required and the conceptual/logical mapping is a walkthrough discussion — so that reasoning lives in the scope-note comments at the top of `03_physical_model.sql` instead of a separate diagram nobody asked for yet.
