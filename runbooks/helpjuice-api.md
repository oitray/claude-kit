# Helpjuice API Runbook

> **Owner:** <your-name> | **Last verified:** 2026-10-11

## API quirks (empirical 2026-05-06)

- **No analytics API exists.** All `/api/v3/analytics*` paths (including `/analytics`, `/analytics/searches`, `/analytics/articles`) and `/api/v3/searches`, `/api/v3/search_terms` return HTTP 404 on both `<your-org>.helpjuice.com` and `<knowledge-base>.helpjuice.com`. Helpjuice analytics is admin-UI only. The `<knowledge-base>-mcp` server's `<kb>_helpjuice_get_analytics` tool (`/Users/<your-username>/Projects/<knowledge-base>-mcp/src/index.ts:1167`) targets `/analytics` and is dead code — calls return 404. **For popularity ranking, use the per-article `views` field instead** (see next bullet).
- **`per_page` is no longer honored on the bulk list — use `limit`.** **empirical (2026-06-12, <clickup-task-id>):** `GET /api/v3/articles?per_page=100` returns 25 items (`meta.limit: 25`); the working param is `limit` (`limit=100` → 100 items, `meta.total_pages: 24`, `total_count: 2335`). Paginate via `meta.total_pages`. Any code still sending `per_page=100` and stopping when a page has <100 items silently truncates the catalog to 25 articles. **contradicts-docs** vs older `per_page=100` snippets in this runbook — live behavior wins.
- **The bulk list no longer exposes `slug` at any location.** **empirical (2026-06-12, <clickup-task-id>):** `item.slug`, `item.answer.slug`, and `item.answer.permalink` are all `null` on every bulk-list item. Derive the slug from the trailing path segment of `url` (e.g. `<internal-url> → `salesforce-lead-playbook`). The plan-audit gate-4 catalog fetcher (`scripts/plan-audit/lib/helpjuice_slugs.py`) does exactly this and fails closed (`HelpjuiceUnreachable`) if a non-empty list yields 0 slugs, so a future shape drift can't poison the slug cache with an empty catalog.
- **Rate limit: 300 requests / 60 s per API key.** **empirical (2026-10-08, <clickup-task-id>):** every response carries `x-ratelimit: {"name":"API","period":60,"limit":300,"remaining":N,"until":"<iso>"}`; once `remaining` hits 0 the API returns **HTTP 429** until `until`. The budget is shared by every consumer of the key (<internal-bot>-gateway, n8n, scripts) — page walks should use bounded concurrency and honor `until` on a 429.
- **The bulk list populates `accessibility`; `views` can still be null.** **empirical (2026-10-08, <clickup-task-id>):** `GET /articles?limit=100&page=1..26` returned a numeric `accessibility` on every article (2,576: 0 → 1,803 · 1 → 682 · 2 → 88 · 4 → 3) and it matched `GET /articles/<id>` on 247/247 sampled articles. Bulk rows also carry `published` (419 unpublished) and `category {id,name}`. `views` is null on some bulk rows, so popularity ranking still needs the per-article fetch. (Until 2026-10-08 this runbook said bulk `accessibility` was always null — empirical 2026-05-06 — which no longer holds.)
- **The unfiltered bulk list sorts published articles first, drafts last.** **empirical (2026-10-11, <clickup-task-id>):** `GET /articles?limit=1000&page=1..3` returned 0, 0 and 425 unpublished rows; at `limit=100` pages 26–23 were all drafts and page 22 was published rows then drafts. There is no draft filter (`published=false`, `status=draft`, `filter[...]`, `sort=` are ignored) and `limit=1000` is honored (`category_id=1369076&limit=1000` → 222 rows, one page; an unfiltered 1000-row page is about 16.6 MB). `GET /search` never returns drafts. Thread-Learning reads the draft tail backwards (`docs/runbooks/thread-learning.md` "Draft catalog").
- **Views field IS the popularity proxy.** Per-article `views` is a monotonic counter. **empirical (2026-05-06)** top-viewed in <knowledge-base>: "Disabling SIP ALG on a Fortigate Firewall" at 42,498 views. There is no `?sort=views` shortcut — fetch each article and sort client-side.
- **Audience filtering pattern — three layers in order.** When matching arbitrary questions back to articles for public-facing surfaces, use these three filters in order:
  1. **Strict `accessibility == 1`** (the bulk list carries it since 2026-10-08; re-fetch the article only when the decision must be current to the minute) — only `1` is publicly reachable on `<knowledge-base>.io`. `0`, `2`, `4` are internal/private/URL-only and must be excluded from public-facing recommendations.
  2. **Host allowlist** — accept only `<knowledge-base>.io` and `<knowledge-base>.helpjuice.com` URLs as voipdoc matches. Reject any cross-categorized hits whose `source_url` is a vendor docs site (e.g. `documentation.netsapiens.com`); those leak through `knowledge_chunks` because some articles cross-link to vendor sources.
  3. **Category deny list** (cheap, available in bulk list `category.name`) — backstop for articles whose accessibility is mistakenly set: drop `HR`, `Job Postings & Descriptions`, `Company Policies`, `Finance`, `Sales`, `Compliance`, `Compliance & Security`, `Marketing`, `Branding`, `White Label Branding`, `Guidelines of Employment`, `Training Syllabi`, `Announcements`.

  Optional 4th layer for precision: parse `answer.body` for the `Intended Audience` callout (`<strong>Intended Audience:</strong>\s*([^<]+)<`) and require the captured text to contain `All Users`, `White Label Partners`, `Clients`, or `Customers`. Skips articles whose accessibility is mistakenly `1` but whose body explicitly tags Engineering/<your-org> staff. Slow because it needs full body — only do this when the audience-filter result is load-bearing.

## Auth

- **Method:** API key (raw, no Bearer prefix — `Authorization: $HELPJUICE_API_KEY`)
- **Vault:** `<credential-vault>`, read via the **<internal-bot> SP cert** (preferred — `.claude/rules/auth.md` §1). `HELPJUICE-API-KEY` was copied into `<credential-vault>` on 2026-09-28; the team lead reported that a cert-authenticated read returned HTTP 200 from the API. The original copy is still in `<credential-vault>` (OCC Orchestrator SP via `<azure-config-dir>`, auth.md §2), which existing daemons such as `local-poller-wrap.sh` read.
- **Rotation:** `HELPJUICE-API-KEY` exists in BOTH vaults — `<credential-vault>` (Claude sessions, <internal-bot> cert) and `<credential-vault>` (daemons, OCC Orchestrator SP). A rotation must update both, or one side keeps a dead key.
- **Secret name:** `HELPJUICE-API-KEY`. Subdomain is `<knowledge-base>` (base `<internal-url>).
- **Fetch creds:**

```bash
CDIR=$(mktemp -d)
AZURE_CONFIG_DIR=$CDIR az login --service-principal -u <azure-uuid> \
  --certificate ~/.claude/orchestrator/certs/<internal-bot>-sp-combined.pem \
  --tenant <azure-uuid> --allow-no-subscriptions >/dev/null
HELPJUICE_API_KEY=$(AZURE_CONFIG_DIR=$CDIR az keyvault secret show --vault-name <credential-vault> \
  --name HELPJUICE-API-KEY --query value -o tsv)
AZURE_CONFIG_DIR=$CDIR az logout; rm -rf "$CDIR"
```

