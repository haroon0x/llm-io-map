# Discovery checklist

Coverage is the job. The sweep script is a starting point; you must verify its hits and find what it misses. Work the six passes below, then prove enumeration is done.

## What counts as a call site

One call site = one distinct place where a model is invoked, identified by the code location of the invocation (plus the resolved provider/model). Not one per caller: a shared wrapper called from 12 places is **one call site with 12 entrypoint edges**. If the wrapper selects different models/prompts by argument, split it.

Exclude: LLM code inside `node_modules/`, `vendor/`, site-packages, or other installed dependencies — map the in-repo invocation and note the library. Include repo-owned generated code and migrations if they call models.

## Pass A — Dependency manifests

Read the manifests and lockfiles; map each LLM-relevant dependency to the surface it exposes.

| Ecosystem | Files |
|---|---|
| Node/TS | `package.json`, `pnpm-lock.yaml`, `package-lock.json`, `yarn.lock` |
| Python | `pyproject.toml`, `requirements*.txt`, `Pipfile`, `poetry.lock`, `uv.lock` |
| Go | `go.mod`, `go.sum` |
| Rust | `Cargo.toml`, `Cargo.lock` |
| Ruby | `Gemfile`, `Gemfile.lock` |
| Java/Kotlin | `pom.xml`, `build.gradle(.kts)`, `gradle.lockfile` |
| .NET | `*.csproj`, `packages.lock.json` |
| PHP | `composer.json`, `composer.lock` |
| Elixir | `mix.exs`, `mix.lock` |

Surface signals: `openai`, `anthropic`, `@google/genai`, `@google-cloud/vertexai`, `@aws-sdk/client-bedrock-runtime`, `azure-openai`, `mistralai`, `cohere-ai`, `groq-sdk`, `together-ai`, `replicate`, `@huggingface/inference`, `ollama`, `openrouter`, `ai` (Vercel), `@ai-sdk/*`, `langchain*`, `@langchain/*`, `llamaindex`, `mastra`, `pydantic-ai`, `instructor`, `dspy`, `semantic-kernel`, `haystack`, `crewai`, `autogen`, `openai-agents`, `claude-agent-sdk`, `anthropic[vertex]`, `litellm`, `portkey`, `@modelcontextprotocol/sdk`, `mcp`, `genkit`, `firebase/vertexai`.

A dependency with no direct call is still a lead: frameworks often wrap the provider (LangChain, LlamaIndex, LiteLLM).

## Pass B — SDK import and instantiation

Search imports, constructors, and client factories. Per language, check the idioms, not just the names:

**JS/TS**
- `new OpenAI(`, `new Anthropic(`, `new GoogleGenerativeAI(`, `createOpenAI(`, `createAnthropic(`, `generateText(`, `streamText(`, `generateObject(`, `embed(`, `embedMany(`
- `ChatOpenAI(`, `ChatAnthropic(`, `HumanMessage`, `.invoke(`, `.stream(`, `.ainvoke(`
- `@ai-sdk/*` providers, `models.dev`, `getModel(`
- `fetch("https://api.openai.com/...")`, `fetch(\`${baseUrl}/v1/...\`)`
- `client.chat.completions.create`, `client.responses.create`, `client.messages.create`, `client.embeddings.create`

**Python**
- `from openai import`, `OpenAI(`, `AsyncOpenAI(`, `client.chat.completions.create(`, `client.responses.create(`, `client.messages.create(`
- `from anthropic import`, `Anthropic(`
- `google.generativeai`, `genai.Client(`, `vertexai`
- `ChatOpenAI`, `ChatAnthropic`, `LLM(`, `ChatPromptTemplate`, `.invoke(`, `.predict(`
- `litellm.completion(`, `completion(`, `@llm`, `instructor.from_openai(`
- `boto3.client("bedrock-runtime")`, `invoke_model(`, `converse(`

**Go**
- `openai.NewClient`, `anthropic.NewClient`, `genai.NewClient`, `bedrockruntime`, `InvokeModel`, `Converse`
- `langchaingo`, `go-openai`, raw `http.NewRequest` to provider hosts

**Rust**
- `async_openai`, `anthropic`, `genai`, `llm`, `rig`, `candle` (local), `reqwest` to provider hosts

**Ruby / Java / C# / PHP** — analogous: provider gems/SDK clients, `.chat(`, `.completions`, `ChatClient`, `OpenAI` classes.

