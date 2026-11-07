// SPDX-License-Identifier: Apache-2.0
import Foundation
import MartyGraphics

/// Beat-by-beat lessons (MartyGraphics `MGLesson` / `MGLessonSession`, docs/LESSONS.md at the pin).
/// `lessonCheck` loads a whole lesson document into a fresh session; `lessonStream` feeds statements into a session the
/// server keeps, so a model can write a lesson one statement at a time and see each refusal at once.
/// Sessions use immediate pacing and a manual clock, so every result is deterministic.
extension MartyEngine {
    /// At most this many stream sessions are kept; the least recently used is dropped first.
    public nonisolated static let maxLessonSessions = 8
    /// Bytes per `lesson_stream` call (the engine's own stream budget is 32 KiB in all).
    public nonisolated static let maxChunkBytes = MGLessonLimits.lessonBytes
    /// Events returned by one call; the rest are counted in `truncatedEvents` (one 32 KiB chunk can hold many
    /// short streams).
    public nonisolated static let maxEventsPerCall = 512
    /// The engine's terminal budget refusals: after one, it ignores the stream until `endStream()`.
    nonisolated static let budgetReasons: Set<String> = ["lesson.bytes", "lesson.statements.count"]

    /// The engine's opt-in geometry pack (`rotate2d`), registered once per process.
    static let geometryRegistered: Bool = {
        do { try MGPacks.register(MGGeometryPack.pack); return true } catch { return MGPacks.pack(ofTemplate: "rotate2d") != nil }
    }()

    static func issue(_ i: MGLessonIssue) -> [String: Any] {
        ["reason": i.reason, "beat": i.beat as Any, "statement": i.statement as Any, "command": i.command as Any,
         "origin": i.origin.rawValue, "detail": i.detail as Any]
    }

    static func event(_ e: MGLessonEvent) -> [String: Any] {
        var out: [String: Any] = ["event": e.name]
        switch e {
        case .accepted(let n): out["statement"] = n
        case .refused(let i): out.merge(issue(i)) { a, _ in a }
        case .lineQueued(let k, let text): out["beat"] = k; out["text"] = text
        case .lineDue(let k, let text, let changed): out["beat"] = k; out["text"] = text; out["changed"] = changed
        case .lineStarted(let k), .lineEnded(let k), .beatPresented(let k): out["beat"] = k
        case .firstPresented, .streamEnded, .lessonComplete: break
        }
        return out
    }

    /// What the learner would see now: the beat cursor, engine values (number and formatted text) and controls.
    static func board(_ s: MGLessonSession) -> [String: Any] {
        guard let st = s.state else { return ["beat": NSNull(), "values": [String: Any](), "controls": [Any]()] }
        var values: [String: Any] = [:]
        for (name, v) in st.scene.values { values[name] = ["value": v.value, "unit": v.unit, "text": v.text] }
        let controls: [[String: Any]] = st.controls.map {
            ["id": $0.id, "kind": $0.kind, "param": $0.param, "min": $0.min, "max": $0.max, "step": $0.step,
             "label": $0.label, "value": st.value(of: $0) as Any]
        }
        return ["beat": st.beat, "values": values, "controls": controls, "title": s.title as Any, "complete": s.isComplete]
    }

