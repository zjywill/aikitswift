import Foundation

/// What a model can do, and what it costs to talk to.
///
/// Sourced from the vendored catalog rather than hardcoded, so capability
/// changes track upstream instead of rotting in Swift.
public struct ModelInfo: Sendable, Hashable, Codable {
    public struct Reasoning: Sendable, Hashable, Codable {
        /// A token range for models whose thinking depth is a number.
        public struct Budget: Sendable, Hashable, Codable {
            public var min: Int?
            public var max: Int?
            /// The provider's own default. `-1` means "the model decides".
            public var `default`: Int?

            public init(min: Int? = nil, max: Int? = nil, default defaultValue: Int? = nil) {
                self.min = min
                self.max = max
                self.default = defaultValue
            }
        }

        public var supported: Bool?
        /// Whether reasoning is on when the request says nothing.
        ///
        /// The field that makes an explicit *off* switch necessary: where this
        /// is `true` — DeepSeek, Qwen, GLM, Gemini Flash — saying nothing buys
        /// thinking tokens whether the task needs them or not.
        public var `default`: Bool?
        public var budget: Budget?

        public init(supported: Bool? = nil, default defaultValue: Bool? = nil, budget: Budget? = nil) {
            self.supported = supported
            self.default = defaultValue
            self.budget = budget
        }
    }

    /// One way a model's thinking can be controlled.
    ///
    /// Kept as loose data because the vocabulary is upstream's, not ours: a
    /// `type` this library has not seen yet decodes and is ignored rather than
    /// failing the model.
    public struct ReasoningOption: Sendable, Hashable, Codable {
        /// `toggle`, `effort`, or `budget_tokens`.
        public var type: String?
        /// Effort names this model accepts, for `type == "effort"`.
        public var values: [String]?
        public var min: Int?
        public var max: Int?

        public init(type: String? = nil, values: [String]? = nil, min: Int? = nil, max: Int? = nil) {
            self.type = type
            self.values = values
            self.min = min
            self.max = max
        }

        private enum CodingKeys: String, CodingKey {
            case type, values, min, max
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decodeIfPresent(String.self, forKey: .type)
            // Upstream spells an unnamed effort level as a null in the list.
            // It drops out; a nameless level is nothing an encoder can send,
            // and failing here would take the whole provider file down.
            values = try container
                .decodeIfPresent([String?].self, forKey: .values)?
                .compactMap { $0 }
            min = try container.decodeIfPresent(Int.self, forKey: .min)
            max = try container.decodeIfPresent(Int.self, forKey: .max)
        }
    }

    /// How a model's thinking must be carried back across a tool-calling turn.
    ///
    /// Most reasoning models treat their own thinking as write-only: it comes
    /// back on the response and is discarded from the history. A few do not.
    /// DeepSeek's thinking models require the `reasoning_content` of every
    /// intermediate assistant message to be replayed verbatim on any request
    /// that carries `tools`, and answer a request that omits it with a 400 —
    /// which makes this the difference between an agent loop that runs and one
    /// that dies on its second request.
    ///
    /// `field` names the request field the text goes back in.
    ///
    /// Upstream writes this two ways: an object naming the field, or a bare
    /// boolean that says whether the replay is demanded without saying where
    /// it goes. Both decode — the bare `true` leans on the dialect's default
    /// field — because a model shape this library has not seen should cost one
    /// model's detail, not the whole provider file.
    public struct Interleaved: Sendable, Hashable, Codable {
        /// Whether the replay is demanded at all. Upstream's bare `false`
        /// says it is not.
        public var required: Bool
        public var field: String?

        public init(field: String? = nil, required: Bool = true) {
            self.field = field
            self.required = required
        }

        private enum CodingKeys: String, CodingKey {
            case field
        }

        public init(from decoder: any Decoder) throws {
            if let flag = try? decoder.singleValueContainer().decode(Bool.self) {
                required = flag
                field = nil
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            required = true
            field = try container.decodeIfPresent(String.self, forKey: .field)
        }

        public func encode(to encoder: any Encoder) throws {
            // Written back in whichever form carries the whole value: the
            // object once there is a field to name, the bare flag otherwise.
            guard required, let field else {
                var container = encoder.singleValueContainer()
                try container.encode(required)
                return
            }
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(field, forKey: .field)
        }
    }

