# Helpjuice API Runbook

> **Owner:** <your-name> | **Last verified:** 2026-05-12

## API quirks (empirical 2026-05-06)

- **No analytics API exists.** All `/api/v3/analytics*` paths (including `/analytics`, `/analytics/searches`, `/analytics/articles`) and `/api/v3/searches`, `/api/v3/search_terms` return HTTP 404 on both `oit.helpjuice.com` and `<knowledge-base>.helpjuice.com`. Helpjuice analytics is admin-UI only. The `<knowledge-base>-mcp` server's `<kb>_helpjuice_get_analytics` tool (`/Users/<your-username>/Projects/<knowledge-base>-mcp/src/index.ts:1167`) targets `/analytics` and is dead code — calls return 404. **For popularity ranking, use the per-article `views` field instead** (see next bullet).
- **`accessibility` and `views` are null in the bulk list, populated in per-article fetch.** `GET /api/v3/articles?per_page=100` returns `"accessibility": null` and `"views": null` for every article. `GET /api/v3/articles/{id}` returns the correct values. **empirical (2026-05-06):** verified against article 3759871 (returns `accessibility: 0`) and the broader 2,135-article catalog (all null in bulk). Any audience-filter or popularity-ranking pipeline that batches over the bulk list MUST either re-fetch each article individually or fall back to category-name filtering. The 2026-05-06 VoIP MSP research deliverable's voipdoc match column shipped with internal-only links because the prior pipeline trusted the bulk-list `accessibility` field — fix in PR #420.
- **Views field IS the popularity proxy.** Per-article `views` is a monotonic counter. **empirical (2026-05-06)** top-viewed in <knowledge-base>: "Disabling SIP ALG on a Fortigate Firewall" at 42,498 views. There is no `?sort=views` shortcut — fetch each article and sort client-side.
- **Audience filtering pattern — three layers in order.** When matching arbitrary questions back to articles for public-facing surfaces, use these three filters in order:
  1. **Strict `accessibility == 1`** (per-article fetch required) — only `1` is publicly reachable on `<knowledge-base>.io`. `0`, `2`, `4` are internal/private/URL-only and must be excluded from public-facing recommendations.
  2. **Host allowlist** — accept only `<knowledge-base>.io` and `<knowledge-base>.helpjuice.com` URLs as voipdoc matches. Reject any cross-categorized hits whose `source_url` is a vendor docs site (e.g. `documentation.netsapiens.com`); those leak through `knowledge_chunks` because some articles cross-link to vendor sources.
  3. **Category deny list** (cheap, available in bulk list `category.name`) — backstop for articles whose accessibility is mistakenly set: drop `HR`, `Job Postings & Descriptions`, `Company Policies`, `Finance`, `Sales`, `Compliance`, `Compliance & Security`, `Marketing`, `Branding`, `White Label Branding`, `Guidelines of Employment`, `Training Syllabi`, `Announcements`.

  Optional 4th layer for precision: parse `answer.body` for the `Intended Audience` callout (`<strong>Intended Audience:</strong>\s*([^<]+)<`) and require the captured text to contain `All Users`, `White Label Partners`, `Clients`, or `Customers`. Skips articles whose accessibility is mistakenly `1` but whose body explicitly tags Engineering/<your-org> staff. Slow because it needs full body — only do this when the audience-filter result is load-bearing.

## Auth

- **Method:** API key (raw, no Bearer prefix — `Authorization: $HELPJUICE_API_KEY`)
- **Vault:** `<credential-vault>`
- **Secret name:** `HELPJUICE-API-KEY` (plus `HELPJUICE-SUBDOMAIN` for the subdomain)
- **Env var:** `$HELPJUICE_API_KEY`, `$HELPJUICE_SUBDOMAIN`
- **Fetch creds:** `eval "$($HOME/.claude/scripts/fetch-secrets.sh <knowledge-base>)"`
- **Base URL:** `<internal-url>

## Common Operations

### Search articles (relevance-ranked)

```
GET /api/v3/search?query=QUERY
```

Returns results ranked by relevance. Response includes `id`, `name`, `slug`, `categories`.

**Do NOT use** `GET /api/v3/articles?search=QUERY` — it returns results sorted by recency, not relevance, and routinely surfaces unrelated articles.

### Get article

```
GET /api/v3/articles/:id
```

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

**Draft mode (for review):** Send `body` WITHOUT `published: true` → creates draft revision. Published version stays live.

**Direct publish:** Send `body` + `published: true` in one call → publishes immediately.

**Does NOT work:** Two-step (body first, then separate `published: true` call) — second call is a no-op on the draft.

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
GET /api/v3/categories
```

Returns top-level categories only. **empirical 2026-05-08:** this endpoint returns 25 categories; some technical categories (e.g. `Development`, `443142`) do not appear in the list but ARE accessible via `GET /api/v3/categories/:id` directly. To enumerate the full tree, walk known IDs individually and scrape `category.sub_categories`.

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
| `private_to_groups` | `[group_id, ...]` | Restrict to specific groups (requires `accessibility: 0` or `2`) |
| `is_private` | `true`/`false` | Legacy; prefer `accessibility` |

