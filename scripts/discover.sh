#!/usr/bin/env bash
# discover.sh — first-pass sweep for LLM call sites in a repo.
# Usage: bash discover.sh [repo-root] [output-dir]
# Writes a human-readable discovery report; the agent must verify and extend it.
set -uo pipefail

ROOT="${1:-.}"
OUT_DIR="${2:-$ROOT/.llmmap/extract}"
OUT="$OUT_DIR/discovery.md"
mkdir -p "$OUT_DIR"

# Always exclude our own output (.llmmap) and heavy/generated trees.
EXCLUDES=( -g '!**/node_modules/**' -g '!**/vendor/**' -g '!**/dist/**' -g '!**/build/**'
           -g '!**/target/**' -g '!**/.git/**' -g '!**/.llmmap/**' -g '!**/*.min.js' -g '!**/*.map' )
GREP_EXCLUDES=( --exclude-dir=node_modules --exclude-dir=vendor --exclude-dir=dist
                --exclude-dir=build --exclude-dir=target --exclude-dir=.git --exclude-dir=.llmmap )
LOCK_EXCLUDES=( -g '!**/package-lock.json' -g '!**/yarn.lock' -g '!**/pnpm-lock.yaml'
                -g '!**/Cargo.lock' -g '!**/go.sum' -g '!**/poetry.lock' -g '!**/uv.lock' )

have_rg=0; command -v rg >/dev/null 2>&1 && have_rg=1

run_pat() { # $1 = label, $2 = title, $3 = extensions (comma list, empty = all), rest = -e patterns
  local label="$1" title="$2" exts="$3"; shift 3
  local tmp; tmp=$(mktemp)
  if [ "$have_rg" -eq 1 ]; then
    local gargs=()
    if [ -n "$exts" ]; then gargs=( -g "*.{$exts}" ); fi
    # glob order matters: explicit excludes must come after the include globs, or rg re-includes them.
    ( cd "$ROOT" && rg -n --no-heading --hidden --color never --sort path "${gargs[@]}" "${EXCLUDES[@]}" "${LOCK_EXCLUDES[@]}" "$@" 2>/dev/null ) >"$tmp"
  else
    local incs=() e
    if [ -n "$exts" ]; then IFS=',' read -ra __exts <<<"$exts"; for e in "${__exts[@]}"; do incs+=(--include="*.$e"); done; fi
    local pats=() joined
    while [ $# -gt 0 ]; do
      case "$1" in -e) pats+=("$2"); shift 2 ;; *) shift ;; esac
    done
    joined=$(printf '%s|' "${pats[@]}"); joined="${joined%|}"
    ( cd "$ROOT" && grep -rnIE "${GREP_EXCLUDES[@]}" "${incs[@]}" -- "$joined" . 2>/dev/null ) >"$tmp"
  fi
  local n; n=$(wc -l <"$tmp" | tr -d ' ')
  {
    echo "## $title"; echo
    if [ "$n" -eq 0 ]; then echo "_no hits_"; else head -120 "$tmp"; [ "$n" -gt 120 ] && echo "... ($((n-120)) more — narrow the pattern or use ripgrep directly)"; fi
    echo
  } >>"$OUT"
  rm -f "$tmp"
  printf '  %-40s %s hits\n' "$label" "$n"
}

: >"$OUT"
{
  echo "# LLM call-site discovery: $ROOT"
  echo
  echo "Generated: $(date -Iseconds 2>/dev/null || date)"
  echo
  echo "This is a first-pass sweep. Verify every hit and look for what it misses"
  echo "(see references/discovery-checklist.md)."
  echo
  echo "## Dependency manifests (read these next to the hits below)"
  echo
  for f in package.json pyproject.toml requirements.txt Pipfile go.mod Cargo.toml Gemfile pom.xml build.gradle composer.json mix.exs; do
    [ -f "$ROOT/$f" ] && echo "- \`$f\`"
  done
  echo
} >>"$OUT"

echo "Scanning $ROOT …"
run_pat "sdk imports (js/ts)" "JS/TS — SDK imports and clients" "js,jsx,ts,tsx,mjs,cjs,vue,svelte,astro" \
  -e 'new OpenAI\(' -e 'new Anthropic\(' -e '@ai-sdk/' -e 'createOpenAI\(' -e 'createAnthropic\(' \
  -e 'generateText\(' -e 'streamText\(' -e 'generateObject\(' -e 'embedMany?\(' -e '"openai"|"@anthropic-ai/sdk"' \
  -e 'ChatOpenAI|ChatAnthropic|HumanMessage' -e 'langchain|llamaindex|mastra|@langchain' \
  -e 'chat\.completions\.create|responses\.create|messages\.create|embeddings\.create'

run_pat "sdk imports (python)" "Python — SDK imports and clients" "py" \
  -e 'from openai|import openai|OpenAI\(|AsyncOpenAI\(' -e 'from anthropic|import anthropic|Anthropic\(' \
  -e 'google\.generativeai|genai\.Client|vertexai' -e 'litellm\.|instructor\.|dspy\.' \
  -e 'ChatOpenAI|ChatAnthropic|PromptTemplate|\.invoke\(|\.predict\(' \
  -e 'boto3\.client\(.bedrock|invoke_model|converse\('

