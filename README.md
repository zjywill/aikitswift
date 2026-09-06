# AIKit

A unified LLM provider layer for Swift. Many wire formats in, one normalized event
stream out.

[简体中文](README.zh-CN.md)

Anthropic's Messages API, OpenAI's Completions and Responses APIs and Google's
Generative AI API all describe the same conversation in mutually incompatible ways.
AIKit maps them onto a single event stream — modeled on the Vercel AI SDK's event
spec — so an app is written once instead of once per vendor.

```swift
let client = try AIClient(providerId: "deepseek", configuration: .init(apiKey: key))

for try await part in try client.stream(CallOptions(model: "deepseek-v4-flash", prompt: [
    .system("You are terse."),
    .user("Weather in Paris?"),
])) {
    switch part {
    case .textDelta(_, let delta, _):      render(delta)
    case .reasoningDelta(_, let delta, _): renderThinking(delta)
    case .toolCall(let call):              try await execute(call)
    case .finish(let usage, _, _):         report(usage)
    default:                               break
    }
}
```

Change `"deepseek"` to `"anthropic"`, `"google"` or any of the other 46 providers.
Nothing else in that loop changes.

When the events don't matter and only the outcome does, skip the loop:

```swift
let response = try await client.generate(options)   // non-streaming on the wire
response.text          // the answer, assembled
response.usage         // what it cost
```

`generate` sends a genuinely non-streaming request and decodes the complete body
through the same mappers a stream goes through, so the two paths cannot drift.
A stream can be drained into the same aggregate with
`try await client.stream(options).collect()`.

Multi-turn — including the tool loop — is append, not reconstruct:

```swift
prompt.append(response.assistantMessage)   // reasoning signatures survive intact
for call in response.pendingToolCalls {
    prompt.append(.toolResult(
        toolCallId: call.toolCallId,
        toolName: call.toolName,
        result: try await run(call)
    ))
}
```

`assistantMessage` keeps block order and thinking-block signatures — the two
things hand-built replay messages get wrong, and the reason Anthropic rejects
the next request when they are.

## The idea: protocols, not providers

The mistake to avoid is writing one implementation per vendor. The bundled catalog
holds **191 providers and 6237 models — but only 5 wire protocols**, because most
providers speak someone else's:

| Protocol | Providers |
|---|---|
| OpenAI Chat Completions | 38 |
| Anthropic Messages | 7 |
| OpenAI Responses | 2 |
| OpenAI Codex | 1 |
| Google Generative AI | 1 |

AIKit splits along that seam:

```
Sources/AIKit/
  Spec/        the normalized vocabulary — one enum every provider maps onto
  Wire/        one implementation per protocol   (5, the real work)
  Providers/   the catalog                       (191 JSON configs, pure data)
  Tokens/      context attribution
  Client/      the plumbing between them
```

A provider is data: a base URL, an auth method, a model list, and the `adapter`
naming the protocol it speaks. Adding one is a config file, not an implementation —
and it needs no new wire tests, because the protocol it points at is already covered.

That factoring is borrowed from [pi-ai][pi], which arrived at it independently. The
counter-example is worth naming too: a well-known Swift LLM client keeps its
provider layer in a single 6,000-line file, and supports fewer formats for it.

## Testing without API keys

Every provider integration faces the same problem: you cannot test what you cannot
call, and nobody holds keys for forty-nine vendors.

AIKit sidesteps it. The suite replays **97 recorded streams and 98 complete
response bodies** captured from real API calls — vendored from the [AI SDK][aisdk]
under MIT — and asserts the normalized output is well-formed. Recorded bytes in,
expected events out. No network, no credentials, no account.

```
$ swift test
Test run with 202 tests in 21 suites passed
```

Fixtures are grouped by **protocol**, not vendor, so the Chat Completions mapper is
validated against real traffic from seven vendors at once:

| Set | Recordings |
|---|---|
| `anthropic` | 27 |
| `openai-responses` | 29 |
| `google` | 20 |
| `xai` | 7 |
| `deepseek`, `groq`, `mistral` | 3 each |
| `openai-completions`, `openai-compatible` | 2 each |
| `cerebras` | 1 |

Invariants checked on every recording:

- text, reasoning and tool-input blocks form balanced `start → delta* → end` triads
- assembled tool-call arguments parse as JSON — fragments arrive individually
  invalid, so reassembly being off by one character is a real and silent failure
- `finish` appears exactly once, last, with internally consistent usage
- unrecognized chunks surface as `.raw` rather than vanishing, so a provider can
  ship a new event type without this library losing data

