// SPDX-License-Identifier: Apache-2.0
import Foundation
import MartyEngine

/// Runs the Marty loop on a question file: a fresh model adapter and a fresh engine per question, one receipt per
/// question, and a summary with the questions' SHA-256. Scores here are machine facts only (accepted, attempts,
/// reasons, time); grading of mechanics and explanations is a separate, independent step.
public enum Bench {
    public struct Question {
        public let id: String
        public let prompt: String
        public let followUp: String?
        public let scope: String
        public let category: String
    }

    public static func load(_ url: URL) throws -> (questions: [Question], sha256: String) {
        let data = try Data(contentsOf: url)
        guard data.count <= 1 << 20 else { throw AdapterError(reason: "bench.bytes", detail: "question file over 1 MiB") }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["questions"] as? [[String: Any]] else {
            throw AdapterError(reason: "bench.format", detail: "expected {\"questions\": [...]}")
        }
        var seen = Set<String>()
        let questions = try list.map { q -> Question in
            guard let id = q["id"] as? String, id.range(of: #"^[A-Za-z0-9_-]{1,32}$"#, options: .regularExpression) != nil,
                  let prompt = q["prompt"] as? String, !prompt.isEmpty, prompt.utf8.count <= 2000, seen.insert(id).inserted else {
                throw AdapterError(reason: "bench.question", detail: "each question needs a unique id and a prompt of 1-2000 bytes")
            }
            return Question(id: id, prompt: prompt, followUp: q["followUp"] as? String,
                            scope: q["scope"] as? String ?? "in", category: q["category"] as? String ?? "")
        }
        return (questions, MartyJSON.sha256(data))
    }

    @MainActor
    public static func run(file: URL, ids: [String]?, makeModel: () throws -> ModelAdapter, out: URL,
                           options: MartyLoop.Options, followUps: Bool) throws -> [String: Any] {
        let (all, sha) = try load(file)
        let chosen = try ids.map { want in
            try want.map { id in
                guard let q = all.first(where: { $0.id == id }) else { throw AdapterError(reason: "bench.id", detail: id) }
                return q
            }
        } ?? all
        do { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false) }
        catch { throw AdapterError(reason: "bench.out", detail: "cannot create a NEW directory at \(out.path)") }
        var runs: [[String: Any]] = []
        var model = ""
        func summary() -> [String: Any] {
            let accepted = runs.filter { $0["accepted"] as? Bool == true }
            let inScope = runs.filter { $0["scope"] as? String == "in" }
            let seconds = runs.compactMap { $0["seconds"] as? Double }.sorted()
            return ["format": "marty.bench-summary/v1", "questionsFile": file.lastPathComponent, "questionsSha256": sha,
                    "model": model, "prompts": MartyPrompts.version,
                    "engine": ["repository": MartyPin.engineRepository, "revision": MartyPin.engineRevision],
                    "options": ["repairs": options.repairs, "render": options.render, "followUps": followUps],
                    "totals": ["questions": runs.count, "accepted": accepted.count,
                               "inScope": inScope.count, "inScopeAccepted": inScope.filter { $0["accepted"] as? Bool == true }.count,
                               "firstTry": runs.filter { $0["firstTry"] as? Bool == true }.count,
                               "medianSeconds": seconds.isEmpty ? 0 : seconds[seconds.count / 2]],
                    "runs": runs]
        }
        for q in chosen {
            let adapter = try makeModel()
            model = adapter.id
            var o = options
            o.followUp = followUps ? q.followUp : nil
            let loop = try MartyLoop(model: adapter, out: out.appendingPathComponent(q.id, isDirectory: true), options: o)
            let r = try loop.run(question: q.prompt)
            let attempts = r["attempts"] as? [[String: Any]] ?? []
            var row: [String: Any] = ["id": q.id, "scope": q.scope, "category": q.category,
                                      "accepted": r["accepted"] ?? false, "attempts": attempts.count,
                                      "firstTry": (attempts.first?["ok"] as? Bool) == true,
                                      "reasons": attempts.map { $0["reason"] ?? NSNull() }, "seconds": r["seconds"] ?? 0,
                                      "inScopePlanned": ((r["plan"] as? [String: Any])?["reply"] as? [String: Any])?["inScope"] ?? NSNull()]
            if let f = r["followUp"] as? [String: Any] { row["followUp"] = ["ok": f["ok"] ?? false, "changed": f["changed"] ?? false] }
            runs.append(row)
            // Write the summary after each question, so a stopped run keeps what it finished.
            let data = try JSONSerialization.data(withJSONObject: MartyJSON.sanitized(summary()), options: [.prettyPrinted, .sortedKeys])
            try data.write(to: out.appendingPathComponent("summary.json"))
        }
        return summary()
    }
}
