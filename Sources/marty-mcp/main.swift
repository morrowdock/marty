// SPDX-License-Identifier: Apache-2.0
// marty-mcp: the MartyGraphics engine as MCP tools over standard input and output.
import Foundation
import MartyEngine
import MartyMCP

let usage = """
    Usage: marty-mcp [--output-dir DIR] [--no-render] [--version]
      Speaks MCP (JSON-RPC 2.0, one message per line) on standard input and output.
      --output-dir DIR   where `render` writes (default: ~/Library/Caches/marty-mcp/renders).
      --no-render        turn the render tool off (it wins over --output-dir).
      --version          print the server version and the engine commit, then stop.
    """

@MainActor func run() -> Int32 {
    var args = Array(CommandLine.arguments.dropFirst())
    var output: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("marty-mcp/renders", isDirectory: true)
    var noRender = false
    while let a = args.first {
        args.removeFirst()
        switch a {
        case "--output-dir":
            guard let d = args.first else { FileHandle.standardError.write(Data((usage + "\n").utf8)); return 2 }
            args.removeFirst()
            output = URL(fileURLWithPath: d, isDirectory: true).standardizedFileURL
        case "--no-render": noRender = true
        case "--version": print("\(MCPServer.name) \(MCPServer.version) engine \(MartyPin.engineRevision)"); return 0
        default: FileHandle.standardError.write(Data((usage + "\n").utf8)); return 2
        }
    }
    let server = MCPServer(engine: MartyEngine(outputRoot: noRender ? nil : output))
    var splitter = LineSplitter()
    let stdout = FileHandle.standardOutput
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        // POSIX read returns as soon as any bytes are available (an interactive client sends one short line and
        // waits), and at most 64 KiB, so a large file on standard input never sits in memory at once.
        let n = buffer.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, $0.count) }
        if n < 0 {
            if errno == EINTR { continue }
            // A non-blocking standard input: wait until it is readable, then read again.
            if errno == EAGAIN { var p = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0); _ = poll(&p, 1, -1); continue }
            return 1
        }
        func answer(_ line: Data?) {
            let reply = line.map { server.handle(line: $0) } ?? MCPServer.tooLarge
            if let reply { stdout.write(reply + Data([0x0A])) }
        }
        if n == 0 {  // end of input: the client closed the pipe; answer a last line that had no newline
            if let last = splitter.finish() { answer(last) }
            return 0
        }
        for line in splitter.feed(Data(buffer[0..<n])) { answer(line) }
    }
}

exit(MainActor.assumeIsolated { run() })
