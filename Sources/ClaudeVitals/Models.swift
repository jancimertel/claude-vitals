import Foundation

// MARK: - Transcript JSONL (decode only the subset we use; tolerant of unknown/variant shapes)

struct CacheCreation: Decodable { let ephemeral_1h_input_tokens: Int? }

struct Usage: Decodable {
    let input_tokens: Int?
    let output_tokens: Int?
    let cache_creation_input_tokens: Int?
    let cache_read_input_tokens: Int?
    let cache_creation: CacheCreation?
    let speed: String?
    let inference_geo: String?

    enum CodingKeys: String, CodingKey {
        case input_tokens, output_tokens, cache_creation_input_tokens, cache_read_input_tokens
        case cache_creation, speed, inference_geo
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Every field via `try?`, like Message: Message decodes usage with `try?`, so one odd field
        // (speed as a number) would otherwise zero the whole usage.
        input_tokens = (try? c.decodeIfPresent(Int.self, forKey: .input_tokens)) ?? nil
        output_tokens = (try? c.decodeIfPresent(Int.self, forKey: .output_tokens)) ?? nil
        cache_creation_input_tokens = (try? c.decodeIfPresent(Int.self, forKey: .cache_creation_input_tokens)) ?? nil
        cache_read_input_tokens = (try? c.decodeIfPresent(Int.self, forKey: .cache_read_input_tokens)) ?? nil
        cache_creation = (try? c.decodeIfPresent(CacheCreation.self, forKey: .cache_creation)) ?? nil
        speed = (try? c.decodeIfPresent(String.self, forKey: .speed)) ?? nil
        inference_geo = (try? c.decodeIfPresent(String.self, forKey: .inference_geo)) ?? nil
    }
}

struct ContentBlock: Decodable { let type: String?; let name: String? }

struct Message: Decodable {
    let id: String?
    let role: String?
    let model: String?
    let stop_reason: String?
    let usage: Usage?
    let content: [ContentBlock]?

    enum CodingKeys: String, CodingKey { case id, role, model, stop_reason, usage, content }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Every field via `try?` so one variant line (e.g. content as String, not array) never
        // discards the whole line — we still keep type/stop_reason.
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil
        role = (try? c.decodeIfPresent(String.self, forKey: .role)) ?? nil
        model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? nil
        stop_reason = (try? c.decodeIfPresent(String.self, forKey: .stop_reason)) ?? nil
        usage = (try? c.decodeIfPresent(Usage.self, forKey: .usage)) ?? nil
        content = (try? c.decodeIfPresent([ContentBlock].self, forKey: .content)) ?? nil
    }
}

extension Message {
    /// Claude Code's API-error placeholder lines carry model "<synthetic>" and all-zero usage.
    var isSynthetic: Bool { model == "<synthetic>" }
}

struct CompactMetadata: Decodable {
    let postTokens: Int?

    enum CodingKeys: String, CodingKey { case postTokens }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        postTokens = (try? c.decodeIfPresent(Int.self, forKey: .postTokens)) ?? nil
    }
}

struct Line: Decodable {
    let type: String?
    let cwd: String?
    let gitBranch: String?
    let timestamp: String?
    let message: Message?
    let aiTitle: String?   // present only on `type: "ai-title"` lines (Claude's auto chat title)
    let subtype: String?   // e.g. "compact_boundary" on `type: "system"` lines
    let compactMetadata: CompactMetadata?

    enum CodingKeys: String, CodingKey { case type, cwd, gitBranch, timestamp, message, aiTitle, subtype, compactMetadata }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? nil
        cwd = (try? c.decodeIfPresent(String.self, forKey: .cwd)) ?? nil
        gitBranch = (try? c.decodeIfPresent(String.self, forKey: .gitBranch)) ?? nil
        timestamp = (try? c.decodeIfPresent(String.self, forKey: .timestamp)) ?? nil
        message = (try? c.decodeIfPresent(Message.self, forKey: .message)) ?? nil
        aiTitle = (try? c.decodeIfPresent(String.self, forKey: .aiTitle)) ?? nil
        subtype = (try? c.decodeIfPresent(String.self, forKey: .subtype)) ?? nil
        compactMetadata = (try? c.decodeIfPresent(CompactMetadata.self, forKey: .compactMetadata)) ?? nil
    }
}

// MARK: - Derived domain types (all Sendable to cross the actor boundary cleanly)

enum Dot: String, Sendable, Equatable {
    case runningModel, runningTool, compacting, waiting, waitingPermission, failed, idle, ended

    var glyph: String {
        switch self {
        case .runningModel:      return "🟢"
        case .runningTool:       return "🔧"
        case .waiting:           return "🟡"
        case .waitingPermission: return "🔐"
        case .compacting:        return "🗜️"
        case .failed:            return "🔴"
        case .idle:              return "⚪️"
        case .ended:             return "⚫️"
        }
    }
    var isRunning: Bool { self == .runningModel || self == .runningTool || self == .compacting }
}

/// Incrementally accumulated effort for a single transcript (byte-offset cached).
struct Effort: Sendable {
    var offset = 0
    var inTok = 0, outTok = 0, cw = 0, cr = 0
    var turns = 0, tools = 0
    var model = "?"
    // A set, not the last id: Claude Code replays whole messages hundreds of lines later.
    var seen: Set<String> = []
    var cost = 0.0
    var estimated = false            // some message used a model missing from RATES
    var mtime: Date = .distantPast   // change-detection signature with offset
    var parsed = false               // false until first read, so the cache gate is skipped initially
    static let zero = Effort()
}

struct Block: Sendable, Identifiable {
    var id: String { sessionId }
    let sessionId: String
    let repo: String
    let title: String
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
    let estimated: Bool
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
    let costEstimated: Bool
    let hookDriven: Bool   // any card currently backed by fresh hook state

    static let empty = Snapshot(blocks: [], running: 0, subsRunning: 0,
                                totalIn: 0, totalOut: 0, totalCw: 0, totalCr: 0, totalCost: 0, costEstimated: false,
                                hookDriven: false)
}
