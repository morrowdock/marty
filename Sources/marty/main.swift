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
        case "--size": options.size = value()
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
            return 0
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
        print(MartyJSON.string(["accepted": r["accepted"] ?? false, "attempts": (r["attempts"] as? [Any])?.count ?? 0,
                                "seconds": r["seconds"] ?? 0, "receipt": out + "/receipt.json"]))
        return (r["accepted"] as? Bool) == true ? 0 : 1
    } catch {
        fail("\(error)")
    }
}

exit(MainActor.assumeIsolated { main() })
