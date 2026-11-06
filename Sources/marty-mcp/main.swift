// SPDX-License-Identifier: Apache-2.0
// marty-mcp: the MartyGraphics engine as MCP tools over standard input and output.
import Foundation
import MartyEngine
import MartyMCP

let usage = """
    Usage: marty-mcp [--output-dir DIR]
      Speaks MCP (JSON-RPC 2.0, one message per line) on standard input and output.
      --output-dir DIR   where `render` writes (default: ~/Library/Caches/marty-mcp/renders).
      --no-render        turn the render tool off.
    """

@MainActor func run() -> Int32 {
    var args = Array(CommandLine.arguments.dropFirst())
    var output: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("marty-mcp/renders", isDirectory: true)
    while let a = args.first {
        args.removeFirst()
        switch a {
        case "--output-dir":
            guard let d = args.first else { FileHandle.standardError.write(Data((usage + "\n").utf8)); return 2 }
            args.removeFirst()
            output = URL(fileURLWithPath: d, isDirectory: true).standardizedFileURL
        case "--no-render": output = nil
        case "--version": print("\(MCPServer.name) \(MCPServer.version) engine \(MartyPin.engineRevision)"); return 0
        default: FileHandle.standardError.write(Data((usage + "\n").utf8)); return 2
        }
    }
    let server = MCPServer(engine: MartyEngine(outputRoot: output))
    var splitter = LineSplitter()
    let stdin = FileHandle.standardInput, stdout = FileHandle.standardOutput
    while true {
        // At most 64 KiB per read, so a large file on standard input never sits in memory at once.
        let chunk = (try? stdin.read(upToCount: 65536)) ?? Data()
        if chunk.isEmpty { return 0 }  // end of input: the client closed the pipe
        for line in splitter.feed(chunk) {
            let reply = line.map { server.handle(line: $0) } ?? MCPServer.tooLarge
            if let reply { stdout.write(reply + Data([0x0A])) }
        }
    }
}

exit(MainActor.assumeIsolated { run() })
