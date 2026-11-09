// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Fetches one web page for the quote check. Tests use a stub; a run uses `PinnedFetcher`.
public protocol PageFetcher {
    /// The page text (HTML or plain) or nil when it could not be fetched, the HTTP status (0 when none), and the URL
    /// the page finally came from (after redirects).
    func fetch(_ url: URL) -> (status: Int, body: String?, final: URL?)
}

/// A plain HTTP(S) GET for model-supplied URLs, guarded against reaching the user's machine or network. Each hop
/// (the first URL and every redirect, at most 3) is checked: http(s), a public dotted DNS name, no credentials, and
/// every address it resolves to public. The connection is then pinned to one of those checked addresses: the system
/// `curl` (part of macOS) runs with `--resolve host:port:address`, so no later DNS answer is used, while TLS is still
/// verified against the host name. `curl` runs with no config file (`-q`), no proxy, no redirects of its own, a 10 s
/// limit, and its output is read with a 2 MB cap (the transfer is stopped past it).
public struct PinnedFetcher: PageFetcher {
    public var timeout: TimeInterval = 10
    public var maxBytes = 2 << 20
    public var curl = URL(fileURLWithPath: "/usr/bin/curl")
    public init() {}

    /// A hop's host and port when the URL may be fetched, else nil.
    static func target(_ url: URL) -> (host: String, port: Int)? {
        // A trailing dot is refused: curl would request the dotted name, which the pin (without the dot) does not cover.
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(), !host.hasSuffix("."), url.user == nil, url.password == nil else { return nil }
        guard host.contains("."), !host.contains(":"), host.range(of: #"^[0-9.]+$"#, options: .regularExpression) == nil,
              host.range(of: #"^[a-z0-9.-]+$"#, options: .regularExpression) != nil,
              !host.hasSuffix(".local"), !host.hasSuffix(".localhost"), !host.hasSuffix(".internal"), host != "localhost" else { return nil }
        return (host, url.port ?? (scheme == "https" ? 443 : 80))
    }

    /// Whether a URL may be fetched: a valid target whose every resolved address is public.
    public static func allowed(_ url: URL) -> Bool {
        guard let t = target(url) else { return false }
        let a = resolve(t.host)
        return !a.isEmpty && a.allSatisfy(isPublic)
    }

    /// The addresses `host` resolves to (IPv4 as 4 bytes, IPv6 as 16).
    static func resolve(_ host: String) -> [[UInt8]] {
        var hints = addrinfo(); hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>? = nil
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return [] }
        defer { freeaddrinfo(first) }
        var out: [[UInt8]] = []
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let a = p {
            if a.pointee.ai_family == AF_INET, let sa = a.pointee.ai_addr {
                sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { s in
                    out.append(withUnsafeBytes(of: s.pointee.sin_addr.s_addr) { Array($0) })
                }
            } else if a.pointee.ai_family == AF_INET6, let sa = a.pointee.ai_addr {
                sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { s in
                    out.append(withUnsafeBytes(of: s.pointee.sin6_addr) { Array($0) })
                }
            }
            p = a.pointee.ai_next
        }
        return out
    }

    /// Whether an address is public. IPv4: not 0/8, 10/8, 100.64/10, 127/8, 169.254/16, 172.16/12, 192.0.0/24,
    /// 192.168/16, 198.18/15, 224/3 and above. IPv6: only global unicast 2000::/3 outside the documentation, Teredo,
    /// 6to4 and NAT64 ranges; an IPv4-mapped address is judged as its IPv4 address.
    public static func isPublic(_ a: [UInt8]) -> Bool {
        if a.count == 4 {
            let (b0, b1) = (a[0], a[1])
            if b0 == 0 || b0 == 10 || b0 == 127 || b0 >= 224 { return false }
            if b0 == 169 && b1 == 254 { return false }
            if b0 == 172 && (16...31).contains(b1) { return false }
            if b0 == 192 && b1 == 168 { return false }
            if b0 == 100 && (64...127).contains(b1) { return false }
            if b0 == 192 && b1 == 0 && a[2] == 0 { return false }
            if b0 == 198 && (b1 == 18 || b1 == 19) { return false }
            return true
        }
        guard a.count == 16 else { return false }
        if a.prefix(10).allSatisfy({ $0 == 0 }) && a[10] == 0xff && a[11] == 0xff { return isPublic(Array(a.suffix(4))) }   // IPv4-mapped
        guard a[0] & 0xe0 == 0x20 else { return false }                                   // only 2000::/3 (global unicast)
        if a[0] == 0x20 && a[1] == 0x01 && a[2] == 0x0d && a[3] == 0xb8 { return false }  // 2001:db8::/32 documentation
        if a[0] == 0x20 && a[1] == 0x01 && a[2] == 0x00 && a[3] == 0x00 { return false }  // 2001::/32 Teredo
        if a[0] == 0x20 && a[1] == 0x02 { return false }                                  // 2002::/16 6to4
        return true
    }

    /// The `curl` arguments for one hop, pinned to `address` (no config file, no proxy, no redirects, http(s) only).
    static func curlArguments(url: URL, host: String, port: Int, address: [UInt8], timeout: TimeInterval, headerFile: String) -> [String] {
        let ip: String
        if address.count == 4 { ip = address.map(String.init).joined(separator: ".") }
        else { ip = "[" + stride(from: 0, to: 16, by: 2).map { String(format: "%x", Int(address[$0]) << 8 | Int(address[$0 + 1])) }.joined(separator: ":") + "]" }
        return ["-q", "-sS", "--noproxy", "*", "--proto", "=http,https", "--max-redirs", "0", "--max-time", String(Int(timeout)),
                "-A", "Marty quote check (+https://github.com/morrowdock/marty)", "-H", "Accept: text/html,text/plain;q=0.9,*/*;q=0.5",
                "--resolve", "\(host):\(port):\(ip)", "-D", headerFile, "-o", "-", "--", url.absoluteString]
    }

    public func fetch(_ url: URL) -> (status: Int, body: String?, final: URL?) {
        var current = url
        for _ in 0...3 {
            guard let t = Self.target(current) else { return (0, nil, nil) }
            let addresses = Self.resolve(t.host)
            guard let address = addresses.first, addresses.allSatisfy(Self.isPublic) else { return (0, nil, nil) }
            let headers = FileManager.default.temporaryDirectory.appendingPathComponent("marty-quote-\(UUID().uuidString).txt")
            defer { try? FileManager.default.removeItem(at: headers) }
            guard let body = run(Self.curlArguments(url: current, host: t.host, port: t.port, address: address, timeout: timeout, headerFile: headers.path)) else {
                return (0, nil, nil)
            }
            let head = (try? String(contentsOf: headers, encoding: .utf8)) ?? ""
            let (status, lines) = Self.finalResponse(head)
            if (300..<400).contains(status) {
                guard let loc = lines.first(where: { $0.lowercased().hasPrefix("location:") })?.dropFirst(9).trimmingCharacters(in: .whitespaces),
                      let next = URL(string: loc, relativeTo: current)?.absoluteURL else { return (status, nil, current) }
                current = next
                continue
            }
            guard (200..<300).contains(status) else { return (status, nil, current) }
            return (status, String(decoding: body, as: UTF8.self), current)
        }
        return (0, nil, nil)
    }

    /// The final response of a curl header dump: header blocks are separated by a blank line; informational (1xx)
    /// responses before the real one are skipped. Its status and header lines.
    static func finalResponse(_ head: String) -> (status: Int, lines: [String]) {
        let blocks = head.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
            .map { $0.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }.filter { !$0.isEmpty }
        var final: (Int, [String]) = (0, [])
        for b in blocks {
            guard let first = b.first, first.uppercased().hasPrefix("HTTP/"),
                  let code = first.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else { continue }
            if (100..<200).contains(code) { continue }
            final = (code, b)
        }
        return final
    }

    /// Runs `curl` and reads at most `maxBytes` of its output (stopping it past that), with its own deadline
    /// (timeout + 5 s): past it the child gets SIGTERM, then SIGKILL after 2 s, and is reaped. Nil on failure,
    /// overflow or deadline.
    func run(_ arguments: [String]) -> Data? {
        let p = Process()
        p.executableURL = curl
        p.arguments = arguments
        p.environment = ["PATH": "/usr/bin:/bin"]   // no proxy or config variables reach curl
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return nil }
        final class Box: @unchecked Sendable { var data = Data(), over = false }
        let box = Box(), lock = NSLock(), read = DispatchSemaphore(value: 0)
        let limit = maxBytes
        let h = out.fileHandleForReading
        DispatchQueue.global().async {
            while true {
                let d = h.availableData
                if d.isEmpty { break }
                lock.lock(); box.data.append(d); let over = box.data.count > limit; if over { box.over = true }; lock.unlock()
                if over { if p.isRunning { p.terminate() }; break }
            }
            read.signal()
        }
        var timedOut = false
        if exited.wait(timeout: .now() + timeout + 5) == .timedOut {
            timedOut = true
            if p.isRunning { p.terminate() }
            if exited.wait(timeout: .now() + 2) == .timedOut, p.isRunning { kill(p.processIdentifier, SIGKILL); _ = exited.wait(timeout: .now() + 2) }
        }
        _ = read.wait(timeout: .now() + 2)
        lock.lock(); let data = box.data, over = box.over; lock.unlock()
        return timedOut || over || p.isRunning || p.terminationStatus != 0 ? nil : data
    }
}

/// The quote check of a fact table: Marty fetches each cited page (a bounded budget) and looks for the source's
/// quote in the page text with a normalized substring match (HTML tags, scripts and styles removed, entities
/// decoded, case, quote marks, dashes and white space unified; an ellipsis splits a quote into parts that must all
/// be found in order).
public enum QuoteCheck {
    public static let budget = 24