    public struct Limit: Sendable, Hashable, Codable {
        /// Context window, in tokens. The denominator for a context-usage report.
        public var context: Int?
        /// Maximum output tokens per request.
        public var output: Int?
    }

    public struct Modalities: Sendable, Hashable, Codable {
        public var input: [String]?
        public var output: [String]?
    }

    public var id: String
    public var name: String?
    public var description: String?
    public var family: String?

    /// Whether files can be attached to a prompt.
    public var attachment: Bool?
    public var reasoning: Reasoning?
    /// How this model's thinking can be controlled — toggled, tuned by effort,
    /// or given a token budget. Often several at once.
    public var reasoningOptions: [ReasoningOption]?
    /// Whether this model's thinking has to be replayed back to it. See
    /// ``ModelInfo/Interleaved``.
    public var interleaved: Interleaved?
    public var toolCall: Bool?
    public var structuredOutput: Bool?

    /// Whether the model accepts a sampling temperature at all.
    ///
    /// `false` on newer Anthropic models, which reject the parameter outright
    /// rather than ignoring it. Encoders consult this to drop the setting and
    /// warn instead of letting the request fail with a 400.
    public var temperature: Bool?

    public var limit: Limit?
    public var modalities: Modalities?
    public var openWeights: Bool?
    public var knowledge: String?
    public var releaseDate: String?
    public var lastUpdated: String?

    public init(
        id: String,
        name: String? = nil,
        description: String? = nil,
        family: String? = nil,
        attachment: Bool? = nil,
        reasoning: Reasoning? = nil,
        reasoningOptions: [ReasoningOption]? = nil,
        interleaved: Interleaved? = nil,
        toolCall: Bool? = nil,
        structuredOutput: Bool? = nil,
        temperature: Bool? = nil,
        limit: Limit? = nil,
        modalities: Modalities? = nil,
        openWeights: Bool? = nil,
        knowledge: String? = nil,
        releaseDate: String? = nil,
        lastUpdated: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.family = family
        self.attachment = attachment
        self.reasoning = reasoning
        self.reasoningOptions = reasoningOptions
        self.interleaved = interleaved
        self.toolCall = toolCall
        self.structuredOutput = structuredOutput
        self.temperature = temperature
        self.limit = limit
        self.modalities = modalities
        self.openWeights = openWeights
        self.knowledge = knowledge
        self.releaseDate = releaseDate
        self.lastUpdated = lastUpdated
    }

    public var contextWindow: Int? {
        guard let context = limit?.context, context > 0 else { return nil }
        return context
    }
    public var maxOutputTokens: Int? {
        guard let output = limit?.output, output > 0 else { return nil }
        return output
    }
    public var supportsTools: Bool { toolCall ?? false }
    public var supportsReasoning: Bool { reasoning?.supported ?? false }
    /// The request field this model's own thinking must be replayed in, if it
    /// demands that at all. Nil for the overwhelming majority.
    public var interleavedReasoningField: String? {
        guard let interleaved, interleaved.required else { return nil }
        guard let field = interleaved.field, !field.isEmpty else { return nil }
        return field
    }
    /// Newer models reject `temperature`; absence of the flag means unknown, so
    /// it is treated as accepted.
    public var supportsTemperature: Bool { temperature ?? true }
    public var supportsVision: Bool { modalities?.input?.contains("image") ?? false }
}

// MARK: - Thinking

extension ModelInfo {

    /// What can actually be asked of this model's thinking.
    ///
    /// Flattened from the catalog's several overlapping fields so encoders ask
    /// one question — "can this be turned off, and how deep can it go?" —
    /// instead of re-deriving the answer from raw JSON four times.
    public struct ThinkingCapability: Sendable, Hashable {
        public var supported: Bool
        /// Whether thinking happens when the request says nothing.
        public var defaultOn: Bool
        /// Whether the model advertises an explicit on/off switch.
        public var hasToggle: Bool
        /// Effort names this model accepts, in the provider's own vocabulary.
        public var effortValues: [String]
        public var budgetRange: ClosedRange<Int>?