**Universal wire-level leads**: hostnames `api.openai.com`, `api.anthropic.com`, `generativelanguage.googleapis.com`, `*.openai.azure.com`, `bedrock-runtime.*.amazonaws.com`, `api.mistral.ai`, `api.cohere.com`, `api.groq.com`, `openrouter.ai`, `api.together.xyz`, `api.replicate.com`, `localhost:11434` (Ollama), gateway hosts (`gateway.ai.cloudflare.com`, Portkey, LiteLLM).
Paths: `/v1/chat/completions`, `/v1/responses`, `/v1/messages`, `/v1/embeddings`, `/v1/rerank`, `/v1/moderations`, `/v1/audio/`, `/v1/images/`, `/v1beta/models`.

## Pass C — Model identifiers

Model-id strings are strong leads even when the SDK is hidden behind a wrapper: `gpt-`, `o1`, `o3`, `o4`, `claude-`, `gemini-`, `text-embedding-`, `text-moderation-`, `whisper-`, `tts-`, `dall-e`, `grok-`, `mistral-`, `llama-`, `command-r`, `deepseek-`, `qwen`, `phi-`.
Also: model ids in config files, `.env`, YAML, JSON, DB seeds, admin settings, feature flags, `models`/`model` fields.

## Pass D — Prompt discovery

Prompts are the thing most likely to be missed:

- Dedicated dirs/files: `prompts/`, `*.prompt`, `*.prompt.md`, `*.jinja`, `*.j2`, `*.hbs`, `*.mustache`, `*.tmpl`, `*.txt`, `*.md` with instructions
- Inline template literals: `system: \`...\``, multi-line strings, `dedent(...)`, `PromptTemplate.from_template`
- Prompt builders: `buildPrompt(`, `getSystemPrompt(`, `renderPrompt(`, `composePrompt(`, template registries / prompt IDs
- Prompts in DB/config/admin panels, feature-flag payloads, CMS, localisation files
- Few-shot examples and tool/function descriptions — they shape the request and belong in the prompt catalog
- Prompt injection defenses, output parsers, and guardrails that modify the payload after the app code

## Pass E — Indirect and dynamic

- **In-repo wrappers/abstractions**: `lib/llm.ts`, `services/ai.ts`, `utils/prompt.ts`, base classes. High fan-out wrappers are where most call sites hide.
- **Factory/registry patterns**: model selected by env, config, user tier, or A/B flag. Record resolution logic, not just the default.
- **Base URL indirection**: `OPENAI_BASE_URL`, proxy/gateway env vars. A gateway means the *gateway* config (routing, fallbacks) is part of the map.
- **Dynamic clients**: DI containers, `getClient()`, module singletons, lazy initialization.
- **Agent graphs/state machines**: LangGraph nodes, workflow definitions, planner/executor loops — each LLM invocation node is a call site; tool loops produce multi-request sequences.
- **MCP / tool servers**: server tool definitions become LLM input; client-side tool calls return results to the model. Map the tool surface and where tools are exposed.
- **Non-chat**: embeddings (RAG indexing + query), rerankers, moderation, transcription, image/audio generation, batch jobs, evals/fine-tune scripts. They are LLM I/O; include them but keep the chat/other split clear.
- **Build-time / offline**: scripts that call models to generate fixtures or code — include if they run in the repo, mark as non-runtime.

## Pass F — Triggers ("when is it used")

For every call site, find what makes it fire and any gating:

- HTTP routes/handlers/controllers/middleware, server actions, tRPC/RPC procedures, GraphQL resolvers, websocket handlers
- CLI commands, admin scripts, notebooks
- Cron/scheduler entries (`vercel.json`, `crontab`, Celery beat, k8s CronJob, GitHub Actions)
- Queue consumers, pub/sub subscribers, webhooks, event handlers
- IDE/editor extension events, browser extension events (for extension repos)
- Background workers, batch jobs, lazy in-request generation
- Gating: auth/plan/rate limits, feature flags, length checks, sampling, retries/fallbacks that change the model

Record `entrypoint` → `call_chain` → `call site`, plus gating conditions. This is what answers "when is that LLM used" in the report.

## Definition of done for enumeration

- [ ] Every LLM-relevant dependency is either mapped to a call site or dismissed with a reason (transitive only, unused, not LLM).
- [ ] Every write/model-id hit was read and classified.
- [ ] Every prompt file/builder is attached to at least one call site (or is demonstrably dead).
- [ ] Shared wrappers are mapped once, with their callers listed as edges.
- [ ] Triggers found for every runtime call site; unreachable/dead code called out.
- [ ] Non-chat calls (embeddings, moderation, etc.) are listed separately and not dropped.
- [ ] Agent loops captured as request sequences.
- [ ] The count of call sites is stable: a re-run of discovery produces the same set (new hits are explained).

Missed call sites are the most common failure. When in doubt, read the wrapper — do not trust the sweep.
