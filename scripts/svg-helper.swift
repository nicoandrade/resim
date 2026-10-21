import CryptoKit
import Darwin
import Foundation
import JavaScriptCore

private enum SVGHelperError: Error {
    case invalidArguments
    case invalidInput
    case invalidRuntime
    case optimizationFailed
    case invalidOutput
}

// Record direct text slots between non-text children using an XML parser.
// CDATA and escaped text are data, never scanned as markup.
private final class SVGContentCollector: NSObject, XMLParserDelegate {
    private final class Element {
        let name: String
        var slots = [""]
        var hasElement = false
        init(name: String) { self.name = name }
    }
    private struct Frame {
        let element: Element
        let namespaces: [String: String]
        let protectedText: Bool
        let mayIndent: Bool
    }
    private var entries: [Element] = []
    private var stack: [Frame] = []
    private var nodes = 0
    var comments: [String] = []
    var rejectedDeclaration = false
    var elements: [[String: Any]] { entries.map { ["name": $0.name, "slots": $0.slots] } }

    private func reject(_ parser: XMLParser) {
        rejectedDeclaration = true
        parser.abortParsing()
    }
    private func count(_ parser: XMLParser) -> Bool {
        nodes += 1
        guard nodes <= 50_000 else { reject(parser); return false }
        return true
    }
    private func advanceParent() {
        stack.last?.element.slots.append("")
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String]) {
        guard count(parser), stack.count < 128, attributes.count <= 256 else { reject(parser); return }
        var namespaces = stack.last?.namespaces ?? ["xml": "http://www.w3.org/XML/1998/namespace"]
        for (key, value) in attributes {
            if key == "xmlns" { namespaces[""] = value }
            else if key.hasPrefix("xmlns:") { namespaces[String(key.dropFirst(6))] = value }
        }
        let pieces = elementName.split(separator: ":", omittingEmptySubsequences: false)
        let local = pieces.last.map(String.init) ?? elementName
        let prefix = pieces.count == 2 ? String(pieces[0]) : ""
        let namespace = namespaces[prefix] ?? ""
        let isSVG = namespace.isEmpty || namespace == "http://www.w3.org/2000/svg"
        let protected = (stack.last?.protectedText ?? false) || !isSVG
            || ["text", "textPath", "tspan", "style", "title", "desc", "metadata"].contains(local)
            || attributes["xml:space"] == "preserve"
        let mayIndent = isSVG && !protected
            && ["svg", "g", "defs", "symbol", "clipPath", "mask", "pattern", "marker", "linearGradient", "radialGradient", "filter", "switch"].contains(local)
        stack.last?.element.hasElement = true
        advanceParent()
        let element = Element(name: elementName)
        entries.append(element)
        stack.append(Frame(element: element, namespaces: namespaces, protectedText: protected, mayIndent: mayIndent))
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let frame = stack.popLast(), frame.element.name == elementName else { reject(parser); return }
        if frame.mayIndent && frame.element.hasElement {
            frame.element.slots = frame.element.slots.map { value in
                value.unicodeScalars.allSatisfy { [9, 10, 13, 32].contains($0.value) } ? "" : value
            }
        }
    }
    private func appendText(_ value: String, parser: XMLParser) {
        guard let element = stack.last?.element, !value.isEmpty else { return }
        let slot = element.slots.count - 1
        if element.slots[slot].isEmpty && !count(parser) { return }
        element.slots[slot] += value
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { appendText(string, parser: parser) }
    func parser(_ parser: XMLParser, foundIgnorableWhitespace string: String) { appendText(string, parser: parser) }
    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        guard let value = String(data: data, encoding: .utf8) else { reject(parser); return }
        appendText(value, parser: parser)
    }
    func parser(_ parser: XMLParser, foundComment comment: String) {
        guard count(parser) else { return }
        comments.append(comment)
        advanceParent()
    }
    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
        reject(parser)
    }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { reject(parser) }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { reject(parser) }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        reject(parser)
        return nil
    }
}