        /// Whether an explicit *off* can be honoured.
        ///
        /// A model that thinks by default and offers neither a toggle, a zero
        /// budget, nor a `none` effort cannot be quieted — Claude Fable 5 and
        /// `deepseek-reasoner` are the shape of this. Anything the catalog does
        /// not describe is assumed disablable, since defaulting to "you cannot"
        /// would silently keep paying for thinking.
        public var canDisable: Bool {
            guard supported, defaultOn else { return true }
            return hasToggle || offEffort != nil || (budgetRange?.lowerBound == 0)
        }

        /// The effort value that means "don't think", where the vocabulary has
        /// one. `minimal` is the nearest approximation where `none` is absent.
        public var offEffort: String? {
            if effortValues.contains("none") { return "none" }
            if effortValues.contains("minimal") { return "minimal" }
            return nil
        }

        /// Whether "off" can only be approximated.
        ///
        /// Gemini 3 Flash is the case: its floor is `minimal`, not silence, so
        /// the request is honoured as closely as the model allows and the
        /// caller is told the difference.
        public var disableIsApproximate: Bool {
            guard canDisable, supported, defaultOn else { return false }
            if hasToggle || budgetRange?.lowerBound == 0 { return false }
            return offEffort == "minimal"
        }

        /// The accepted effort name closest to a requested level.
        ///
        /// Ties go to the cheaper rung, and `none` is never chosen — asking to
        /// think harder must not turn thinking off.
        public func nearestEffort(to level: ThinkingLevel) -> String? {
            let candidates = effortValues.compactMap { value in
                ThinkingLevel(rawValue: value).map { ($0, value) }
            }
            guard !candidates.isEmpty else { return nil }

            return candidates.min { lhs, rhs in
                let left = abs(lhs.0.rank - level.rank)
                let right = abs(rhs.0.rank - level.rank)
                return left == right ? lhs.0.rank < rhs.0.rank : left < right
            }?.1
        }

        /// A token budget for a requested level, clamped to the model's range.
        public func budget(for level: ThinkingLevel) -> Int? {
            guard budgetRange != nil else { return nil }
            return clampBudget(level.budgetTokens)
        }

        public func clampBudget(_ tokens: Int) -> Int {
            guard let range = budgetRange else { return tokens }
            return Swift.min(Swift.max(tokens, range.lowerBound), range.upperBound)
        }

        var budgetDescription: String {
            guard let range = budgetRange else { return "any" }
            return "\(range.lowerBound)–\(range.upperBound)"
        }
    }

    public var thinkingCapability: ThinkingCapability {
        let options = reasoningOptions ?? []

        var efforts: [String] = []
        var lower: Int?
        var upper: Int?
        var hasToggle = false

        for option in options {
            switch option.type {
            case "effort":
                efforts.append(contentsOf: option.values ?? [])
            case "budget_tokens":
                lower = option.min ?? lower
                upper = option.max ?? upper
            case "toggle":
                hasToggle = true
            default:
                break
            }
        }

        // Some providers describe the budget on `reasoning` instead of as an
        // option; either is authoritative.
        lower = lower ?? reasoning?.budget?.min
        upper = upper ?? reasoning?.budget?.max

        var range: ClosedRange<Int>?
        if lower != nil || upper != nil {
            let low = lower ?? 0
            // No advertised ceiling: the model's output cap is the real bound,
            // since thinking is drawn from the same budget.
            let high = Swift.max(upper ?? maxOutputTokens ?? 32768, low)
            range = low...high
        }

        return ThinkingCapability(
            supported: reasoning?.supported ?? !options.isEmpty,
            defaultOn: reasoning?.default ?? false,
            hasToggle: hasToggle,
            effortValues: efforts,
            budgetRange: range
        )
    }
}

/// A provider: where to send a request, how to authenticate, and — the field
/// that matters most — which wire protocol it speaks.
public struct ProviderInfo: Sendable, Hashable, Codable {

    /// A provider-level override for how thinking is switched on and off.
    ///
    /// Resellers of the Anthropic protocol rename the values — MiniMax wants
    /// `adaptive` where Anthropic wants `enabled` — so the field path and both
    /// values travel as data rather than as a branch per provider.
    public struct ReasoningToggle: Sendable, Hashable, Codable {
        /// Dotted path into the request body, e.g. `thinking.type`.
        public var field: String
        public var enabled: String?
        public var disabled: String?

