# Harness recipes

Goal: execute the real code path with the provider stubbed, and capture the **serialized** wire request (and a response, if you have one). Harnesses live in `.llmmap/extract/` and must be re-runnable.

## Principles

1. **Intercept at the serialization boundary** — the HTTP body or the SDK's final request object. Capturing app-level dicts is not `serialized`.
2. **Never hit the network.** Stub, mock, or redirect to a local recorder. No live calls without explicit approval.
3. **Capture bytes, not summaries.** Write the exact body (and SSE stream) to `captures/<site>/`; redact only secrets.
4. **Reuse a real fixture response when one exists** so the pair is meaningful; a recorded fixture response keeps the demo honest.
5. **One file per call site**: `harness-<site-id>.<ext>`. A `run.sh` runs them all.
6. **Idempotent output**: stable filenames, sorted keys where the format allows, cleared old captures before a run.

## Local recorder (works for every stack)

Start a tiny HTTP server, point the SDK's base URL at it, return a canned response.

```js
// .llmmap/extract/recorder.mjs
import http from 'node:http';
import fs from 'node:fs';
const fixture = JSON.parse(fs.readFileSync(process.env.FIXTURE ?? 'response.json', 'utf8'));
const out = process.env.OUT ?? 'capture';
http.createServer((req, res) => {
  let body = '';
  req.on('data', (c) => (body += c));
  req.on('end', () => {
    fs.writeFileSync(`${out}.request.json`, body);
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify(fixture));
  });
}).listen(process.env.PORT ?? 4319, '127.0.0.1');
```

Point the client at it (no real key, no network):

```ts
const client = new OpenAI({ apiKey: 'test', baseURL: 'http://127.0.0.1:4319/v1' });
```

For streaming, have the recorder serve `text/event-stream` from a saved chunk file and tee the exact bytes.

## Node / TypeScript

**OpenAI SDK** — `baseURL` redirect (above) or intercept `globalThis.fetch`:

```ts
const realFetch = globalThis.fetch;
globalThis.fetch = async (input, init) => {
  const req = new Request(input, init);
  captured.push({ url: req.url, body: await req.clone().text(), headers: Object.fromEntries(req.headers) });
  return new Response(JSON.stringify(fixture), { headers: { 'content-type': 'application/json' } });
};
```

**Vercel AI SDK** — `ai/test` mock provider, or a language-model middleware whose `wrapGenerate` / `wrapStream` receives the normalized call options (closest to the wire payload the SDK builds):

```ts
import { wrapLanguageModel } from 'ai';
const captureModel = wrapLanguageModel({
  model: openai('gpt-5-mini'),
  middleware: {
    wrapGenerate: async ({ doGenerate, params }) => {
      captures.push(params);            // serialized call options
      return doGenerate();
    },
  },
});
```

For the actual HTTP body, use `MockLanguageModelV2`-free approach: base URL redirect against a fetch stub. Prefer that when you need byte fidelity.

**Anthropic SDK** — `new Anthropic({ apiKey: 'test', baseURL: 'http://127.0.0.1:4319' })` (path is `/v1/messages`).

**LangChain JS** — a `BaseCallbackHandler` sees messages but not the final wire body → that is `reconstructed` at best; for `serialized`, wrap the model's `invoke`/`_generate` or intercept fetch.

**HTTP-level capture** — `undici` `MockAgent`, `nock`, or `msw` intercepts, logging request body; msw handlers can replay fixtures.

**Test plumbing** — put the capture in a vitest/jest test that calls the real handler with fixtures (`supertest`, `next-test-api-route-handler`, direct function call). Run with `pnpm vitest run .llmmap/extract/harness-cs-001.test.ts`.

## Python

**openai / anthropic SDK** — `httpx.MockTransport` (captures exact request bytes) or respx; or `base_url` redirect to the recorder.

```python
import httpx, json, pathlib
captured = []
def handler(request: httpx.Request) -> httpx.Response:
    captured.append({"url": str(request.url), "body": json.loads(request.content or b"{}")})
    return httpx.Response(200, json=fixture)
client = OpenAI(api_key="test", http_client=httpx.Client(transport=httpx.MockTransport(handler)))
```

**LangChain** — `BaseCallbackHandler.on_chat_model_start` / `on_llm_start` (prompts only → `reconstructed`); for bytes, patch the underlying client or intercept httpx.

**LiteLLM** — `litellm.callbacks` (success/failure) or point `api_base` at the recorder.

**Pytest plumbing** — a test module under `.llmmap/extract/` with fixtures copied from the repo's existing tests; run `pytest .llmmap/extract/harness_cs_001_test.py -q`.

## Go

Wrap the `http.Client.Transport` (or `http.RoundTripper`) to capture bodies, or rewrite the base URL to an `httptest.Server` returning a fixture:

```go
type captureTransport struct{ inner http.RoundTripper; sink *string }
func (t captureTransport) RoundTrip(r *http.Request) (*http.Response, error) {
  b, _ := io.ReadAll(r.Body); *t.sink = string(b); r.Body = io.NopCloser(bytes.NewReader(b))
  return t.inner.RoundTrip(r)
}
```

Many Go SDKs expose `config.HTTPClient` / `WithHTTPClient`. Run via a `go test` in `.llmmap/extract/`.

## Rust

Use `reqwest_middleware` to log request bodies, or `wiremock` for a local server + override the base URL. Closest-boundary capture is the JSON body written by the SDK; a callback/logging layer above it is `reconstructed`.

## Ruby / Java / C# / PHP

- Ruby: Faraday/VCR cassettes are excellent `recorded` evidence; otherwise Faraday middleware logging.
- Java/Kotlin: OkHttp `Interceptor` or `HttpClient` wrapper.
- C#/.NET: `DelegatingHandler` around `HttpClient`.
- PHP: Guzzle history middleware.

## Streaming

- Record the raw SSE body verbatim (`text/event-stream` bytes) plus a small metadata file with chunk count and content type.
- Reconstruct the final assistant text for display, but keep chunks as the recorded artifact.
- Async/generator paths: drain the stream inside the harness before exiting.

## Multi-request interactions

- Recorder appends to an ordered list: `{turn, attempt, request, response}`; write one JSONL per interaction.
- Tool loops: stub tool execution deterministically (canned tool results) so the loop is reproducible; note which tool results were stubbed.
- Retries/fallbacks: force one retry (stub a 429/500 once) to capture the retry payload, or note that retries are inferred.

## Fidelity checks before labeling `serialized`

- [ ] The captured bytes are the HTTP body (or the SDK's final request params), not an app-level dict.
- [ ] Defaults the SDK injects are present (e.g. `stream: false` when omitted? — record what is actually sent).
- [ ] Headers are excluded from the payload but auth redaction is noted.
- [ ] The harness can be re-run and produces the same payload (modulo timestamps/ids).
- [ ] The run used fixtures/deterministic stubs, not cached network state.

If any check fails, label the payload `reconstructed` and say why.

## When a harness is impossible

Record it: `unresolved` with `blocked.reason`/`needs`/`attempts`. Typical blockers: the call only happens in an environment you cannot recreate (production credentials, external services), code is generated at runtime, or the framework hides the boundary. Offer the cheapest unblock (recorded cassette, one approved live call, adding a logging hook upstream).
