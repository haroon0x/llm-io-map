# The evidence ladder

Every payload in the map carries a grade stating how it was obtained. The grade is the difference between a report a team can trust and a plausible fiction. Do not blur grades, and never silently upgrade one.

The ladder, strongest to weakest:

```
recorded  →  serialized  →  reconstructed  →  representative  →  unresolved
```

Climb as far as the repo allows, per call site, per request.

---

## `recorded` — the artifact already exists

A real request/response pair produced by this codebase and stored somewhere in the repo.

Qualifies:
- HTTP fixtures / cassettes: VCR.py, Polly, VCR (Ruby), nock `*.json`, msw handlers with payloads
- Snapshot tests containing serialized requests or responses
- Eval datasets (`.jsonl`, `.json`) with model inputs/outputs
- Logs / debug dumps / `.llmmap`-style captures from a previous run
- Cached responses used by the app itself (response caches, memoized fixtures)

Does **not** qualify:
- Hand-written example payloads in tests that are asserted against, not sent
- Example payloads in README/docs (unless they are demonstrably this app's own output)
- A response body copied from a different model or project

Requirements: give the fixture path and the test/command that exercises it. If the fixture was hand-edited, say so.

## `serialized` — captured from a real code path

You executed the code path with the provider stubbed, and captured the byte-for-byte serialized request (and response, if the stub returns one).

Qualifies:
- SDK client mocked at its boundary; you dumped the kwargs/body it would send
- Base URL redirected to a local recorder; the HTTP body was logged
- Framework middleware/callback that sees the serialized payload (`wrapLanguageModel`, LangChain callbacks, etc.)

Does **not** qualify:
- A dict/dataclass you hand-assembled to *imitate* the SDK call
- Capture at a layer above serialization (e.g. logging `messages` before the SDK adds defaults, tools, or param normalization)

Requirements: name the harness, the command, and the concrete input it was run with. Include the harness in `.llmmap/extract/` so it can be re-run.

## `reconstructed` — exact for a stated input, derived statically

You resolved the code path (template + config + params + interpolation) and assembled the request for one concrete, named input.

Qualifies:
- Prompt file + interpolation sites fully resolved with a stated input
- Model and params resolved from config/env/constants
- Wrapper and framework layers accounted for

Does **not** qualify:
- Values you invented for unknowns (DB rows, retrieved docs, user context) — those stay `representative`
- "Approximately what it would look like"

Requirements: `input_context` must name the exact input; mark every dynamic input that had to be assumed. If any non-trivial dynamic value was assumed, the payload is `representative`, not `reconstructed`.

## `representative` — shape and example, explicitly not a capture

For dynamic parts that vary per request and cannot be resolved statically (RAG results, DB rows, user context), show the shape and a clearly-labeled example.

Requirements: state in `input_context` that it is representative and why; never give it a response grade it did not earn. A representative request can pair with an `unresolved` response. This is the correct grade for "this is what it looks like, not what it was."

## `unresolved` — not obtainable here

Use a `blocked` object with `reason`, `needs`, and `attempts`. This is a first-class outcome, not a failure to hide. A map with honest `unresolved` entries is more useful than one that fakes completeness.

Common reasons: dynamic input with no recorded example; requires live provider call the user has not approved; path needs credentials/services unavailable; code is generated at runtime; call site is in a vendored dependency.

---

## Borderline cases

- **Request vs response fidelity** — grade separately: `grade`/`request_grade` is the **request** evidence, `response_grade` is the **response** evidence; a null response is `unresolved`. A `serialized` request with an `unresolved` response is normal and must not be rolled up as if the response were captured.
- **Streaming** — capture the SSE chunk sequence verbatim in `captures/`; the assembled text is a derived view. Grade the capture, note that the response is streamed, and keep chunk boundaries.
- **Multi-request interactions** (tool loops, retries, fallbacks) — one entry per wire request in `requests[]`, in order, with `turn`/`attempt` metadata. Do not collapse to the final request only.
- **LangChain / Vercel AI SDK / similar** — the framework may transform messages after your app code. Capture at the deepest point you can reach; if you only see pre-framework messages, grade `reconstructed` and say so.
- **System prompt assembled from multiple pieces** — store the resolved final text in `system_prompt.text`; record the pieces and their sources in `system_prompt.source`/`dynamic_parts`.
- **Empty or missing prompt** — valid: embeddings, moderation, transcription may have no system prompt. Use `null`, not an empty string, and explain in `notes`.
- **Redacted payload** — redaction does not lower the grade. Record every rule in `redaction.rules` and per-payload `redactions`.

## Redaction

Redact values, keep structure. Replace secret values with `<REDACTED:kind>`.

Scan for at least:
- `sk-`, `sk-ant-`, `sk-proj-`, `AIza`, `ghp_`, `gho_`, `AKIA`, `xox[baprs]-`, `Bearer `
- keys named `api_key`, `apikey`, `authorization`, `x-api-key`, `token`, `secret`, `password`, `cookie`
- connection strings (`postgres://`, `redis://`, `mongodb+srv://`) and signed URLs
- `.env` values: if a value from `.env` appears in a payload, redact it

Keep: model names, message text (unless it contains PII the user flagged), tool names, params. If payloads contain obvious user PII, warn the user before committing `captures/`.

After redaction, re-scan the produced files. Grep the captures and manifest for the patterns above and for the literal value of every key found in `.env` files. Do not finish while anything matches.

## Rule of thumb

If you cannot point to the file, command, or derivation that produced a payload, its grade is lower than you think. Label it accordingly — the report tells the truth.