        public init(field: String, enabled: String? = nil, disabled: String? = nil) {
            self.field = field
            self.enabled = enabled
            self.disabled = disabled
        }

        /// Writes `value` at this toggle's path, creating intermediate objects.
        func apply(_ value: String, to body: inout [String: JSONValue]) {
            let path = field.split(separator: ".").map(String.init)
            guard !path.isEmpty else { return }
            body = Self.write(.string(value), at: path[...], into: body)
        }

        private static func write(
            _ value: JSONValue,
            at path: ArraySlice<String>,
            into object: [String: JSONValue]
        ) -> [String: JSONValue] {
            guard let key = path.first else { return object }

            var object = object
            if path.count == 1 {
                object[key] = value
            } else {
                let nested = object[key]?.objectValue ?? [:]
                object[key] = .object(write(value, at: path.dropFirst(), into: nested))
            }
            return object
        }
    }

    public var id: String
    public var name: String?
    /// Base URL. Absent for providers whose endpoint is configured per install
    /// (self-hosted gateways, local runtimes).
    public var api: String?
    /// The wire protocol, as named upstream.
    ///
    /// Kept as a raw string so an adapter this library has not implemented yet
    /// still loads instead of failing the whole catalog.
    public var adapter: String?
    /// How this provider spells "think" and "don't", when it differs from the
    /// protocol's own spelling.
    public var reasoningToggle: ReasoningToggle?
    public var models: [ModelInfo]?

    /// Memberwise, and public — an app that lets a user point at an arbitrary
    /// OpenAI-compatible endpoint has to be able to build one of these without
    /// finding it in the catalog first.
    public init(
        id: String,
        name: String? = nil,
        api: String? = nil,
        adapter: String? = nil,
        reasoningToggle: ReasoningToggle? = nil,
        models: [ModelInfo]? = nil
    ) {
        self.id = id
        self.name = name
        self.api = api
        self.adapter = adapter
        self.reasoningToggle = reasoningToggle
        self.models = models
    }

    /// Convenience for a user-configured endpoint: id, URL, and the protocol
    /// it speaks.
    public init(id: String, name: String? = nil, api: String?, speaking wire: WireProtocol) {
        self.init(id: id, name: name, api: api, adapter: wire.rawValue)
    }

    /// The implemented protocol for this provider, if there is one.
    public var wireProtocol: WireProtocol? {
        adapter.flatMap(WireProtocol.init(rawValue:))
    }

    public func model(_ id: String) -> ModelInfo? {
        models?.first { $0.id == id }
    }
}

/// The bundled provider catalog.
///
/// Loaded once, lazily, from JSON shipped with the package. Adding a provider
/// upstream needs no Swift changes here at all.
public enum ProviderCatalog {

    /// Every provider in the catalog, sorted by id.
    public static var all: [ProviderInfo] { loaded.providers }

    /// Catalog files that were found but could not be decoded, with the reason.
    ///
    /// Empty in every shipped build — a non-empty list means upstream's schema
    /// moved and those providers are missing from ``all``. Surfaced here
    /// because the loader skips them quietly, which is the right behaviour at
    /// runtime and an invisible one in a test.
    public static var skipped: [String] { loaded.skipped }

    private static let loaded: (providers: [ProviderInfo], skipped: [String]) = load()

    private static let byId: [String: ProviderInfo] = Dictionary(
        all.map { ($0.id, $0) },
        uniquingKeysWith: { first, _ in first }
    )

    public static func provider(_ id: String) -> ProviderInfo? { byId[id] }

    /// Providers speaking a given protocol.
    public static func providers(speaking wire: WireProtocol) -> [ProviderInfo] {
        all.filter { $0.wireProtocol == wire }
    }

    /// Finds a model by id, searching every provider.
    ///
    /// Model ids are not globally unique — several providers resell the same
    /// model — so this returns the first match. Pass a provider id when the
    /// distinction matters.
    public static func model(_ modelId: String, provider providerId: String? = nil) -> (ProviderInfo, ModelInfo)? {
        let candidates = providerId.flatMap { byId[$0].map { [$0] } } ?? all

        for provider in candidates {
            if let model = provider.model(modelId) { return (provider, model) }
        }
        return nil
    }

