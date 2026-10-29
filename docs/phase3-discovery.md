# Phase 3 Milestone 5 — reviewed product discovery

Entry: **Digital vanity → Discover products**. Catalogue records describe products; they do
not imply ownership. “I own this — add to Vanity” opens the existing editor for explicit
review/save under a new private item ID. Catalogue updates do not rewrite owned copies.
The authenticated account-change guard is reused on navigation.

## Source/search strategy

Initial strategy is a small manually maintained catalogue, not an unverified shopping API or
runtime scraper. Six genuine product/shade records from two official manufacturer pages were
reviewed on **2026-10-28** (local calendar review date):

- [e.l.f. Cosmetics Australia — O Face Satin Lipstick](https://www.elfcosmetics.com.au/collections/lip-colour/products/o-face-satin-lipstick?variant=42661593219261): Dirty Talk, Drive, Effortless, No Regrets; satin finish.
- [Maybelline US — Lash Sensational Sky High Washable Mascara](https://www.maybelline.com/eye-makeup/mascara/lash-sensational-sky-high-washable-mascara-makeup?variant=Very+Black): Very Black, Blackest Black; semi-matte finish listed on the product page.

Links are product-family pages that list multiple shades, not invented per-shade URLs.
Only short factual names/shade/finish metadata is stored; no images, marketing copy, medical
claims or ingredients are copied. Category is an editorial classification. Product/brand/shade/
finish have manufacturer-page provenance; no skin suitability or color harmony is inferred.
Source regions are displayed; listings do not confirm availability in the user's location.

`catalogue/products.json` is the reviewed source-controlled input. Internal UUIDs are stable
catalogue keys, not retailer SKUs. Prices, availability, undertones, shade identifiers and hex
colors are absent rather than guessed. The UI explicitly marks missing fields and the small
coverage. No recommendation ranking/affiliate/retailer integration or analytics is added.

Search is backend PostgreSQL word search (`simple` full-text document, GIN index), with exact
category/brand filters, deterministic ordering, 20-row pages and a lookahead. Multiword queries
require matching words; arbitrary substrings are not promised. Text is a bound argument to
plainto_tsquery, never SQL/filter syntax. This is not an all-products frontend download.
No large-catalogue performance benchmark was run on the six-row starter.

No retail product has a defensible exact YouCam mapping. API/UI explicitly expose no exact
preview. Generic VTO remains a separate journey; a product name/finish is never converted to
an invented color or provider parameter. Gemini planning remains limited to private owned
items and does not silently mix catalogue products into inventory.

## Schema, import and API

Forward-only `supabase/migrations/202610280002_product_discovery.sql` adds a shared
`discovery_products` table, GIN/filter indexes, an active-record authenticated-read policy,
and server-only `search_discovery`. Ordinary users cannot write it; anonymous reads are denied.
It contains public manufacturer facts, no user IDs/private observations. Existing private
Vanity policies/data are unchanged. Backend search/detail require the existing verified Auth.

Apply only to confirmed development project `zouvroynucstxqimygzd` after reviewing the SQL.
Then from backend:

```powershell
.\.venv\Scripts\python.exe scripts/import_catalogue.py
# Review validated source file/target; this updates only explicit public catalogue IDs:
.\.venv\Scripts\python.exe scripts/import_catalogue.py --apply
.\.venv\Scripts\python.exe scripts/check_discovery_live.py
```

Importer dry-run is the default. It rejects malformed fields, duplicate IDs, unreviewed URL
hosts/schemes/credentials and dates beyond the global current-calendar-day allowance. Apply
is hard-restricted to the confirmed dev project, using backend-only credentials. Upserts only
the explicit IDs; missing rows are not deleted. Retire records with `active:false` after source
review; inactive rows disappear from ordinary direct reads and backend searches. New source
hosts require an explicit validator change and evidence. Recheck dates/facts when editing;
there is no automated refresh or claim that a once-reviewed page remains current forever.

- `GET /v1/discovery?q=&category=&brand=&offset=0`: items, has_more, filter choices and
  exact_vto_available=false. Query 200 chars max; page offset 0–1,000,000.
- `GET /v1/discovery/{uuid}`: active record detail; missing/inactive 404.
- No catalogue mutation route is exposed. An owned copy uses existing `/v1/vanity/{new-id}`
  only after editor Save, preserving existing authorization and retry/version behavior.

## Validation and remaining gates

`supabase/tests/discovery.sql` runs migration/RLS/search/paging assertions in isolated local
PostgreSQL and rolls back. Backend tests mock the database; Flutter tests mock APIs. They are
not live RLS proof. `check_discovery_live.py` is ready to check two ordinary logins plus fresh
login, shared catalogue visibility, denied writes, authenticated search and anonymous denial.
It does not add owned products or call Gemini/YouCam.

Actual command results, migration/import status, source-check evidence and platform gaps are
in `validation.md`. Remote migration/import/live catalogue checks have passed. Later actual
browser search and explicit owned-copy Save also passed; the marked disposable copy persisted
after fresh login, was denied to another ordinary user, then was removed by its owner through
the existing API. The catalogue source remained unchanged. Remaining UI filters/paging/platform
and native VTO/Talk checks stay separate from that evidence.
Prior VTO rendering/cleanup and Talk device gaps remain; Phase 3 is not fully accepted yet.
