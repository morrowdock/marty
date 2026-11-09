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
            t = t.replacingOccurrences(of: #"(?i)</?(?:td|th|tr|thead|tbody|tfoot|table|caption|p|div|br|hr|li|ul|ol|dl|dt|dd|h[1-6]|section|article|header|footer|aside|nav|main|figure|figcaption|blockquote|pre|form|fieldset|legend|details|summary|address)\b[^>]*>"#,
                                       with: "\u{2}", options: .regularExpression)
            t = t.replacingOccurrences(of: #"(?i)</?(?:span|a|b|i|em|strong|sup|sub|small|abbr|code|mark|u|s|q|cite|bdi|bdo|data|dfn|kbd|samp|var|wbr|time|font)\b[^>]*>"#,
                                       with: "", options: .regularExpression)
            t = t.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            t = decodeEntities(t)
            // Reference marks of the page ("[3]", "[edit]", "[citation needed]") are not quoted text.
            t = t.replacingOccurrences(of: #"\[(?:\d{1,3}|[a-z]|edit|citation needed|note \d+)\]"#, with: "", options: [.regularExpression, .caseInsensitive])
            // A superscript mark left with nothing after it (a removed "[1]" reference) is dropped.
            t = t.replacingOccurrences(of: #"\^(?=[\s.,;:!?)]|$)"#, with: "", options: .regularExpression)
        }
        // Unicode superscripts likewise ("10³" is "10^3", "10⁻³" is "10^-3"), before NFKC would fold them to digits.
        t = markedSuperscripts(t)
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
        for (a, b) in [("\u{2018}", "'"), ("\u{2019}", "'"), ("\u{201A}", "'"), ("\u{201B}", "'"), ("\u{2032}", "'"),
                       ("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{201E}", "\""), ("\u{2033}", "\""), ("\u{00AB}", "\""), ("\u{00BB}", "\""),
                       ("\u{2010}", "-"), ("\u{2011}", "-"), ("\u{2012}", "-"), ("\u{2013}", "-"), ("\u{2014}", "-"), ("\u{2015}", "-"),
                       ("\u{2212}", "-"), ("\u{00A0}", " "), ("\u{202F}", " "), ("\u{2009}", " "), ("\u{2026}", "...")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        // Quote marks are dropped on both sides: a page that quotes a figure ("'1,050 bhp'") still matches.
        t = t.replacingOccurrences(of: #"['"`]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        // Spaces around a dash vary ("suit—with", "suit - with", "at − 5"): none on either side. A quote part that
        // starts with a sign ("-5 degrees") is matched after a letter but not after a digit (see `match`).
        t = t.replacingOccurrences(of: #" ?- ?"#, with: "-", options: .regularExpression)
        // A removed tag leaves a space before punctuation ("derail ."); drop it on both sides.
        t = t.replacingOccurrences(of: #" ([.,;:!?)\]])(?![0-9])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"([(\[]) "#, with: "$1", options: .regularExpression)
        // Plain-space thousands groups ("1 144") are one number on the page and in the quote alike; a block mark
        // with its spaces is one mark, never a grouping space, then a space.
        t = t.replacingOccurrences(of: "[ \u{2}]*\u{2}[ \u{2}]*", with: "\u{2}", options: .regularExpression)
        t = groupedThousands(t)
        t = t.replacingOccurrences(of: "\u{2}", with: " ")
        t = t.replacingOccurrences(of: #" ?- ?"#, with: "-", options: .regularExpression)
        t = t.replacingOccurrences(of: #" ([.,;:!?)\]])(?![0-9])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"([(\[]) "#, with: "$1", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    static let superscripts: [Character: Character] = ["\u{2070}": "0", "\u{00B9}": "1", "\u{00B2}": "2", "\u{00B3}": "3", "\u{2074}": "4",
        "\u{2075}": "5", "\u{2076}": "6", "\u{2077}": "7", "\u{2078}": "8", "\u{2079}": "9", "\u{207A}": "+", "\u{207B}": "-"]

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
        for (e, c) in [("&nbsp;", "\u{00A0}"), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
                       ("&rsquo;", "'"), ("&lsquo;", "'"), ("&ldquo;", "\""), ("&rdquo;", "\""), ("&ndash;", "-"), ("&mdash;", "-"),
                       ("&hellip;", "..."), ("&deg;", "\u{00B0}"), ("&times;", "\u{00D7}")] {
            t = t.replacingOccurrences(of: e, with: c)
        }
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

    /// Where `quote` is in `page` (normalized page text and the matched ranges), or nil: every part of the quote
    /// (split at an ellipsis or a bracketed insertion) in order, all parts together at least `minimumPart`
    /// characters and the longest at least half that. A part starts and ends on a word boundary ("85 mph" does not
    /// match inside "185 mph"), except a letter glued to a gap (a word completed in brackets, "engine[s]"). A part that starts with a sign ("-5 degrees") may follow a letter, not a digit.
    static func match(_ quote: String, in page: String, html: Bool = true) -> (page: String, ranges: [Range<String.Index>])? {
        // In a quote, an ellipsis and any bracketed insertion ("[...]", "[…]", "[s]", "[the suit]") are gaps.
        let gap = "\u{1}"
        var q = normalized(quote, html: false).replacingOccurrences(of: #"\[[^\]]{0,40}\]"#, with: gap, options: .regularExpression)
            .replacingOccurrences(of: "...", with: gap)
        q = trimEdges(q)   // a trailing period the page may not have
        let p = normalized(page, html: html)
        let raw = q.components(separatedBy: gap)
        // A part needs a word boundary on each side, except where a gap is glued to it (no space or punctuation
        // between) and the glued character is a letter: a word completed in brackets ("engine[s]", "[T]he"). A
        // number always needs its boundaries ("[…]85 mph" does not match "185 mph").
        func glued(_ c: Character?) -> Bool { c.map { !" .,;:!?".contains($0) } ?? false }
        var parts: [(text: String, before: Bool, after: Bool)] = []
        for (n, r) in raw.enumerated() {
            let t = trimEdges(r)
            guard !t.isEmpty else { continue }
            let inWordBefore = n > 0 && glued(r.first) && t.first?.isLetter == true
            let inWordAfter = n < raw.count - 1 && glued(r.last) && t.last?.isLetter == true
            parts.append((t, !inWordBefore, !inWordAfter))
        }
        // All parts together at least 16 characters, the longest at least 8 (a bare value is no evidence).
        guard let longest = parts.map(\.text.count).max(), longest >= minimumPart / 2,
              parts.reduce(0, { $0 + $1.text.count }) >= minimumPart else { return nil }
        // A number is a whole token: "5" is not inside "1.5", ".5" or "-5", and "144" is not inside "1,144", "1 144"
        // (a grouping space) or "144.5".
        func boundary(_ i: String.Index, before: Bool, signed: Bool = false, decimalLead: Bool = false, numeric: Bool = false) -> Bool {
            if before {
                guard i != p.startIndex else { return true }
                let j = p.index(before: i), c = p[j]
                if signed { return !c.isNumber && !(decimalLead && c == "-") }
                if c.isLetter || c.isNumber { return false }
                // A sign, a decimal point or a separator right before a number is part of it ("-5", ".5", "1,144"):
                // a quote without it is a different value.
                if numeric, c == "." || c == "," || c == "-" { return false }
                return true
            }
            guard i != p.endIndex else { return true }
            let c = p[i]
            if c.isLetter || c.isNumber { return false }
            if numeric, c == "." || c == ",", let k = p.index(i, offsetBy: 1, limitedBy: p.endIndex), k != p.endIndex, p[k].isNumber { return false }
            return true
        }
        var from = p.startIndex
        var ranges: [Range<String.Index>] = []
        for (part, needBefore, needAfter) in parts {
            var search = from
            var hit: Range<String.Index>? = nil
            // A sign ("-5") may follow a letter or a space, never a digit; a leading decimal point (".5") neither a
            // digit nor a sign ("-.5" is another value).
            let decimalLead = (part.first == "." || part.first == ",") && part.dropFirst().first?.isNumber == true
            let signed = decimalLead || (part.first == "-" && part.dropFirst().first?.isNumber == true)
            while let r = p.range(of: part, range: search..<p.endIndex) {
                if (!needBefore || boundary(r.lowerBound, before: true, signed: signed, decimalLead: decimalLead, numeric: part.first?.isNumber == true))
                    && (!needAfter || boundary(r.upperBound, before: false, numeric: part.last?.isNumber == true)) { hit = r; break }
                search = p.index(after: r.lowerBound)
            }
            guard let r = hit else { return nil }
            ranges.append(r); from = r.upperBound
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

    /// Spaces and punctuation trimmed from both ends, except a leading decimal point or comma before a digit (".5
    /// litres" is not "5 litres").
    static func trimEdges(_ s: String) -> String {
        let edge = " .,;:!?"
        var t = Substring(s)
        while let c = t.last, edge.contains(c) { t = t.dropLast() }
        while let c = t.first, edge.contains(c) {
            if (c == "." || c == ","), t.dropFirst().first?.isNumber == true { break }
            t = t.dropFirst()
        }
        return String(t)
    }

    /// Whether the quote, or the page text within 160 characters around it, attributes the figure to its maker or
    /// one person.
    static func attributed(_ quote: String, in page: String) -> Bool {
        guard let m = match(quote, in: page) else { return false }
        let p = m.page
        return m.ranges.contains { r in
            let lo = p.index(r.lowerBound, offsetBy: -160, limitedBy: p.startIndex) ?? p.startIndex
            let hi = p.index(r.upperBound, offsetBy: 160, limitedBy: p.endIndex) ?? p.endIndex
            return String(p[lo..<hi]).range(of: attribution, options: .regularExpression) != nil
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
        func first(_ p: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: p),
                  let m = re.firstMatch(in: tags, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
            return ns.substring(with: m.range(at: 1)).replacingOccurrences(of: "/", with: "-")
        }
        let names = #"(?:article:published_time|og:published_time|date|dc\.date|dc\.date\.issued|citation_publication_date|pubdate)"#
        let attr = #"(?:property|name)\s*=\s*["']"# + names + #"["']"#
        let date = #"(\d{4}[-/]\d{2}[-/]\d{2})"#
        if let d = first(#"(?i)<meta[^>]+"# + attr + #"[^>]+content\s*=\s*["']"# + date) ?? first(#"(?i)<meta[^>]+content\s*=\s*["']"# + date + #"[^"']*["'][^>]+"# + attr) {
            return d
        }
        // JSON-LD outside inert templates.
        let live = h.replacingOccurrences(of: #"(?is)<template\b.*?(</template\s*>|$)"#, with: " ", options: .regularExpression)
        return jsonLDDate(live, NSRange(location: 0, length: (live as NSString).length))
    }

    static let articleTypes: Set<String> = ["Article", "NewsArticle", "BlogPosting", "TechArticle", "ScholarlyArticle", "Report",
                                            "ReportageNewsArticle", "AnalysisNewsArticle", "LiveBlogPosting", "PressRelease"]
    static let pageTypes: Set<String> = ["WebPage", "ItemPage", "AboutPage", "CollectionPage", "FAQPage", "QAPage"]

    /// The `datePublished` of the page's own JSON-LD article (scripts of type application/ld+json; their top-level
    /// objects, lists and @graph). The article is the one the page names: a page object's `mainEntity` (inline or by
    /// @id); else the one article that says `mainEntityOfPage`; else the only article. With no article, the only
    /// page object's own date. Anything else (several candidates, a related article) is ambiguous: nil.
    static func jsonLDDate(_ html: String, _ scan: NSRange) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"(?is)<script[^>]+type=["']application/ld\+json["'][^>]*>(.*?)</script>"#) else { return nil }
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
            return String(s.prefix(10))
        }
        let articles = objects.filter(isArticle)
        let pages = objects.filter(isPage)
        // 1. The page names its main entity: that article's date (nil when it has none; the owner is known). All
        // named articles count: two different ones (a collection, two page objects) are ambiguous.
        var named: [[String: Any]] = []
        for page in pages {
            guard let me = page["mainEntity"] else { continue }
            for e in (me as? [Any]) ?? [me] {
                if let inline = e as? [String: Any], isArticle(inline) { named.append(inline); continue }
                let ref = (e as? String) ?? ((e as? [String: Any])?["@id"] as? String)
                if let ref, let a = articles.first(where: { $0["@id"] as? String == ref }) { named.append(a) }
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
    public mutating func checkQuotes(fetcher: PageFetcher, budget: Int = QuoteCheck.budget, blocked: [String] = ResearchLimits.defaultBlocked) {
        var fetched = 0
        var pages: [String: (status: Int, body: String?, final: URL?)] = [:]
        for n in rows.indices {
            var foundSites = Set<String>()
            var attributed = false
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
            if after != before {
                downgrades.append("\(rows[n].id): \(before.rawValue) to \(after.rawValue) (quote check: \(foundSites.count) site\(foundSites.count == 1 ? "" : "s") with the quote\(attributed ? ", attributed to its maker or one person" : ""))")
                rows[n].label = after
            }
            if rows[n].label == .unknown { rows[n].value = "" }
        }
        quoteChecks = fetched
    }
}
