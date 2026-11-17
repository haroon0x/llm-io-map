# Verification checklist

Do not report the map as complete until every item passes. Run the checks, paste the evidence into the final report. An honest gap is acceptable; a silent gap is not.

## 1. Coverage

- [ ] Re-run discovery: the call-site set is identical to the one in the manifest (or new hits are explained).
- [ ] Every LLM-relevant dependency found in Pass A is mapped or dismissed with a reason.
- [ ] Every model-id string and prompt file hit is classified (no unexplained `rg` hits).
- [ ] Shared wrappers appear once, with all callers as edges.
- [ ] Non-chat calls (embeddings, moderation, transcription, images) are listed.
- [ ] Agent loops / multi-request interactions are captured as sequences.
- [ ] `manifest.summary.call_sites` equals `call_sites.length`.
- [ ] Every discovery candidate is either a call site or in `dismissed[]` with a category and a reason. Silence is a failed map.

**Command:** `rg -n --hidden --glob '!**/node_modules/**' --glob '!**/.llmmap/**' --glob '!**/*.md' --glob '!**/*.lock' -e 'gpt-|claude-|gemini-|openai|anthropic|@ai-sdk|langchain|llamaindex' <repo>` — every **code** hit must be in the manifest or in `dismissed[]`. Docs/plans are not runtime code; do not chase markdown hits.

## 2. Evidence integrity

- [ ] Every `requests[]` entry has a `grade` in the allowed set.
- [ ] `recorded` payloads point at a real fixture path that exists.
- [ ] `serialized` payloads name a harness command that exists and is re-runnable.
- [ ] `reconstructed` payloads include `input_context` naming the concrete input.
- [ ] `representative` payloads say so in `input_context` and never claim a response grade they did not earn.
- [ ] Every `unresolved` has `blocked.reason`, `blocked.needs`, `blocked.attempts`.
- [ ] No payload was invented: spot-check each captured body against its source file/command.
- [ ] Request/response grade split is correct (`request_grade`/`response_grade` when they differ).

**Command:** validate JSON and grades:

```bash
node -e '
const m = require("./.llmmap/manifest.json");
const g = new Set(["recorded","serialized","reconstructed","representative","unresolved"]);
let bad = 0;
for (const cs of m.call_sites) for (const r of cs.requests ?? []) {
  for (const k of ["grade","request_grade","response_grade"]) if (r[k] && !g.has(r[k])) { console.log("bad grade", cs.id, r.id, k, r[k]); bad++; }
  if (r.grade !== "unresolved" && !r.provenance) { console.log("no provenance", cs.id, r.id); bad++; }
  if (r.request == null && r.grade !== "unresolved") { console.log("no request payload", cs.id, r.id); bad++; }
}
console.log(bad ? `${bad} problems` : "evidence labels OK");
process.exit(bad ? 1 : 0);'
```

## 3. Secrets and PII

- [ ] Redaction pass ran on every capture and inline payload. `redact.py` scans payload files only (`.json/.jsonl/.ndjson/.txt/.log/.http/.sse`); source and docs are skipped by design — pass a specific file explicitly if you need it checked.
- [ ] Re-scan found no matches:

```bash
rg -n -i --hidden --glob '!.git' -e 'sk-[a-zA-Z0-9]{10,}' -e 'sk-ant-' -e 'AIza[0-9A-Za-z_-]{10,}' -e 'ghp_[0-9A-Za-z]{10,}' -e 'Bearer [A-Za-z0-9._-]{12,}' -e 'AKIA[0-9A-Z]{12,}' -e '(postgres|redis|mongodb(\+srv)?)://[^ "\x27]+:[^ "\x27]+' .llmmap || echo "clean"
```

- [ ] For every **secret-looking** key in `.env*` files (name matching `(^|_)(KEY|TOKEN|SECRET|PASSWORD|DSN|CREDENTIALS)$`, case-insensitive), its value does not appear in `.llmmap/`. Ignore benign config like `NODE_ENV` or model ids.
- [ ] If payloads contain user data, the manifest/README warns before committing `captures/`.
- [ ] No full secret in provenance commands, README, or the viewer.

## 4. Viewer

- [ ] `report.html` opens offline from disk (`file://`) with no console errors.
- [ ] No external requests: viewer has no CDN/src/href/fetch to the network.
- [ ] Every call site in the manifest is selectable; grade badges match the manifest.
- [ ] Raw request/response JSON is verbatim, syntax-highlighted, copyable.
- [ ] Empty/missing fields render cleanly (null system prompt, no response, no tools).
- [ ] Unresolved/blocked entries are visibly flagged, not hidden.
- [ ] Summary counts match `manifest.summary.evidence`.
- [ ] Large payloads scroll rather than break layout; 100+ call sites stay responsive.
- [ ] HTML-escape check: a payload containing `<script>alert(1)</script>` renders as text.

```bash
# console errors (a JS syntax error renders a blank page with exit 0 on --dump-dom alone)
google-chrome --headless=new --disable-gpu --no-sandbox --virtual-time-budget=3000 \
  --enable-logging=stderr --v=0 --dump-dom "file://$PWD/.llmmap/report.html" \
  2>&1 >/tmp/report-dom.html | grep -iE 'CONSOLE|Uncaught|SyntaxError' && echo "FAIL: console errors" || echo "no console errors"
grep -q 'class="site-btn"' /tmp/report-dom.html && echo "rendered: YES" || echo "FAIL: empty #root"

# external requests: only network-bearing attributes matter; payload URLs are legitimate data
grep -nE '<(script|img|link|iframe)[^>]+(src|href)="https?://|fetch\(' .llmmap/report.html | head
```

## 5. Paths and reproducibility

- [ ] Every `file:line`/`file:line-end` resolves in the current commit.
- [ ] Every `reproduce` command works from the repo root (or is marked as harness-only).
- [ ] Re-running `extract/` scripts regenerates the manifest without churn (stable IDs/order).
- [ ] `.llmmap/README.md` explains refresh, grades, and known gaps.
- [ ] The `generated_at` and `repo.commit` are current.

## 6. Honesty pass

Read the final report as a skeptical reviewer:

- [ ] Does any payload claim more fidelity than its evidence supports?
- [ ] Are dynamic inputs (RAG, DB, user context) clearly marked where they were assumed?
- [ ] Does the "limitations" list match reality?
- [ ] Would the team be misled about what is captured vs. reconstructed? If yes, fix before shipping.

## Final report to the user

Include:
- call sites found (and dismissed categories)
- evidence breakdown: `X recorded / Y serialized / Z reconstructed / W representative / V unresolved`
- unresolved list with the exact blocker and cheapest next step
- path to `.llmmap/report.html` (and how to open it)
- what was assumed, what is live-call-dependent
- refresh command

Never claim "all LLM calls captured" unless coverage section passed. Say "N call sites mapped; V unresolved because..."
