import Foundation

// MARK: - Transcript JSONL (decode only the subset we use; tolerant of unknown/variant shapes)

struct Usage: Decodable {
    let input_tokens: Int?
    let output_tokens: Int?
    let cache_creation_input_tokens: Int?
    let cache_read_input_tokens: Int?
}

struct ContentBlock: Decodable { let type: String?; let name: String? }

struct Message: Decodable {
    let role: String?
    let model: String?
    let stop_reason: String?
    let usage: Usage?
    let content: [ContentBlock]?

    enum CodingKeys: String, CodingKey { case role, model, stop_reason, usage, content }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Every field via `try?` so one variant line (e.g. content as String, not array) never
        // discards the whole line — we still keep type/stop_reason.
        role = (try? c.decodeIfPresent(String.self, forKey: .role)) ?? nil
        model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? nil
        stop_reason = (try? c.decodeIfPresent(String.self, forKey: .stop_reason)) ?? nil
        usage = (try? c.decodeIfPresent(Usage.self, forKey: .usage)) ?? nil
        content = (try? c.decodeIfPresent([ContentBlock].self, forKey: .content)) ?? nil
    }
}

struct Line: Decodable {
    let type: String?
    let cwd: String?
    let gitBranch: String?
    let timestamp: String?
    let message: Message?

    enum CodingKeys: String, CodingKey { case type, cwd, gitBranch, timestamp, message }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? nil
        cwd = (try? c.decodeIfPresent(String.self, forKey: .cwd)) ?? nil
        gitBranch = (try? c.decodeIfPresent(String.self, forKey: .gitBranch)) ?? nil
        timestamp = (try? c.decodeIfPresent(String.self, forKey: .timestamp)) ?? nil
        message = (try? c.decodeIfPresent(Message.self, forKey: .message)) ?? nil
    }
}

// MARK: - Derived domain types (all Sendable to cross the actor boundary cleanly)

enum Dot: String, Sendable, Equatable {
    case runningModel, runningTool, waiting, idle, ended

    var glyph: String {
        switch self {
        case .runningModel: return "🟢"
        case .runningTool:  return "🔧"
        case .waiting:      return "🟡"
        case .idle:         return "⚪️"
        case .ended:        return "⚫️"
        }
    }
    var isRunning: Bool { self == .runningModel || self == .runningTool }
}

/// Incrementally accumulated effort for a single transcript (byte-offset cached).
struct Effort: Sendable {
    var offset = 0
    var inTok = 0, outTok = 0, cw = 0, cr = 0
    var turns = 0, tools = 0
    var model = "?"
    var cost = 0.0
    var mtime: Date = .distantPast   // change-detection signature with offset
    var parsed = false               // false until first read, so the cache gate is skipped initially
    static let zero = Effort()
}

struct Block: Sendable, Identifiable {
    var id: String { sessionId }
    let sessionId: String
    let repo: String
    let cwd: String
    let branch: String
    let age: Int
    let dot: Dot
    let state: String
    let ctx: Int
    let ctxLimit: Int
    let ctxPct: Double
    let model: String
    let inTok: Int, outTok: Int, cw: Int, cr: Int
    let cost: Double
    let turns: Int, tools: Int
    let subsTotal: Int, subsRunning: Int
    let live: Bool
    let pids: Int
}

struct Snapshot: Sendable {
    let blocks: [Block]
    let running: Int
    let subsRunning: Int
    let totalIn: Int, totalOut: Int, totalCw: Int, totalCr: Int
    let totalCost: Double

    static let empty = Snapshot(blocks: [], running: 0, subsRunning: 0,
                                totalIn: 0, totalOut: 0, totalCw: 0, totalCr: 0, totalCost: 0)
}
