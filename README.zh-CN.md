# AIKit

Swift 的统一 LLM provider 层。多种 wire format 进，一条归一化事件流出。

[English](README.md)

Anthropic 的 Messages API、OpenAI 的 Completions 和 Responses、Google 的 Generative
AI，描述的是同一件事，但格式互不兼容。AIKit 把它们映射到同一条事件流上 —— 事件规范对齐
Vercel AI SDK —— 让应用只写一遍，而不是每接一家写一遍。

```swift
let client = try AIClient(providerId: "deepseek", configuration: .init(apiKey: key))

for try await part in try client.stream(CallOptions(model: "deepseek-v4-flash", prompt: [
    .system("回答简洁。"),
    .user("巴黎天气怎么样？"),
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

把 `"deepseek"` 换成 `"anthropic"`、`"google"` 或另外 46 家中的任意一家 —— 这个循环里
不用改任何东西。

只要结果、不关心过程事件时，循环也可以省掉：

```swift
let response = try await client.generate(options)   // wire 上是真正的非流式请求
response.text          // 拼好的回答
response.usage         // 花了多少 token
```

`generate` 发送的是真正的非流式请求，完整响应体走的是与流式相同的 mapper，两条路径
不可能产生分歧。流式响应也能收拢成同一个聚合结果：
`try await client.stream(options).collect()`。

多轮对话（包括工具循环）是"追加"，不是"手工重建"：

```swift
prompt.append(response.assistantMessage)   // reasoning 签名原样保留
for call in response.pendingToolCalls {
    prompt.append(.toolResult(
        toolCallId: call.toolCallId,
        toolName: call.toolName,
        result: try await run(call)
    ))
}
```

`assistantMessage` 保持块的顺序、保留 thinking 块的签名 —— 这正是手工重建最容易出错
的两处，也是 Anthropic 拒收下一条请求的原因。

## 核心思路：按协议切，不按厂商切

最该避免的错误是每家厂商写一套实现。内置的 catalog 里有 **190 家 provider、6190 个模型，
但只有 5 种 wire protocol** —— 因为大多数厂商说的是别人的协议：

| 协议 | provider 数 |
|---|---|
| OpenAI Chat Completions | 38 |
| Anthropic Messages | 7 |
| OpenAI Responses | 2 |
| OpenAI Codex | 1 |
| Google Generative AI | 1 |

AIKit 就沿着这条缝切开：

```
Sources/AIKit/
  Spec/        归一化词汇表 —— 所有 provider 都映射到同一个 enum
  Wire/        每个协议一份实现   （5 个，真正的工作量在这）
  Providers/   catalog            （190 个 JSON 配置，纯数据）
  Tokens/      上下文分摊
  Client/      把它们连起来的管道
