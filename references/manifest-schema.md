# Manifest schema

`.llmmap/manifest.json` is the contract. The viewer renders it; the extract scripts regenerate it. Keep field names stable so reports stay comparable across repos and refreshes.

## Top level

```jsonc
{
  "schema_version": "1.0",
  "generated_at": "2026-11-17T15:30:00+05:30",   // ISO 8601, top level only
  "repo": {
    "name": "example-app",
    "root": ".",
    "commit": "3f2a1c9",           // short SHA if available
    "branch": "main"
  },
  "profile": {
    "languages": ["typescript"],
    "package_managers": ["pnpm"],
    "frameworks": ["next", "vercel-ai-sdk"],
    "runnable": true,              // can the path be executed in this environment?
    "evidence_sources": [
      { "type": "fixture", "path": "tests/fixtures/llm/*.json", "count": 4 },
      { "type": "eval-dataset", "path": "evals/support-qa.jsonl", "count": 120 }
    ]
  },
  "summary": {
    "call_sites": 3,
    "evidence": { "recorded": 1, "serialized": 1, "reconstructed": 0, "representative": 1, "unresolved": 0 },
    "response_evidence": { "recorded": 1, "serialized": 0, "reconstructed": 0, "representative": 0, "unresolved": 2 },
    "providers": ["openai"],
    "models": ["gpt-5-mini", "text-embedding-3-small"],
    "trigger_kinds": { "http": 2, "job": 1 }
  },
  "entrypoints": [ /* see below */ ],
  "call_sites": [ /* see below */ ],
  "dismissed": [ /* see below */ ],
  "flow": { /* see below */ },
  "redaction": {
    "rules": ["authorization -> <REDACTED:bearer>", "api_key -> <REDACTED:api_key>"],
    "applied_to": ["captures/**"]
  },
  "limitations": [
    "Response for cs-002 was not recorded; request only.",
    "Embedding call in cs-003 runs inside the vector-store client; provider resolved from config."
  ]
}
```

## Entrypoints

An entrypoint is what makes the LLM fire. One per trigger (route, job, CLI, event).

```jsonc
{
  "id": "route:POST /api/chat",
  "type": "http",                          // http | job | cron | queue | cli | webhook | ide | other
  "file": "app/api/chat/route.ts",
  "line": 12,
  "trigger": "POST request; streams response",
  "auth": "session cookie required",
  "gating": "only when message is non-empty and rate limit passes",
  "call_sites": ["cs-001"]
}
```

## Call sites

```jsonc
{
  "id": "cs-001",                          // stable: cs-001, cs-002, ...; never renumber on refresh
  "name": "support chat completion",
  "provider": "openai",
  "sdk": "ai@5",                           // framework or provider SDK
  "method": "streamText",                  // the in-code entry used
  "model": "gpt-5-mini",
  "model_resolution": { "source": "env:OPENAI_MODEL", "default": "gpt-5-mini", "file": "lib/llm.ts", "line": 8 },
  "location": { "file": "lib/llm.ts", "line": 42, "end_line": 58 },
  "call_chain": [
    { "file": "app/api/chat/route.ts", "line": 12, "name": "POST" },
    { "file": "lib/agent.ts", "line": 30, "name": "runAgent" },
    { "file": "lib/llm.ts", "line": 42, "name": "complete" }
  ],
  "trigger": { "kind": "http", "detail": "POST /api/chat", "entrypoint_id": "route:POST /api/chat" },
  "gating": "message.length > 0 && rateLimit.ok",
  "system_prompt": {
    "text": "You are a support agent for Acme. Use retrieved docs when available.",
    "source": { "type": "file", "path": "prompts/system.md", "line": 1 },   // inline | file | config | db | generated
    "dynamic_parts": ["{user.name}", "{retrieved_docs}"]
  },
  "messages": {
    "template": [
      { "role": "system", "content": "$system_prompt" },
      { "role": "user", "content": "{question}\n\nContext:\n{retrieved_docs}" }
    ],
    "assembly": { "file": "lib/prompt.ts", "line": 20, "note": "docs from vector search, top 5" },
    "dynamic_inputs": [
      { "placeholder": "{question}", "origin": "request body .message" },
      { "placeholder": "{retrieved_docs}", "origin": "vector store top-5, RAG" }
    ]
  },
  "tools": [
    { "name": "search_docs", "description": "Search the help center.", "params_schema_file": "lib/tools.ts", "params_schema_line": 10 }
  ],
  "params": {
    "temperature": 0.2,
    "max_tokens": 800,
    "stream": true,
    "response_format": null,
    "retries": 2,
    "fallback_models": []
  },
  "requests": [
    {
      "id": "req-001",
      "grade": "serialized",              /* request grade */
      "response_grade": "unresolved",     /* response grade; null response => unresolved */
      "provenance": { "type": "harness", "command": "node .llmmap/extract/harness-cs-001.mjs" },
      "request_file": "captures/cs-001/req-001.request.json",
      "response_file": null,
      "request": { "model": "gpt-5-mini", "messages": [ /* verbatim payload */ ] },
      "response": null,
      "input_context": "user message: 'How do refunds work?'",
      "redactions": ["authorization"],
      "reproduce": "pnpm vitest run tests/chat.test.ts -t refund",
      "note": "streamed; response not recorded"
    }
  ],
  "notes": ""
}
```