Refresh with `Scripts/sync-fixtures.sh`. A diff there is the earliest available
signal that a provider changed its wire format.

Beyond fixtures, an Anthropic-compatible local server such as [Osaurus][osaurus]
gives real end-to-end coverage over a real socket, also without keys.

## Context attribution

Where a request's tokens went, and how much window is left:

```swift
let usage = ContextReporter().report(
    options,
    contextWindow: ProviderCatalog.model("claude-opus-4-8")?.1.contextWindow,
    extras: [("Skills", 5_500), ("Memory files", 284)]
)

for entry in usage.entries {
    print(entry.segment.label, ContextUsage.format(entry.tokens),
          String(format: "%.1f%%", usage.share(of: entry) * 100))
}
// Messages       463.4k  46.3%
// System prompt    6.1k   0.6%
// Skills           5.5k   0.6%
// Memory files      284   0.0%
```

Attribution is provider-independent; only counting is provider-specific, so the
tokenizer is injected. The default estimator is script-aware — Latin text runs about
four characters per token while CJK runs closer to one, and a uniform `characters/4`
rule under-counts Chinese by roughly fourfold.

For an exact total, don't pay for it twice:

```swift
usage.calibrated(toTotal: lastResponse.inputTokens.total ?? 0)
```

The previous response's usage is authoritative and already paid for. Anchoring to it
gives an exact total with proportionally-correct segments and no extra network call.
Reach for a provider's `count_tokens` endpoint only when the figure is needed
*before* sending.

## Thinking, in both directions

```swift
CallOptions(model: "deepseek-v4-flash", prompt: prompt, thinking: .off)
CallOptions(model: "claude-opus-4-8",   prompt: prompt, thinking: .level(.high))
```

Leaving `thinking` unset is not the same as turning it off. DeepSeek, Qwen, GLM
and Gemini Flash reason **by default**, so an unset field buys thinking tokens
whether the task needs them or not — and writing a commit message is not a
reasoning problem, it is latency and money.

Off has three incompatible spellings on the wire, and enabling has seven more:

| | on | off |
|---|---|---|
| OpenAI-style | `reasoning_effort: "high"` | `reasoning_effort: "none"` — where the model has the word |
| DeepSeek, Z.ai | `thinking: {type: "enabled"}` | `thinking: {type: "disabled"}` |
| Qwen | `enable_thinking: true` | `enable_thinking: false`, `thinking_budget: 0` |
| Ollama, vLLM | `chat_template_kwargs.enable_thinking` | same, `false` |
| Anthropic (4.6+) | `thinking: {type: "adaptive"}` + `output_config.effort` | `thinking: {type: "disabled"}` |
| Anthropic (4.x) | `thinking: {type: "enabled", budget_tokens: N}` | `thinking: {type: "disabled"}` |
| Gemini 3 | `thinkingConfig.thinkingLevel` | its lowest level |
| Gemini 2.5 | `thinkingConfig.thinkingBudget` | `thinkingBudget: 0` |

`ThinkingLevel` is normalized (`minimal` … `max`) and clamped per model: `.max`
against a model that stops at `high` sends `high`, not a 400. Two cases the
catalog resolves rather than guessing — a model that *always* thinks (Claude
Fable 5, `deepseek-reasoner`) drops the request and warns instead of sending a
disable the API rejects, and a model whose floor is `minimal` rather than
silence is taken to its floor and says so.

## Asking an endpoint what it serves

```swift
let models = try await client.models()
```

The catalog cannot answer this for everyone: Ollama and LM Studio serve whatever
was pulled locally, and a gateway serves whatever its operator wired up. That is
the "Fetch models" button, and it is `GET /models` in three response shapes —
`data[].id`, Anthropic's `display_name`, and Gemini's path-qualified
`models/gemini-…` mixed in with embedding models that cannot serve a chat turn.
Results are enriched from the catalog where it knows the model, since no
`/models` response carries a context window.

For an endpoint with no catalog entry at all:

```swift
try await AIClient.models(at: url, speaking: .openAICompletions)
```

## Install

```swift
.package(url: "https://github.com/zjywill/aikitswift.git", branch: "main")
```

Then `import AIKit`. Swift 6, macOS 14+, iOS 17+. No dependencies.

**Packaging.** The catalog ships as a SwiftPM resource bundle,
`AIKitSwift_AIKit.bundle`. An app that assembles its own bundle must copy it
into `Contents/Resources` — `swift build` passing proves nothing about the
packaged `.app`. AIKit deliberately does not use SwiftPM's generated
`Bundle.module`, which calls `fatalError` when the bundle is missing: it
searches the plausible locations instead, so a packaging mistake degrades to an
empty catalog you can detect rather than a crash on first access.

