---
name: llm-io-map
description: Map every LLM call site in a codebase and reconstruct what actually goes in and out (system prompts, messages, tools, model parameters, raw request/response payloads), each payload graded by how it was obtained. Emits an evidence-graded JSON manifest plus a self-contained HTML viewer showing the call site, its trigger, the surrounding app flow, and the raw payloads. Use when asked where an LLM is used in a repo, to audit prompts, to trace an AI feature end to end, or to produce an LLM I/O report a team can open in a browser.
license: MIT
---

# LLM I/O Map

Produce a per-repo map of every place an LLM is called: where it lives, when it fires, what exactly is sent, and what comes back — with every payload labeled by how it was obtained. Output is a manifest, a single-file HTML viewer, and the repo-tailored scripts used to extract and refresh it.

This skill is a procedure, not a fixed pipeline. **The extraction is personalized per repo**: profile the stack, choose the capture technique that fits, generate the machinery under `.llmmap/extract/`. The evidence labels are not negotiable.

## Output contract

Create inside the target repo:

```
.llmmap/
  manifest.json      # contract: profile, entrypoints, call sites, payloads, evidence, flow
  report.html        # self-contained viewer (opens from disk, offline, no server)
  captures/<site>/   # one request/response pair per captured interaction (redacted)
  extract/           # repo-tailored scripts: discovery, harnesses, redaction, render, refresh
  README.md          # what this is, how to refresh, grade definitions, known gaps
```

Copy the shipped tools into `.llmmap/extract/` on first run so the map is reproducible from inside the repo:
`discover.sh`, `redact.py`, `render.mjs`, and `viewer.template.html` (from `assets/viewer.html`).

Keep it diff-friendly: stable call-site IDs, sorted arrays, timestamps only at top level.

## Non-negotiables

1. **Grade every payload** — `recorded | serialized | reconstructed | representative | unresolved`. Never present a lower grade as a higher one.
2. **Never invent a payload.** No plausible-looking "example" passed off as a capture, no response copied from docs or another project. If unobtainable: `unresolved` + reason.
3. **Raw means raw.** Captured request/response bodies go into `captures/` verbatim except secret redaction. Do not summarize, reorder, or prettify the payload itself.
4. **Every call site is resolved or explicitly blocked.** A silent omission is a failed map.
5. **No live model calls by default.** Live calls require explicit user approval (cost, key, nondeterminism). Never print secrets.
6. **Do not modify application code.** Harnesses, stubs, and scripts live under `.llmmap/extract/`.

## Evidence ladder

Climb as far as the repo allows for each call site.

| Grade | Meaning | Typical source |
|---|---|---|
| `recorded` | A real request/response already exists in the repo | fixtures, VCR/Polly cassettes, snapshot tests, eval datasets, `.jsonl` logs, cached responses, debug dumps |
| `serialized` | The exact request the SDK would send, captured by executing the code path against a stub | harness with provider client mocked or base URL pointed at a local recorder |
| `reconstructed` | Exact for a stated concrete input, assembled by resolving the code path | static analysis + resolved templates/config/params |
| `representative` | Shape and example for dynamic parts; explicitly not a real capture | types, schemas, mocks, documented defaults |
| `unresolved` | Not obtainable here | reason + what would be needed |

Rules:
- Recorded evidence wins. Reproduce it before reconstructing anything.
- `serialized` must intercept the *serialized* payload (SDK kwargs or HTTP body), not a hand-built dict.
- `reconstructed` is exact only for the concrete input you state — name that input in the payload metadata.
- Responses are the hard part: recorded, or opt-in live call, or drill down. A request can be `serialized` while its response is `unresolved`. See `references/evidence-ladder.md`.

## Procedure

### Phase 0 — Profile the repo
- Languages, package managers, monorepo layout, framework(s).
- Can it run? deps installed, tests pass, keys present? (Never print key values.)
- Inventory evidence sources: test trees, fixtures, cassettes, eval dirs, logs, caches, prompt files, docs with example payloads.
- Write the short profile into `manifest.json` and `extract/profile.json`.

### Phase 1 — Enumerate call sites
Run the shipped sweep as a starting point, then verify and extend it by reading code. Every candidate you rule out goes into `manifest.dismissed[]` with a category and a reason — a silent omission is a failed map:

```bash
bash scripts/discover.sh "<repo-root>"      # or the copy in .llmmap/extract/
```

Coverage is the job. Check every surface in `references/discovery-checklist.md`:
- **Provider SDKs**: OpenAI, Anthropic, Google GenAI/Vertex, Bedrock, Azure OpenAI, Mistral, Cohere, Groq, Together, OpenRouter, Replicate, Hugging Face, Ollama/vLLM.
- **Framework SDKs**: Vercel AI SDK, LangChain/LangGraph, LlamaIndex, Mastra, Pydantic AI, Instructor, DSPy, Semantic Kernel, Haystack, CrewAI/AutoGen, OpenAI Agents SDK, Claude Agent SDK, MCP clients.
- **Raw HTTP** to provider/gateway endpoints, proxies (LiteLLM, OpenRouter, Portkey, Cloudflare AI Gateway).
- **Non-chat LLM calls**: embeddings, rerank, moderation, transcription, image/audio generation — they are LLM I/O too.
- **Indirect**: in-repo wrapper classes (one wrapper called from N places = one site with N edges), env-configured base URLs, dynamic client construction, prompt registries, template files (`.jinja`, `.hbs`, `.prompt`, `.md`), prompts in DB/config.
- **Agent loops**: one logical call = many requests (tool loops, retries). Capture the request *sequence*, not just the first.
- **Triggers**: HTTP route, CLI, cron, queue consumer, webhook, background worker, IDE event. "When is it used" includes the trigger and any gating condition.