@main
private enum SVGHelper {
    static func main() {
        // The signed helper deliberately uses the interpreter. Hardened Runtime
        // remains enabled without an allow-jit entitlement.
        setenv("JSC_useJIT", "false", 1)
        let status: Int32 = autoreleasepool {
            do {
                try run()
                return 0
            } catch {
                // Avoid echoing XML or file paths into diagnostic logs.
                let message: String
                switch error {
                case SVGHelperError.invalidArguments: message = "Usage: resim-svg input.svg output.svg"
                case SVGHelperError.invalidInput: message = "SVG input must be valid UTF-8 and at most 4 MiB."
                case SVGHelperError.invalidRuntime: message = "SVG optimization runtime could not be verified."
                case SVGHelperError.optimizationFailed: message = "SVG optimization failed."
                case SVGHelperError.invalidOutput: message = "SVG optimization returned an invalid or oversized result."
                default: message = "SVG optimization could not read or write the requested file."
                }
                FileHandle.standardError.write(Data((message + "\n").utf8))
                return 1
            }
        }
        exit(status)
    }

    static func run() throws {
        guard CommandLine.arguments.count == 3 else { throw SVGHelperError.invalidArguments }
        let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
        guard inputURL.standardizedFileURL != outputURL.standardizedFileURL else {
            throw SVGHelperError.invalidArguments
        }
        let inputHandle = try FileHandle(forReadingFrom: inputURL)
        defer { try? inputHandle.close() }
        let input = try inputHandle.read(upToCount: 4 * 1024 * 1024 + 1) ?? Data()
        guard !input.isEmpty, input.count <= 4 * 1024 * 1024,
              let text = String(data: input, encoding: .utf8) else { throw SVGHelperError.invalidInput }
        // Reject declarations before invoking either parser. Disabling external
        // entity resolution also prevents any network or local-file resolution.
        let declarationProbe = text.uppercased()
        guard !declarationProbe.contains("<!DOCTYPE"), !declarationProbe.contains("<!ENTITY") else {
            throw SVGHelperError.invalidInput
        }
        let collector = SVGContentCollector()
        let parser = XMLParser(data: input)
        parser.delegate = collector
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        guard parser.parse(), !collector.rejectedDeclaration else { throw SVGHelperError.invalidInput }
        guard let executable = Bundle.main.executableURL else { throw SVGHelperError.invalidRuntime }
        let runtimeURL = executable.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("svgo.js")
        let runtimeHandle = try FileHandle(forReadingFrom: runtimeURL)
        defer { try? runtimeHandle.close() }
        let runtime = try runtimeHandle.read(upToCount: 4 * 1024 * 1024 + 1) ?? Data()
        guard runtime.count <= 4 * 1024 * 1024 else { throw SVGHelperError.invalidRuntime }
        let digest = SHA256.hash(data: runtime).map { String(format: "%02x", $0) }.joined()
        guard digest == bundledSVGOHash, let source = String(data: runtime, encoding: .utf8),
              let context = JSContext() else { throw SVGHelperError.invalidRuntime }
        var didThrow = false
        context.exceptionHandler = { _, _ in didThrow = true }
        context.evaluateScript(source)
        guard !didThrow, let optimize = context.objectForKeyedSubscript("ResimSVGOptimize"),
              !optimize.isUndefined, !optimize.isNull else { throw SVGHelperError.invalidRuntime }
        // SVG is passed as data; it is never evaluated as JavaScript or rendered.
        guard let result = optimize.call(withArguments: [text, collector.comments, collector.elements]), !didThrow,
              result.isString, let optimized = result.toString() else {
            throw SVGHelperError.optimizationFailed
        }
        let output = Data(optimized.utf8)
        guard !output.isEmpty, output.count <= 4 * 1024 * 1024 else { throw SVGHelperError.invalidOutput }
        try output.write(to: outputURL, options: .atomic)
    }
}