```

一个 provider 就是数据：base URL、认证方式、模型列表，以及标明它说哪种协议的 `adapter`
字段。加一家是写配置，不是写实现 —— 而且**不需要新的 wire 测试**，因为它指向的协议早就
被覆盖了。

这个切法借鉴自 [pi-ai][pi]，是各自独立得出的同一结论。反面教材也值得一提：某个知名的
Swift LLM 客户端把 provider 层塞在一个 6000 行的文件里，支持的格式反而更少。

## 没有 API key 也能测

做 provider 集成的人都会遇到同一个问题：调不通的东西没法测，而没人手里有 186 家的 key。

AIKit 绕开了它。测试套件回放 **97 组真实录制的流 + 98 个完整响应体**（从 [AI SDK][aisdk]
按 MIT 协议 vendored 过来），断言归一化后的输出结构正确。录制的字节进，期望的事件出。
不联网、无凭证、不需要账号。

```
$ swift test
Test run with 202 tests in 21 suites passed
```

Fixture 按**协议**分组而非按厂商，所以 Chat Completions 这一个 mapper 同时被 7 家厂商的
真实流量验证：

| 集合 | 录制数 |
|---|---|
| `anthropic` | 27 |
| `openai-responses` | 29 |
| `google` | 20 |
| `xai` | 7 |
| `deepseek`、`groq`、`mistral` | 各 3 |
| `openai-completions`、`openai-compatible` | 各 2 |
| `cerebras` | 1 |

每组录制都会检查这些不变量：

- text / reasoning / tool-input 三者都构成配平的 `start → delta* → end` 三元组
- 拼装出的 tool 参数能解析成 JSON —— 分片单独都是非法 JSON，错一个字符就废，而且这种错
  只会在真实调用时才暴露
- `finish` 恰好出现一次、在最后，且 usage 内部自洽
- 未识别的 chunk 走 `.raw` 而不是消失，这样 provider 上新事件类型时本库不会丢数据

用 `Scripts/sync-fixtures.sh` 刷新。这里出现 diff，是 provider 改了 wire format 的最早
信号。

除 fixture 外，[Osaurus][osaurus] 这类 Anthropic 兼容的本地服务器可以提供走真实 socket
的端到端覆盖，同样不需要 key。

## 上下文分摊

一次请求的 token 花在哪了，窗口还剩多少：

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

**分摊与 provider 无关，只有计数是 provider 专属的**，所以 tokenizer 是注入进来的。默认
的估算器按字符所属文字系统区分 —— 拉丁文约 4 字符 1 token，而中日韩接近 1 字符 1 token；
统一按 `字符数 / 4` 算会把中文少算约四倍。

要精确总数，别花两遍钱：

```swift
usage.calibrated(toTotal: lastResponse.inputTokens.total ?? 0)
```

上一次响应里的 usage 是权威值，而且已经付过费了。用它作锚点缩放，就能得到**精确的总数
和比例正确的分段，且零额外网络调用**。只有在发送**之前**就要知道数字时，才需要走 provider
的 `count_tokens` 端点。

## 思考：既能开，也能关

```swift
CallOptions(model: "deepseek-v4-flash", prompt: prompt, thinking: .off)
CallOptions(model: "claude-opus-4-8",   prompt: prompt, thinking: .level(.high))
```

不设 `thinking` 不等于关掉它。DeepSeek、Qwen、GLM、Gemini Flash **默认开思考**，
所以字段空着就是在为思考 token 买单——而写一条 commit message 不是推理问题，那些
token 只是延迟和钱。

关的写法有三种互不兼容，开的写法还有七种：

| | 开 | 关 |
|---|---|---|
| OpenAI 系 | `reasoning_effort: "high"` | `reasoning_effort: "none"`——模型词表里有这个词才发 |
| DeepSeek、Z.ai | `thinking: {type: "enabled"}` | `thinking: {type: "disabled"}` |
| Qwen | `enable_thinking: true` | `enable_thinking: false`、`thinking_budget: 0` |
| Ollama、vLLM | `chat_template_kwargs.enable_thinking` | 同上，`false` |
| Anthropic（4.6+） | `thinking: {type: "adaptive"}` + `output_config.effort` | `thinking: {type: "disabled"}` |
| Anthropic（4.x） | `thinking: {type: "enabled", budget_tokens: N}` | `thinking: {type: "disabled"}` |
| Gemini 3 | `thinkingConfig.thinkingLevel` | 该模型的最低档 |
| Gemini 2.5 | `thinkingConfig.thinkingBudget` | `thinkingBudget: 0` |

`ThinkingLevel` 是归一化的（`minimal` … `max`），按模型裁剪：对只支持到 `high` 的
模型请求 `.max`，发出去的是 `high`，而不是一个 400。两种情况由 catalog 判断而不是
瞎猜——**永远思考**的模型（Claude Fable 5、`deepseek-reasoner`）会丢掉这个请求并给出
warning，而不是发一个会被拒绝的 disable；下限只到 `minimal` 而非静默的模型，会被压到
下限并说明差别。

## 问端点要模型列表

```swift
let models = try await client.models()
```

这个问题 catalog 答不了：Ollama、LM Studio 提供的是本地拉了什么，自建 gateway 提供的
是运维接了什么。这就是设置面板里的 "Fetch models" 按钮——`GET /models`，三种响应形状：
`data[].id`、Anthropic 的 `display_name`，以及 Gemini 带路径前缀的 `models/gemini-…`
（还混着不能对话的 embedding 模型）。catalog 认识的模型会被补全元数据，因为没有哪个
`/models` 响应带上下文窗口。

catalog 里完全没有的端点：

```swift
try await AIClient.models(at: url, speaking: .openAICompletions)
```

## 安装

```swift
.package(url: "https://github.com/zjywill/aikitswift.git", branch: "main")
```

然后 `import AIKit`。Swift 6，macOS 14+、iOS 17+。无依赖。

**打包。** catalog 以 SwiftPM 资源 bundle 的形式分发，名字是
`AIKitSwift_AIKit.bundle`。自己组装 .app 的话，必须把它一起拷进 `Contents/Resources`
——`swift build` 过了不能证明打包好的 .app 没问题。AIKit 特意没有用 SwiftPM 生成的
`Bundle.module`：它在 bundle 缺失时是 `fatalError`。这里改成搜索若干候选位置，于是
打包失误退化成一个可检测的空 catalog，而不是首次访问时崩溃。

```swift
guard ProviderCatalog.isLoaded else { fatalError(ProviderCatalog.diagnostics) }
```

## 现状

早期，API 会变。五种协议的流式响应和请求编码都能用了，catalog 覆盖 190 家。

| | |
|---|---|
| 归一化事件规范 | ✅ |
| SSE 分帧 | ✅ |
| Anthropic Messages | ✅ 流式 + 请求 |
| OpenAI Chat Completions | ✅ 流式 + 请求 |
| OpenAI Responses | ✅ 流式 + 请求 |
| Google Generative AI | ✅ 流式 + 请求 |
| Provider catalog | ✅ 190 家、6190 模型 |
| 思考开 / 关 / 分级 | ✅ 全协议 |
| 在线模型列表（`GET /models`） | ✅ 全协议 |
| 上下文分摊 | ✅ |
| 非流式响应（`generate()`） | ✅ 全协议 |
| 聚合结果与多轮回放（`AIResponse`） | ✅ |
| Server tool 结果（代码执行 / MCP / 联网搜索） | ✅ 全协议 |
| OAuth（PKCE + 回环监听） | ✅ |
| 各家方言差异 | ✅ 见下 |

**方言。** "38 家说 OpenAI 协议"是个有用的简化，不是事实 —— 它们说的是三十八种方言。
有的要 `max_completion_tokens`，有的不认 `strict`，有的要求 tool result 带 `name`；
光是 reasoning 一项，catalog 里就有七种互不兼容的请求形状。`CompletionsDialect` 把这些
差异编码成**数据而非分支**，所以一个编码器仍然服务所有人 —— 这是 [pi-ai][pi] 的做法，
也是 JS 生态不得不每家发一个包的原因。

其中 `supportsUsageInStreaming` 最值得注意：向不支持的 provider 发
`stream_options.include_usage` 会 400；向支持的 provider 漏发，则所有 token 计数**静默
消失**。两个方向都会出事。

**关于覆盖度的诚实说明。** Anthropic 和 OpenAI Responses 的 server tool 路径是拿真实录
制的流量测的。Gemini 那部分（代码执行、grounding）不是 —— 语料里没有任何一条录制触及它
们，所以那几个测试编码的是文档形状而非捕获流量。这是更弱的保证，我在测试套件里标注了，
没有蒙混过去。

## 设计取舍

**归一化对齐 AI SDK。** 事件词汇表镜像 AI SDK 的 `LanguageModelV4StreamPart` —— 这是整
个生态里对这个问题打磨得最充分的一套归一化。沿用它的形状意味着它的 fixture 可以直接当
conformance 套件用，它的设计评审也白送。

**什么都不丢。** 没有归一化归宿的 provider 专属细节，按 provider 命名空间放进
`providerMetadata`；未识别的 chunk 原样走 `.raw`；原始 usage 载荷完整保留，以便对账。

**三家的 usage 口径互相矛盾，每一种都单独编码。** 同一个概念，三种含义：

| | 输入含缓存吗？ | 输出含推理吗？ |
|---|---|---|
| Anthropic | 否 —— 要把缓存两条腿加回去 | 不适用 |
| OpenAI | 是 —— 要减掉才得到未缓存量 | 是 —— 要减掉才得到正文 |
| Google | 是 | **否** —— 要加上 thoughts 才是总量 |

拿一家的算法套另一家，**不会报错，只会算错钱**。每种口径都有独立测试。

**会导致 400 的参数会被丢弃并上报。** 较新的 Anthropic 模型直接拒收 `temperature`。
catalog 里记录了哪些模型如此，编码器据此丢弃该参数并在 `streamStart` 上发一条
`Warning`，而不是让请求失败。

**Tool 参数保持字符串。** `ToolCall.input` 是流进来的 JSON **文本**，不是解析后的对象 ——
因为重新编码一个已解析的值无法还原原始字节。要用的时候再解析。

**`nil` 表示"没报"。** 所有 usage 字段都是可选的，"provider 没说"和"值为零"是两回事。

**编码时对 key 排序。** Prompt 缓存是字节级前缀匹配，请求体里 key 顺序不稳定会悄悄摧毁
所有缓存命中。这类问题不会报错，只会安静地烧钱。

## 参照

- **[vercel/ai][aisdk]** —— 归一化事件规范，以及本库据以测试的 fixture 语料。MIT。
- **[pi-ai][pi]** —— 协议/provider 的二分法，以及"provider 层里有多大比例其实是配置而非
  代码"这个提醒。
- **[Osaurus][osaurus]** —— 原生 Swift，也是个好用的本地被测端。

## 许可

MIT。

`Tests/AIKitTests/Fixtures/` 下的录制 fixture vendored 自 [vercel/ai][aisdk]，沿用其
MIT 许可，目录下有 `PROVENANCE.md`。`Sources/AIKit/Catalog/` 下的 provider catalog 是
vendored 数据，用 `Scripts/sync-catalog.sh` 刷新。

[aisdk]: https://github.com/vercel/ai
[pi]: https://github.com/earendil-works/pi
[osaurus]: https://github.com/osaurus-ai/osaurus