    /// Whether the catalog actually loaded.
    ///
    /// `false` means the resource bundle was not found — almost always a
    /// packaging problem in the host app rather than anything about the
    /// catalog. An app that depends on the catalog should check this at launch
    /// and show ``diagnostics`` rather than presenting an empty provider list.
    public static var isLoaded: Bool { !all.isEmpty }

    /// The name SwiftPM gives the resource bundle: `<package>_<target>.bundle`.
    ///
    /// A packaging script has to copy this into `Contents/Resources`; it is
    /// spelled out here so the script and the loader cannot drift apart.
    public static let bundleName = "AIKitSwift_AIKit.bundle"

    /// Where the loader looked, for when it found nothing.
    public static var diagnostics: String {
        if let directory = catalogDirectory {
            let base = "Catalog loaded from \(directory.path) (\(all.count) providers)."
            guard !skipped.isEmpty else { return base }
            return base + " Skipped \(skipped.count):\n  " + skipped.joined(separator: "\n  ")
        }
        let searched = searchRoots.map(\.path).joined(separator: "\n  ")
        return """
            Could not find \(bundleName). Copy it into the app's Resources \
            directory alongside the executable. Searched:
              \(searched)
            """
    }

    private static func load() -> (providers: [ProviderInfo], skipped: [String]) {
        guard let directory = catalogDirectory,
              let files = try? FileManager.default.contentsOfDirectory(
                  at: directory, includingPropertiesForKeys: nil
              )
        else {
            return ([], [])
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        var providers: [ProviderInfo] = []
        var skipped: [String] = []

        for url in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.path < $1.path }) {
            guard let data = try? Data(contentsOf: url) else {
                skipped.append("\(url.lastPathComponent): unreadable")
                continue
            }
            do {
                // A provider whose schema drifted is skipped rather than
                // taking the whole catalog down with it — but it is named in
                // ``skipped`` rather than vanishing without a trace.
                providers.append(try decoder.decode(ProviderInfo.self, from: data))
            } catch {
                skipped.append("\(url.lastPathComponent): \(error)")
            }
        }

        return (providers.sorted { $0.id < $1.id }, skipped)
    }

    // MARK: - Locating the resources

    /// Anchor for `Bundle(for:)`, which needs a class.
    private final class BundleAnchor {}

    /// Every plausible directory the resource bundle could sit in.
    ///
    /// SwiftPM's generated `Bundle.module` is deliberately not used: when the
    /// bundle is missing it calls `fatalError`, so a packaging mistake in the
    /// host app crashes on first catalog access instead of degrading. Searching
    /// by hand costs a few `FileManager` probes once and fails as `nil`.
    private static var searchRoots: [URL] {
        var roots: [URL] = []
        let anchor = Bundle(for: BundleAnchor.self)

        func add(_ url: URL?) {
            guard let url, !roots.contains(url) else { return }
            roots.append(url)
        }

        // A packaged app: Contents/Resources.
        add(Bundle.main.resourceURL)
        // A command-line tool: the directory holding the executable.
        add(Bundle.main.bundleURL)
        // Linked as a framework, or running from a test bundle.
        add(anchor.resourceURL)
        add(anchor.bundleURL)
        // The build directory, when the anchor is inside an .xctest bundle.
        add(anchor.bundleURL.deletingLastPathComponent())
        // A framework embedded in an app.
        add(Bundle.main.resourceURL?.deletingLastPathComponent()
            .appending(path: "Frameworks/AIKit.framework/Resources"))

        return roots
    }

    private static let catalogDirectory: URL? = {
        let manager = FileManager.default

        func providers(in directory: URL) -> URL? {
            let candidate = directory.appending(path: "Catalog/providers")
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { return nil }
            return candidate
        }

        for root in searchRoots {
            let bundleURL = root.appending(path: bundleName)
            // `Bundle(url:)` resolves the platform's layout — flat on Linux and
            // iOS, Contents/Resources on macOS.
            if let bundle = Bundle(url: bundleURL),
               let resources = bundle.resourceURL,
               let directory = providers(in: resources) {
                return directory
            }
            if let directory = providers(in: bundleURL) {
                return directory
            }
            // Resources flattened straight into the app, without the wrapper.
            if let directory = providers(in: root) {
                return directory
            }
        }

        return nil
    }()
}