- **Transport — use `curl`, not Python `urllib`.** Python 3.13's SSL trust store raises `CERTIFICATE_VERIFY_FAILED` against the Helpjuice host (workaround: `docs/runbooks/macos-shell.md`).
- **Base URL:** `<internal-url>

### Before any write — engineering-doc checklist

(Moved from `.claude/rules/engineering-doc-dual-home.md`, <clickup-task-id>. The rule itself says *when* a voipdoc is owed; this is *how*.)

1. **Look before creating.** `GET /categories` is paginated (~25/page) — walk every `?page=N` before concluding a category is missing, and search existing articles (`GET /articles?category_id=1366806&limit=50`, `GET /search?query=...`) so you don't duplicate. (<clickup-task-id> created two duplicate "Automations and Engineering" categories by skipping pagination.)
2. **Create** with `POST /articles` and `{"article":{"name":"<title>","body":"<html>","category_id":1366806,"accessibility":0,"published":true,"description":"<one line>","tag_names":["alpha","beta"]}}`. `body` is raw HTML. Keywords are written as **`tag_names`** — `keywords` is silently ignored (see "Keywords (a.k.a. tags)").
3. **Update** with `PUT /articles/<id>` wrapped under `article`. **Snapshot `answer.body` first** — there is no revision API. A body PUT on an already-published article **publishes immediately** (see "Update article").
4. **Visibility:** hold edits with `visibility_id:2`; restore an internal article with **`{"visibility_id":0,"published":true}` — never `visibility_id:1`, which makes it PUBLIC** even if `accessibility:0` is in the same payload.
5. **Read shape:** `article.answer` is an object — use `article.answer.body` / `.body_txt` (see "Article body shape").
6. **The public URL is not a staged-vs-live check for an internal article.** `accessibility: 0` articles sit behind a login wall — `curl -s -L <internal-url> returns `<title>Sign in to your account` and neither body. **empirical (2026-07-30), article 2000317.** Open the editor UI if you need certainty.
7. Body opens with the Scope info-callout (Article Template below); current-state content only. Public URL: `<internal-url>

## Common Operations

### Search articles (relevance-ranked)

```
GET /api/v3/search?query=QUERY
```

A hit carries `id, name, slug, url, categories, answer_sample, long_answer_sample, tag_names, is_internal, is_private, is_published, last_published_*` — **no `accessibility`**. `is_internal` is `true` for both Internal (0) and URL-only (4) articles (empirical 2026-10-08: URL-only 3654522, 3579442, 2151896 → `is_internal:true, is_private:false`; private 2603680, 2559764 → `is_private:true`; public 3961989 → both false), so a decision that must exclude URL-only articles needs `GET /articles/<id>`.

Returns results ranked by relevance. The result array is keyed **`searches`** (not `questions`) — `{"meta": {...}, "searches": [{"id", "name", "slug", "tag_names", "answer_sample", ...}]}`. **empirical (2026-05-25):** verified against `<knowledge-base>.helpjuice.com` — `r.get('questions', [])` returns empty on every query; the live key is `searches`. (An older snippet in this runbook used `questions` and silently returned 0 hits — fixed below.)

**Do NOT use** `GET /api/v3/articles?search=QUERY` — it returns results sorted by recency, not relevance, and routinely surfaces unrelated articles.

### Search query length cap — 512 characters (hard 500 above it)

`GET /api/v3/search?query=...` returns **HTTP 500** for any query longer than **512
characters**. It is a **character** cap, not a word cap — 60 short words (299 chars)
succeed, one 800-character token fails. The 500's body was not captured (the probe below measured status codes only);
downstream, n8n surfaces the failure as its own generic
"The service was not able to process your request", which is what reaches the ClickUp
error card — that phrasing is n8n's, not Helpjuice's.

**empirical (2026-08-17, re-confirmed 2026-08-18T02:23:53Z, card <clickup-task-id>):**

| query length | HTTP |
|---|---|
| 200 | 200 |
| 511 | 200 |
| 512 | 200 |
| **513** | **500** |
| 600 | 500 |
| 2,323 (the reported failure) | 500 |

| control | HTTP |
|---|---|
| 60 x `word` (299 chars incl. separators) | 200 |
| one 800-char token | 500 |

(The plan's [P4] ran the same control with a shorter word set — 60 words / 240 chars —
and also got 200. Both confirm the cap counts characters, not words; the char totals
differ only because the word sets differ.)

Any caller that forwards free-form user text into `query` MUST cap it. The shared cap +
error-classifier logic and its regression suite live in
`n8n/_tests/helpjuice_query_cap_logic.mjs` (`MAX_QUERY_CHARS = 200`, cut on a word
boundary).

**deployed (2026-08-18T03:25:28Z, card <clickup-task-id>).** The `Helpjuice KB Search` sub-workflow
(`3PmhgjqQoqZTIQ7J`) now carries the cap live. `PUT /workflows/3PmhgjqQoqZTIQ7J` → 200,
`updatedAt` 2026-08-18T03:25:28.633Z, `versionId` 850b3c90; the mandatory post-PUT re-GET
confirms `MAX_QUERY_CHARS = 200` in `Extract Keywords` (4 `capQuery(` call sites),
`classifyHelpjuiceError` in `Sanitize & Retry`, `onError: continueErrorOutput` on both
`Fetch Helpjuice Articles` and `Retry Helpjuice`, and the two new error branches
(`-> Sanitize & Retry`, `-> Error Output`). Workflow remained `active` throughout.

**Precedent (<clickup-task-id>, 2026-08-17):** a user pasted a ~245-word compliance
questionnaire at <internal-bot> in Teams. The keyword-extraction regex fallback emitted a
2,323-character query, Helpjuice 500'd, and because the fetch node carried no `onError`
the entire <internal-bot> Handler execution hard-failed — the user got no reply at all.
Card <clickup-task-id> (2026-08-12) is the same node failing on the same surface.

### Get article

```
GET /api/v3/articles/:id
```

#### Doc-driven testing fetch path

The `/sf-smoke-doc` runner uses this endpoint to load an article's text for grammar-based step parsing. Fetch and parse:

```bash
eval "$($HOME/.claude/scripts/fetch-secrets.sh <knowledge-base>)"
curl -s "<internal-url> -H "Authorization: $HELPJUICE_API_KEY" \
  | python3 -c "
import json,sys
d = json.load(sys.stdin)
art = d.get('article', d)
print(art.get('answer', {}).get('body_txt', ''))
"
```

Use `answer.body_txt` (plaintext) for parsing. For slug-to-ID resolution:

```bash
curl -s "<internal-url> -H "Authorization: $HELPJUICE_API_KEY" \
  | python3 -c "import json,sys; r=json.load(sys.stdin); [print(a.get('id'), a.get('name')) for a in r.get('searches',[])]"
```

**empirical (2026-05-18):** article 3727088 (Salesforce Lead Playbook) — `name="Salesforce Lead Playbook"`, `body_txt` length 13800 chars, `accessibility=0`. Referenced by `/sf-smoke-doc` runner in `tests/playwright/sf-smoke-doc.mjs`. Full step-list round-trip documented in `docs/superpowers/specs/evidence/<clickup-task-id>/phase-1-parser-roundtrip.md`.

See `docs/runbooks/sf-smoke-doc.md` for the full fetch path, grammar, and runner usage.

#### Article body shape (gotcha)

`article.answer` is a **dict**, not a string:

```json
{
  "article": {
    "id": "...",
    "name": "...",
    "answer": {
      "body":      "<p>HTML content with tags</p>",
      "body_txt":  "Plaintext content (use this for LLM context)",
      "format":    "html",
      "updated_at": "..."
    }
  }
}
```

For LLM ingestion or text comparison, use `article.answer.body_txt` — pre-stripped of HTML tags. The `body` field is raw HTML and requires regex stripping. Treating `article.answer` as a string raises `TypeError: expected string or bytes-like object, got 'dict'`.

#### Field-name asymmetry — read vs write ⚠

The GET response and the PUT/POST payload do **not** use the same field names for category membership, tags, or visibility. A naïve `payload = {k: GET_RESPONSE[k] for k in [...]}` will produce keys the API ignores.

| Concept | GET response field | POST/PUT field | Shape on GET |
|---|---|---|---|
| Primary category | `category` | `category_ids` (POST: `category_id`) | Object `{id, name, codename, accessibility, description, icon, image_url}` — becomes the FIRST element of `category_ids` on write |
| Also-In categories | (not returned on per-article GET) | `category_ids[1:]` | Query from the category side — see "Read — only the primary surfaces in the article object" below |
| Tags / keywords | `keywords` | `tag_names` | Array of `{id, name}` objects on read; array of strings on write |
| Visibility | (not returned on per-article GET) | `visibility_id` | n/a |

**Implication for body-only updates.** To update only the body of an already-published article, send the minimal payload:

```json
{"article": {"body": "<new html>", "published": true}}
```

The server preserves `category`, `keywords`, `accessibility`, `url`, and visibility automatically — there is no need to round-trip them. **empirical (2026-05-15):** verified against articles 3727087, 3727088, 3727091, 3727484 — all four had `category.id`, `keywords`, `accessibility`, `published`, and `url` unchanged after a `{body, published:true}` PUT (Wave C / Phase 7 of <clickup-task-id>).

**Implication for "preserve everything" patterns in plans.** Plans that instruct an implementer to "extract `category_ids` and `tag_ids` from the GET response and pass them on PUT" will silently no-op those keys (the GET response has `category` and `keywords`, not `category_ids` and `tag_ids`). A common None-filter pattern (`{k:v for k,v in payload.items() if v is not None}`) hides the bug — values are silently dropped instead of erroring, then the PUT either succeeds-with-no-effect or relies on server-side preservation. Prefer the minimal-PUT path above for body-only edits; reach for the elaborate "preserve all fields" pattern only when also writing category/visibility/tags, and use the WRITE-side names (`category_ids`, `tag_names`, `visibility_id`) when you do.

### Create article

```
POST /api/v3/articles
{ "article": { "name": "Title", "body": "<html>...", "category_id": 1348715 } }
```
**Required wrapper:** Body must be nested under `{"article": {...}}` — same as PUT. Sending fields at the top level returns 500.

Omit `published: true` to create as draft. Include `published: true` to publish immediately.

### Update article

```
PUT /api/v3/articles/:id
{ "article": { "body": "<html>..." } }
```

**Required wrapper:** Body must be nested under `{"article": {...}}`. Sending `body` at the top level returns 400.

**⚠️ Already-published article: a body PUT publishes IMMEDIATELY — there is NO draft-hold via the API.**
**empirical (2026-06-10, article 1933891, accessibility 1):** `PUT {"article":{"body":"<html>"}}` WITHOUT `published: true` on an already-published, public article updated **and published** the live body — the public `<knowledge-base>.io` page served the new content within ~4 minutes and `accessibility` stayed `1`. The article carries a single `answer.body`; a body PUT overwrites it live regardless of the `published` key. **The earlier "omit `published: true` → draft revision, published version stays live" claim is FALSE for already-published articles** (it holds only for never-published POST drafts — see below). There is **no revisions/versions API** (`/articles/<id>/revisions` and `/versions` both 404), so the prior body is **unrecoverable** once overwritten — `GET` and save the existing `answer.body` BEFORE any PUT if you might need to revert.

**`visibility_id: 0` = INTERNAL + published** (the state every "Automations and Engineering" article should be in). The `visibility_id` → `accessibility` map is **0 → 0 (internal, published, staff-only), 1 → 1 (PUBLIC on <knowledge-base>.io), 2 → 2 (private/URL-only)**. Sending `accessibility: 0` in the same payload as `visibility_id: 1` does NOT win — `visibility_id` overrides it silently. **empirical (2026-07-24, article 3895465):** publishing an internal engineering doc with `{"published":true,"visibility_id":1,"accessibility":0}` returned 200 and set `accessibility: 1`, serving it publicly; `{"visibility_id":0,"published":true}` corrected it to `accessibility: 0`, after which an anonymous fetch of the public URL returned the Helpjuice sign-in page instead of the body. A bare `{"accessibility":0}` PUT is a no-op — the field is derived from `visibility_id`, not set directly.

**To hold edits OFF the public site on an already-published article → set `visibility_id: 2` (private/draft).**
**empirical (2026-06-10):** `PUT {"article":{"visibility_id":2}}` flipped article 1933891 `accessibility` 1→2 and the public URL stopped serving it (anonymous fetch returned a Helpjuice sign-in page; the article body was absent). The new content stays in the (now-private) article for staff review in the KB. Re-publish to the public site with `PUT {"article":{"visibility_id":1,"published":true}}`. For a TRUE draft/revision workflow (stage edits without touching the live body at all), use the Helpjuice **admin editor UI** (`/admin/en_US/questions/<id>`), which versions saves — the v3 API does not expose that.

**Never-published draft (CREATE via POST without `published: true`):** stays a draft until a later `published: true`. This is the ONLY case where "omit `published: true` = draft" holds — and it is CREATE (POST of a brand-new article), not UPDATE (PUT/PATCH of an article that is already live).

**Direct publish:** Send `body` + `published: true` in one call → publishes immediately (same end-state as omitting the key on an already-published article).

**Does NOT work:** Two-step (body first, then separate `published: true` call) — the second call is a no-op.

### Delete article (DRAFT or published)

```
DELETE /api/v3/articles/:id
```

Returns HTTP 204 No Content on success. A subsequent `GET /api/v3/articles/:id` on the same ID returns 404.

Works on both DRAFT and published articles — no distinction at the API level.

**empirical 2026-05-08:** verified by creating draft article 3803218 → `DELETE` returning 204 → `GET` returning 404.

**Use case:** <internal-bot> answer-to-doc loop's Discard action. Prefer DELETE over leaving accumulated draft pollution in the admin index — draft articles created by the bot but never actioned pile up in `/admin/dashboard/published` and clutter the author view.

### List categories

```
GET /api/v3/categories?limit=100&page=N
```

Paginated — walk `meta.total_pages`. **empirical (2026-10-08, <clickup-task-id>):** the default page size is 25 (`meta.limit: 25`, `total_pages: 10`); `limit=100` is honored (`total_pages: 3`, `total_count: 235`), and the walk returns every category, nested ones included (e.g. `Development` `443142` is present; 26 have `parent: null`). Each row carries `parent {id,name}`, `hierarchy[]`, `accessibility`, and `published_questions[]` / `draft_questions[]` (article stubs incl. secondary-category membership, so their lengths differ from a count of articles whose *main* category is that id — 71 of 235 categories differed). `GET /categories/<id>` exposes no group/user permit list for a private category. *(Superseded 2026-05-08 note: "returns top-level categories only, 25" — that was page 1 of the default page size.)*

### Create category

```
POST /api/v3/categories
{ "category": { "name": "Name", "accessibility": 0, "parent_id": 1366806, "codename": "optional-custom-slug" } }
```

**Required wrapper:** `{"category": {...}}` — same as articles.

**Fields:**
- `name` (required) — display name.
- `accessibility` — `0` internal (default for new), `1` public.
- `parent_id` — omit for top-level; set to a parent category id for a subcategory. **empirical 2026-05-12:** verified by creating 6 subcategories under id 1366806 (`Automations and Engineering`); hierarchy populated correctly on GET.
- `codename` — optional URL slug override. **empirical 2026-05-12:** auto-generated from `name` if omitted (e.g. `"Bots & Personas"` → `bots-personas`). If the auto-generated slug collides with an existing codename (live OR previously-used — see retention below), POST returns HTTP 422 `{"codename": ["has already been taken"]}`. Workaround: pass an explicit `codename` distinct from any prior value.

### Update category

```
PUT /api/v3/categories/:id
{ "category": { "name": "...", "parent_id": 1366806, "codename": "...", "accessibility": 0, "description": "..." } }
```

**Reparenting works.** **empirical 2026-05-12:** PUT with `parent_id: <new_id>` moves the category and the post-update `hierarchy` array reflects the new parent. Reparenting an old top-level category under a new parent does NOT change the URL slug of its child articles — only the category's own codename does.

#### Codename retention — categorical one-way trip ⚠

**empirical 2026-05-12:** Helpjuice retains every codename a category has ever used. The retention applies globally and is case-insensitive:

- Setting `codename: salesforce` on a category whose previous codename was `salesforce` returns `{"codename": ["has already been taken"]}` even when no other live category holds that codename.
- Case variants collide: `salesforce`, `Salesforce`, `SalesForce` are all treated as the same reserved slug.
- The reservation survives even after the previous holder has been renamed and no record currently uses the slug.
- No `/url_redirects`, `/redirects`, `/category_redirects`, or `/categories/:id/redirects` v3 endpoint exists (all 404). The old `/<old-codename>/<article-slug>` URL also returns a hard 404 — there is no automatic redirect from the prior slug.

**Operational consequence:** changing a category's codename is irreversible via the v3 API and breaks every existing `/<old-codename>/*` URL with no fallback. Reclaiming a previously-used codename appears to require Helpjuice support.

**Recovery path during the <clickup-task-id> Phase 4 sync (2026-05-12):** existing `Salesforce` category (id 443330, codename `salesforce`) needed to move under a new parent `Automations and Engineering` (id 1366806). PUT with `parent_id` alone returned `{"codename": ["has already been taken"]}` against the category's own current value (apparent self-validation bug). Workaround was a two-step swap — `PUT codename=salesforce-tmp` (succeeded), then `PUT parent_id=1366806` (succeeded), then attempt to restore `codename=salesforce` (failed — retention block). Settled on `salesforce-internal` as a permanent codename; the 37 internal articles below it now live at `/salesforce-internal/<slug>` and the historical `/salesforce/<slug>` paths return 404.

### Delete category

```
DELETE /api/v3/categories/:id
```

**empirical 2026-05-12:** returns HTTP 204 on success, 404 on missing. Subcategories cascade-delete with the parent (`DELETE` on parent → child GET returns 404).

### Keywords (a.k.a. tags)

Helpjuice calls them **keywords** in the API and the response body, but the editor UI labels them **tags** at the bottom of the article editor. They drive site search.

```
PUT /api/v3/articles/:id
{ "article": { "tag_names": ["alpha", "beta", "gamma"] } }
```

**Field name:** `tag_names` (array of strings) — matches the editor form field `article[tag_names][]`. Other names (`keywords`, `keyword_names`, `keyword_list`, `keywords_attributes`) are silently ignored — the API returns 200 with the unchanged keyword list.

**Replace, not append:** sending `tag_names` REPLACES the entire keyword set on the article. Send `["alpha"]` and you'll have exactly one keyword — anything not in the array gets removed. To add to existing, GET first, merge, then PUT.

**Read field:** the response returns them as `keywords: [{id, name}, ...]`. To get a clean string list: `jq '.article.keywords | map(.name)'`.

Verified 2026-05-02 against article 3795764.

## <your-org>-Specific IDs

| Category | ID |
|----------|-----|
| Sales Management | `1348715` |
| Development | `443142` |
| Automations | `1350391` |
| Development Guides | `1350540` |
| Automations and Engineering (internal, engineering docs) | `1366806` |
| Article: AE Console Release Notes (internal, Sales Management `1348715`; updated by the `ae-release-notes` skill) | `3972268` |
| Article: AE Console Roadmap (internal, Sales Management `1348715`; updated by the `ae-release-notes` skill) | `3972269` |

Reference article for house style: `1912906` ("Create a KB Article").

## Editor URLs

Helpjuice's admin internally calls articles "questions". The API does not return an `edit_url` (always null) — construct it manually:

| Purpose | URL pattern |
|---------|-------------|
| Edit (admin, SAML-gated) | `<internal-url> |
| Edit (slug variant) | `<internal-url> |
| Public view | `.article.url` from the API response (already a full URL) |

Verified 2026-05-02 — `/admin/en_US/questions/<id>` (no `/edit` suffix) loads "<Article Name> - Article Editor". The `/admin/en_US/questions/<id>/edit` pattern returns a Helpjuice 500. Both `/admin/articles/<id>` and `/admin/answers/<id>` variants 404. Discovered by scraping the admin's `/admin/dashboard/published` index for in-the-wild edit links.

## Access Control

Helpjuice enforces access at two layers: **article-level** (the whole article) and **block-level** (Internal Info Blocks inside an article body).

### Article-level access

Set via JSON fields on POST/PUT:

| Field | Values | Meaning |
|-------|--------|---------|
| `accessibility` | `0` | **Internal** — signed-in KB users only (default for engineering/ops docs) |
| `accessibility` | `1` | **Public** — published to the public `<knowledge-base>.io` site |
| `accessibility` | `2` | **Private** — draft/hidden, not listed |
| `accessibility` | `4` | **URL only** — direct-link only, hidden from search; takes its public-vs-internal flavor from the parent category (see "Visibility ↔ category gating" below) |
| `group_ids` / `user_ids` | `[id, ...]` | Grant a private article to groups/users — **write-only** (docs-confirmed: help.helpjuice.com/en_US/api-v3/using-api-v3); reads never return them, so check access with "Per-user access (Helpjuice as the user)" |
| `is_private` | `true`/`false` | Legacy; prefer `accessibility` |

Example — create a private article granted to MMN Staff (the shape Thread-Learning's `Build Draft Request` sends):

```json
{"article": {"name": "<title>", "body": "<html>", "category_id": 1366806, "accessibility": 2, "visibility_id": 2, "group_ids": [21309]}}
```

**`group_ids` grants on create; `private_to_groups` does not.** Grants are checked as a member and a non-member of the group (both viewers), after the approve-style `PUT {"article":{"body":…,"published":true}}` so viewers are eligible (an unpublished private article also needs `admin`/`draft_writer`, see "Measured rules").

**Probe: private grant field on `POST /articles`** (two throwaway articles in category 1366806, then `PUT {body, published:true}`, then `curl -I -u "<user>:" "$B/articles/<id>?api_key=$K"`; both deleted, `GET` → 404)

Captured: 2026-10-08T20:59:28Z

```
A: {"accessibility":2,"visibility_id":2,"private_to_groups":[21309]} → id 3968139 accessibility 2
   after publish PUT: accessibility 2, published true
   heb@mspmedianetwork.com (MMN Staff) 403   <service-email> (<your-org> Staff) 403   ← grant NOT applied
B: {"accessibility":2,"visibility_id":2,"group_ids":[21309]} → id 3968140 accessibility 2
   after publish PUT: heb@mspmedianetwork.com 200   <service-email> 403              ← grant applied, and it survives the body+published PUT
```

> **`accessibility` is READ-ONLY on PUT — write visibility via `visibility_id`.** **empirical (2026-06-09):** `PUT /articles/<id> {"article":{"accessibility":2}}` returns HTTP 200 but the article's `accessibility` stays unchanged (silent no-op). The write-side field is **`visibility_id`** — `PUT {"article":{"visibility_id":2}}` flipped article 3843527 from `0`→`2` (verified via fresh GET). Mapping observed: `visibility_id:1`=public, `visibility_id:2`=private; the integer matches the `accessibility` value it sets. The `accessibility` column above documents the READ shape (and the POST-create shape, where `accessibility` IS honored — verified on the same article's create); on PUT, use `visibility_id`. Pair with `group_ids` / `user_ids` for group-restricted private. (Found setting the AI Acceptable Use Policy to Private — task <clickup-task-id>.)

Current KB split (as of 2026-04-29): **~100 internal**, **~672 public**. Defaults — engineering/automation articles are `accessibility: 0`, customer-facing how-tos are `accessibility: 1`.

#### Visibility ↔ category gating

Helpjuice enforces that an article cannot be **more permissive than its parent category**. Setting `accessibility: 1` on an article inside a category whose own `accessibility` is `0` returns:

```
HTTP 422 {"accessibility":["Cannot be Public parent being Internal."]}
```

Verified 2026-05-03 against article 3796191 in category 1350391 (Automations, accessibility: 0).

**On create the gate is silent.** `POST /articles` with `accessibility: 1` and an internal `category_id` returns HTTP 200 and creates the article with `accessibility: 0` (empirical 2026-10-08: category 1366806 → article 3968157 `accessibility 0`, deleted). The same POST into a public category (443410 Voicemail) created `accessibility 1` (article 3968156, deleted).

To make an article public-but-unlisted, the article needs membership in at least one **public** category. See [Multi-category publishing](#multi-category-publishing) below.

### Multi-category publishing ("Main Category" + "Also-In")

An article can belong to **multiple categories simultaneously** — including categories with different `accessibility` values. Each category produces its own `/<category-codename>/<slug>` URL, and the article is reachable from all of them.

**Live example:** Article 1933891 ("Professional Migration Service") lives in two categories:

- `443135` Hosted Voice — `accessibility: 1` (public) — primary; URL `<internal-url>
- `443141` Client Success — `accessibility: 0` (internal) — also-in; URL `<internal-url>

The article's own `accessibility` is `1` (public). The public Hosted Voice category (primary) exposes it on `<knowledge-base>.io` for customers; the Client Success "also-in" membership gives staff a way to find it through the staff KB navigation.

#### Write — `category_ids` array

The v3 API field is **`category_ids`** (array). First element is the **primary/main** category (defines the article's `.url` and the visibility gate); remaining elements are **"Also-In"** sidebar memberships. Send it on PUT alongside `visibility_id`, `published`, and (when changing membership) the `body` — the API silently no-ops `category_ids` if sent in isolation.

```bash
# Set primary = Hosted Voice (public), also-in = Client Success (internal)
curl -X PUT "<internal-url> \
  -H "Authorization: $HELPJUICE_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"article": {
    "category_ids": [443135, 443141],
    "visibility_id": 1,
    "published": true
  }}'
```

The same call also handles the move from internal-only to public — the primary's accessibility (1) becomes the article's effective visibility, satisfying the parent-category gate. Without this, attempting `accessibility: 1` on an internal-categorized article returns 422.

#### Read — only the primary surfaces in the article object

The article object's `.category` is **singular** and reflects only the primary category. Verified 2026-05-03 — `?include=categories`, `?expand=categories`, and `?with_categories=true` all return the same single-category shape; there is no `categories[]` or `linked_categories` field on the article. Sub-resource endpoints (`/articles/:id/categories`, `/categories/:id/articles`) return 404.

To find every category an article belongs to, query from the **category** side:

```bash
# Walk every category and check published_questions for the article id
PAGES=$(curl -s "$BASE/categories?limit=100&page=1" -H "Authorization: $K" | jq -r '.meta.total_pages')
for cat_id in $(for p in $(seq 1 "$PAGES"); do curl -s "$BASE/categories?limit=100&page=$p" -H "Authorization: $K" | jq -r '.categories[].id'; done); do
  curl -s "$BASE/categories/$cat_id" -H "Authorization: $K" \
    | jq --arg id "$ARTICLE_ID" -r '.category | (.published_questions // [])[] | select(.id == ($id | tonumber)) | "\($cat_id)\t\(.url)"'
done
```

#### Gotcha: `category_ids` no-ops without companion fields

`PUT {"article":{"category_ids":[a,b]}}` returns HTTP 200 but does not change the membership. Pair it with `visibility_id`, `published`, and the `body` (or at least the fields you'd send for a normal publish) in the same call. This is why a one-shot `category_ids` probe looks like the field is unsupported — it isn't, just silently rejected when sent alone. Tracked here so future runs don't repeat the misdiagnosis.

### Groups

| ID | Name | Auto-assign |
|----|------|-------------|
| `21307` | White Label Partners | manual |
| `21308` | <your-org> Staff | `@<your-org>` email |
| `21309` | MMN Staff | `@mspmedianetwork.com` email |
| `22433` | Channel Partners | manual |
| `25395` | GTN Dev Team | `@gtnllc.com` email |

Fetch current list: `GET /api/v3/groups?limit=100` → `{groups:[{id,name,auto_groups,users,smart_load,created_at}], meta}`. There is no group named "<your-org> Internal"; the automated KB scope of that name is accessibility-based (`knowledge-platform.md` "Automated callers").

**Probe: live groups** (`curl -s "$B/groups?limit=100" -H "Authorization: $K" | jq -c '.groups[] | {id,name}'`)

Captured: 2026-10-08T20:50:21Z

```
{"id":21307,"name":"White Label Partners"}
{"id":21308,"name":"<your-org> Staff"}
{"id":21309,"name":"MMN Staff"}
{"id":22433,"name":"Channel Partners"}
{"id":25395,"name":"GTN Dev Team"}
```

### Block-level: Internal Info Blocks

Helpjuice supports per-block visibility inside a single article ("Internal Info Blocks") — a section of an otherwise-public article that only signed-in members of specific groups can see. Live example: [`<knowledge-base>.io/en_US/integrations/url-call-popup`](<internal-url>) renders an "Internal Team Guidance" block visible only to <your-org> Staff.

**You CAN create, update, and delete internal blocks via the API.** Verified 2026-04-19. The server encrypts the inner content on save; no editor-only step is required.

#### How the block is stored

After save, Helpjuice stores it with an AES-encrypted blob:

```html
<div class="helpjuice-internal-block"
     data-permitted-groups="21308"
     data-permitted-users=""
     data-controller="editor--internal-block"
     data-internal-block-id="272713753513110316"
     data-encrypted-content="VTJGc2RHVmtYMS96NVc4ZHF1am9E...=.<cloudflare-id>"></div>
```

#### How to author one via PUT

Send the **unencrypted** form as the inner content — Helpjuice encrypts it on save and fills in `data-encrypted-content` + `data-internal-block-id` automatically:

```html
<div class="helpjuice-internal-block"
     data-permitted-groups="21308"
     data-permitted-users=""
     data-controller="editor--internal-block">
  <div class="helpjuice-internal-block-body">
    <div class="raw-html-embed">
      <h3>🎯 Internal Team Guidance</h3>
      <p>Content visible only to permitted groups...</p>
    </div>
  </div>
</div>
```

Wrap the actual internal HTML in `<div class="raw-html-embed">` so Helpjuice treats it as a single opaque block during re-render. Everything inside that div is encrypted together.

#### Attributes

| Attribute | Purpose |
|-----------|---------|
| `data-permitted-groups` | Comma-separated group IDs (e.g. `"21308"` = <your-org> Staff, `"21308,25395"` = <your-org> Staff + GTN Dev) |
| `data-permitted-users` | Comma-separated user IDs; leave empty when using groups |
| `data-controller` | Always `"editor--internal-block"` |
| `data-internal-block-id` | Assigned by server on first save; preserve on subsequent PUTs |
| `data-encrypted-content` | Set by server; do not author manually |

#### Round-trip rules

- **Updating the whole article but keeping an existing block unchanged:** GET the article, copy the existing `<div class="helpjuice-internal-block" ... data-encrypted-content="..."></div>` verbatim into your new body, PUT. The encrypted blob re-saves cleanly.
- **Editing an existing block's content:** GET with `?processed=true`, extract the `.answer.processed_body` (which has the block expanded back to `<div class="raw-html-embed">...</div>`), edit inside it, PUT the edited form. Server re-encrypts.
- **Changing permitted groups:** PUT with the new `data-permitted-groups` value and the existing `data-encrypted-content`. Server re-issues encryption on save.

#### Reading internal blocks (verification)

- `GET /articles/:id` (default) — `.article.answer.body` shows the encrypted form.
- `GET /articles/:id?processed=true` — `.article.answer.processed_body` shows the decrypted inner HTML (API key alone acts as super-admin for decryption).
- `GET /articles/:id?processed=true&api_key=<key>` with **HTTP Basic Auth** `-u "<user email>:"` (blank password) renders as that user (Helpjuice "User Identification"). The key MUST go in the `api_key` query param: a key sent as the `Authorization` header replaces curl's Basic header, and the request then runs as the account owner. See "Per-user access (Helpjuice as the user)".

#### Quick authoring example

```bash
eval "$($HOME/.claude/scripts/fetch-secrets.sh <knowledge-base>)"
curl -s -X PUT "<internal-url> \
  -H "Authorization: $HELPJUICE_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"article":{"body":"<p>Public intro</p><div class=\"helpjuice-internal-block\" data-permitted-groups=\"21308\" data-permitted-users=\"\" data-controller=\"editor--internal-block\"><div class=\"helpjuice-internal-block-body\"><div class=\"raw-html-embed\"><p>Staff-only content</p></div></div></div>"}}'
```

Verify after PUT:
```bash
curl -s "<internal-url> -H "Authorization: $HELPJUICE_API_KEY" \
  | jq -r '.article.answer.body' | grep -o 'data-encrypted-content' # should find 1 match
```

## Per-user access (Helpjuice as the user)

Who may see an article is decided by asking Helpjuice as the caller's own Helpjuice user. Every <internal-bot> KB path (Teams, semantic search, the <internal-bot>-gateway) does this through the n8n **Helpjuice Access Check** (`nQfH6pcSmgEwKI0y`) — design, callers and failure behaviour: `docs/runbooks/knowledge-platform.md`.

### The impersonation recipe

```bash
# K = HELPJUICE-API-KEY (see Auth). The key goes in the QUERY STRING; the user goes in Basic auth.
curl -s -I -u "<service-email>:" "<internal-url>   # HEAD → 200 visible / 403 not visible / 404 missing
```

- docs-confirmed: help.helpjuice.com/en_US/api-v3/using-api-v3 "User Identification" — HTTP Basic auth with the user's email and a blank password makes Helpjuice "perform the request as if that user were logged in".
- **Header key + Basic user does NOT impersonate.** curl's `-H "Authorization: <key>"` replaces the `-u` Basic header, so the request runs as the account owner; Basic alone (no key) is 403 for everyone. This is why the 2026-06-28 probe ([P8], spec `2026-06-28-<internal-bot>-gateway-per-user-identity-scoping-design.md`) and an earlier 2026-10-08 probe both concluded "no render-as-user path" — both sent the key as a header.
- The email must match the Helpjuice user's stored email exactly as stored: `DENA@<your-org>.CO` → 401. Resolve it first with `GET /users?filter[email]=<email>` (the filter itself is case-insensitive) and impersonate with the returned `email`.
- Unknown or deactivated users → **401** (`<service-email>`; also kevin@, veronica@, victoria@ and two non-staff accounts that `/users` still lists). Being listed in `/users` is therefore not proof of an active account: verify a caller by making one request as them (the Access Check uses `HEAD /articles?limit=1`) before trusting their role.
- `HEAD` returns the same status with no body.

**Probe: impersonated article reads follow the caller's permissions** (`curl -s -o /dev/null -w '%{http_code}' -u "<user>:" "$B/articles/<id>?api_key=$K"` for header-key vs query-key, then query-key across users)

Captured: 2026-10-08T19:00Z

```
hdr-key + -u dena 2402244: 200        (runs as owner)
-u dena only      2402244: 403
qkey no user      2402244: 200
qkey + dena       2402244: 403
qkey + DENA@<your-org>.CO 2402244: 401
HEAD 1998780 dena 200 | marissa 200      HEAD 2402244 dena 403 | marissa 200      HEAD 999999999 dena 404
```

### What the API does not expose

`GET /articles/<id>` has no grant list (no `private_to_groups` / `private_to_users` / `group_ids` / `user_ids`) on any of the 88 private articles, raw, `?processed=true` or `?include=...`; `/articles/<id>/groups|users|permissions|visibility|accesses` → 404; `/api/v2/articles/<id>` → 404; `/api/v2/questions/<id>` → 403. `group_ids` / `user_ids` are documented as **write** fields only. The grants exist in the admin editor (`/admin/en_US/questions/<id>`: `input[name="article[accessor_ids][]"]`, `data-method="delete"` = granted), which needs a browser session — evidence only, never a runtime source.

### Measured rules (why the Access Check may skip some live calls)

**Probe: impersonated `GET /articles/<id>` vs the admin-UI grant lists** (all 88 private articles × <service-email> viewer/<your-org> Staff, <service-email> admin/<your-org> Staff, marissa@<voip-mcp>.com viewer/White Label Partners, heb@mspmedianetwork.com viewer/MMN Staff; grants scraped read-only from the admin editor with the Playwright-<internal-bot> Edge profile)

Captured: 2026-10-08T19:15Z

```
compared 352 mismatches 0
rule: superadmin → all; published private → user in a granted group or user list; unpublished private → also needs admin/draft_writer
dena 200 68 / 403 20   blaine 200 75 / 403 13   marissa@<voip-mcp>.com 200 4 / 403 84   heb@mspmedianetwork.com 200 54 / 403 34
1998780 (CompTIA) grants: group_21309, group_21308, user_1158534 → visible to every <your-org> Staff member, dena included
```

**Probe: non-private articles by role** (impersonated GET; 20 internal drafts, 10 public drafts, 15 internal published, 15 public published, 3 URL-only × 5 users)

Captured: 2026-10-08T19:20Z

```
published 0/1 and URL-only 4:  200 for viewer, draft_writer, admin, WLP viewer, MMN viewer (all 5)
unpublished 0/1:               200 admin + draft_writer; 403 every viewer
```

- **Do not use the impersonated LIST endpoint as the decision.** `GET /articles?filter[accessibility]=2` as a viewer omits 1959447, 1959449 and 2205431 although their grants include <your-org> Staff and the impersonated article GET returns 200; `/search` as the user does filter (dena's "Cloudflare WARP" search omits 2402244).
- **Users:** 59 in `/users`; roles `superadmin` 8 · `admin` 5 · `draft_writer` 2 · `viewer` 44; groups 21307 White Label Partners, 21308 <your-org> Staff (auto-group `@<your-org>`), 21309 MMN Staff, 22433 Channel Partners, 25395 GTN Dev Team.
- **Internal blocks:** 98 articles carry `helpjuice-internal-block` elements with `data-permitted-groups`; all of them include 21308 (<your-org> Staff), so no block is hidden from an `@<your-org>` caller today (empirical 2026-10-08, scan of all 2,576 bodies).

### Internal-block stripping (gateway side)

The admin key returns `helpjuice-internal-block` elements with their content decrypted. The gateway strips blocks the caller is not permitted for before returning any article body. A block's permission is gated by `data-permitted-groups` (comma-separated group IDs) and/or `data-permitted-users` (comma-separated user IDs). A block with neither attribute is staff-wide. Stripping is depth-aware and recurses into permitted blocks so nested blocks with stricter permissions are independently evaluated. Group IDs in `data-permitted-groups` are the same IDs returned by `GET /users` in the `groups[].id` array (e.g. `21308` = <your-org> Staff).

## Article Template

**Every article body starts with a blue Info Callout containing the Scope block — never a plain `<h2>Scope</h2>`.** Use a green Success Callout for discrete requirement lists, and a red Danger Callout for warnings. Source: article 1912906.

### Scope (required — blue Info Callout)

**Exactly two lines: `Intended Audience` + one sentence.** No `Time to read`, no
`Prerequisites`, no `Outcome` — prerequisites belong in the separate green Requirements
callout below.

```html
<div class="helpjuice-callout info">
<div class="helpjuice-callout-body">
<h3 id="scope-0" data-toc="false">Scope</h3>
<p><strong>Intended Audience: </strong><!-- controlled label — see below --></p>
<p><!-- one sentence describing what the article covers --></p>
</div>
<div class="helpjuice-callout-delete"> </div>
</div>
```

**Verified against ground truth** (empirical (2026-07-30): `GET /articles/1912906?processed=true`,
first callout extracted verbatim):

```html
<p><strong>Intended Audience: </strong>Solutions Hub Department</p>
<p>This article outlines how to create a knowledgebase article according to <your-org> standards. All articles should match the standards outlined here before being submitted for review.</p>
```

#### `Intended Audience` is a controlled vocabulary — not free text

Resolve to the **tightest group that actually performs or needs the process**:

- **Department** — the active `SFDC_Employee__c.Department__c` picklist: Administration ·
  Client Experience · Client Success · Core Services Engineering · Development · ELT · Finance ·
  Human Resources · Marketing · MSP Media Network · Operations · Sales · Solutions Hub ·
  Technical Services · Telco Services.
- **Role** — a specific role that owns the process regardless of department.
- **Broad / external** — All Users · White Label Partners · Channel Partners · Customers.

Invented descriptors are invalid. `Engineering Staff`, `Engineering`, and
`<your-org> engineers who operate …` are **NOT** valid labels — resolve to the real department
(e.g. `Core Services Engineering`). Several existing articles in the "Automations and
Engineering" category carry invalid labels; do not pattern-match off them, they are drift
pending cleanup.

> ⚠ **This block previously documented a four-field Scope** (`Intended Audience` /
> `Time to read` / `Prerequisites` / `Outcome`) with `Engineering Staff` as an example — both
> contradicted article 1912906. Corrected 2026-07-30 after the divergence was caught mid-authoring.
> Per the `docs` skill: **1912906 wins; fix the runbook.** A `scripts/kb-scope-drift-check` guard to catch this
> automatically is **proposed, not built** — `ls scripts/kb-scope-drift-check` returns
> "No such file or directory" (verified 2026-07-30). Until it exists, re-read 1912906 when
> touching this template.

### Requirements (optional — green Success Callout)

Use when there's a discrete prerequisite list beyond what fits in Scope.

```html
<div class="helpjuice-callout success">
<div class="helpjuice-callout-body">
<h3 id="requirements-1" data-toc="false">Requirements</h3>
<ul>
<li>Item one</li>
<li>Item two</li>
</ul>
</div>
<div class="helpjuice-callout-delete"> </div>
</div>
```

### Warning (optional — red Danger Callout)

Use for destructive actions, production impact, or irreversible steps.

```html
<div class="helpjuice-callout danger">
<div class="helpjuice-callout-body">
<h3 id="warning-2" data-toc="false">Warning</h3>
<p>This action is destructive / affects production / etc.</p>
</div>
<div class="helpjuice-callout-delete"> </div>
</div>
```

### Body conventions

- `<h1>` for section info-block titles; `<h2>`/`<h3>` for nested subsections
- Active voice, present tense, second person ("you")
- One action per numbered step, with expected result
- `<pre><code class="language-bash">` for shell blocks; `language-python`, `language-java`, etc. for other langs
- Tables for quick-reference (symptom → action) — not for prose
- Brand neutral — no "<your-org>"/"<VOIP-BRAND>" in article body; use generic role names
- Cross-link related articles by `<internal-url> URL

### Multi-audience: one article with tabs, not two articles

When a doc covers multiple audiences with overlapping content (e.g. general staff overview + engineering deep-dive, or end-user steps + admin notes), use **one article with tab sections per audience** rather than two separate articles. Helpjuice's `helpjuice-tab` primitive (see Formatting Cookbook below) is the canonical structure for this.

- Single Scope callout at top — set the most general audience there ("All Employees") and note time-to-read for each tab in the Time-to-read field.
- One tab per audience. Use accordions instead when the second audience is "click to expand if you need detail" rather than parallel content.
- Default to one article. Only split when the audiences are genuinely separate flows that share no content.

Reference: article 3796191 ("Local LLM Stack: Overview & Engineering Reference") uses this pattern — Overview tab for all employees, Engineering Reference tab for Development Department.

## Formatting Cookbook

> **What this is:** every editor primitive Helpjuice supports, with the exact HTML the API stores after save. Each entry was round-tripped through the internal reference article (article ID `3795764`) on 2026-05-02. To verify the live shape, GET that article and grep for `id="primitive-<slug>"`.

> **How to find the right entry:** Ctrl-F for the visual treatment you want ("yellow box", "tabs", "expandable", "video", "branch"). Each entry shows when to use it and the exact HTML to drop into your `body`.

> **Machine-readable IDs:** every entry has a `<!-- primitive: <slug> -->` marker. Verification scripts and the audit pipeline key off these — heading text is human-friendly and may evolve, but the slugs are stable.

### Callout — Info (blue)
<!-- primitive: callout-info -->

When to use: Required Scope block at the top of every article; general FYI notes.

```html

<div class="helpjuice-callout info">
<div class="helpjuice-callout-body">
<h3 id="callout-info-demo" data-toc="false">Info Callout (blue)</h3>
<p>Use for the required Scope block at the top of every article, and for general notes.</p>
</div>
<div class="helpjuice-callout-delete"> </div>
</div>
```

**Tested ✓ (article `3795764`, 2026-05-02)**

### Callout — Success (green)
<!-- primitive: callout-success -->

When to use: Discrete prerequisite/requirement lists; happy-path completion.

```html

<div class="helpjuice-callout success">
<div class="helpjuice-callout-body">
<h3 id="callout-success-demo" data-toc="false">Success Callout (green)</h3>
<p>Use for discrete requirement lists, completion confirmations, or 'happy path' guidance.</p>
</div>
<div class="helpjuice-callout-delete"> </div>
</div>
```

**Tested ✓ (article `3795764`, 2026-05-02)**

### Callout — Danger (red)
<!-- primitive: callout-danger -->

When to use: Destructive actions, production impact, irreversible steps.

```html

<div class="helpjuice-callout danger">
<div class="helpjuice-callout-body">
<h3 id="callout-danger-demo" data-toc="false">Danger Callout (red)</h3>
<p>Use for destructive or production-impacting actions, security warnings, irreversible operations.</p>
</div>
<div class="helpjuice-callout-delete"> </div>
</div>
```

**Tested ✓ (article `3795764`, 2026-05-02)**

### Callout — Warning (yellow)
<!-- primitive: callout-warning -->

When to use: Non-blocking caution; "watch out for X" without "do not".

```html

<div class="helpjuice-callout warning">
<div class="helpjuice-callout-body">
<h3 id="callout-warning-demo" data-toc="false">Warning Callout (yellow)</h3>
<p>Use for non-blocking cautions, deprecations, edge cases that need extra care.</p>
</div>
<div class="helpjuice-callout-delete"> </div>
</div>
```

**Tested ✓ (article `3795764`, 2026-05-02)**

### Code Block
<!-- primitive: code-block -->

When to use: Shell/code samples. Set `class="language-<lang>"` on `<code>` for syntax highlighting. Demonstrated languages: bash, python, typescript, json — see `scripts/helpjuice-audit/inventory.json` for the full corpus set.

```html

<p><strong>bash</strong></p>
<pre><code class="language-bash">echo "hello world"
</code></pre>
<p><strong>python</strong></p>
<pre><code class="language-python">print("hello world")
</code></pre>
<p><strong>typescript</strong></p>
<pre><code class="language-typescript">console.log("hello world");
</code></pre>
<p><strong>json</strong></p>
<pre><code class="language-json">{"hello": "world"}
</code></pre>
```

**Tested ✓ (article `3795764`, 2026-05-02)**

### Table — Basic
<!-- primitive: table-basic -->

When to use: Quick-reference lookups (symptom → action). Not for prose.

```html

<table>
<thead><tr>
<th>Col A</th>
<th>Col B</th>
</tr></thead>
<tbody>
<tr>
<td>row 1 a</td>
<td>row 1 b</td>
</tr>
<tr>
<td>row 2 a</td>
<td>row 2 b</td>
</tr>
</tbody>
</table>
```

**Tested ✓ (article `3795764`, 2026-05-02)**

### Blockquote
<!-- primitive: blockquote -->

When to use: Pulled excerpts, definitions, important non-coloured emphasis.

```html

<blockquote><p>This is a blockquote — use it for pulled excerpts or important callouts that don't merit a full coloured Callout.</p></blockquote>
```

**Tested ✓ (article `3795764`, 2026-05-02)**

### Tabs
<!-- primitive: tabs -->

When to use: Parallel content variants where the reader picks one (e.g., macOS / Windows / Linux instructions). Note: each tab is a sibling div, not nested under a tab-list — see HTML for the flat structure.

```html

<div class="helpjuice-tab" data-controller="editor--toggle-element">
<h2 class="helpjuice-tab-title">Tab One</h2>
<div class="helpjuice-tab-body active" data-editor--toggle-element-target="body">
<p>Content for the first tab.</p>
</div>
<div class="helpjuice-tab-toggle"> </div>
<div class="helpjuice-tab-delete"> </div>
</div>
<div class="helpjuice-tab" data-controller="editor--toggle-element">
<h2 class="helpjuice-tab-title">Tab Two</h2>
<div class="helpjuice-tab-body active" data-editor--toggle-element-target="body">
<p>Content for the second tab.</p>
</div>
<div class="helpjuice-tab-toggle"> </div>
<div class="helpjuice-tab-delete"> </div>
</div>
```

**Tested ✓ (article `3795764`, 2026-05-02)**

### Accordion / Collapsible
<!-- primitive: accordion -->

When to use: Optional or supplementary detail that shouldn't crowd the main flow. Mirrors the tab structure with `data-controller="editor--toggle-element"`.

```html

<div class="helpjuice-accordion" data-controller="editor--toggle-element">
<h2 class="helpjuice-accordion-title">Click to expand</h2>
<div class="helpjuice-accordion-body active" data-editor--toggle-element-target="body">
<p>Hidden content shown only when the user clicks the accordion title.</p>
</div>
<div class="helpjuice-accordion-toggle"> </div>
<div class="helpjuice-accordion-delete"> </div>
</div>
```

**Tested ✓ (article `3795764`, 2026-05-02)**

### Glossary Tooltip
<!-- primitive: glossary -->

When to use: Inline jargon definition shown on hover. Speculative shape — no in-the-wild corpus example, but Helpjuice round-trips this verbatim.

```html

<p>The <span class="helpjuice-glossary" data-term="VoIP" data-definition="Voice over IP — telephony delivered over the internet.">VoIP</span> term has a hover tooltip.</p>
```

**Tested ✓ (article `3795764`, 2026-05-02)**

### Image Frame
<!-- primitive: image-frame -->

When to use: Screenshots and diagrams. Real shape uses `<figure class="image">`; the `<figcaption>` element is optional.

```html

<figure class="image"><img src="https://static.helpjuice.com/helpjuice_production/uploads/upload/image/14706/direct/1777569829560/CleanShot%202026-04-30%20at%2001.45.12%402x.png" alt="placeholder" width="800" height="600"></figure>
```

**Tested ✓ (article `3795764`, 2026-05-02)**

### Embed (iframe — video, etc.)
<!-- primitive: embed-iframe -->

When to use: Embedded YouTube/Loom/Vimeo or any iframe widget. CKEditor wraps it in `<div class="raw-html-embed">` automatically.

```html

<div class="raw-html-embed">
<iframe src="https://www.youtube-nocookie.com/embed/aaaaaaaaaaa" width="100%" height="450" allowfullscreen loading="lazy" style="border: none;"></iframe>
</div>
```

**Tested ✓ (article `3795764`, 2026-05-02)**

### Decision Tree
<!-- primitive: decision-tree -->

When to use: Multi-branch interactive widget — reader clicks a tab/branch button to reveal that branch's content. Each tab is keyed by a unique `data-id` shared between the button and its content panel.

```html

<div class="helpjuice-decision-tree">
<div class="helpjuice-decision-tree-first-question"><p><span style="font-size:30px;">Decision Tree Demo Question</span></p></div>
<div class="helpjuice-decision-tree-tabs">
<div class="helpjuice-decision-tree-tab-nav">
<div class="helpjuice-decision-tree-button" data-id="demo-tab-a" data-active="active">
<div class="helpjuice-decision-tree-button-text notranslate"><p>Branch A</p></div>
<div class="helpjuice-decision-tree-delete-button"> </div>
</div>
<div class="helpjuice-decision-tree-button" data-id="demo-tab-b" data-active="inactive">
<div class="helpjuice-decision-tree-button-text notranslate"><p>Branch B</p></div>
<div class="helpjuice-decision-tree-delete-button"> </div>
</div>
<div class="helpjuice-decision-tree-add-tab-button"> </div>
</div>
<div class="helpjuice-decision-tree-tab-content" id="demo-tab-a" data-active="active"><div class="helpjuice-decision-tree-tab-content-inner"><p>Content for branch A goes here.</p></div></div>
<div class="helpjuice-decision-tree-add-answers" data-behavior="back"> </div>
<div class="helpjuice-decision-tree-tab-content" id="demo-tab-b" data-active="inactive"><div class="helpjuice-decision-tree-tab-content-inner"><p>Content for branch B goes here.</p></div></div>
</div>
</div>
```

**Tested ✓ (article `3795764`, 2026-05-02)**

### Hyperlink
<!-- primitive: hyperlink -->

When to use: Internal article links (using `/_questions/<id>` so Helpjuice resolves the public URL at render time) and external links. External links should carry `target="_blank" rel="noopener noreferrer"`.

```html

<p>Internal article link: <a href="/_questions/1912906">Create a KB Article</a> (Helpjuice resolves <code>/_questions/&lt;id&gt;</code> to the public URL at render time).</p>
<p>External link with security attrs: <a href="https://example.com/" target="_blank" rel="noopener noreferrer">example.com</a></p>
```

**Tested ✓ (article `3795764`, 2026-05-02)**

### File Insert (Files Manager)
<!-- primitive: file-insert -->

When to use: Toolbar's Files Manager button uploads a file to Helpjuice CDN and inserts a hyperlink. Output is a standard `<a href="<helpjuice-cdn-url>">filename.ext</a>` with `target="_blank" rel="noopener noreferrer"` — no Helpjuice-specific class. When authoring via API, upload the file to a stable URL (Helpjuice CDN, Azure Blob, <your-org> CDN) and use the same hyperlink pattern.

```html
<p>Direct link to a hosted file (PDF/DOCX/CSV — link text becomes the visible label):</p>
<p><a href="<internal-url> target="_blank" rel="noopener noreferrer">Example Spec Sheet (PDF)</a></p>
<p>For files behind auth, host them on the <your-org> CDN or Azure Blob and use the same hyperlink pattern. The Files Manager toolbar button uploads to Helpjuice CDN and inserts this exact shape.</p>
```

**Tested ✓ (article `3795764`, 2026-05-02)**

### Highlight
<!-- primitive: highlight -->

When to use: Inline background color highlight on a word or phrase. CKEditor 5 Highlight plugin emits `<mark class="marker-<color>">`. Four colors: yellow (default), green, pink, blue. Prefer semantic callout blocks (callout-warning, callout-success, etc.) for paragraph-level emphasis.

```html

<p>Yellow <mark class="marker-yellow">highlighted text</mark>; green <mark class="marker-green">pass marker</mark>; pink <mark class="marker-pink">attention marker</mark>; blue <mark class="marker-blue">info marker</mark>.</p>
```

**Tested ✓ (article `3795764`, 2026-05-02)**

### Text Color
<!-- primitive: text-color -->

When to use: Inline text color override. CKEditor 5 Font Color emits `style="color: <hex>"` on a `<span>`. Prefer Callouts for semantic emphasis — inline color does not survive theme changes and screen readers ignore it.

```html

<p>Inline text color override: <span style="color:#e42e1b;"><your-org> Red brand text</span>. Prefer Callouts for semantic emphasis — inline color does not survive theme changes and screen readers ignore it.</p>
```

**Tested ✓ (article `3795764`, 2026-05-02)**

### Text Background Color
<!-- primitive: text-background-color -->

When to use: Inline background color on a span. CKEditor 5 Font Background Color emits `style="background-color: <hex>"` on a `<span>`. Prefer the yellow Callout for warnings — inline backgrounds break in dark mode and don't carry semantic meaning.

```html

<p>Inline background color: <span style="background-color:#fff3cd;">soft-yellow background fill</span>. Prefer the yellow Callout for warnings — inline backgrounds break in dark mode and don't carry semantic meaning.</p>
```

**Tested ✓ (article `3795764`, 2026-05-02)**

### Text Styles (Styles dropdown)
<!-- primitive: text-styles -->

When to use: Four named CKEditor 5 styles: `Disable Text Selecting`, `Bordered`, `Spaced`, `Uppercase`. **Zero corpus usage in 2125 articles** (verified by grepping inventory.json for `bordered`, `spaced`, `uppercase`, `disable-text-select`, `noselect`, `user-select`). Round-trip confirmed class names are CKEditor defaults: `.bordered`, `.spaced`, `.uppercase`, `.disable-text-selecting` — Helpjuice preserved them verbatim.

Recommendation: continue avoiding these in favor of semantic primitives. The article carries visual examples so staff can see the rendered output, but these classes carry no Helpjuice-specific behavior.

```html
<p class="bordered">Bordered style — adds a visible border around the paragraph.</p>
<p class="spaced">Spaced style — adds extra letter or word spacing.</p>
<p class="uppercase">Uppercase style — renders as ALL CAPS.</p>
<p class="disable-text-selecting">Disable Text Selecting — prevents the reader from highlighting this text.</p>
```

**Tested ✓ (article `3795764`, 2026-05-02)**

### Fonts (font family + size dropdowns)
<!-- primitive: fonts -->

When to use: Emits inline `style="font-family: <name>"` and `style="font-size: <size>"` on a `<span>`. The defaults Helpjuice uses for body text inherit from the theme; explicit overrides should be rare (e.g. reproducing a quoted spec sheet that uses a specific font). Sizes seen in corpus: `12px`, `14px`, `16px`, `20px`, `24px`, `30px`. Steer authors away from manual font/size overrides — they break theme changes and accessibility.

```html
<p>Font family override: <span style="font-family:Georgia, serif;">Georgia serif sample</span> · <span style="font-family:Courier New, monospace;">Courier New monospace sample</span>.</p>
<p>Font size override (most common in corpus): <span style="font-size:12px;">12px small</span> · <span style="font-size:16px;">16px default body</span> · <span style="font-size:20px;">20px subheading-like</span> · <span style="font-size:30px;">30px display-like</span>.</p>
```

**Tested ✓ (article `3795764`, 2026-05-02)**

### Headings
<!-- primitive: headings -->

When to use: Standard `<h2>` through `<h6>` for article section structure. `<h1>` is reserved by Helpjuice for the article title — do not author it manually. Use `<h2>` for top-level sections, `<h3>` for subsections, `<h4>` sparingly (consider splitting into a separate article instead).

```html

<h2>Heading 2 — main section break</h2>
<p>Used for the top-level section divisions inside an article body.</p>
<h3>Heading 3 — subsection</h3>
<p>Used for distinct steps inside a section.</p>
<h4>Heading 4 — sub-subsection</h4>
<p>Rarely needed; consider whether you should split into a separate article instead.</p>
```

**Tested ✓ (article `3795764`, 2026-05-02)**

### Extra Formatting (Strikethrough / Subscript / Superscript)
<!-- primitive: extra-formatting -->

When to use: Strikethrough (`<s>`) for deprecated steps; Subscript (`<sub>`) for chemical or technical notation; Superscript (`<sup>`) for footnote refs and exponents.

```html

<p>Strikethrough for deprecated steps: <s>old workflow that no longer applies</s>.</p>
<p>Subscript for chemical/technical notation: H<sub>2</sub>O, log<sub>10</sub>(x).</p>
<p>Superscript for footnote refs and exponents: see footnote<sup>1</sup>; the area is r<sup>2</sup>·π.</p>
```

**Tested ✓ (article `3795764`, 2026-05-02)**

### Special Characters
<!-- primitive: special-characters -->

When to use: Toolbar's Special Characters picker inserts the literal Unicode codepoint — no HTML entity wrapper, no extra markup. Common inserts: © ™ ® → ✓ ✗ — …

```html

<p>Common inserts: © (copyright), ™ (trademark), ® (registered), → (arrow), ✓ (check), ✗ (cross), — (em dash), … (ellipsis).</p>
```

**Tested ✓ (article `3795764`, 2026-05-02)**

### Inserted Article
<!-- primitive: inserted-article -->

When to use: Embed another article's content as a fragment. The `[insert-question <id>]` placeholder is server-side replaced with the referenced article. Get the target article ID via the API.

```html

<div class="helpjuice-inserted-article notranslate">
<div class="helpjuice-inserted-article-body">
<h3 id="inserted-article-demo-header" data-toc="true">Inserted Article Demo</h3>
<p class="article-insert-fragment">Excerpt of the inserted article body.</p>
<p>[insert-question 1912906]</p>
</div>
<div class="helpjuice-inserted-article-delete"> </div>
</div>
```

**Tested ✓ (article `3795764`, 2026-05-02)**

### Internal Info Block
<!-- primitive: internal-info-block -->

Per-block visibility (the only primitive scoped to a fragment of an article rather than the whole article). Full HTML shape, attributes, and round-trip rules are documented in [Block-level: Internal Info Blocks](#block-level-internal-info-blocks) above — that section is the canonical reference.

**Tested ✓ (article 3772051, 2026-04-19)** — verified during the original Internal Info Blocks investigation.

### AI Features (none in this Helpjuice instance)
<!-- primitive: ai-features -->

The Helpjuice editor in this account/version exposes **no AI controls** — neither AI Suggest nor AI Rewrite is present in the toolbar (verified 2026-05-02 by enumerating every `.ck-toolbar button.ck-button`). There is nothing to author via API. If Helpjuice adds AI controls later, re-walk the toolbar and update `scripts/helpjuice-audit/snippets/ai-features-notes.md`.

## Webhooks

Helpjuice supports webhooks for article CRUD events. Managed via API or Settings > Integrations > Webhooks in the UI.

### API

```bash
# List webhooks
GET /api/v3/webhooks

# Create webhook
POST /api/v3/webhooks
{"url": "https://example.com/hook", "event": "question_create"}

# Delete webhook
DELETE /api/v3/webhooks/:id
```

### Events

| Event | Fires when |
|-------|-----------|
| `question_create` | New article created |
| `question_update` | Article body or metadata edited |
| `question_publish` | Article published (draft → live) |
| `question_delete` | Article deleted |

### Payload

**Payload format:** `application/x-www-form-urlencoded` with bracket notation:
- `activity_fields[trackable_id]` — article ID
- `activity_fields[action]` — CRUD action
- `event` — event name (e.g. `question_update`)

In n8n, these arrive as flat string keys (e.g. `body["activity_fields[trackable_id]"]`), NOT as nested objects. The connector's Extract Event Data node handles both bracket-notation (production) and nested JSON (testing).

Webhook does NOT include the full article body. Fetch the article separately:

```bash
curl -s "<internal-url> \
  -H "Authorization: $HELPJUICE_API_KEY"
```

### Current webhooks (as of 2026-04-27)

| ID | Event | Target |
|----|-------|--------|
| 1137 | question_create | n8n `knowledge-helpjuice-sync` |
| 1138 | question_update | n8n `knowledge-helpjuice-sync` |
| 1139 | question_publish | n8n `knowledge-helpjuice-sync` |
| 1140 | question_delete | n8n `knowledge-helpjuice-sync` |
| 788 | question_publish | Zapier (legacy, 404) |

## Gotchas

- **No Bearer prefix:** `Authorization: Bearer $KEY` returns "Not allowed". Use `Authorization: $HELPJUICE_API_KEY` (raw key, no prefix). All examples in this runbook follow this pattern.
- **POST also needs `{"article": {...}}` wrapper:** Same as PUT. Sending `name`/`body`/`category_id` at the top level returns 500 with no helpful error message.
- **Draft vs publish:** "Omit `published: true` = draft" holds ONLY for **CREATE (POST of a never-published article)**. On an **already-published article, a body PUT/PATCH publishes immediately** (empirical 2026-06-10 — see Update article section). To hold edits off the public site on a live article, set `visibility_id: 2` (private/draft), not key-omission.
- **`published: true` alone (no body)** → no-op, article stays as-is.
- **Article body is HTML**, not markdown.
- **`GET /api/v3/articles` list: `slug` is None.** The list endpoint returns a `url` field (e.g., `<internal-url>) but `slug` is always null. To build public URLs, extract the path from `url` and transform: `<internal-url>` + path after `/en_US`.

## Troubleshooting

| Symptom | Resolution |
|---------|------------|
| Body PUT on a live article unexpectedly went PUBLIC | Expected — a body PUT on an already-published article publishes immediately regardless of the `published` key (empirical 2026-06-10, article 1933891). To stage edits without going live, set `visibility_id: 2` first (or edit in the admin editor UI). Key-omission does NOT create a draft on a live article. |
| Need to hold edits on a live article for review | `PUT {"article":{"visibility_id":2}}` → private/draft (off public site); re-publish with `{"visibility_id":1,"published":true}`. No API revision history exists — snapshot `answer.body` before editing if you may revert. |
| Two-step update (body first, then `published: true`) no-ops | Second call is a no-op on the draft. Must send body + `published: true` in a single call |
| `GET /articles?search=QUERY` returns irrelevant results | Use `GET /search?query=QUERY` instead — articles endpoint sorts by recency, search endpoint sorts by relevance |
| 401 Unauthorized | Vault secret expired or wrong. Re-fetch: `eval "$($HOME/.claude/scripts/fetch-secrets.sh <knowledge-base>)"` |

## Answer-to-doc loop (<internal-bot> Phase 5)

<internal-bot> detects a digest reply from <your-name> (Phase 4 trigger — see `docs/runbooks/<internal-bot>-feedback.md`), then runs the following sequence:

1. **Draft creation** — POST a **new** article as draft (omit `published: true`). ⚠️ The "PATCH an existing article" path does NOT produce a draft — a body PATCH on an already-published article publishes immediately (empirical 2026-06-10; see Update article section). For an edit-an-existing-article proposal flow, set `visibility_id: 2` to hold it off the public site until approval. Both paths use the `{"article": {...}}` wrapper.
2. **Adaptive Card proposal** — bot posts a card to the RD Private channel with the draft title, proposed category (friendly name from `n8n/_data/helpjuice-categories.json`), and Publish / Discard buttons. If the Claude-suggested `category_id` is not in the JSON seed, the card shows `Category #<id>` and an override picklist of known IDs.
3. **On Publish** — `PATCH /api/v3/articles/:id` with `{"article": {"published": true}}`. Supabase row status updated to `published` first (claims the proposal); Helpjuice call second. If Helpjuice fails, retry inline; on exhaustion, revert Supabase status to `pending_approval`.
4. **On Discard** — `DELETE /api/v3/articles/:id`. Supabase row updated to `discarded` first; Helpjuice DELETE second. 404 on DELETE is treated as success (already deleted).

**Category seed file:** `n8n/_data/helpjuice-categories.json` — static lookup for friendly names and the override picklist. Unknown IDs are flagged via `proposed_category_id_unknown=true` on the Supabase `cloudie_doc_proposals` row; no hard rejection.

**Refresh procedure:** walk `GET /api/v3/categories?limit=100&page=N` over `meta.total_pages` (see "List categories" — `per_page` is ignored; every category, nested included, is returned across the pages). Update the JSON file periodically.

**Auth:** service-role Supabase key for all PostgREST calls (RLS policy on `cloudie_digest_cache` is service-role only). `docs/runbooks/<internal-bot>-feedback.md` Phase 4 already documents service-role usage; Phase 5 inherits.

## Resolved Issues

> Log fixes here when an API/CLI/MCP call fails and you figure out why. Future sessions check this before re-investigating.

| Date | Issue | Root Cause | Fix |
|------|-------|-----------|-----|
| 2026-04-19 | PUT /articles/:id returns 400 for any payload | Must wrap body under `{"article": {...}}` — top-level `body` is rejected | Use `{"article": {"body": "..."}}` |
| 2026-04-29 | POST /articles returns 500 | Same wrapper requirement as PUT — top-level fields rejected silently | Use `{"article": {"name": "...", "body": "...", "category_id": N}}` |
| 2026-04-29 | `Authorization: Bearer $KEY` returns "Not allowed" | Helpjuice API key is sent raw, not as a Bearer token | Use `Authorization: $HELPJUICE_API_KEY` without Bearer prefix |
| 2026-04-19 | Internal blocks believed un-authorable via API (encrypted content) | Not true — server encrypts on save if you PUT the unencrypted wrapper. Requires `<div class="helpjuice-internal-block">` > `<div class="helpjuice-internal-block-body">` > `<div class="raw-html-embed">` structure. Verified on draft article 3772051 | Document real shape in Access Control section |
| 2026-04-29 | `GET /api/v3/articles` list endpoint: `slug` field is always `null` | API returns `url` but not `slug` on list responses | Use `url` field and extract path; transform to public URL via `<internal-url>` + path after `/en_US` |