```swift
guard ProviderCatalog.isLoaded else { fatalError(ProviderCatalog.diagnostics) }
```

## Status

Early, and the API will change. Streaming responses and request encoding work across
all five protocols; the catalog covers 191 providers.

| | |
|---|---|
| Normalized event spec | ✅ |
| SSE framing | ✅ |
| Anthropic Messages | ✅ stream + request |
| OpenAI Chat Completions | ✅ stream + request |
| OpenAI Responses | ✅ stream + request |
| Google Generative AI | ✅ stream + request |
| Provider catalog | ✅ 191 providers, 6237 models |
| Thinking on / off / level | ✅ all protocols |
| Live model listing (`GET /models`) | ✅ all protocols |
| Context attribution | ✅ |
| Non-streaming responses (`generate()`) | ✅ all protocols |
| Aggregated response + multi-turn replay (`AIResponse`) | ✅ |
| Server-tool results (code exec, MCP, web search) | ✅ all protocols |
| OAuth with PKCE + loopback | ✅ |
| Per-provider dialect quirks | ✅ see below |

**Dialects.** "38 providers speak Chat Completions" is a useful simplification,
not the truth. They speak thirty-eight dialects: some want
`max_completion_tokens`, some reject `strict`, some need a `name` on tool
results, and reasoning alone has seven incompatible request shapes across the
catalog. `CompletionsDialect` encodes those as data rather than branches, so one
encoder still serves all of them — the approach [pi-ai][pi] arrived at, and the
reason the JavaScript SDKs need a package per provider instead.

`supportsUsageInStreaming` is the flag worth knowing about: send
`stream_options.include_usage` to a provider that rejects it and the request
400s; omit it where it is supported and every token count silently vanishes.

**Honest caveat on coverage.** The Anthropic and OpenAI Responses server-tool
paths are tested against recorded traffic. The Gemini equivalents — code
execution, grounding — are not: no recording in the corpus exercises them, so
those tests encode the documented shapes instead. That is a weaker guarantee and
is flagged in the suite rather than papered over.

## Design notes

**Normalization follows the AI SDK.** The event vocabulary mirrors the AI SDK's
`LanguageModelV4StreamPart`, the most battle-tested normalization of this problem in
any ecosystem. Reusing its shape means its fixtures are directly usable as a
conformance suite, and its design review comes for free.

**Nothing is discarded.** Provider-specific detail that has no normalized home is
carried in `providerMetadata`, namespaced by provider. Unknown chunks pass through as
`.raw`. Raw usage payloads are preserved so a bill can be audited.

**Usage conventions disagree, and each one is encoded.** Three providers, three
different meanings for the same idea:

| | includes cached input? | includes reasoning in output? |
|---|---|---|
| Anthropic | no — add the cache legs back | n/a |
| OpenAI | yes — subtract to get uncached | yes — subtract to get text |
| Google | yes | **no** — add thoughts to get the total |

Applying one provider's arithmetic to another misprices silently rather than
failing. Each convention has its own test.

**Settings that would 400 are dropped and reported.** Newer Anthropic models reject
`temperature` outright. The catalog knows which, so the encoder drops it and emits a
`Warning` on `streamStart` instead of letting the request fail.

**Tool inputs stay strings.** `ToolCall.input` is the JSON *text* that streamed in,
not a parsed object, because re-encoding a parsed value would not reproduce the
original bytes. Parse at the point of use.

**`nil` means unreported.** Every usage field is optional and distinguishes "the
provider did not say" from zero.

**Key order is sorted on encode.** Prompt caching is a byte-level prefix match, so
unstable key ordering in a request body silently destroys every cache hit. This is
the kind of thing that costs money quietly rather than failing loudly.

## Prior art

- **[vercel/ai][aisdk]** — the normalized event spec, and the fixture corpus this
  library is tested against. MIT.
- **[pi-ai][pi]** — the protocol/provider split, and a reminder of how much of a
  provider layer is configuration rather than code.
- **[Osaurus][osaurus]** — Swift-native, and a usable local test target.

## License

MIT.

Recorded fixtures under `Tests/AIKitTests/Fixtures/` are vendored from
[vercel/ai][aisdk] and keep its MIT license — see the `PROVENANCE.md` there. The
provider catalog under `Sources/AIKit/Catalog/` is vendored data refreshed by
`Scripts/sync-catalog.sh`.

[aisdk]: https://github.com/vercel/ai
[pi]: https://github.com/earendil-works/pi
[osaurus]: https://github.com/osaurus-ai/osaurus
