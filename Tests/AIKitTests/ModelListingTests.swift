import Foundation
import Testing

@testable import AIKit

/// A settings panel's "Fetch models" button. The catalog cannot answer this for
/// a local runtime or a gateway someone stood up this morning, so the endpoint
/// has to be asked — in three response shapes.
@Suite("Model listing")
struct ModelListingTests {

    @Test("the OpenAI-compatible shape is a data array of ids")
    func decodesOpenAIShape() throws {
        let body = try JSONValue.decode(from: """
            {"object": "list", "data": [
              {"id": "qwen3-coder:30b", "object": "model"},
              {"id": "llama4:16b", "object": "model"}
            ]}
            """)

        let models = AIClient.decodeModels(body, wire: .openAICompletions)

        #expect(models.map(\.id) == ["qwen3-coder:30b", "llama4:16b"])
    }

    @Test("the Anthropic shape carries a display name alongside the id")
    func decodesAnthropicShape() throws {
        let body = try JSONValue.decode(from: """
            {"data": [{"type": "model", "id": "claude-opus-4-8", "display_name": "Claude Opus 4.8"}]}
            """)

        let models = AIClient.decodeModels(body, wire: .anthropicMessages)

        #expect(models.first?.id == "claude-opus-4-8")
        #expect(models.first?.name == "Claude Opus 4.8")
    }

    @Test("the Gemini shape is path-qualified and mixed with non-chat models")
    func decodesGoogleShape() throws {
        let body = try JSONValue.decode(from: """
            {"models": [
              {"name": "models/gemini-3.5-flash", "displayName": "Gemini 3.5 Flash",
               "inputTokenLimit": 1048576, "outputTokenLimit": 65536,
               "supportedGenerationMethods": ["generateContent", "countTokens"]},
              {"name": "models/text-embedding-004", "displayName": "Embedding",
               "supportedGenerationMethods": ["embedContent"]}
            ]}
            """)

        let models = AIClient.decodeModels(body, wire: .googleGenerativeAI)

        // The `models/` prefix is on the wire but not in a request, and a model
        // that cannot serve a chat turn has no business in a model picker.
        #expect(models.map(\.id) == ["gemini-3.5-flash"])
        #expect(models.first?.contextWindow == 1_048_576)
        #expect(models.first?.maxOutputTokens == 65536)
    }

    @Test("each protocol's models endpoint sits where that vendor put it")
    func resolvesEndpoints() throws {
        func endpoint(_ wire: WireProtocol, _ base: String) -> String {
            AIClient.modelsEndpoint(wire: wire, base: URL(string: base)!).absoluteString
        }

        #expect(endpoint(.openAICompletions, "http://localhost:11434/v1") == "http://localhost:11434/v1/models")
        // A base URL without the version prefix gets one.
        #expect(endpoint(.anthropicMessages, "https://api.anthropic.com") == "https://api.anthropic.com/v1/models")
        #expect(endpoint(.googleGenerativeAI, "https://generativelanguage.googleapis.com") ==
            "https://generativelanguage.googleapis.com/v1beta/models")
    }

    @Test("a provider can be built for an endpoint the catalog has never seen")
    func buildsCustomProvider() throws {
        // The reason `ProviderInfo` needs a public initializer: a
        // "Custom (OpenAI-compatible)" entry in a settings panel has no catalog
        // row to look up.
        let provider = ProviderInfo(
            id: "custom",
            name: "Custom (OpenAI-compatible)",
            api: "https://gateway.example/v1",
            speaking: .openAICompletions
        )

        #expect(provider.wireProtocol == .openAICompletions)

        let client = AIClient(provider: provider, configuration: .init(apiKey: "k"))
        let body = client.encode(
            CallOptions(model: "some-model", prompt: [.user("hi")]),
            wire: .openAICompletions,
            model: nil
        ).body

        #expect(body["model"]?.stringValue == "some-model")
    }
}

