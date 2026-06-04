import Foundation

/// $ per million tokens: (input, output, cache-write, cache-read). Matches collector.py.
let PRICING: [String: (Double, Double, Double, Double)] = [
    "opus":   (15.0, 75.0, 18.75, 1.50),
    "sonnet": (3.0, 15.0, 3.75, 0.30),
    "haiku":  (1.0, 5.0, 1.25, 0.10),
]

func modelFamily(_ model: String) -> String {
    for fam in ["opus", "sonnet", "haiku"] where model.contains(fam) { return fam }
    return "opus"
}

func tokenCost(model: String, inTok: Int, outTok: Int, cw: Int, cr: Int) -> Double {
    let (i, o, w, r) = PRICING[modelFamily(model)] ?? PRICING["opus"]!
    return (Double(inTok) * i + Double(outTok) * o + Double(cw) * w + Double(cr) * r) / 1e6
}

/// Holds a per-path byte-offset cache so each refresh only parses newly appended bytes.
/// Must live inside the Collector actor (one instance, reused across refreshes).
final class TranscriptParser {
    private var cache: [String: Effort] = [:]

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
                    e.inTok += msg.usage?.input_tokens ?? 0
                    e.outTok += msg.usage?.output_tokens ?? 0
                    e.cw += msg.usage?.cache_creation_input_tokens ?? 0
                    e.cr += msg.usage?.cache_read_input_tokens ?? 0
                    if let model = msg.model { e.model = model }
                    if msg.stop_reason == "end_turn" { e.turns += 1 }
                    if let content = msg.content { e.tools += content.filter { $0.type == "tool_use" }.count }
                }
                e.offset += consumed
            }
        }

        e.mtime = m
        e.parsed = true
        e.cost = tokenCost(model: e.model, inTok: e.inTok, outTok: e.outTok, cw: e.cw, cr: e.cr)
        cache[path] = e
        return e
    }
}
