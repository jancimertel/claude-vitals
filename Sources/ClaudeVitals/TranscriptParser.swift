import Foundation

/// $ per million tokens (input, output, cache read), from
/// https://platform.claude.com/docs/en/about-claude/pricing, checked 2026-11-15. Cache writes are
/// derived in messageCost (5m = 1.25x input, 1h = 2x input), so they are not stored.
let RATES: [String: (input: Double, output: Double, read: Double)] = [
    "claude-fable-5-2": (8, 40, 0.20), "claude-mythos-5-2": (8, 40, 0.20),
    "claude-fable-5-1": (10, 50, 0.25), "claude-mythos-5-1": (10, 50, 0.25),
    "claude-fable-5": (10, 50, 1.00), "claude-mythos-5": (10, 50, 1.00),
    "claude-opus-5-5": (4, 20, 0.20),
    "claude-opus-5": (5, 25, 0.50), "claude-opus-4-8": (5, 25, 0.50), "claude-opus-4-7": (5, 25, 0.50),
    "claude-opus-4-6": (5, 25, 0.50), "claude-opus-4-5": (5, 25, 0.50),
    "claude-opus-4-1": (15, 75, 1.50), "claude-opus-4": (15, 75, 1.50),
    "claude-sonnet-5-5": (2, 10, 0.10),
    "claude-sonnet-5": (2, 10, 0.20),
    "claude-sonnet-4-6": (3, 15, 0.30), "claude-sonnet-4-5": (3, 15, 0.30), "claude-sonnet-4": (3, 15, 0.30),
    "claude-haiku-5-5": (0.10, 0.50, 0.01),
    "claude-haiku-4-5": (1, 5, 0.10),
]

/// Strips a Bedrock `us.anthropic.` prefix, a Vertex `@date` and a `-YYYYMMDD` suffix. The lookahead
/// keeps `claude-opus-5-20260101` from becoming `claude-opus-5-20`.
func canonicalModel(_ model: String) -> String {
    guard let r = model.range(of: #"claude-[a-z]+-\d+(-\d{1,2}(?!\d))?"#, options: .regularExpression) else { return model }
    return String(model[r])
}

/// Prices one API message. An unknown model is priced at Opus 5.5 rates and flagged, so the UI can show `~`.
func messageCost(model: String, usage u: Usage) -> (usd: Double, estimated: Bool) {
    let id = canonicalModel(model)
    let known = RATES[id]
    let r = known ?? RATES["claude-opus-5-5"]!
    let inTok = u.input_tokens ?? 0, cr = u.cache_read_input_tokens ?? 0, cw = u.cache_creation_input_tokens ?? 0
    let w1h = min(u.cache_creation?.ephemeral_1h_input_tokens ?? 0, cw)
    var m = 1.0
    if id == "claude-haiku-5-5", inTok + cr + cw > 100_000 { m *= 5 }   // long-prompt tier
    if u.speed == "fast" { m *= 2 }                                                          // fast mode
    if u.inference_geo == "us" { m *= 1.1 }                                                  // US-only inference
    let usd = (Double(inTok) * r.input + Double(u.output_tokens ?? 0) * r.output + Double(cr) * r.read
               + Double(w1h) * r.input * 2 + Double(cw - w1h) * r.input * 1.25) / 1e6 * m
    return (usd, known == nil)
}

/// Holds a per-path byte-offset cache so each refresh only parses newly appended bytes.
/// Must live inside the Collector actor (one instance, reused across refreshes).
final class TranscriptParser {
    private var cache: [String: Effort] = [:]

    func prune(keep: Set<String>) { cache = cache.filter { keep.contains($0.key) } }

    func effort(path: String) -> Effort {
        let size = fileSize(path)
        let m = mtime(path) ?? .distantPast
        var e = cache[path] ?? .zero

        // Unchanged since last parse (covers the idle steady state): no new bytes AND not replaced.
        // Returns without opening the file. Gate on size==offset (not >=) so a same-mtime append is
        // never missed; gate on mtime so a same-size replacement is never served stale.
        if e.parsed, size == e.offset, m <= e.mtime { return e }

        // Past the gate the file genuinely changed. If it didn't grow beyond our offset it was
        // replaced/truncated (rotation, mid-file edit) -> full rescan from scratch.
        if size <= e.offset { e = .zero }

        if let fh = FileHandle(forReadingAtPath: path) {
            defer { try? fh.close() }
            // On seek failure (truncated/locked between stat and open) fall back to a full rescan.
            do { try fh.seek(toOffset: UInt64(e.offset)) }
            catch { e = .zero; try? fh.seek(toOffset: 0) }
            let data = (try? fh.readToEnd()) ?? Data()
            if let lastNL = data.lastIndex(of: UInt8(ascii: "\n")) {
                let consumed = lastNL + 1                       // fresh Data -> startIndex 0
                let complete = Data(data.prefix(consumed))
                for l in parseLines(complete, dropFirstPartial: false) {
                    guard l.type == "assistant", let msg = l.message else { continue }
                    if msg.isSynthetic { continue }   // else e.model becomes "<synthetic>" and the card shows it as an estimate
                    if let u = l.uuid, !e.seenLines.insert(u).inserted { continue }   // a replayed line counts nothing twice
                    if let model = msg.model { e.model = model }
                    if let content = msg.content { e.tools += content.filter { $0.type == "tool_use" }.count }
                    // In main transcripts each split line repeats the message's full usage, so only the first line
                    // of an id counts. Sub-agent transcripts write a partial usage first: take the last if they are ever priced.
                    if let id = msg.id, !e.seen.insert(id).inserted { continue }
                    e.inTok += msg.usage?.input_tokens ?? 0
                    e.outTok += msg.usage?.output_tokens ?? 0
                    e.cw += msg.usage?.cache_creation_input_tokens ?? 0
                    e.cr += msg.usage?.cache_read_input_tokens ?? 0
                    if let u = msg.usage { let c = messageCost(model: e.model, usage: u); e.cost += c.usd; if c.estimated { e.estimated = true } }
                    if msg.stop_reason == "end_turn" { e.turns += 1 }
                }
                e.offset += consumed
            }
        }

        e.mtime = m
        e.parsed = true
        cache[path] = e
        return e
    }
}