For each candidate record: `file:line`, the call chain up to the entrypoint, the trigger/gating condition, and how provider/model are resolved.

### Phase 2 — Extract prompts and parameters
- Static prompts: full verbatim text.
- Dynamic assembly: template + interpolation sites; note where each variable originates (request, DB, RAG, tool result, env).
- Params: model (and how it resolves), temperature, max tokens, tools/function schemas, response format, streaming, retries/fallbacks.
- Resolve the layering: app wrapper → framework → SDK. The wire payload is what matters.

### Phase 3 — Obtain raw I/O (climb the ladder)
1. **Search recorded evidence first.** Grep for response shapes (`choices`, `tool_calls`, `"role": "assistant"`, `content_block`, SSE chunks), cassette patterns, `.jsonl`, eval datasets.
2. **Reconstruct** where recorded evidence doesn't exist: trace the path, resolve templates with one concrete input, assemble the exact request.
3. **Serialize via harness**: generate `.llmmap/extract/harness-<site>.{py,ts,go,...}` that stubs the provider client or redirects its base URL to a local recorder, run the path, dump the serialized request/response. Recipes: `references/harness-recipes.md`.
4. **Responses**: recorded > user-approved live call > representative from fixtures > `unresolved`. Never copy a response from documentation as if it were this app's output.

### Phase 4 — Build the manifest
Follow `references/manifest-schema.md`. One entry per call site, plus entrypoints, flow edges, and a `dismissed[]` list for ruled-out candidates. Each payload carries: **request grade** and **response grade** (separately — a null response is `unresolved`), provenance (file or command), capture file path, the concrete input it represents, redactions applied, and a reproduce command. Redact with `scripts/redact.py` and record the rules.

### Phase 5 — Render the viewer
Render with the shipped script — do not hand-edit the report:

```bash
cp assets/viewer.html .llmmap/extract/viewer.template.html   # once
cp scripts/render.mjs .llmmap/extract/render.mjs             # once
node .llmmap/extract/render.mjs                              # manifest.json -> report.html
```

`render.mjs` validates the manifest, embeds it safely, and prints the evidence breakdown plus warnings. The template must keep its single marker line `const MANIFEST = /*__LLMMAP_MANIFEST__*/null;`. Personalize styling in the copy under `.llmmap/extract/`, never in the shipped original.

The viewer must show:
- summary strip: call sites, grade breakdown, providers/models, trigger kinds, unresolved count
- flow view: entrypoint → trigger → call chain → LLM call
- call-site detail: system prompt, messages/template with dynamic parts highlighted, tools, params, raw request JSON, raw response JSON with grade badge
- provenance + reproduce command + redaction notice per payload
- offline, no external requests, no CDN assets

The shipped viewer also renders prompts as a transcript with placeholders highlighted, supports system/light/dark themes (`report.html?theme=light|dark`), keyboard navigation (`j`/`k`, `1`–`5`, `/`, `t`), and prints cleanly to PDF.

Personalize styling to the repo only if trivial (name/logo/colors). Keep the data contract stable.

### Phase 6 — Verify (do not skip)
Run `references/verification.md`. Minimum bar:
- [ ] every discovered call site is in the manifest, or blocked with a reason
- [ ] every ruled-out candidate is in `manifest.dismissed[]` with category + reason
- [ ] request and response grades are separate; `summary.evidence` and `summary.response_evidence` match the payloads
- [ ] every payload has a grade + provenance + reproduce command
- [ ] no secrets/tokens/user PII in captures (redaction pass, then re-scan)
- [ ] no fabricated payloads; representative ones are labeled
- [ ] `report.html` opens offline, no console errors, no network requests
- [ ] file paths and line references resolve
- [ ] refresh works: re-running the extract scripts regenerates the manifest without churn

### Phase 7 — Report back
Give the user: call sites found, evidence breakdown (X recorded / Y serialized / … / Z unresolved), the unresolved list with *why*, path to `report.html`, and the cheapest next step to raise the weakest grades. Do not overstate: an honest map with gaps beats a complete-looking one.

## Refresh

`.llmmap/extract/` must be re-runnable. When the code changes, re-run discovery + harnesses, update the manifest, re-render. Keep IDs stable so diffs are meaningful. Suggest wiring it into CI or a pre-commit hook only if the user asks.

## Guardrails

- **Secrets**: scan for `sk-`, `sk-ant-`, `AIza`, `ghp_`, bearer tokens, connection strings, `.env` values; replace with `<REDACTED:kind>`. Never echo a full key.
- **Privacy**: captures may contain user data. Default to local-only; warn before committing `captures/`.
- **Cost**: live calls only with explicit approval; state count and model; keep it minimal.
- **Safety**: harnesses must stub/loopback the network by default; don't run untrusted code beyond what the repo's own test setup does.
- **Dependencies**: LLM calls inside `node_modules/`/`vendor/` are external surface — map the in-repo invocation, note the library, don't paste third-party internals as "your" call site.

## References

- `references/discovery-checklist.md` — full surface matrix and per-language leads
- `references/evidence-ladder.md` — grade definitions, borderline cases, redaction
- `references/harness-recipes.md` — capture recipes per stack
- `references/manifest-schema.md` — manifest contract + example
- `references/verification.md` — completion checklist