    public func lessonCheck(lesson: Any) throws -> [String: Any] {
        _ = Self.geometryRegistered
        let json: MGJSON
        switch Decode.json(lesson, limit: 2 * MGLessonLimits.lessonBytes, tooLarge: "lesson.bytes") {
        // The engine's own words for unreadable or oversized lesson input.
        case .failure(let r): return ["ok": false, "reason": r.reason == "json" ? "lesson.json" : r.reason]
        case .success(let j): json = j
        }
        let parsed: MGLesson
        switch MGLesson.parse(json: json) {
        case .failure(let i): return (["ok": false] as [String: Any]).merging(Self.issue(i)) { a, _ in a }
        case .success(let l): parsed = l
        }
        var session = MGLessonSession(pacing: .immediate, clock: MGManualClock())
        switch session.load(parsed) {
        case .failure(let i):
            // All or nothing: the first problem refuses the whole lesson, with its location.
            return (["ok": false, "statementBytes": parsed.statementStream.utf8.count] as [String: Any]).merging(Self.issue(i)) { a, _ in a }
        case .success:
            // Under immediate pacing `load` presents every beat itself (the statements end with {"end": true}).
            break
        }
        let events = session.events
        // What the learner hears: lineDue text is filled from the presented state.
        let lines: [[String: Any]] = events.compactMap {
            if case .lineDue(let k, let text, _) = $0 { return ["beat": k, "text": text] }
            return nil
        }
        return ["ok": true, "reason": NSNull(), "title": parsed.title as Any, "beats": parsed.beats.count, "lines": lines,
                "board": Self.board(session), "statementBytes": parsed.statementStream.utf8.count,
                "events": events.map(\.name)]
    }

    /// Feeds `chunk` (raw statement text, any split) into session `id`, or into a new session when `id` is nil.
    /// `end` ends the stream (`endStream()`), which presents every complete beat under immediate pacing.
    public func lessonStream(session id: String?, chunk: String, end: Bool) throws -> [String: Any] {
        _ = Self.geometryRegistered
        guard chunk.utf8.count <= Self.maxChunkBytes else {
            throw ToolError("lesson.chunk.bytes", "at most \(Self.maxChunkBytes) bytes per call; the whole stream is at most 32 KiB")
        }
        let key: String
        var session: MGLessonSession
        var exhausted = false
        if let id {
            guard let i = lessonSessions.firstIndex(where: { $0.id == id }) else {
                throw ToolError("lesson.session.unknown", "this server does not hold \(id.prefix(40)); start a new session without `session`")
            }
            key = id
            let entry = lessonSessions.remove(at: i)
            session = entry.session; exhausted = entry.exhausted
        } else {
            lessonSessionCounter += 1
            key = "lesson-\(lessonSessionCounter)"
            session = MGLessonSession(pacing: .immediate, clock: MGManualClock())
        }
        // Always feed: the engine itself ignores an exhausted stream, and it starts a fresh stream on the first statement
        // after an ended one. Marty only reads what happened.
        let wasExhausted = exhausted
        var events = session.feed(chunk)
        let budgetHit = events.lastIndex { if case .refused(let i) = $0 { return Self.budgetReasons.contains(i.reason) }; return false }
        if let k = budgetHit {
            // Exhausted unless something was accepted or started after the budget refusal (a new stream).
            exhausted = k == events.count - 1 && session.unfinishedInput.isEmpty
        } else if wasExhausted {
            exhausted = events.isEmpty && session.unfinishedInput.isEmpty
        }
        // Statements sent to a stream that was already exhausted are dropped by the engine: say so, not silent success.
        // The engine's own whitespace: space, tab, CR, LF (not NBSP or other Unicode spaces). Computed before endStream, so a
        // call that also ends the stream still reports the dropped statements.
        let ignored = wasExhausted && exhausted && chunk.utf8.contains { ![0x20, 0x09, 0x0D, 0x0A].contains($0) }
        if end { events += session.endStream(); exhausted = false }
        // Least recently used goes first: the session used now is the newest.
        lessonSessions.append((key, session, exhausted))
        if lessonSessions.count > Self.maxLessonSessions { lessonSessions.removeFirst(lessonSessions.count - Self.maxLessonSessions) }
        let refused = events.contains { if case .refused = $0 { return true }; return false }
        var out: [String: Any] = ["ok": !refused && !ignored, "session": key,
                                  "events": events.prefix(Self.maxEventsPerCall).map(Self.event), "board": Self.board(session),
                                  "waitingBeats": session.waitingBeats, "unfinishedBytes": session.unfinishedInput.count,
                                  "exhausted": exhausted]
        if events.count > Self.maxEventsPerCall { out["truncatedEvents"] = events.count - Self.maxEventsPerCall }
        if ignored { out["reason"] = "lesson.stream.exhausted" }
        return out
    }
}