@Suite("Catalog resources")
struct CatalogResourceTests {

    @Test("the bundled catalog is found without trusting Bundle.module")
    func findsTheResourceBundle() {
        // `Bundle.module` traps with fatalError when the bundle is missing, so
        // a packaging mistake in a host app would crash rather than degrade.
        // The searching loader reports instead.
        #expect(ProviderCatalog.isLoaded)
        #expect(ProviderCatalog.diagnostics.contains("providers"))
        #expect(ProviderCatalog.bundleName == "AIKitSwift_AIKit.bundle")
    }

    @Test("every bundled provider decodes")
    func nothingIsSilentlyDropped() {
        // The loader skips a file it cannot decode, so a schema drift upstream
        // costs a whole provider — every model it sells — without raising a
        // sound. This is the test that makes that noise.
        #expect(ProviderCatalog.skipped.isEmpty, "\(ProviderCatalog.skipped)")
    }

    @Test("a model keeps the effort levels upstream named")
    func effortValuesSurviveAnUnnamedLevel() {
        // sarvam-105b lists a null level alongside the named ones.
        let named = ProviderCatalog.all
            .flatMap { $0.models ?? [] }
            .flatMap { $0.reasoningOptions ?? [] }
            .flatMap { $0.values ?? [] }
        #expect(!named.isEmpty)
        #expect(!named.contains(""))
    }
}

@Suite("Catalog decoding")
struct CatalogDecodingTests {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: Data(json.utf8))
    }

    @Test("interleaved reads upstream's object form")
    func interleavedObject() throws {
        let model = try decode(
            ModelInfo.self,
            #"{"id": "m", "interleaved": {"field": "reasoning_content"}}"#
        )
        #expect(model.interleavedReasoningField == "reasoning_content")
    }

    @Test("interleaved reads upstream's bare boolean")
    func interleavedBoolean() throws {
        // `true` demands the replay without naming the field, which leaves the
        // dialect's default to supply it — not a decoding failure that would
        // cost the reader every other model in the file.
        let on = try decode(ModelInfo.self, #"{"id": "m", "interleaved": true}"#)
        #expect(on.interleaved?.required == true)
        #expect(on.interleavedReasoningField == nil)

        let off = try decode(ModelInfo.self, #"{"id": "m", "interleaved": false}"#)
        #expect(off.interleaved?.required == false)
        #expect(off.interleavedReasoningField == nil)
    }

    @Test("an explicit false outranks a field")
    func interleavedFalseWins() {
        let model = ModelInfo(id: "m", interleaved: .init(field: "thought", required: false))
        #expect(model.interleavedReasoningField == nil)
    }

    @Test("an unnamed effort level drops out of the list")
    func nullEffortValue() throws {
        let model = try decode(
            ModelInfo.self,
            #"{"id": "m", "reasoning_options": [{"type": "effort", "values": [null, "low", "high"]}]}"#
        )
        #expect(model.reasoningOptions?.first?.values == ["low", "high"])
    }

    @Test("interleaved round-trips through both forms")
    func interleavedRoundTrip() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        for value in [
            ModelInfo.Interleaved(field: "reasoning_content"),
            ModelInfo.Interleaved(field: nil),
            ModelInfo.Interleaved(field: nil, required: false),
        ] {
            let data = try JSONEncoder().encode(value)
            #expect(try decoder.decode(ModelInfo.Interleaved.self, from: data) == value)
        }
    }

    @Test("a provider file survives one model's unknown shape")
    func providerStillDecodes() throws {
        let provider = try decode(
            ProviderInfo.self,
            #"""
            {
              "id": "p",
              "adapter": "openai",
              "models": [
                {"id": "a", "interleaved": true},
                {"id": "b", "interleaved": {"field": "reasoning_content"}}
              ]
            }
            """#
        )
        #expect(provider.models?.count == 2)
        #expect(provider.model("b")?.interleavedReasoningField == "reasoning_content")
    }
}