Example — internal, restricted to <your-org> Staff + GTN Dev Team:

```json
{"article": {"accessibility": 0, "private_to_groups": [21308, 25395]}}
```

Current KB split (as of 2026-04-29): **~100 internal**, **~672 public**. Defaults — engineering/automation articles are `accessibility: 0`, customer-facing how-tos are `accessibility: 1`.

#### Visibility ↔ category gating

Helpjuice enforces that an article cannot be **more permissive than its parent category**. Setting `accessibility: 1` on an article inside a category whose own `accessibility` is `0` returns:

```
HTTP 422 {"accessibility":["Cannot be Public parent being Internal."]}
```

Verified 2026-05-03 against article 3796191 in category 1350391 (Automations, accessibility: 0).

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
for cat_id in $(curl -s "$BASE/categories?per_page=200" -H "Authorization: $K" | jq -r '.categories[].id'); do
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

Fetch current list: `GET /api/v3/groups`.

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
- `GET /articles/:id?processed=true` with **HTTP Basic Auth** (`-u "user@email:"`, blank password) — renders as that user; internal blocks only appear if the user is in `data-permitted-groups`. Useful to verify non-superadmin visibility.

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

## Article Template

**Every article body starts with a blue Info Callout containing the Scope block — never a plain `<h2>Scope</h2>`.** Use a green Success Callout for discrete requirement lists, and a red Danger Callout for warnings. Source: article 1912906.

### Scope (required — blue Info Callout)

```html
<div class="helpjuice-callout info">
<div class="helpjuice-callout-body">
<h3 id="scope-0" data-toc="false">Scope</h3>
<p><strong>Intended Audience:</strong> <!-- e.g. Engineering Staff, All Employees, Tier 2+ Technicians --></p>
<p><strong>Time to read:</strong> <!-- e.g. 5 minutes --></p>
<p><strong>Prerequisites:</strong> <!-- e.g. ClickUp access, Azure CLI configured --></p>
<p><strong>Outcome:</strong> <!-- one sentence — what the reader can do after --></p>
</div>
<div class="helpjuice-callout-delete"> </div>
</div>
```

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
- **Draft vs publish:** Default to draft mode (omit `published: true`) unless explicitly told to publish. Bot proposes, human approves.
- **`published: true` alone (no body)** → no-op, article stays as-is.
- **Article body is HTML**, not markdown.
- **`GET /api/v3/articles` list: `slug` is None.** The list endpoint returns a `url` field (e.g., `<internal-url>) but `slug` is always null. To build public URLs, extract the path from `url` and transform: `<internal-url>` + path after `/en_US`.

## Troubleshooting

| Symptom | Resolution |
|---------|------------|
| Article update succeeds but published version unchanged | You sent `body` without `published: true` — creates a draft revision only. Include `published: true` in same call to publish |
| Two-step update (body first, then `published: true`) no-ops | Second call is a no-op on the draft. Must send body + `published: true` in a single call |
| `GET /articles?search=QUERY` returns irrelevant results | Use `GET /search?query=QUERY` instead — articles endpoint sorts by recency, search endpoint sorts by relevance |
| 401 Unauthorized | Vault secret expired or wrong. Re-fetch: `eval "$($HOME/.claude/scripts/fetch-secrets.sh <knowledge-base>)"` |

## Answer-to-doc loop (<internal-bot> Phase 5)

<internal-bot> detects a digest reply from <your-name> (Phase 4 trigger — see `docs/runbooks/<internal-bot>-feedback.md`), then runs the following sequence:

1. **Draft creation** — POST a new article as draft (omit `published: true`) OR PATCH an existing article with new content. Both paths use the `{"article": {...}}` wrapper.
2. **Adaptive Card proposal** — bot posts a card to the RD Private channel with the draft title, proposed category (friendly name from `n8n/_data/helpjuice-categories.json`), and Publish / Discard buttons. If the Claude-suggested `category_id` is not in the JSON seed, the card shows `Category #<id>` and an override picklist of known IDs.
3. **On Publish** — `PATCH /api/v3/articles/:id` with `{"article": {"published": true}}`. Supabase row status updated to `published` first (claims the proposal); Helpjuice call second. If Helpjuice fails, retry inline; on exhaustion, revert Supabase status to `pending_approval`.
4. **On Discard** — `DELETE /api/v3/articles/:id`. Supabase row updated to `discarded` first; Helpjuice DELETE second. 404 on DELETE is treated as success (already deleted).

**Category seed file:** `n8n/_data/helpjuice-categories.json` — static lookup for friendly names and the override picklist. Unknown IDs are flagged via `proposed_category_id_unknown=true` on the Supabase `cloudie_doc_proposals` row; no hard rejection.

**Refresh procedure:** `GET /api/v3/categories?per_page=200` returns top-level categories only. **empirical 2026-05-08:** this endpoint returns 25 categories; some technical categories (e.g. `Development`, `443142`) do not appear in the list but ARE accessible via `GET /api/v3/categories/:id` directly. To enumerate the full tree, walk known IDs individually and scrape `category.sub_categories` field. Update the JSON file periodically.

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