Payloads are stored **twice on purpose**:
- `request` / `response` — the verbatim payload inline in the manifest, so the viewer is a single offline file.
- `request_file` / `response_file` — the same bytes written to `captures/`, so humans can copy the raw artifact.

When a payload is `unresolved` or `representative` with no response, the corresponding value is `null` and a `blocked` object explains why (see below). Inline payloads are redacted the same way as capture files.

Rules:
- `location` is the LLM call itself; `call_chain` is the path to it, ordered entrypoint → call.
- `dynamic_inputs` must cover every placeholder that changes per request; that's what makes `reconstructed` honest.
- `requests` is a list because one call site often produces many wire requests (agent loops, retries, streaming chunks). Record the sequence.
- **Grade semantics:** `grade` (alias `request_grade`) describes the **request** payload; `response_grade` describes the **response**. A `null`/absent response with no evidence is `unresolved`. Never use the request grade to imply what the response is. `summary.evidence` is the request rollup; `summary.response_evidence` is the response rollup (both optional but recommended — the renderer warns when they disagree).
- `input_context` states the concrete input a `reconstructed` payload represents. Required for `reconstructed`.
- `provenance` carries the source (fixture path / harness command) and flags — **not timestamps**. Timestamps live in `captures/*.meta.json` only, so refreshes stay diff-stable.
- `provenance.command` must actually work; the verifier runs it.

## Flow

A compact, human-readable graph. The viewer draws it; keep it simple.

```jsonc
{
  "description": "Chat request reaches the agent, which retrieves docs and streams a completion.",
  "edges": [
    { "from": "route:POST /api/chat", "to": "cs-001", "via": "runAgent -> streamText", "when": "on POST" }
  ]
}
```

## Dismissed

Every candidate the discovery pass considered and ruled out gets an explicit entry. This is how "no silent omissions" is enforced: anything not in `call_sites` must be here with a reason.

```jsonc
"dismissed": [
  {
    "id": "search:tinyfish",
    "path": "src/search/tinyfish.ts:41",
    "category": "retrieval-only",            // retrieval-only | external-agent-artifact | non-llm | dead-code | third-party
    "reason": "Search API returns ranked results; it never invokes a model."
  }
]
```

Categories worth using: `retrieval-only` (search/rerank without generation), `external-agent-artifact` (prompt shipped for other agents/humans, never sent by this repo), `non-llm` (name suggests LLM but no model call), `dead-code` (unreachable), `third-party` (inside a dependency).

## Unresolved

For anything that could not be captured, use `grade: "unresolved"` and a `blocked` object instead of pretending:

```jsonc
{
  "id": "req-003",
  "grade": "unresolved",
  "blocked": {
    "reason": "requires a live provider call; no recorded response found",
    "needs": "user approval for one live gpt-5-mini call, or a recorded cassette",
    "attempts": ["searched tests/fixtures", "searched logs", "harness stubs request only"]
  }
}
```

## Redaction

Redact values, never structure: keep keys, replace values with `<REDACTED:kind>`. Record every rule applied. Re-scan captures for `sk-`, `sk-ant-`, `AIza`, `ghp_`, `Bearer `, `AKIA`, and connection strings before finishing.

## What not to put in the manifest

- Full secret values, even in `provenance.command`.
- Entire prompt files duplicated per call site — reference the file, keep the resolved text in `system_prompt.text`.
- Third-party library internals as if they were in-repo call sites.

See `assets/manifest.example.json` for a complete, viewer-ready example.