    /// Plain, comparable text: lower case, one space between words, no quote marks, plain hyphens.
    static func normalized(_ s: String, html: Bool) -> String {
        var t = s
        if html {
            t = t.replacingOccurrences(of: #"(?is)<(script|style|noscript)\b.*?</\1\s*>"#, with: " ", options: .regularExpression)
            t = t.replacingOccurrences(of: #"(?s)<!--.*?-->"#, with: " ", options: .regularExpression)
            // Block tags (cells, rows, paragraphs, line breaks, list items, headings) separate text with a block mark
            // that is never a thousands space ("<td>1</td><td>144 kgf</td>" is not "1,144 kgf"); inline tags join
            // their text as it renders ("<span>1</span><span>.5</span>" is "1.5"); any other tag is a space.
            // A superscript is marked, never joined to the number before it ("144<sup>1</sup>" is "144^1", not
            // "1441"; "10<sup>3</sup>" is "10^3").
            t = t.replacingOccurrences(of: #"(?is)<sup\b[^>]*>(.*?)</sup\s*>"#, with: "^$1 ", options: .regularExpression)
            // A subscript likewise ("101<sub>2</sub>" is "101_2", not "1012").
            t = t.replacingOccurrences(of: #"(?is)<sub\b[^>]*>(.*?)</sub\s*>"#, with: "_$1 ", options: .regularExpression)
            t = t.replacingOccurrences(of: #"(?i)</?(?:td|th|tr|thead|tbody|tfoot|table|caption|p|div|br|hr|li|ul|ol|dl|dt|dd|h[1-6]|section|article|header|footer|aside|nav|main|figure|figcaption|blockquote|pre|form|fieldset|legend|details|summary|address)\b[^>]*>"#,
                                       with: "\u{2}", options: .regularExpression)
            t = t.replacingOccurrences(of: #"(?i)</?(?:span|a|b|i|em|strong|sup|sub|small|abbr|code|mark|u|s|q|cite|bdi|bdo|data|dfn|kbd|samp|var|wbr|time|font)\b[^>]*>"#,
                                       with: "", options: .regularExpression)
            t = t.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            t = decodeEntities(t)
            // Reference marks of the page ("[3]", "[edit]", "[citation needed]") are not quoted text.
            // A superscripted reference ("^[1]") goes with its mark; then any other reference mark.
            t = t.replacingOccurrences(of: #"\^\s*\[(?:\d{1,3}|[a-z]|edit|citation needed|note \d+)\]"#, with: "", options: [.regularExpression, .caseInsensitive])
            t = t.replacingOccurrences(of: #"\[(?:\d{1,3}|[a-z]|edit|citation needed|note \d+)\]"#, with: "", options: [.regularExpression, .caseInsensitive])
        }
        // Unicode superscripts likewise ("10³" is "10^3", "10⁻³" is "10^-3"), before NFKC would fold them to digits.
        t = markedSuperscripts(t)
        // A vulgar fraction stays a fraction: "1½" is "1+1/2" (NFKC alone makes it "11⁄2", a different number).
        t = plainFractions(t)
        // A digit-grouping space (no-break, narrow no-break or thin, before a group of 3 digits: "1 144 kgf") is a
        // thousands separator, so the number stays one token ("144" is not inside it). Before NFKC, which makes
        // these spaces plain.
        t = t.replacingOccurrences(of: "(?<=[0-9])[\u{00A0}\u{202F}\u{2009}](?=[0-9]{3}(?![0-9]))", with: ",", options: .regularExpression)
        // Unicode compatibility forms (NFKC: ligatures, full-width forms, superscripts), then invisible characters
        // (zero-width spaces and joiners, the word joiner U+2060, BOM, soft hyphen) are removed.
        t = t.precomposedStringWithCompatibilityMapping
        t = t.unicodeScalars.filter { !["\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}", "\u{00AD}", "\u{180E}"].contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
        t = t.lowercased()
        // A prime after a digit, ASCII or curly, is a unit mark ("5'11\"" and "5’11”" are 5′11″), kept, never a quote mark
        // (dropping it would make "511"), unless a quote mark opened right before the number ("\"10\"", "“-5”" are
        // quoted numbers).
        t = unitPrimes(t)
        for (a, b) in [("\u{2018}", "'"), ("\u{2019}", "'"), ("\u{201A}", "'"), ("\u{201B}", "'"),
                       ("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{201E}", "\""), ("\u{00AB}", "\""), ("\u{00BB}", "\""),
                       ("\u{2010}", "-"), ("\u{2011}", "-"), ("\u{2012}", "-"), ("\u{2013}", "-"), ("\u{2015}", "\u{2014}"),
                       ("\u{2212}", "-"), ("\u{00A0}", " "), ("\u{202F}", " "), ("\u{2009}", " "), ("\u{2026}", "...")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        // Quote marks are dropped on both sides: a page that quotes a figure ("'1,050 bhp'") still matches.
        t = t.replacingOccurrences(of: #"['"`]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        // Number operators bind without spaces ("10 ^ 3", "3 / 4", "1 : 30", "10 ± 2", "10 x 20", "≥ 10", "10 m / s"), so a
        // number is one expression however the page spaces it.
        t = t.replacingOccurrences(of: "(?<![<>])>=|=>", with: "\u{2265}", options: .regularExpression)
            .replacingOccurrences(of: "<=(?!>)|=<", with: "\u{2264}", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?<=[0-9)]) ?[x\u{00D7}\u{00B7}\u{22C5}\u{2219}] ?(?=[0-9]|[.-][0-9])", with: "\u{00D7}", options: .regularExpression)
        // Between a unit and a number, a spaced "x" multiplies too ("10 cm x 20 cm").
        t = t.replacingOccurrences(of: "(?<=\\p{L}) x (?=[0-9]|[.-][0-9])", with: " \u{00D7} ", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?<=[0-9]) ?([\\^/\u{2044}\u{00B1}:+]) ?(?=[0-9+.-])", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "([\u{00B1}<>\u{2264}\u{2265}~\u{2248}$\u{20AC}\u{00A3}\u{00A5}]) (?=[0-9]|[.-][0-9])", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?<=[a-z]) ?([\\^/]) ?(?=[a-z0-9])", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?<=[0-9]) (?=[%\u{2030}\u{00B0}\u{2032}\u{2033}])", with: "", options: .regularExpression)
        // A hyphen glued between letters ("n-m", "five-engine") is marked (U+2011) apart from a spaced one; any other
        // dash is its own token, however it is spaced ("suit - with", "at − 5", "10-20"): see `tokens`, `match`.
        t = t.replacingOccurrences(of: "(?<=\\p{L})-(?=\\p{L})", with: " \u{2011} ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s*-\s*"#, with: " - ", options: .regularExpression)
        // A removed tag leaves a space before punctuation ("derail ."); drop it on both sides.
        t = t.replacingOccurrences(of: #" ([.,;:!?)\]])(?![0-9])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"([(\[]) "#, with: "$1", options: .regularExpression)
        // Plain-space thousands groups ("1 144") are one number on the page and in the quote alike; a block mark
        // with its spaces is one mark, never a grouping space, then a space.
        t = t.replacingOccurrences(of: "[ \u{2}]*\u{2}[ \u{2}]*", with: "\u{2}", options: .regularExpression)
        // A spaced mixed fraction ("1 1/2", "1 ½") is one number, as "1½" is: "1+1/2".
        t = t.replacingOccurrences(of: #"(?<![0-9.,/])([0-9]+) ([0-9]+/[0-9]+)(?![0-9/])"#, with: "$1+$2", options: .regularExpression)
        t = groupedThousands(t)
        // The block mark stays a token of its own (a hard boundary between tokens, see `tokens`).
        t = t.replacingOccurrences(of: "\u{2}", with: " \u{2} ")
        t = t.replacingOccurrences(of: #"\s*-\s*"#, with: " - ", options: .regularExpression)
            .replacingOccurrences(of: "\\s*\u{2014}\\s*", with: " \u{2014} ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #" ([.,;:!?)\]])(?![0-9])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"([(\[]) "#, with: "$1", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    static let superscripts: [Character: Character] = ["\u{2070}": "0", "\u{00B9}": "1", "\u{00B2}": "2", "\u{00B3}": "3", "\u{2074}": "4",
        "\u{2075}": "5", "\u{2076}": "6", "\u{2077}": "7", "\u{2078}": "8", "\u{2079}": "9", "\u{207A}": "+", "\u{207B}": "-"]

    /// A quote mark after a digit is a prime (a unit mark: "5'11\"", "5’11”" are 5′11″; ″ as NFKC writes it, ′′) unless
    /// it closes a quotation of its own kind that is open in the same block ("“The turbine produces 144”",
    /// "\"5'11\"\"" is a quoted 5′11″). Straight double quotes pair in order; a block mark ends every quotation.
    /// Spelled or symbolic unit words that make a bare number a quantity ("10 percent", "100 watt", "10 m").
    static func isUnitWord(_ t: String) -> Bool {
        if isUnitSymbol(t) || timeUnits.contains(t) || magnitudes.contains(t) { return true }
        let spelled = ["percent", "percentage", "pct", "bar", "psi", "rpm", "mph", "kph", "kmh", "knot", "knots", "hp", "bhp", "kgf", "lbf",
                       "btu", "db", "decibel", "decibels", "degree", "degrees", "kelvin", "celsius", "fahrenheit", "foot", "feet", "inch",
                       "inches", "yard", "yards", "mile", "miles", "ton", "tons", "tonne", "tonnes", "pound", "pounds", "lb", "lbs", "ounce",
                       "ounces", "oz", "gallon", "gallons", "gal", "horsepower", "calorie", "calories", "kcal", "ft", "in",
                       "cubic", "square", "sq", "cu", "bit", "bits", "byte", "bytes", "kb", "mb", "gb", "tb", "pb", "kib", "mib", "gib",
                       "tib", "kbps", "mbps", "gbps", "bps", "flops",
                       "metric", "nautical", "force", "imperial", "fluid", "statute", "troy", "tons-force", "pound-force"]
        if spelled.contains(t) { return true }
        return t.range(of: "^(kilo|mega|giga|tera|milli|micro|nano|centi|deci)?(watt|volt|amp|ampere|joule|newton|pascal|metre|meter|gram|litre|liter|hertz|second|ohm|watt-hour|bit|byte)s?$",
                       options: .regularExpression) != nil
    }

    /// Words between a connector and a quantity ("in just 30 seconds", "by about 20 cm").
    static let modifiers: Set<String> = ["just", "about", "approximately", "approx", "roughly", "only", "around", "nearly", "almost",
                                         "some", "under", "over", "less", "than", "more", "at", "least", "most", "up", "to", "a", "mere"]
    /// Words right after a quantity that bound or qualify it ("10 kg max", "10 kw peak").
    static let postBounds: Set<String> = ["max", "maximum", "min", "minimum", "approx", "approximately", "nominal", "typical", "peak",
                                          "plus", "minimum", "maximal", "or"]
    /// The word after "or"/"and" that makes it a bound ("or less", "or more", "and up", "and above").
    static let boundTails: Set<String> = ["less", "more", "fewer", "greater", "higher", "lower", "above", "below", "over", "under",
                                          "so", "up", "beyond", "thereabouts", "better", "worse"]

    /// Written bounds and approximations right before a number: the quote must keep them ("up to 10", "at least 10").
    static let boundWords: Set<String> = ["than", "least", "most", "about", "around", "approximately", "approx", "nearly", "almost",
        "roughly", "over", "under", "above", "below", "upto", "max", "maximum", "min", "minimum", "circa", "ca", "estimated", "est",
        "exceeding", "beyond", "within", "some", "nearly", "up"]

    /// Ordinary words that may follow a quantity with a unit without continuing it.
    static let proseAfterQuantity: Set<String> = ["of", "at", "on", "in", "for", "with", "from", "into", "over", "under", "and", "or", "the",
        "its", "his", "her", "their", "is", "was", "are", "were", "be", "been", "has", "had", "have", "which", "that", "when", "while", "after",
        "before", "during", "by", "than", "as", "but", "so", "if", "up", "down", "out", "off", "more", "less", "total", "overall", "tall",
        "long", "wide", "high", "deep", "thick", "away", "apart", "across", "ago", "old", "later", "earlier", "above", "below", "behind",
        "ahead", "faster", "slower", "heavier", "lighter", "it", "this", "these", "those", "they", "he", "she", "we", "you", "not", "only",
        "about", "around", "near", "through", "across", "without", "within", "between", "against", "toward", "towards", "while", "until",
        "dry", "wet", "empty", "net", "gross", "loaded", "unloaded", "fuelled", "fueled"]

    /// Words that scale the number before them.
    static let magnitudes: Set<String> = ["hundred", "thousand", "million", "billion", "trillion", "k", "m", "bn", "mn", "mln", "tn", "lakh", "crore"]
    /// Time units after "a", "an", "each" or "every" in a rate.
    static let timeUnits: Set<String> = ["second", "seconds", "sec", "secs", "s", "minute", "minutes", "min", "mins", "hour", "hours", "hr",
                                         "hrs", "h", "day", "days", "week", "weeks", "month", "months", "year", "years", "yr", "yrs"]
    /// Number words that count the time unit after them ("every two hours").
    static let countWords: Set<String> = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "twelve",
                                          "few", "several", "half"]
    /// Ordinary short words that are not unit symbols though they look like one ("at", "in", "of").
    static let notUnits: Set<String> = ["a", "an", "at", "as", "am", "pm", "in", "on", "is", "it", "of", "or", "by", "to", "me", "my", "do",
                                        "no", "so", "up", "we", "he", "us", "ha", "be", "go", "if", "cd"]
    /// A unit symbol that multiplies a unit before it when written apart ("kw h", "n cm", "w ms"): an SI prefix and a
    /// base or derived unit symbol.
    static func isUnitSymbol(_ t: String) -> Bool {
        guard !notUnits.contains(t), t.count <= 5 else { return false }
        return t.range(of: "^(da|[yzafpnµumcdhkmgtpe])?(m|g|s|a|k|mol|n|j|w|pa|hz|v|c|f|ω|ohm|t|h|l|b|bar|wh|ah|ev)$", options: .regularExpression) != nil
    }

    static let numberWords: [String: String] = ["zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6",
        "seven": "7", "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12", "thirteen": "13", "fourteen": "14",
        "fifteen": "15", "sixteen": "16", "seventeen": "17", "eighteen": "18", "nineteen": "19", "twenty": "20", "thirty": "30",
        "forty": "40", "fifty": "50", "sixty": "60", "seventy": "70", "eighty": "80", "ninety": "90", "hundred": "100",
        "thousand": "1000", "million": "1000000", "billion": "1000000000", "single": "1", "twin": "2", "pair": "2", "dozen": "12"]
    static let ordinals: [String: String] = ["first": "1", "second": "2", "third": "3", "fourth": "4", "fifth": "5", "sixth": "6",
        "seventh": "7", "eighth": "8", "ninth": "9", "tenth": "10"]

    /// The numbers a quote states: its digits, number words ("five"), and Roman version numerals after a version
    /// word ("Mk IV" is 4).
    @MainActor static func statedNumbers(_ rawQuote: String, inOrder: Bool = false) -> [String] {
        // Digit groups are joined first, as the quote matcher joins them ("1 144" and "1\u{202F}144" are 1144).
        let quote = groupedThousands(rawQuote.replacingOccurrences(of: "(?<=[0-9])[\u{00A0}\u{202F}\u{2009}](?=[0-9]{3}(?![0-9]))",
                                                                   with: ",", options: .regularExpression))
        // Words in order: a token with a digit gives its whole numeric spans ("85.06", "1,200", the 4 of "Mk4"); the
        // letter parts of other tokens give words, and any punctuation after a word ends a number-word run.
        var words: [(w: String, stop: Bool)] = []
        var spans: [Int: [String]] = [:]
        for raw in quote.lowercased().split(whereSeparator: { $0.isWhitespace }) {
            if raw.contains(where: { $0.isNumber }) {
                spans[words.count] = MartyLoop.numbers(String(raw))
                // The letters before the digits ("mk" of "mk4") still name a version for a Roman numeral after it.
                words.append((String(raw.prefix { $0.isLetter }), true))
                continue
            }
            var part = ""
            for c in raw {
                if c.isLetter { part.append(c); continue }
                if !part.isEmpty { words.append((part, c != "-" && c != "\u{2011}")); part = "" }
                else if c != "-", !words.isEmpty { words[words.count - 1].stop = true }
            }
            if !part.isEmpty { words.append((part, false)) }
        }
        var found: [(Int, String)] = []
        var i = 0
        while i < words.count {
            let w = words[i].w
            if let ns = spans[i] {
                for n in ns { found.append((i, n)) }
                i += 1; continue
            }
            // "One of the …" names one of several, not a count.
            if w == "one", i + 1 < words.count, words[i + 1].w == "of", !words[i].stop { i += 1; continue }
            if numberWords[w] != nil {
                // A run of number words is one number ("twenty-four" is 24, "two hundred and five" 205, "one
                // million" 1000000), never its parts; "and" joins only after a scale word ("five and six" are two).
                var total = 0, current = 0, j = i
                while j < words.count {
                    let x = words[j].w
                    if x == "and", j > i, ["hundred", "thousand", "million", "billion"].contains(words[j - 1].w),
                       j + 1 < words.count, numberWords[words[j + 1].w] != nil, !words[j - 1].stop, !words[j].stop { j += 1; continue }
                    // "single", "twin" and "pair" are counts of their own, never part of a run ("two single-spool
                    // engines" is 2); alone they are 1, 2 and 2.
                    if ["single", "twin", "pair"].contains(x), j > i { break }
                    guard let v = numberWords[x].flatMap(Int.init) else { break }
                    if ["single", "twin", "pair"].contains(x) { current = v; j += 1; break }
                    switch x {
                    case "hundred": current = max(current, 1) * 100
                    case "thousand": total += max(current, 1) * 1_000; current = 0
                    case "million": total += max(current, 1) * 1_000_000; current = 0
                    case "billion": total += max(current, 1) * 1_000_000_000; current = 0
                    case "dozen": current = max(current, 1) * 12
                    default: current += v
                    }
                    let stop = words[j].stop
                    j += 1
                    if stop { break }
                }
                found.append((i, String(total + current)))
                i = j
                continue
            }
            if i > 0, ["mk", "mark", "version", "gen", "generation", "series", "type", "model"].contains(words[i - 1].w), let r = romanValue(w) {
                found.append((i, String(r)))
            }
            i += 1
        }
        let ordered = found.map(\.1)
        return inOrder ? ordered : Array(Set(ordered + MartyLoop.numbers(quote)))
    }

    /// Whether `quote` states the count `headline` of the row's counted thing (`entities`, see `countedWords`) in
    /// words that are no cardinal: an ordinal ("a fifth engine" is 5), or for 1 an article, "single" or "sole" ("a
    /// rear jet engine"), for 2 "both", "either", "pair" or "twin" ("either side"). The cue must come within three
    /// words before the counted noun, with no number between ("a five-engine suit" states no 1; "a housing with five
    /// rotors" no 1 rotor; "first flight" no count of engines).
    static func statesCountWord(_ headline: String, _ quote: String, entities: Set<String>) -> Bool {
        let cue: Set<String>
        switch headline {
        case "1": cue = ["a", "an", "single", "sole"]
        case "2": cue = ["both", "either", "pair", "twin"]
        default: cue = []
        }
        let wanted = Set(entities.map(singular))
        guard !wanted.isEmpty else { return false }
        // One clause at a time: a cue never reaches into the next sentence, clause or parenthesis.
        // (Unicode hyphens are hyphens: "second\u{2011}generation" stays one compound.)
        let folded = quote.lowercased().replacingOccurrences(of: "[\u{2010}\u{2011}\u{2012}\u{00AD}]", with: "-", options: .regularExpression)
        for clause in folded.components(separatedBy: CharacterSet(charactersIn: ".,;:!?()[]\u{2014}\u{2013}")) {
            // (A hyphenated compound stays one word: "second-generation" is no ordinal, "five-engine" a count.)
            if statesCountWord(headline, clause: clause.split { !$0.isLetter && !$0.isNumber && $0 != "-" }.map(String.init), cue: cue, wanted: wanted) { return true }
        }
        return false
    }

    static func statesCountWord(_ headline: String, clause words: [String], cue: Set<String>, wanted: Set<String>) -> Bool {
        for (i, w) in words.enumerated() where cue.contains(w) || ordinals[w] == headline {
            if i > 0, words[i - 1] == "one", w != "a" { continue }   // "one of five" is no count
            // Up to two plain modifiers between the cue and the noun ("a rear jet engine"); a connector, a verb-like
            // word, a plural noun or another count ends the phrase ("a housing with rotors", "both arms carry engines").
            // Agreement: an article, "single", "sole", "either" or an ordinal counts a singular head; "both", "pair",
            // "twin" a plural one ("a few engines", "both engine and battery" count nothing).
            let wantsPlural = ["both", "pair", "twin"].contains(w)
            for j in (i + 1)..<min(words.count, i + 4) {
                let x = words[j]
                if wanted.contains(singular(x)), (singular(x) != x) == wantsPlural {
                    // The noun must be the phrase's head, not a modifier of another noun ("a jet engine mount", "both
                    // rotor blades", "a rotor housing"): only the clause's end, a connector, a common verb or an -ed
                    // participle ("housed", "mounted") may follow it; any other word may be the real head, so the cue
                    // counts nothing.
                    guard j + 1 < words.count else { return true }
                    let n = words[j + 1]
                    if phraseBreaks.contains(n) || (n.count > 3 && n.hasSuffix("ed")) { return true }
                    break
                }
                if x.first?.isNumber == true || numberWords[x] != nil || ordinals[x] != nil || quantifiers.contains(x) { break }
                if x.contains("-"), x.split(separator: "-").contains(where: { numberWords[String($0)] != nil || ordinals[String($0)] != nil || $0.first?.isNumber == true }) { break }
                if wanted.contains(singular(x)) { break }   // the noun in the wrong number
                if phraseBreaks.contains(x) || x.hasSuffix("ing") || x.hasSuffix("ed") || (x.count > 3 && x.hasSuffix("s") && !x.hasSuffix("ss")) { break }
            }
        }
        return false
    }

    /// Share and comparison words: a claim that uses one needs a quote that uses it too.
    static let shareWords: Set<String> = ["most", "majority", "half", "halves", "third", "thirds", "quarter", "quarters", "share", "shares",
        "split", "mainly", "mostly", "chiefly", "primarily", "largely", "largest", "main", "bulk", "predominantly", "dominant", "equal",
        "equally", "evenly", "uniformly", "all", "more", "less", "fewer", "twice", "double", "triple", "entire", "whole"]

    /// The claim word that none of the found quotes states, or nil: each share or comparison word of the value and
    /// claim, and for a value in words (no number) at least one of its content words.
    @MainActor static func unstatedWord(value: String, claim: String, quotes: [String]) -> String? {
        func words(_ t: String) -> [String] { t.lowercased().split { !$0.isLetter }.map(String.init) }
        let quoted = Set(quotes.flatMap(words).map(singular))
        for w in words(value + " " + claim) where shareWords.contains(w) && !quoted.contains(singular(w)) { return w }
        guard statedNumbers(value, inOrder: true).isEmpty else { return nil }
        // (Only function words are left out: a short term or acronym, "LPG", "gas", "Jet A", must be stated too.)
        let filler: Set<String> = ["with", "from", "that", "this", "than", "their", "there", "which", "about", "into", "over", "each",
            "the", "a", "an", "and", "or", "of", "in", "on", "at", "to", "for", "by", "as", "is", "are", "was", "were", "its", "it", "be", "but", "not"]
        let content = words(value).filter { !filler.contains($0) }
        guard let first = content.first else { return nil }
        return content.contains(where: { quoted.contains(singular($0)) }) ? nil : first
    }

    /// Words of quantity that are no count ("a few", "several", "a number of").
    static let quantifiers: Set<String> = ["few", "several", "many", "couple", "number", "lot", "lots", "some", "more", "most", "all", "multiple", "various"]

    /// Words that end a noun phrase: connectors, articles and common verbs.
    /// (Only words that are never nouns: "power", "drive", "run" or "turn" may head a compound, "engine power".)
    static let phraseBreaks: Set<String> = ["with", "of", "for", "to", "from", "in", "on", "at", "by", "and", "or", "but", "that", "which",
        "the", "a", "an", "its", "their", "his", "her", "is", "are", "was", "were", "be", "has", "have", "had", "carries",
        "provides", "produces", "generates", "sits", "can", "will", "must", "may", "each", "only", "also", "contains", "weighs"]

    /// A plural noun as its singular ("batteries" battery, "boxes" box, "engines" engine).
    static func singular(_ w: String) -> String {
        if w.count > 4, w.hasSuffix("ies") { return String(w.dropLast(3)) + "y" }
        if w.count > 4, ["sses", "xes", "ches", "shes", "zes"].contains(where: { w.hasSuffix($0) }) { return String(w.dropLast(2)) }
        if w.count > 3, w.hasSuffix("s"), !w.hasSuffix("ss") { return String(w.dropLast()) }
        return w
    }

    /// The row's counted noun: the head noun of the value's phrase after its number, up to a connector ("1 rear
    /// engine": engine; "2 engines per arm": engines), or else the first content word of its claim. A version or
    /// model row counts nothing ("Version 1", "Current model": an identifier must be stated, never an article).
    static func countedWords(value: String, claim: String, unit: String = "") -> Set<String> {
        let filler: Set<String> = ["the", "and", "with", "for", "per", "its", "of", "on", "in", "a", "an", "number", "count", "total", "each",
                                   "how", "many", "there", "are", "is", "current", "new", "latest", "main"]
        let identifiers: Set<String> = ["version", "model", "generation", "gen", "mark", "mk", "type", "series", "edition", "release", "variant"]
        let connectors: Set<String> = ["per", "each", "on", "in", "for", "at", "of", "with", "by", "to", "from", "across", "under", "over"]
        let tokens = value.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let claimWords = claim.lowercased().split { !$0.isLetter }.map(String.init)
        // The claim's head noun: the last content word of its first phrase ("Arm engines": engines; "Engine count
        // for the jet suit": engine; "Suit model": model). An identifier row: its value names a version or model, or
        // its claim's head is one ("Current model").
        let claimHead = claimWords.prefix { !connectors.contains($0) }.filter { $0.count >= 3 && !filler.contains($0) }.last
        if tokens.contains(where: identifiers.contains) || claimHead.map(identifiers.contains) == true { return [] }
        // A measured quantity takes no count word: a unit after the value's number ("1 kg") or a measurement claim
        // ("Dry mass", "Thrust"); its number must be stated.
        let measures: Set<String> = ["mass", "weight", "thrust", "force", "power", "speed", "velocity", "length", "height", "width", "depth",
            "diameter", "radius", "range", "distance", "time", "duration", "pressure", "temperature", "capacity", "energy", "volume", "area",
            "rate", "price", "cost", "altitude", "endurance", "payload", "efficiency", "torque", "voltage", "frequency", "size"]
        // (The unit is the word right after the number, or the row's own unit field: "1" with unit "kg/h".)
        let at0 = tokens.firstIndex { $0.first?.isNumber == true || numberWords[$0] != nil || ordinals[$0] != nil }
        if let at0, at0 + 1 < tokens.count, isUnitWord(tokens[at0 + 1]) { return [] }
        let unitWords = unit.lowercased().split { !$0.isLetter }.map(String.init)
        if unit.contains("/") || unitWords.contains(where: { isUnitWord($0) }) { return [] }
        if let head = claimHead, measures.contains(head) || measures.contains(singular(head)) { return [] }
        let at = tokens.firstIndex { $0.first?.isNumber == true || numberWords[$0] != nil || ordinals[$0] != nil }
        if let at {
            let phrase = tokens[(at + 1)...].prefix { !connectors.contains($0) }.filter { $0.allSatisfy(\.isLetter) && $0.count >= 3 && !filler.contains($0) }
            if let head = phrase.last { return [head] }
        }
        if let u = unitWords.last, u.count >= 3 { return [u] }   // a count unit ("engines")
        return claimHead.map { [$0] } ?? []
    }

    /// The value of a Roman numeral (i to mmmcmxcix), or nil.
    static func romanValue(_ s: String) -> Int? {
        let v: [Character: Int] = ["i": 1, "v": 5, "x": 10, "l": 50, "c": 100, "d": 500, "m": 1000]
        guard !s.isEmpty, s.count <= 15, s.allSatisfy({ v[$0] != nil }) else { return nil }
        let n = s.compactMap { v[$0] }
        var total = 0
        for (k, x) in n.enumerated() { total += k + 1 < n.count && x < n[k + 1] ? -x : x }
        return total > 0 ? total : nil
    }

    /// Whether a number starts at `i` and the mark `close` follows it right away ("10'" in "'10'").
    static func closesAfterNumber(_ chars: [Character], _ i: Int, _ close: Character) -> Bool {
        var i = i
        if i < chars.count, "-+\u{2212}".contains(chars[i]) { i += 1 }
        var k = i
        while k < chars.count, chars[k].isNumber || chars[k] == "." || chars[k] == "," { k += 1 }
        return k > i && k < chars.count && chars[k] == close && !(k + 1 < chars.count && chars[k + 1].isNumber)
    }

    static func unitPrimes(_ s: String) -> String {
        let chars = Array(s)
        var out = "", curlyDouble = 0, curlySingle = 0, straightDouble = false, straightSingle = false
        for (i, c) in chars.enumerated() {
            let prev = out.last, next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            let afterDigit = prev?.isNumber == true, beforeDigit = next?.isNumber == true
            // A number may start with a sign or a decimal point ("'-10'", "'.5'").
            let beforeNumber = beforeDigit || (next.map { "-+.\u{2212}".contains($0) } == true && i + 2 < chars.count
                && (chars[i + 2].isNumber || (chars[i + 2] == "." && i + 3 < chars.count && chars[i + 3].isNumber)))
            let afterWord = prev.map { $0.isLetter || $0.isNumber } ?? false, beforeLetter = next?.isLetter == true
            switch c {
            case "\u{2}": curlyDouble = 0; curlySingle = 0; straightDouble = false; straightSingle = false; out.append(c)
            case "\u{201C}", "\u{201E}": curlyDouble += 1; out.append(c)
            case "\u{2018}", "\u{201A}":   // "‘90s" opens nothing; "‘10’" does
                if !beforeNumber || closesAfterNumber(chars, i + 1, "\u{2019}") { curlySingle += 1 }; out.append(c)
            case "\u{201D}":
                if afterDigit, beforeDigit || curlyDouble == 0 { out += "\u{2032}\u{2032}" } else { curlyDouble = max(0, curlyDouble - 1); out.append(c) }
            case "\u{2019}":
                if afterDigit, beforeDigit || curlySingle == 0 { out += "\u{2032}" }
                else if afterWord, beforeLetter { out.append(c) }   // an apostrophe: "it’s"
                else { if afterWord { curlySingle = max(0, curlySingle - 1) }; out.append(c) }
            case "\"":
                if afterDigit, beforeDigit || !straightDouble { out += "\u{2032}\u{2032}" } else { straightDouble.toggle(); out.append(c) }
            case "'":
                if afterDigit, beforeDigit || !straightSingle { out += "\u{2032}" }   // "5'11", "5' tall"
                else if afterWord, beforeLetter { out.append(c) }                     // an apostrophe: "it's"
                else if afterWord { straightSingle = false; out.append(c) }           // closes "'compact'"
                else if beforeNumber, closesAfterNumber(chars, i + 1, "'") { straightSingle = true; out.append(c) }   // "'10'"
                else if beforeDigit { out.append(c) }                                 // an elision: "'90s"
                else if beforeLetter { straightSingle = true; out.append(c) }         // opens "'compact'"
                else { out.append(c) }
            default: out.append(c)
            }
        }
        return out
    }

    /// Each vulgar fraction character as "n/d", after a digit as "+n/d" ("1½" is "1+1/2").
    static func plainFractions(_ s: String) -> String {
        var out = ""
        for c in s {
            guard let v = c.unicodeScalars.first?.value, c.unicodeScalars.count == 1,
                  (0xBC...0xBE).contains(v) || (0x2150...0x215E).contains(v) || v == 0x2189 else { out.append(c); continue }
            let f = String(c).precomposedStringWithCompatibilityMapping.replacingOccurrences(of: "\u{2044}", with: "/")
            if out.last?.isNumber == true { out += "+" }
            out += f
        }
        return out
    }

    /// Each run of Unicode superscript digits and signs as "^" and plain characters.
    static func markedSuperscripts(_ s: String) -> String {
        var out = "", inRun = false
        for c in s {
            if let plain = superscripts[c] { if !inRun { out.append("^") }; out.append(plain); inRun = true }
            else { out.append(c); inRun = false }
        }
        return out
    }

    static func decodeEntities(_ s: String) -> String {
        var t = s
        // Named entities (the common ones; "&amp;" last, so "&amp;minus;" stays text), then numeric ones below.
        for (e, c) in [("&nbsp;", "\u{00A0}"), ("&thinsp;", "\u{2009}"), ("&hairsp;", "\u{200A}"), ("&ensp;", " "), ("&emsp;", " "),
                       ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
                       ("&rsquo;", "\u{2019}"), ("&lsquo;", "\u{2018}"), ("&sbquo;", "\u{201A}"), ("&ldquo;", "\u{201C}"), ("&rdquo;", "\u{201D}"), ("&bdquo;", "\u{201E}"),
                       ("&laquo;", "\u{00AB}"), ("&raquo;", "\u{00BB}"), ("&ndash;", "\u{2013}"), ("&mdash;", "\u{2014}"), ("&minus;", "\u{2212}"),
                       ("&hellip;", "..."), ("&deg;", "\u{00B0}"), ("&times;", "\u{00D7}"), ("&divide;", "\u{00F7}"), ("&plusmn;", "\u{00B1}"),
                       ("&le;", "\u{2264}"), ("&ge;", "\u{2265}"), ("&asymp;", "\u{2248}"), ("&prime;", "\u{2032}"), ("&Prime;", "\u{2033}"),
                       ("&sup1;", "\u{00B9}"), ("&sup2;", "\u{00B2}"), ("&sup3;", "\u{00B3}"), ("&frac14;", "\u{00BC}"), ("&frac12;", "\u{00BD}"),
                       ("&frac34;", "\u{00BE}"), ("&frasl;", "\u{2044}"), ("&permil;", "\u{2030}"), ("&euro;", "\u{20AC}"), ("&pound;", "\u{00A3}"),
                       ("&yen;", "\u{00A5}"), ("&cent;", "\u{00A2}"), ("&micro;", "\u{00B5}"), ("&middot;", "\u{00B7}"), ("&shy;", "\u{00AD}"),
                       ("&zwj;", "\u{200D}"), ("&zwnj;", "\u{200C}"),
                       ("&leq;", "\u{2264}"), ("&geq;", "\u{2265}"), ("&approx;", "\u{2248}"), ("&sim;", "\u{223C}"), ("&sdot;", "\u{22C5}"),
                       ("&ne;", "\u{2260}"), ("&radic;", "\u{221A}"), ("&lowast;", "\u{2217}"), ("&infin;", "\u{221E}"), ("&mp;", "\u{2213}"),
                       ("&amp;", "&")] {
            t = t.replacingOccurrences(of: e, with: c)
        }
        // Any other named entity is a symbol (never letters, so a number beside it is not a bare number).
        t = t.replacingOccurrences(of: #"&[a-zA-Z][a-zA-Z0-9]{1,30};"#, with: "\u{FFFC}", options: .regularExpression)
        guard let re = try? NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]+);"#) else { return t }
        let ns = t as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let hex = ns.substring(with: m.range(at: 1)) == "x"
            if let v = UInt32(ns.substring(with: m.range(at: 2)), radix: hex ? 16 : 10), let u = Unicode.Scalar(v) { out.unicodeScalars.append(u) }
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    /// The shortest quote part that counts as evidence (characters after normalizing): a bare value such as
    /// "85 mph" is not enough context.
    public static let minimumPart = 16

    /// One word of normalized text: its text without trailing sentence punctuation (and, for a word, without
    /// enclosing brackets), and whether a hard boundary (punctuation, a block such as a table cell or paragraph, the
    /// start or end of the text) is on either side.
    struct Token: Equatable {
        var text: String
        var closedBefore: Bool
        var closedAfter: Bool
        var hasLetter: Bool { text.contains { $0.isLetter } }
        var hasDigit: Bool { text.contains { $0.isNumber } }
    }

    static func tokens(_ normalized: String) -> [Token] {
        var out: [Token] = []
        var closed = true
        func close() { if !out.isEmpty { out[out.count - 1].closedAfter = true }; closed = true }
        let raws = normalized.split(separator: " ")
        for (n, raw) in raws.enumerated() {
            if raw == "\u{2}" || raw == "\u{2014}" { close(); continue }
            // An opening parenthesis starts an aside, a hard boundary before it ("1,050 horsepower (incidentally …"),
            // unless the aside qualifies the quantity: a rate, unit, bound, magnitude or number ("10 litres (per minute)",
            // "10 kW (maximum)") goes on with it.
            if raw.first == "(" || raw.first == "[" {
                let inner = String(raw.dropFirst()).trimmingCharacters(in: CharacterSet(charactersIn: "()[].,;:!?"))
                let qualifies = inner.first?.isNumber == true || inner.first.map { "+-\u{2212}~\u{00B1}\u{2248}<>".contains($0) } == true
                    || ["per", "every", "each", "plus", "daily", "hourly", "weekly", "monthly", "yearly", "annually"].contains(inner)
                    || isUnitWord(inner) || postBounds.contains(inner) || boundTails.contains(inner) || magnitudes.contains(inner)
                    || boundWords.contains(inner)
                // (Two-word openers: "(a minute)", "(an hour)", "(and up)", "(or more)", "(at most)", "(up to)".)
                let second = n + 1 < raws.count ? String(raws[n + 1]).trimmingCharacters(in: CharacterSet(charactersIn: "()[].,;:!?")) : ""
                let qualifiesTwo = (["a", "an"].contains(inner) && timeUnits.contains(second))
                    || (["and", "or"].contains(inner) && (boundTails.contains(second) || second == "more" || second == "less"))
                    || (inner == "at" && ["most", "least"].contains(second)) || (inner == "up" && second == "to")
                if !qualifies, !qualifiesTwo { close() }
            }
            // A hyphen between two words ("five-engine", "suit - with") is punctuation: next to a number it stays
            // a word of its own (a sign or a range).
            // A glued hyphen is punctuation ("five-engine" is "five engine"), except in a compound unit right after a
            // number ("10 n-m", "10 amp-hours"), where it stays a word of the quantity.
            if raw == "\u{2011}" {
                let unit = out.count >= 2 && out[out.count - 2].hasDigit && !out[out.count - 1].closedBefore
                if unit { out.append(Token(text: "-", closedBefore: false, closedAfter: false)); closed = false } else { close() }
                continue
            }
            if raw == "-", let before = out.last, before.text.allSatisfy({ $0.isLetter }), n + 1 < raws.count,
               raws[n + 1].first?.isLetter == true, !raws[n + 1].contains(where: { $0.isNumber }) { close(); continue }
            var t = String(raw), after = false
            func trimEnd() { while let c = t.last, ".,;:!?".contains(c) { t.removeLast(); after = true } }
            trimEnd()
            // A bound abbreviation's period ("approx. 10", "max. 10") does not end it either.
            if after, raw.last == ".", !raw.dropLast().contains(where: { ".,;:!?".contains($0) }),
               ["approx", "appx", "max", "min", "ca", "c", "est", "abt", "nom", "typ"].contains(t) { after = false }
            // A unit abbreviation's period after a number ("10 in.", "10 gal.", "10 cu. ft.") does not end the
            // quantity: what may follow it is decided in `match` (a sentence after it, "10 s. A second", then misses).
            if after, raw.last == ".", !raw.dropLast().contains(where: { ".,;:!?".contains($0) }), t.count <= 3,
               t.allSatisfy({ $0.isLetter }), let before = out.last, before.hasDigit || before.text.count <= 3, !before.closedAfter,
               out.count >= 1, out.suffix(2).contains(where: { $0.hasDigit }) { after = false }
            if t.contains(where: { $0.isLetter }), !t.contains(where: { $0.isNumber }) {
                t = t.trimmingCharacters(in: CharacterSet(charactersIn: "()[]{}"))
                trimEnd()
            }
            if t.isEmpty || t == "..." { close(); continue }
            out.append(Token(text: t, closedBefore: closed, closedAfter: after))
            closed = after
        }
        if !out.isEmpty { out[out.count - 1].closedAfter = true }
        return out
    }

    /// Where `quote` is in `page` (the page's tokens and the matched token ranges), or nil. The quote is split at
    /// an ellipsis or a bracketed insertion into parts; all parts together are at least `minimumPart` characters
    /// and the longest at least half that. Each part's words must equal the page's words in order (a word ends at a
    /// space; a dash is a word of its own), except that a letters-only word glued to a gap may be completed by it
    /// ("engine[s]", "[T]he"; not a unit after a number, "10 m[…]"). A number is a whole expression: a part that
    /// starts with a number (or a sign, or a unit right after a number) may not follow a page word without letters
    /// (an operator, a symbol, another number: "≥ 10", "10 ± 2", "6.674 30", "5′ 11″") unless a hard boundary is
    /// between them, and one that starts with a sign may not follow a word with a digit ("2e - 3"); a part that ends
    /// with a number or a unit after one may not be followed by such a word, nor by "to" and a number (a range).
    static func match(_ quote: String, in page: String, html: Bool = true) -> (tokens: [Token], ranges: [Range<Int>])? {
        // In a quote, an ellipsis and any bracketed insertion ("[...]", "[…]", "[s]", "[the suit]") are gaps.
        let gap = "\u{1}"
        let q = normalized(quote, html: false).replacingOccurrences(of: #"\[[^\]]{0,40}\]"#, with: gap, options: .regularExpression)
            .replacingOccurrences(of: "...", with: gap)
        let p = tokens(normalized(page, html: html))
        let raw = q.components(separatedBy: gap)
        // Each part: its words, and whether a gap is glued to its first or last word (no space between).
        struct Part { var words: [Token]; var gluedBefore: Bool; var gluedAfter: Bool; var text: String }
        var parts: [Part] = []
        for (n, r) in raw.enumerated() {
            let words = tokens(r)
            guard !words.isEmpty else { continue }
            let gb = n > 0 && r.first.map { !" .,;:!?".contains($0) } == true
            let ga = n < raw.count - 1 && r.last.map { !" .,;:!?".contains($0) } == true
            // (Its length is that of its normalized text, as the too-short check measures it: "dry weight: 27kg" is 16.)
            parts.append(Part(words: words, gluedBefore: gb, gluedAfter: ga, text: r.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:!?"))))
        }
        guard let longest = parts.map(\.text.count).max(), longest >= minimumPart / 2,
              parts.reduce(0, { $0 + $1.text.count }) >= minimumPart else { return nil }
        func isSign(_ t: Token) -> Bool { t.text == "-" || t.text == "+" }
        // At the start: a number or a sign. At the end: a number, or a unit right after a number.
        func numericStart(_ words: [Token]) -> Bool { words[0].hasDigit || isSign(words[0]) }
        func numericEnd(_ words: [Token]) -> Bool { quantityEnd(words, words.count - 1) != nil }
        // The number a quantity ends with: `i` itself when it has a digit, else the number before up to 3 unit words
        // ("10 degrees celsius"); nil when there is none.
        func quantityEnd(_ ws: [Token], _ i: Int) -> Int? {
            var k = i
            while k >= 0, k > i - 6 {
                if ws[k].hasDigit, !unitWord(ws[k]) { return k }
                guard unitWord(ws[k]), k == i || !ws[k].closedAfter else { return nil }
                k -= 1
            }
            return nil
        }
        // A unit word: letters with unit symbols ("m", "n·m", "m/s", "m^2", "s^", "µm", "°c") or a compound
        // unit's hyphen.
        // Only a real unit word or symbol counts ("kg", "litres", "n·m", "m/s", "°c"); an ordinary word does not
        // ("175kg of thrust" ends in prose, not in a unit).
        func unitWord(_ t: Token) -> Bool {
            if t.text == "-" { return true }
            guard t.hasLetter, !(t.text.first?.isNumber ?? false) else { return false }
            if Self.isUnitWord(t.text) { return true }
            return t.text.contains { "/^\u{00B7}\u{22C5}_\u{00B0}".contains($0) }
                && t.text.allSatisfy { $0.isLetter || $0.isNumber || "/^\u{00B7}\u{22C5}_\u{00B0}%".contains($0) }
        }
        func bare(_ t: Token) -> Bool { !t.hasLetter }
        // A letters-only quote word glued to a gap may be completed by it, unless it is a unit after a number.
        func completable(_ words: [Token], at i: Int, neighbor j: Int) -> Bool {
            let w = words[i]
            guard w.text.allSatisfy({ $0.isLetter }) else { return false }
            return !(j >= 0 && j < words.count && words[j].hasDigit)
        }
        func fits(_ part: Part, at s: Int) -> Bool {
            let w = part.words, last = w.count - 1
            guard s + last < p.count else { return false }
            // Whether a glued gap completes the first or last word (then that edge is inside a word).
            var completedStart = false, completedEnd = false
            for j in 0...last {
                let page = p[s + j].text, mine = w[j].text
                if page == mine { continue }
                if j == 0, part.gluedBefore, completable(w, at: 0, neighbor: 1), page.hasSuffix(mine) { completedStart = true; continue }
                if j == last, part.gluedAfter, completable(w, at: last, neighbor: last - 1), page.hasPrefix(mine) { completedEnd = true; continue }
                return false
            }
            // The start: a number may not continue an expression before it (a gap glued to it changes nothing).
            if !completedStart, s > 0, !p[s].closedBefore, numericStart(w) {
                let prev = p[s - 1]
                if bare(prev) { return false }
                // The end of a range in words ("10 to 20 bar", "10 bar to 20 bar").
                // The end of a "between … and …" range.
                // A written bound or approximation ("up to 10", "at least 10", "less than 10", "about 10").
                if Self.boundWords.contains(prev.text) || (prev.text == "to" && s >= 2 && p[s - 2].text == "up") { return false }
                if (prev.text == "and" || prev.text == "to"), !prev.closedBefore, s >= 2, let k = quantityEnd(p, s - 2) {
                    if prev.text == "to" { return false }
                    if p[max(0, k - 3)..<k].contains(where: { $0.text == "between" }) { return false }
                }
                if isSign(w[0]) || w[0].text.first == "+" || w[0].text.first == "-", prev.hasDigit { return false }
                if w[0].hasDigit, prev.text.last == "e", prev.text.dropLast().last?.isNumber == true { return false }
            }
            // The end: a number may not go on after it.
            let e = s + last
            // A counted noun right after a number ("5 engines") keeps its bounds, rates and ranges ("or more", "per
            // wing", "every …"), though it is no unit (no default deny after it).
            // (Also a few words: "2 jet engines", "100 brake horsepower".)
            let countEnd: Bool = {
                guard w[last].text.allSatisfy(\.isLetter) else { return false }
                var k = last - 1
                while k >= 0, k >= last - 3 {
                    if w[k].closedAfter { return false }
                    if w[k].hasDigit { return true }
                    guard w[k].text.allSatisfy(\.isLetter) else { return false }
                    k -= 1
                }
                return false
            }()
            if !completedEnd, e + 1 < p.count, !p[e].closedAfter, numericEnd(w) || countEnd {
                let next = p[e + 1]
                // A dash goes on with a number only when a number follows it ("10 - 20"); before a word it is
                // punctuation ("1,050 bhp - the company").
                let after = e + 2 < p.count ? p[e + 2] : nil
                let unitEnd = w[last].hasLetter && !(w[last].text.first?.isNumber ?? false)
                // A unit goes on: "per …", or a power or quotient unit ("10 m s^-1", "10 metres per second").
                if unitEnd, quantityEnd(w, last) != nil, next.text == "per" || next.text.contains("^") || next.text.contains("/") { return false }
                // After a number, "per" always goes on ("10 per minute", "10l per minute", "10% per month").
                if next.text == "per" { return false }
                // A quantity with a unit (attached, "10l", "10%", "5′11″", or a unit word after the number) is followed
                // only by ordinary prose words: any other word may continue the unit, a rate or a product ("100 amp
                // hours", "100 v a", "10 litres every fifteen minutes").
                let withUnit = (w[last].hasDigit && w[last].text.contains { !$0.isNumber && !".,".contains($0) }) || (unitEnd && quantityEnd(w, last) != nil)
                // (An ordinary word of four letters or more is prose too, "1,050hp other than …"; a unit, time,
                // magnitude, bound or rate word, or a short symbol-like word, may go on with the quantity.)
                let plainProse = next.text.count >= 4 && next.text.allSatisfy(\.isLetter) && !Self.isUnitWord(next.text)
                    && !Self.timeUnits.contains(next.text) && !Self.magnitudes.contains(next.text) && !Self.postBounds.contains(next.text)
                    && !Self.boundTails.contains(next.text) && !["every", "each", "plus", "times", "minus", "daily", "hourly", "weekly",
                        "monthly", "yearly", "annually", "annual", "nightly", "apiece", "continuously"].contains(next.text)
                if withUnit, !Self.proseAfterQuantity.contains(next.text), !plainProse { return false }
                // An allowed word that leads into another quantity or a time continues it ("10 cm by 20 cm",
                // "10 litres in 30 seconds", "10 kg over 2 hours").
                // Modifiers between the connector and the quantity are skipped ("in just 30 seconds", "by about 20 cm").
                var m = e + 2
                while m < p.count, m < e + 5, Self.modifiers.contains(p[m].text) { m += 1 }
                // (After a counted noun only a rate goes on: "5 engines in two pods" is an arrangement.)
                let connectors: Set<String> = withUnit || w[last].hasDigit ? ["by", "in", "over", "for", "within", "under", "every", "each"] : ["every", "each"]
                if withUnit || w[last].hasDigit || countEnd, m < p.count, connectors.contains(next.text) {
                    let t = p[m]
                    if t.hasDigit || isSign(t) || Self.countWords.contains(t.text)
                        || ((t.text == "a" || t.text == "an") && m + 1 < p.count && Self.timeUnits.contains(p[m + 1].text)) { return false }
                }
                // A bound after the quantity ("10 kg or less", "10 kw or more", "10 kg max", "10 bar and up").
                if withUnit || w[last].hasDigit || countEnd {
                    if Self.postBounds.contains(next.text) { return false }
                    if next.text == "or" || next.text == "and", let t = after, Self.boundTails.contains(t.text) { return false }
                    // ("10 litres at most", "10 kW at least", "10 litres up to 12")
                    if next.text == "at", let t = after, ["most", "least"].contains(t.text) { return false }
                    if next.text == "up", let t = after, t.text == "to" { return false }
                }
                // After a bare number, a unit word goes on ("10 percent", "100 watt hours", "10 m").
                if !withUnit, w[last].hasDigit, Self.isUnitWord(next.text) { return false }
                // A number goes on with a magnitude ("$10 million", "3 bn").
                if w[last].hasDigit, Self.magnitudes.contains(next.text) { return false }
                if quantityEnd(w, last) != nil || countEnd {
                    // A rate ("10 metres a second", "5 litres each hour") or a unit product ("10 kw h").
                    if ["a", "an", "each", "every"].contains(next.text), let t = after,
                       Self.timeUnits.contains(t.text) || t.hasDigit || Self.countWords.contains(t.text) { return false }
                    if unitEnd, quantityEnd(w, last) != nil, Self.isUnitSymbol(next.text) { return false }
                }
                let dashBeforeWord = next.text == "-" && !(unitEnd && quantityEnd(w, last) != nil) && !(after.map { $0.hasDigit || $0.text.first == "." || isSign($0) } ?? false)
                if bare(next), !dashBeforeWord { return false }
                if next.text == "to", e + 2 < p.count, p[e + 2].hasDigit || isSign(p[e + 2]) || Self.numberWords[p[e + 2].text] != nil { return false }
                // The start of a "between … and …" range.
                if next.text == "and", e + 2 < p.count, p[e + 2].hasDigit || isSign(p[e + 2]), let k = quantityEnd(p, e),
                   p[max(0, k - 3)..<k].contains(where: { $0.text == "between" }) { return false }
            }
            return true
        }
        var from = 0
        var ranges: [Range<Int>] = []
        for (n, part) in parts.enumerated() {
            // A part glued after the previous part's completed word may start in that same word.
            let start = n > 0 && part.gluedBefore && parts[n - 1].gluedAfter ? max(0, from - 1) : from
            guard let s = (start..<max(start, p.count)).first(where: { fits(part, at: $0) }) else { return nil }
            ranges.append(s..<(s + part.words.count)); from = s + part.words.count
        }
        return (p, ranges)
    }

    public static func found(_ quote: String, in page: String, html: Bool = true) -> Bool { match(quote, in: page, html: html) != nil }


    /// A number written with plain spaces between groups of 3 digits ("1 144", "12 500 000"; the first group 1 to 3
    /// digits) is one number ("1,144"), on the page and in the quote: a page may group with plain spaces, and a model
    /// often copies a narrow no-break space as a plain one. A year before a number ("2019 144") stays apart.
    static func groupedThousands(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"(?<![0-9.,])[0-9]{1,3}(?: [0-9]{3})+(?![0-9])"#) else { return s }
        let ns = s as NSString
        var out = "", last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += ns.substring(with: m.range).replacingOccurrences(of: " ", with: ",")
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }


    /// Whether the quote, or the page text within 160 characters around it, attributes the figure to its maker or
    /// one person.
    static func attributed(_ quote: String, in page: String) -> Bool {
        guard let m = match(quote, in: page) else { return false }
        // The quote and about 160 characters (25 words) on either side.
        return m.ranges.contains { r in
            let lo = max(0, r.lowerBound - 25), hi = min(m.tokens.count, r.upperBound + 25)
            return m.tokens[lo..<hi].map(\.text).joined(separator: " ").range(of: attribution, options: .regularExpression) != nil
        }
    }

    /// The page's own publication date (YYYY-MM-DD), nil when the page states none. In order: its page-level
    /// publication meta tags (property or name article:published_time, og:published_time, date, dc.date,
    /// citation_publication_date, pubdate; either attribute order and quote style); the top-level `datePublished`
    /// of its JSON-LD article object (Article, NewsArticle, BlogPosting, ...; then WebPage), never a nested one such
    /// as a related article's or a comment's. Microdata (`itemprop`) and `<time>` are not read: their owner (the
    /// article, a comment, a review) is not known without the page's item scopes.
    static func pageDate(_ html: String) -> String? {
        // The first 400k characters, without HTML comments (a commented-out tag is not the page's metadata).
        let raw = (html as NSString).substring(to: min((html as NSString).length, 400_000))
        let h = raw.replacingOccurrences(of: #"(?s)<!--.*?(-->|$)"#, with: " ", options: .regularExpression)
        // Meta tags only outside script, style, template and noscript content (a widget's template text is not
        // the page's metadata); JSON-LD is read from its own scripts.
        let tags = h.replacingOccurrences(of: #"(?is)<(script|style|template|noscript)\b.*?(</\1\s*>|$)"#, with: " ", options: .regularExpression)
        let ns = tags as NSString
        // The first valid date among the matches of all patterns, in document order (an impossible or ambiguous one
        // is skipped).
        func first(_ ps: [String]) -> String? {
            var found: [(Int, String)] = []
            for p in ps {
                guard let re = try? NSRegularExpression(pattern: p) else { continue }
                for m in re.matches(in: tags, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges > 1 {
                    found.append((m.range.location, ns.substring(with: m.range(at: 1))))
                }
            }
            return found.sorted { $0.0 < $1.0 }.lazy.compactMap { isoDate($0.1) }.first
        }
        // 1. Page-level meta tags (also Dublin Core terms and common publishing names).
        let names = #"(?:article:published_time|og:published_time|date|dc\.date|dc\.date\.issued|dcterms\.date|dcterms\.created|dcterms\.issued|citation_publication_date|pubdate|publish[-_]?date|publication[-_]date|sailthru\.date|parsely-pub-date)"#
        let attr = #"(?:property|name)\s*=\s*["']"# + names + #"["']"#
        let date = #"(\d{4}[-/]\d{1,2}[-/]\d{1,2}|\d{1,2}[-/]\d{1,2}[-/]\d{4})"#
        if let d = first([#"(?i)<meta[^>]+"# + attr + #"[^>]+content\s*=\s*["']"# + date, #"(?i)<meta[^>]+content\s*=\s*["']"# + date + #"[^"']*["'][^>]+"# + attr]) {
            return d
        }
        // 2. JSON-LD outside inert templates.
        let live = h.replacingOccurrences(of: #"(?is)<template\b.*?(</template\s*>|$)"#, with: " ", options: .regularExpression)
        if let d = jsonLDDate(live, NSRange(location: 0, length: (live as NSString).length)) { return d }
        // 3. With no usable metadata: the date the page shows in its dateline under the title.
        return shownDate(tags)
    }

    /// A numeric date as YYYY-MM-DD, or nil when it is not a real date or its order is ambiguous ("08-10-2020" could
    /// be 8 October or 10 August; "13-10-2020" is day first).
    static func isoDate(_ s: String) -> String? {
        let parts = s.split(whereSeparator: { $0 == "-" || $0 == "/" }).compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var y = parts[0], m = parts[1], d = parts[2]
        if parts[2] > 999 {
            y = parts[2]
            if parts[0] > 12, parts[1] <= 12 { d = parts[0]; m = parts[1] }
            else if parts[1] > 12, parts[0] <= 12 { m = parts[0]; d = parts[1] }
            else if parts[0] == parts[1] { m = parts[0]; d = parts[1] }
            else { return nil }
        }
        guard (1900...2100).contains(y), (1...12).contains(m) else { return nil }
        let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1]
        guard (1...days).contains(d) else { return nil }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    static let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]

    /// The date the page shows in its dateline under the title: the text of the first `<time>` element, or of an
    /// element marked as a date, dateline, byline or publication line (not an "updated" or "related" one), within
    /// 3,000 characters of markup after the first <h1>; nil without one. Body prose is never read for a date.
    static func shownDate(_ html: String) -> String? {
        guard let h1 = html.range(of: #"(?is)<h1\b[^>]*>.*?</h1\s*>"#, options: .regularExpression) else { return nil }
        let after = String(html[h1.upperBound...].prefix(3_000))
        let ans = after as NSString
        guard let tagRe = try? NSRegularExpression(pattern: #"<(/?)([a-zA-Z0-9]+)\b([^>]*)>"#) else { return nil }
        let tags = tagRe.matches(in: after, range: NSRange(location: 0, length: ans.length))
        let void: Set<String> = ["br", "img", "meta", "link", "input", "hr", "wbr", "source", "area", "col", "embed", "param", "track"]
        func bad(_ attrs: String) -> Bool {
            let a = attrs.lowercased()
            return ["updat", "modif", "related", "revis", "recommend", "more-stories"].contains { a.contains($0) }
        }
        func isCandidate(_ name: String, _ attrs: String) -> Bool {
            name == "time" || attrs.range(of: #"(?i)(?:class|id|itemprop)\s*=\s*["'][^"']*(?:date|byline|publish|posted)[^"']*["']"#, options: .regularExpression) != nil
        }
        // Walk the tags with a stack of open elements; each candidate is judged by its own attributes, its open
        // ancestors (an "updated" or "related" container), the words right before it and its own text. A candidate
        // that contains another candidate is left to its children.
        var stack: [(name: String, attrs: String, index: Int)] = []
        // Containers still open at the h1 (an "updated" or "related" one around the title) are ancestors too.
        let prefix = String(html[..<h1.lowerBound].suffix(50_000)) as NSString
        for t in tagRe.matches(in: prefix as String, range: NSRange(location: 0, length: prefix.length)) {
            let name = prefix.substring(with: t.range(at: 2)).lowercased(), attrs = prefix.substring(with: t.range(at: 3))
            if prefix.substring(with: t.range(at: 1)) == "/" { if let at = stack.lastIndex(where: { $0.name == name }) { stack.removeSubrange(at...) }; continue }
            if void.contains(name) || attrs.hasSuffix("/") { continue }
            stack.append((name, attrs, -1))
        }
        for (k, t) in tags.enumerated() {
            let closing = ans.substring(with: t.range(at: 1)) == "/"
            let name = ans.substring(with: t.range(at: 2)).lowercased()
            let attrs = ans.substring(with: t.range(at: 3))
            if closing {
                if let at = stack.lastIndex(where: { $0.name == name }) { stack.removeSubrange(at...) }
                continue
            }
            if void.contains(name) || attrs.hasSuffix("/") { continue }
            defer { stack.append((name, attrs, k)) }
            guard isCandidate(name, attrs), !bad(attrs), !stack.contains(where: { bad($0.attrs) }) else { continue }
            // The element's inner markup, to its matching close tag.
            var depth = 0, end: Int? = nil, nested = false
            for u in tags[(k + 1)...] {
                let c = ans.substring(with: u.range(at: 1)) == "/"
                let n = ans.substring(with: u.range(at: 2)).lowercased()
                if !c, isCandidate(n, ans.substring(with: u.range(at: 3))) { nested = true }
                if n == name { if c { if depth == 0 { end = u.range.location; break }; depth -= 1 } else { depth += 1 } }
            }
            guard let close = end, !nested else { continue }
            let innerStart = t.range.location + t.range.length
            let inner = ans.substring(with: NSRange(location: innerStart, length: close - innerStart))
            let before = decodeEntities(ans.substring(with: NSRange(location: max(0, t.range.location - 300), length: min(300, t.range.location))))
                .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\u{00A0}", with: " ").lowercased()
            if before.range(of: #"(updated|modified|revised|last edited|related)\s*(?:on|at)?\s*:?\s*$"#, options: .regularExpression) != nil { continue }
            // Nor one followed by its own update marker ("June 1, 2023 (updated)"); an update label that introduces the
            // next date ("… Updated <time>…") belongs to that date.
            let rest = ans.substring(with: NSRange(location: close, length: min(200, ans.length - close)))
            if let gt = rest.firstIndex(of: ">") {
                let tail = rest[rest.index(after: gt)...]
                let segment = decodeEntities(String(tail.prefix { $0 != "<" })).lowercased()
                let nextTag = tail.drop { $0 != "<" }.lowercased()
                // (Through neutral inline wrappers: "Updated: <span><time>…".)
                let unwrapped = nextTag.replacingOccurrences(of: #"^(?:<(?:span|b|strong|em|i|a|small|font)\b[^>]*>\s*){1,3}"#, with: "", options: .regularExpression)
                let introducesNext = unwrapped.hasPrefix("<time") || unwrapped.range(of: #"^<[a-z0-9]+[^>]*(date|byline|publish|posted)"#, options: .regularExpression) != nil
                if segment.range(of: #"^\s*[\(\[,\-\x{2013}\x{2014}]?\s*(updated|modified|revised)"#, options: .regularExpression) != nil, !introducesNext { continue }
            }
            let text = decodeEntities(inner.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression))
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            if text.lowercased().range(of: #"\b(updated|modified|revised|related)\b"#, options: .regularExpression) != nil { continue }
            if let d = writtenDate(text) { return d }
        }
        return nil
    }

    /// The first written date in `window` ("October 8, 2020", "09 Apr 2020", "2020-04-09"), or nil.
    static func writtenDate(_ window: String) -> String? {
        guard !window.isEmpty else { return nil }
        let mon = #"(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?"#
        let patterns: [(String, (NSTextCheckingResult, NSString) -> String?)] = [
            (#"(?i)\b"# + mon + #"\s+(\d{1,2}),?\s+(\d{4})\b"#, { m, ns in
                guard let mo = months[String(ns.substring(with: m.range(at: 1)).lowercased().prefix(3))] else { return nil }
                return isoDate("\(ns.substring(with: m.range(at: 3)))-\(mo)-\(ns.substring(with: m.range(at: 2)))") }),
            (#"(?i)\b(\d{1,2})(?:st|nd|rd|th)?\s+"# + mon + #",?\s+(\d{4})\b"#, { m, ns in
                guard let mo = months[String(ns.substring(with: m.range(at: 2)).lowercased().prefix(3))] else { return nil }
                return isoDate("\(ns.substring(with: m.range(at: 3)))-\(mo)-\(ns.substring(with: m.range(at: 1)))") }),
            (#"\b(\d{4}-\d{2}-\d{2})\b"#, { m, ns in isoDate(ns.substring(with: m.range(at: 1))) }),
        ]
        let ns = window as NSString
        var best: (Int, String)? = nil
        for (p, read) in patterns {
            guard let re = try? NSRegularExpression(pattern: p),
                  let m = re.firstMatch(in: window, range: NSRange(location: 0, length: ns.length)), let d = read(m, ns) else { continue }
            if best == nil || m.range.location < best!.0 { best = (m.range.location, d) }
        }
        return best?.1
    }

    static let articleTypes: Set<String> = ["Article", "NewsArticle", "BlogPosting", "TechArticle", "ScholarlyArticle", "Report",
                                            "ReportageNewsArticle", "AnalysisNewsArticle", "LiveBlogPosting", "PressRelease"]
    static let pageTypes: Set<String> = ["WebPage", "ItemPage", "AboutPage", "CollectionPage", "FAQPage", "QAPage"]

    /// The `datePublished` of the page's own JSON-LD article (scripts of type application/ld+json; their top-level
    /// objects, lists and @graph). The article is the one the page names: a page object's `mainEntity` (inline or by
    /// @id); else the one article that says `mainEntityOfPage`; else the only article. With no article, the only
    /// page object's own date. Anything else (several candidates, a related article) is ambiguous: nil.
    static func jsonLDDate(_ html: String, _ scan: NSRange) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"(?is)<script[^>]+type\s*=\s*["']\s*application/ld\+json\s*["'][^>]*>(.*?)</script>"#) else { return nil }
        let ns = html as NSString
        var objects: [[String: Any]] = []
        for m in re.matches(in: html, range: scan) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(ns.substring(with: m.range(at: 1)).utf8)) else { continue }
            let top = (o as? [Any]) ?? [o]
            for case let d as [String: Any] in top {
                objects.append(d)
                for case let g as [String: Any] in d["@graph"] as? [Any] ?? [] { objects.append(g) }
            }
        }
        func types(_ d: [String: Any]) -> [String] { (d["@type"] as? [String]) ?? [(d["@type"] as? String) ?? ""] }
        func isArticle(_ d: [String: Any]) -> Bool { types(d).contains(where: articleTypes.contains) }
        func isPage(_ d: [String: Any]) -> Bool { types(d).contains(where: pageTypes.contains) }
        func date(_ d: [String: Any]) -> String? {
            guard let s = d["datePublished"] as? String, s.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil else { return nil }
            return isoDate(String(s.prefix(10)))
        }
        let articles = objects.filter(isArticle)
        let pages = objects.filter(isPage)
        // 1. The page names its main entity: that article's date (nil when it has none; the owner is known). All
        // named articles count: two different ones (a collection, two page objects) are ambiguous.
        var named: [[String: Any]] = []
        for page in pages {
            guard let me = page["mainEntity"] else { continue }
            for e in (me as? [Any]) ?? [me] {
                // A reference (also a typed stub with an @id) resolves to the graph's object first.
                let ref = (e as? String) ?? ((e as? [String: Any])?["@id"] as? String)
                if let ref, let a = articles.first(where: { $0["@id"] as? String == ref }) { named.append(a); continue }
                if let inline = e as? [String: Any], isArticle(inline) { named.append(inline) }
            }
        }
        // The same article named twice (by @id, or the same inline object) is one.
        func key(_ a: [String: Any]) -> String {
            (a["@id"] as? String).map { "id:" + $0 }
                ?? String(decoding: (try? JSONSerialization.data(withJSONObject: a, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
        }
        var seen = Set<String>()
        let distinct = named.filter { seen.insert(key($0)).inserted }
        if distinct.count == 1 { return date(distinct[0]) }
        if distinct.count > 1 { return nil }
        // 2. The one article that says it is the page's main entity.
        let main = articles.filter { $0["mainEntityOfPage"] != nil }
        if main.count == 1 { return date(main[0]) }
        if main.count > 1 { return nil }
        // 3. The only article; 4. with no article, the only page object.
        if articles.count == 1 { return date(articles[0]) }
        if articles.isEmpty, pages.count == 1 { return date(pages[0]) }
        return nil
    }

    /// Words in a quote that mark a statement by the maker or one person: such a row is at most a CLAIM.
    static let attribution = #"(?i)\b(claims?|claimed|claiming|according to|says|said|states|stated|told|the company|the maker|the manufacturer|manufacturer|founder|inventor|ceo|spokes(man|woman|person))\b"#
}

extension FactTable {
    /// Checks every source's quote on its page (at most `QuoteCheck.budget` fetches), and sets each row's label from
    /// the sources whose quote was found: none found, UNKNOWN (no value; the sources stay as notes with their check);
    /// found on two or more sites, VERIFIED only if the model said VERIFIED and no found quote attributes the figure
    /// to its maker or one person; otherwise CLAIM (or PLAUSIBLE when the model said so). Every change is listed.
    @MainActor public mutating func checkQuotes(fetcher: PageFetcher, budget: Int = QuoteCheck.budget, blocked: [String] = ResearchLimits.defaultBlocked) {
        var fetched = 0
        var pages: [String: (status: Int, body: String?, final: URL?)] = [:]
        for n in rows.indices {
            var foundSites = Set<String>()
            var attributed = false
            var foundQuotes: [String] = []
            for k in rows[n].sources.indices {
                let src = rows[n].sources[k]
                // A source's date comes only from its page: the page's publication date when the page states one,
                // else none (the model's date is removed; every change is listed).
                var dateOnPage: String? = nil
                defer {
                    let d = dateOnPage ?? ""
                    rows[n].sources[k].date = d
                    if !src.date.isEmpty, src.date != d {
                        downgrades.append("\(rows[n].id): source date \(src.date) " + (d.isEmpty ? "removed (not stated on the page)" : "corrected from the page to \(d)"))
                    }
                }
                guard !src.quote.isEmpty else { rows[n].sources[k].check = "no quote"; continue }
                // A quote under the minimum is never evidence: it is reported as too short, not as not found.
                guard QuoteCheck.normalized(src.quote, html: false).count >= QuoteCheck.minimumPart else {
                    rows[n].sources[k].check = "quote too short to check"; continue
                }
                guard let url = URL(string: src.url) else { rows[n].sources[k].check = "bad url"; continue }
                let page: (status: Int, body: String?, final: URL?)
                if let cached = pages[src.url] { page = cached }
                else if fetched < budget { fetched += 1; page = fetcher.fetch(url); pages[src.url] = page }
                else { rows[n].sources[k].check = "not checked (budget)"; continue }
                guard let body = page.body else { rows[n].sources[k].check = "page failed (\(page.status))"; continue }
                // The site that counts is where the page finally came from; a redirect to a blocked or mirror site fails.
                let finalHost = FactTable.canonicalHost(page.final?.host ?? src.host)
                if (blocked + FactTable.mirrorHosts).contains(where: { finalHost == $0 || finalHost.hasSuffix("." + $0) }) {
                    rows[n].sources[k].check = "redirected to a blocked site (\(finalHost))"; continue
                }
                dateOnPage = QuoteCheck.pageDate(body)
                if QuoteCheck.found(src.quote, in: body) {
                    rows[n].sources[k].check = "quote found"
                    foundQuotes.append(src.quote)
                    foundSites.insert(FactTable.site(finalHost))
                    if QuoteCheck.attributed(src.quote, in: body) { attributed = true }
                } else {
                    rows[n].sources[k].check = "quote not found"
                }
            }
            let before = rows[n].label
            var after = before
            // No found quote: UNKNOWN, also when every source was dropped. A row the model gave as PLAUSIBLE with no
            // source at all (a class inference) stays PLAUSIBLE.
            let inference = before == .plausible && rows[n].sources.isEmpty && rows[n].dropped == 0
            // A row whose sources were all rejected (UNKNOWN from the parse) is unconfirmed too, not "not published";
            // only a row the model itself gave as UNKNOWN with no source rejected is a researched absence.
            if foundSites.isEmpty, !inference, before != .unknown || rows[n].dropped > 0 || !rows[n].sources.isEmpty {
                after = .unknown
                // Not confirmed is not "not published": the row is left out of the author's table.
                rows[n].unconfirmed = true
            } else if before == .verified, foundSites.count < 2 || attributed {
                after = .claim
            }
            // The row's value must be what a found quote states: its headline number in one of them. A value computed
            // from other figures (a ratio of two rows' numbers) is no published fact: the row is left out.
            if !rows[n].unconfirmed, after != .unknown, let headline = QuoteCheck.statedNumbers(rows[n].value, inOrder: true).first,
               !foundQuotes.flatMap({ QuoteCheck.statedNumbers($0) }).contains(headline),
               !foundQuotes.contains(where: { QuoteCheck.statesCountWord(headline, $0, entities: QuoteCheck.countedWords(value: rows[n].value, claim: rows[n].claim, unit: rows[n].unit)) }) {
                downgrades.append("\(rows[n].id): value \(rows[n].value) is in none of its found quotes (computed, not published); left out")
                after = .unknown
                rows[n].unconfirmed = true
            }
            // A found quote must also state the claim: its share or comparison word ("most of the lifting" needs "most"),
            // and for a value in words one of its words. A quote that is on the page but says something else is no
            // evidence for the row.
            if !rows[n].unconfirmed, after != .unknown, !foundQuotes.isEmpty,
               let missing = QuoteCheck.unstatedWord(value: rows[n].value, claim: rows[n].claim, quotes: foundQuotes) {
                downgrades.append("\(rows[n].id): the found quotes do not state \"\(missing)\" (the claim's key word); left out")
                after = .unknown
                rows[n].unconfirmed = true
            }
            if after != before {
                downgrades.append("\(rows[n].id): \(before.rawValue) to \(after.rawValue) (quote check: \(foundSites.count) site\(foundSites.count == 1 ? "" : "s") with the quote\(attributed ? ", attributed to its maker or one person" : ""))")
                rows[n].label = after
            }
            if rows[n].label == .unknown { rows[n].value = "" }
        }
        quoteChecks = fetched
    }
}
