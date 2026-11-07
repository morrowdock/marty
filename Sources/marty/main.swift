// SPDX-License-Identifier: Apache-2.0
// marty: the reference Marty loop. `ask` runs one question; `bench` runs a question file.
import Foundation
import MartyEngine
import MartyLoop

let usage = """
    Usage: marty ask QUESTION --out NEW_DIR [MODEL] [--follow-up TEXT] [--render] [--size WxH] [--repairs N]
           marty bench QUESTIONS.json --out NEW_DIR [MODEL] [--ids Q01,Q02] [--no-follow-up] [--render] [--repairs N]
      MODEL is --model ID (a Claude model id for the local `claude -p` CLI; default claude-haiku-5-5)
            or --scripted REPLIES.json (replay a JSON array of reply strings; `ask` only)
      --repairs N   repairs after the first attempt, 0-3 (default 3)
    """

func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(2) }

@MainActor func main() -> Int32 {
    // A model process that exits early must not kill marty with SIGPIPE.
    signal(SIGPIPE, SIG_IGN)
    var args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first, ["ask", "bench"].contains(command), args.count >= 2 else { fail(usage) }
    args.removeFirst()
    let subject = args.removeFirst()
    guard !subject.hasPrefix("--"), subject.utf8.count <= 2000 else { fail(usage) }
    var out: String? = nil, modelID = "claude-haiku-5-5", scripted: String? = nil, ids: [String]? = nil, followUps = true
    var options = MartyLoop.Options()
    while let a = args.first {
        args.removeFirst()
        func value() -> String { guard let v = args.first else { fail(usage) }; args.removeFirst(); return v }
        switch a {
        case "--out": out = value()
        case "--model": modelID = value()
        case "--scripted" where command == "ask": scripted = value()
        case "--follow-up" where command == "ask": options.followUp = value()
        case "--ids" where command == "bench": ids = value().split(separator: ",").map(String.init)
        case "--no-follow-up" where command == "bench": followUps = false
        case "--render": options.render = true
        case "--size":
            options.size = value()
            guard MartyEngine.parseSize(options.size) != nil else { fail("--size is WIDTHxHEIGHT, width 320-1920 and height 200-1200") }
        case "--repairs":
            guard let n = Int(value()), (0...3).contains(n) else { fail("--repairs is 0-3") }
            options.repairs = n
        default: fail(usage)
        }
    }
    guard let out else { fail(usage) }
    let outURL = URL(fileURLWithPath: out, isDirectory: true)
    do {
        if command == "bench" {
            let s = try Bench.run(file: URL(fileURLWithPath: subject), ids: ids, makeModel: { try ClaudeCLIAdapter(model: modelID) },
                                  out: outURL, options: options, followUps: followUps)
            print(MartyJSON.string(["totals": s["totals"] ?? [String: Any](), "summary": out + "/summary.json"]))
            // A question that could not run, or where a model call failed in the adapter, is an infrastructure failure.
            return ((s["totals"] as? [String: Any])?["errors"] as? Int ?? 0) > 0 ? 1 : 0
        }
        let model: ModelAdapter
        if let s = scripted {
            guard let replies = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: s))) as? [String] else {
                fail("--scripted needs a JSON array of strings")
            }
            model = ScriptedAdapter(replies: replies)
        } else {
            model = try ClaudeCLIAdapter(model: modelID)
        }
        let r = try MartyLoop(model: model, out: outURL, options: options).run(question: subject)
        var line: [String: Any] = ["accepted": r["accepted"] ?? false, "attempts": (r["attempts"] as? [Any])?.count ?? 0,
                                   "seconds": r["seconds"] ?? 0, "receipt": out + "/receipt.json"]
        // Exit codes: 0 accepted, 1 not accepted, 2 usage or setup error, 3 a model call failed in the adapter.
        if let errs = r["adapterErrors"] as? [String], !errs.isEmpty { line["adapterErrors"] = errs; print(MartyJSON.string(line)); return 3 }
        print(MartyJSON.string(line))
        return (r["accepted"] as? Bool) == true ? 0 : 1
    } catch {
        fail("\(error)")
    }
}

exit(MainActor.assumeIsolated { main() })