run_pat "sdk imports (other)" "Go / Rust / other — SDK clients" "go,rs,rb,java,kt,kts,cs,php,ex,exs" \
  -e 'openai\.NewClient|anthropic\.NewClient|genai\.NewClient|bedrockruntime' \
  -e 'async_openai|anthropic::|genai::|rig::' \
  -e 'Faraday|OpenAI::Client|Azure::OpenAI' -e 'BedrockRuntimeClient|ChatClient|OpenAIClient'

run_pat "model ids" "Model identifiers (strong leads)" "js,jsx,ts,tsx,py,go,rs,rb,java,kt,cs,php,yaml,yml,toml,env,example,json" \
  -e 'gpt-[0-9]' -e '\bo[134]-' -e 'claude-[a-z0-9]' -e 'gemini-[0-9]' -e 'text-embedding-' \
  -e 'text-moderation-|whisper-|tts-|dall-e' -e 'grok-|deepseek-|command-r|llama-[0-9]|qwen|phi-[0-9]|mistral-'

run_pat "wire endpoints" "Provider / gateway endpoints" "js,jsx,ts,tsx,py,go,rs,rb,java,kt,cs,php,yaml,yml,toml,env,example,json,conf,ini" \
  -e 'api\.openai\.com|api\.anthropic\.com|generativelanguage\.googleapis\.com' \
  -e 'openai\.azure\.com|bedrock-runtime\.[a-z0-9-]+\.amazonaws\.com' \
  -e 'api\.mistral\.ai|api\.cohere\.com|api\.groq\.com|openrouter\.ai|api\.together\.xyz|api\.replicate\.com' \
  -e 'localhost:11434|ollama' -e 'gateway\.ai\.cloudflare\.com|portkey|litellm|/v1/(chat/completions|responses|messages|embeddings|rerank|moderations|audio|images)'

run_pat "prompts" "Prompt files, builders, and prompt-ish strings" "js,jsx,ts,tsx,py,go,rs,rb,java,kt,cs,php,md,txt,jinja,j2,hbs,mustache,tmpl,prompt,yaml,yml,json" \
  -e 'prompts?/' -e 'system[_-]?prompt|SYSTEM_PROMPT|instructions:' -e 'buildPrompt|getSystemPrompt|renderPrompt|composePrompt|PromptTemplate' \
  -e 'you are (a|an|the) ' -e 'Your task is|You will be given' -e 'few[_-]?shot|chain[_-]?of[_-]?thought'

run_pat "env/config" "Env vars and config leads" "env,example,ini,conf,cfg,yaml,yml,toml,json,js,ts,tsx,jsx,py,go,rs,sh" \
  -e 'OPENAI_(API_KEY|BASE_URL)|ANTHROPIC_(API_KEY|BASE_URL)|GOOGLE_(API_KEY|GENAI)' \
  -e 'AZURE_OPENAI|AWS_BEDROCK|OLLAMA_HOST' -e 'LLM_|MODEL_|_MODEL='

run_pat "triggers" "Triggers: routes, jobs, queues, cron" "js,jsx,ts,tsx,py,go,rs,rb,java,kt,cs,php,ex,exs,yaml,yml,toml,json,sh" \
  -e 'export (async )?function (POST|GET|PUT)' -e 'app\.(post|get)\(|router\.(post|get)\(|procedure\(' \
  -e 'cron|setInterval|Celery|@task|CronJob|APScheduler|celerybeat' -e 'Queue\(|SQS|pubsub|webhook|onMessage\('

run_pat "agent/mcp" "Agent frameworks and MCP surfaces" "js,jsx,ts,tsx,py,go,rs,rb,java,kt,cs,php,ex,exs" \
  -e 'Agent\(|createAgent|AgentExecutor|StateGraph' -e '@modelcontextprotocol|McpServer|mcp\.' \
  -e 'tools: ?\[|tool[s]?:|function_calling|tool_choice'

{
  echo "## Non-chat LLM calls"
  echo
  echo "Check separately: embeddings, rerank, moderation, transcription, image/audio generation."
  echo
  echo "## Next steps"
  echo
  echo "1. Read every dependency hit in the manifests; map it to a surface or dismiss it."
  echo "2. Read every model-id and prompt hit; attach it to a call site or prove it dead."
  echo "3. Trace each candidate to its entrypoint and gating condition."
  echo "4. Look for indirect call sites: wrappers, factories, base-URL env vars, prompt registries."
  echo "5. Write the verified set to manifest.json — do not paste this sweep as the map."
  echo
  echo "Note: the sweep excludes .llmmap from the scan, so re-running it does not count its own output."
  echo "If your re-run count changes, investigate the new hits — stability is a coverage check."
} >>"$OUT"

echo
echo "Wrote $OUT"
echo "Remember: this sweep is a starting point, not the map. Read references/discovery-checklist.md."
