import Foundation

/// A conservative XML pass around the isolated SVGO helper. Neither admission
/// nor equivalence validation executes JavaScript, loads resources, or rasterizes SVG.
nonisolated struct SVGProcessor {
    func inspect(_ data: Data) throws -> ImageInfo {
        let document = try Document(data)
        return ImageInfo(format: .svg, width: document.width, height: document.height,
                         hasAlpha: true, estimatedMemory: document.estimatedMemory)
    }

    func optimize(_ original: Data, source: URL, workDirectory: URL,
                  settings: OptimizationSettings, cancellation: CancellationToken) throws -> URL? {
        try cancellation.check()
        _ = try Document(original)
        guard !settings.stripPersonalMetadata else {
            throw ProcessingError.unsupported(String(localized: "Removing personal metadata from SVG is not supported yet. Turn off this option to optimize it."))
        }
        let executable = Bundle.main.url(forResource: "resim-svg", withExtension: nil, subdirectory: "Codecs")
            ?? Bundle.main.url(forResource: "resim-svg", withExtension: nil)
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ProcessingError.unavailable(String(localized: "The SVG tool bundled with the app is missing."))
        }
        let reference = workDirectory.appendingPathComponent("reference.svg")
        let output = workDirectory.appendingPathComponent("candidate.svg")
        try original.write(to: reference, options: .atomic)
        let log = workDirectory.appendingPathComponent("svgo.log")
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = [reference.path, output.path]
        process.standardOutput = handle; process.standardError = handle
        try cancellation.check()
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while process.isRunning {
            if cancellation.isCancelled {
                process.terminate(); process.waitUntilExit(); try cancellation.check()
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                process.terminate(); process.waitUntilExit()
                throw ProcessingError.resourceLimit(String(localized: "The SVG took too long to optimize safely."))
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
        process.waitUntilExit()
        try cancellation.check()
        let diagnostics = (try FileManager.default.attributesOfItem(atPath: log.path)[.size] as? NSNumber)?.uint64Value
        guard process.terminationReason == .exit, process.terminationStatus == 0, diagnostics == 0,
              let attributes = try? FileManager.default.attributesOfItem(atPath: output.path),
              let count = (attributes[.size] as? NSNumber)?.uint64Value, count > 0, count <= Document.maximumBytes else {
            throw ProcessingError.invalid(String(localized: "The SVG is damaged or the optimizer could not validate it."))
        }
        guard count < original.count else { return nil }
        let candidate = try Data(contentsOf: output, options: .mappedIfSafe)
        guard semanticsPreserved(original: original, candidate: candidate) else { return nil }
        try cancellation.check()
        return output
    }

    /// Attribute order, XML declaration/quote syntax and harmless container
    /// indentation may change. IDs, literal numeric values, CSS, accessibility
    /// text, licenses, metadata, element order and text content must all survive.
    func semanticsPreserved(original: Data, candidate: Data) -> Bool {
        guard let a = try? Document(original), let b = try? Document(candidate) else { return false }
        return a.events == b.events && a.width == b.width && a.height == b.height
    }

    private struct Document {
        static let maximumBytes = 4 * 1_024 * 1_024
        let events: [Event]
        let width: Int
        let height: Int
        let estimatedMemory: UInt64

        init(_ data: Data) throws {
            guard data.count <= Self.maximumBytes else { throw Self.limit() }
            guard var text = String(data: data, encoding: .utf8) else { throw Self.unsupported() }
            if text.first == "\u{FEFF}" { text.removeFirst() }
            // Reject before XMLParser gets any opportunity to resolve a DTD.
            let upper = text.uppercased()
            guard !upper.contains("<!DOCTYPE"), !upper.contains("<!ENTITY") else { throw Self.unsupported() }
            if text.hasPrefix("<?xml"), let end = text.range(of: "?>") {
                let header = String(text[..<end.upperBound])
                if let encoding = header.range(of: #"encoding\s*=\s*['"]([^'"]+)['"]"#, options: .regularExpression) {
                    let declaration = String(header[encoding])
                    guard declaration.range(of: #"['"]utf-?8['"]"#, options: [.regularExpression, .caseInsensitive]) != nil else { throw Self.unsupported() }
                }
            }
            let delegate = Reader()
            let parser = XMLParser(data: Data(text.utf8))
            parser.shouldResolveExternalEntities = false
            parser.externalEntityResolvingPolicy = .never
            parser.shouldProcessNamespaces = false
            parser.delegate = delegate
            let parsed = parser.parse()
            if let error = delegate.failure { throw error }
            guard parsed, delegate.stack.isEmpty, delegate.rootCount == 1,
                  let root = delegate.rootAttributes else { throw Self.bad() }
            events = delegate.events.filter { $0 != .ignored }
            let dimensions = try Self.dimensions(root)
            width = dimensions.0; height = dimensions.1
            estimatedMemory = UInt64(data.count) * 64 + 32 * 1_024 * 1_024
            guard estimatedMemory <= 512 * 1_024 * 1_024 else { throw Self.limit() }
        }

        private static func dimensions(_ attributes: [String: String]) throws -> (Int, Int) {
            var fallback = (300.0, 150.0)
            if let viewBox = attributes["viewBox"] {
                let tokens = viewBox.split(whereSeparator: { $0 == "," || $0.isWhitespace })
                guard tokens.count == 4 else { throw bad() }
                let values = tokens.compactMap { Double($0) }
                guard values.count == 4, values.allSatisfy(\.isFinite), values[2] > 0, values[3] > 0 else { throw bad() }
                fallback = (values[2], values[3])
            }
            func length(_ value: String?, fallback: Double) throws -> Double {
                guard let value else { return fallback }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                let pattern = #"^([+]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)(px|pt|pc|in|cm|mm|Q|q|%)?$"#
                let regex = try NSRegularExpression(pattern: pattern)
                let range = NSRange(trimmed.startIndex..., in: trimmed)
                guard let match = regex.firstMatch(in: trimmed, range: range),
                      let numberRange = Range(match.range(at: 1), in: trimmed),
                      let number = Double(trimmed[numberRange]), number.isFinite, number > 0 else { throw bad() }
                let unit = Range(match.range(at: 2), in: trimmed).map { String(trimmed[$0]) } ?? ""
                if unit == "%" { return fallback }
                let factors = ["": 1.0, "px": 1, "pt": 96.0 / 72, "pc": 16, "in": 96,
                               "cm": 96 / 2.54, "mm": 96 / 25.4, "Q": 96 / 101.6, "q": 96 / 101.6]
                return number * (factors[unit] ?? 1)
            }
            let w = try length(attributes["width"], fallback: fallback.0)
            let h = try length(attributes["height"], fallback: fallback.1)
            guard w.isFinite, h.isFinite, w <= 40_000_000, h <= 40_000_000,
                  ceil(w) * ceil(h) <= 40_000_000 else {
                throw ProcessingError.resourceLimit(String(localized: "The image exceeds the 40-megapixel limit."))
            }
            return (max(1, Int(ceil(w))), max(1, Int(ceil(h))))
        }

        static func bad() -> ProcessingError {
            .invalid(String(localized: "The SVG is damaged or incomplete."))
        }
        static func limit() -> ProcessingError {
            .resourceLimit(String(localized: "The SVG exceeds the limit of 4 MB, 50,000 XML nodes, or 128 nested elements."))
        }
        static func unsupported() -> ProcessingError {
            .unsupported(String(localized: "Only self-contained UTF-8 SVG images without scripts, animations, external resources, or DTDs are supported. The original is preserved."))
        }
    }

    private enum Event: Equatable {
        case ignored
        case start(String, [String: String])
        case end(String)
        case text(String)
        case comment(String)
    }

    private final class Reader: NSObject, XMLParserDelegate {
        struct Frame {
            let name: String
            let namespaces: [String: String]
            let protectedText: Bool
            let mayIndent: Bool
            let start: Int
            var hasElement = false
        }
        var events: [Event] = []
        var stack: [Frame] = []
        var failure: ProcessingError?
        var rootAttributes: [String: String]?
        var rootCount = 0
        private var nodes = 0
        private let svgNamespace = "http://www.w3.org/2000/svg"

        private func reject(_ parser: XMLParser, _ error: ProcessingError) {
            failure = error; parser.abortParsing()
        }
        private func count(_ parser: XMLParser) -> Bool {
            nodes += 1
            if nodes > 50_000 { reject(parser, Document.limit()); return false }
            return true
        }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            guard count(parser) else { return }
            guard stack.count < 128, attributeDict.count <= 256 else { reject(parser, Document.limit()); return }
            let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
            let lower = local.lowercased()
            guard !["script", "foreignobject", "animate", "animatemotion", "animatetransform", "animatecolor", "set", "discard", "handler"].contains(lower) else {
                reject(parser, Document.unsupported()); return
            }
            var namespaces = stack.last?.namespaces ?? ["xml": "http://www.w3.org/XML/1998/namespace"]
            for (key, value) in attributeDict {
                if key == "xmlns" { namespaces[""] = value }
                else if key.hasPrefix("xmlns:") { namespaces[String(key.dropFirst(6))] = value }
            }
            for (key, value) in attributeDict {
                let keyParts = key.split(separator: ":", omittingEmptySubsequences: false)
                if keyParts.count > 2 { reject(parser, Document.bad()); return }
                if keyParts.count == 2, keyParts[0] != "xmlns", namespaces[String(keyParts[0])] == nil {
                    reject(parser, Document.bad()); return
                }
                let attribute = key.split(separator: ":").last.map(String.init)?.lowercased() ?? key.lowercased()
                let xmlBase = attribute == "base" && keyParts.count == 2
                    && namespaces[String(keyParts[0])] == "http://www.w3.org/XML/1998/namespace"
                guard !attribute.hasPrefix("on"), !xmlBase else { reject(parser, Document.unsupported()); return }
                if ["href", "src"].contains(attribute), !Self.safeReference(value) { reject(parser, Document.unsupported()); return }
                if !key.hasPrefix("xmlns"), value.contains("\\") { reject(parser, Document.unsupported()); return }
                if !key.hasPrefix("xmlns"), (attribute == "style" || value.contains("(") || value.lowercased().contains("url") || value.contains("@")),
                   !Self.safeCSS(value) { reject(parser, Document.unsupported()); return }
            }
            let pieces = elementName.split(separator: ":", omittingEmptySubsequences: false)
            let prefix = pieces.count == 2 ? String(pieces[0]) : ""
            guard pieces.count <= 2, pieces.count != 2 || namespaces[prefix] != nil else { reject(parser, Document.bad()); return }
            let namespace = namespaces[prefix] ?? ""
            let isSVG = namespace == svgNamespace || namespace.isEmpty
            if stack.isEmpty {
                rootCount += 1
                guard elementName == "svg" || (local == "svg" && namespace == svgNamespace), isSVG else { reject(parser, Document.unsupported()); return }
                rootAttributes = attributeDict
            } else { stack[stack.count - 1].hasElement = true }
            let protected = (stack.last?.protectedText ?? false) || !isSVG
                || ["text", "textPath", "tspan", "style", "title", "desc", "metadata"].contains(local)
                || attributeDict["xml:space"] == "preserve"
            let mayIndent = isSVG && !protected && ["svg", "g", "defs", "symbol", "clipPath", "mask", "pattern", "marker", "linearGradient", "radialGradient", "filter", "switch"].contains(local)
            let start = events.count
            events.append(.start(elementName, attributeDict))
            stack.append(Frame(name: elementName, namespaces: namespaces, protectedText: protected, mayIndent: mayIndent, start: start))
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            guard let frame = stack.popLast(), frame.name == elementName else { reject(parser, Document.bad()); return }
            if frame.mayIndent && frame.hasElement {
                // Only the direct text children of this known container qualify.
                // Whitespace in an otherwise empty element is retained for :empty.
                var depth = 0
                for index in (frame.start + 1)..<events.count {
                    switch events[index] {
                    case .start: depth += 1
                    case .end: depth -= 1
                    case .text(let value) where depth == 0 && value.unicodeScalars.allSatisfy({ [9, 10, 13, 32].contains($0.value) }): events[index] = .ignored
                    default: break
                    }
                }
            }
            if elementName.split(separator: ":").last?.lowercased() == "style" {
                let css = events[(frame.start + 1)...].compactMap { event -> String? in
                    if case .text(let value) = event { return value }; return nil
                }.joined()
                guard Self.safeCSS(css) else { reject(parser, Document.unsupported()); return }
            }
            events.append(.end(elementName))
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { appendText(string, parser: parser) }
        func parser(_ parser: XMLParser, foundIgnorableWhitespace whitespaceString: String) { appendText(whitespaceString, parser: parser) }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard let string = String(data: CDATABlock, encoding: .utf8) else { reject(parser, Document.bad()); return }
            appendText(string, parser: parser)
        }
        private func appendText(_ text: String, parser: XMLParser) {
            if stack.isEmpty {
                if !text.unicodeScalars.allSatisfy({ [9, 10, 13, 32].contains($0.value) }) { reject(parser, Document.bad()) }
                return
            }
            if case .text(let previous) = events.last { events[events.count - 1] = .text(previous + text) }
            else { guard count(parser) else { return }; events.append(.text(text)) }
        }
        func parser(_ parser: XMLParser, foundComment comment: String) {
            guard count(parser) else { return }; events.append(.comment(comment))
        }
        func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
            reject(parser, Document.unsupported())
        }
        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
            reject(parser, Document.unsupported()); return nil
        }
        private static func safeReference(_ raw: String) -> Bool {
            // Trimming here would admit references whose literal value differs
            // across consumers, so require an unambiguous local fragment/data URI.
            if raw.hasPrefix("#"), !raw.contains(where: { $0.isWhitespace || $0.isNewline }) { return true }
            let prefixes = ["data:image/png;base64,", "data:image/jpeg;base64,", "data:image/webp;base64,"]
            guard let prefix = prefixes.first(where: raw.hasPrefix),
                  let bytes = Data(base64Encoded: String(raw.dropFirst(prefix.count))) else { return false }
            if prefix.contains("png") { return bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) }
            if prefix.contains("jpeg") { return bytes.starts(with: [255, 216, 255]) }
            return bytes.count >= 12 && bytes.starts(with: Data("RIFF".utf8)) && bytes[8..<12] == Data("WEBP".utf8)
        }
        private static func safeCSS(_ raw: String) -> Bool {
            guard !raw.contains("\\") else { return false }
            let text = raw.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
            let lower = text.lowercased()
            guard lower.range(of: #"@(?:-[a-z]+-)?keyframes|(?:^|[;{])\s*(?:-[a-z]+-)?animation(?:-[a-z-]+)?\s*:"#, options: .regularExpression) == nil,
                  // These CSS image sources also accept bare strings, bypassing
                  // url(...) checks and breaking relative paths after relocation.
                  lower.range(of: #"(?:^|[^a-z0-9_-])(?:-[a-z]+-)?(?:image-set|image|src)\s*\("#, options: .regularExpression) == nil,
                  !lower.contains("@import"), !lower.contains("@namespace"), !lower.contains("expression("),
                  !lower.contains("javascript:"), !lower.contains("-moz-binding") else { return false }
            guard let regex = try? NSRegularExpression(pattern: #"url\s*\(([^)]*)\)"#, options: .caseInsensitive) else { return false }
            let full = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, range: full)
            for match in matches {
                guard let range = Range(match.range(at: 1), in: text) else { return false }
                var value = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if value.first == "\"" || value.first == "'" {
                    guard value.count >= 2, value.first == value.last else { return false }
                    value.removeFirst(); value.removeLast()
                }
                guard safeReference(value) else { return false }
            }
            // Malformed URL syntax is rejected rather than interpreted differently
            // by the optimizer and the eventual SVG consumer.
            let remaining = regex.stringByReplacingMatches(in: text, range: full, withTemplate: "")
            if remaining.range(of: #"url\s*\("#, options: [.regularExpression, .caseInsensitive]) != nil { return false }
            return true
        }
    }
}
