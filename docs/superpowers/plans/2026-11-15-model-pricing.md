# Model Pricing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Session and header cost match list price for every current model: each API message counted once, priced at its own model's rate, 1-hour cache writes at 2x input, and a visible `~` when a model is not in the table.

**Architecture:** Pricing stays in `TranscriptParser.swift`, which owns it. A per-id rate table replaces the family table; `messageCost` prices one message as the parser reads it, so model switches inside a session are priced correctly. A `Set` of seen message ids in `Effort` stops the split and replayed lines from being counted again. The `estimated` flag travels `Effort -> Block -> Snapshot` and one formatter adds the `~`.

**Tech Stack:** Swift 6 (SwiftPM executable target), Foundation, SwiftUI.

**Spec:** GitHub issue #4 (`gh issue view 4`). The context-window half was fixed by PR #16 (dd9469c) and is out of scope; Haiku 4.5's 200K window is correct.

## Global Constraints

- Platform floor macOS 14, swift-tools-version 6.0, no new dependencies.
- Rates, from https://platform.claude.com/docs/en/about-claude/pricing, checked 2026-11-15. $ per million tokens (input, output, cache read):
  - `claude-fable-5-2`, `claude-mythos-5-2`: 8, 40, 0.20
  - `claude-fable-5-1`, `claude-mythos-5-1`: 10, 50, 0.25
  - `claude-fable-5`, `claude-mythos-5`: 10, 50, 1.00
  - `claude-opus-5-5`: 4, 20, 0.20
  - `claude-opus-5`, `claude-opus-4-8`, `claude-opus-4-7`, `claude-opus-4-6`, `claude-opus-4-5`: 5, 25, 0.50
  - `claude-opus-4-1`, `claude-opus-4`: 15, 75, 1.50
  - `claude-sonnet-5-5`: 2, 10, 0.10
  - `claude-sonnet-5`: 2, 10, 0.20
  - `claude-sonnet-4-6`, `claude-sonnet-4-5`, `claude-sonnet-4`: 3, 15, 0.30
  - `claude-haiku-5-5`: 0.10, 0.50, 0.01 (prompts over 100,000 tokens: every rate x5; prompt = input + cache read + cache write)
  - `claude-haiku-4-5`: 1, 5, 0.10
- Every model: 5-minute cache write = 1.25x input, 1-hour cache write = 2x input (derive them, do not store them). Fast mode (`usage.speed == "fast"`) = 2x every rate on every model that offers it. `usage.inference_geo == "us"` = 1.1x every rate.
- Transcript facts, verified in local transcripts (Claude Code 2.1.3xx): Claude Code writes one JSONL line per content block and repeats the full message `usage` and `stop_reason` on every line of that message (12,612 usage lines, 5,281 message ids, 0 usage differences between lines of the same id). Some lines are replayed hundreds of lines later with the same id, so an adjacent-only check is not enough. `usage` carries `cache_creation: {ephemeral_5m_input_tokens, ephemeral_1h_input_tokens}`, `speed` (`"standard"`), `inference_geo` (`"global"` or `"not_available"`). Older transcripts may lack `cache_creation`.
- Follow existing style: top-level free functions for pure logic, comments explain WHY. No em-dash characters anywhere (code, comments, docs, commits); use a plain hyphen.
- Commits: conventional-commit subject, no `Co-Authored-By` or "Generated with" trailer. Stage ONLY the files the task names with explicit `git add <path>`. `.gitignore` carries an unrelated pending edit that must stay uncommitted; never `git add -A` or `git add .`.
- TEST EXECUTION: this machine has Command Line Tools only, so XCTest and `swift test` are unavailable. The runnable check is `runSelfCheck()` in `Sources/ClaudeVitals/Entry.swift` (prints `ok <name>` per check, `FAIL <name>` and exit 1 on failure). Add new checks there, before the ring checks. Verify with `swift build 2>&1 | tail -1 && .build/debug/ClaudeVitals --selfcheck; echo "exit=$?"` and expect `Build complete!`, every new `ok <name>` line, and `exit=0`. Also run `.build/debug/ClaudeVitals --dump` once and eyeball that costs look plausible (no crash, `$` figures far below the old ones).

## Review Focus

- A message split across lines or replayed later is counted once for tokens, cost and turns. Tools are still counted per line, because each split line carries different content blocks. Pinned by `effortCountsEachMessageOnce`.
- Cost is priced per message at that message's model, not at the last model of the session. Pinned by `costPricesEachMessageAtItsModel`.
- One odd field (`speed` as a number, `cache_creation` as a string) must not zero the whole `usage`, because `Message` decodes `usage` with `try?`. Pinned by `usageToleratesOddShapes`.
- An unknown model is never shown as a confident figure. Pinned by `costUnknownModelIsEstimate`.

---

### Task 1: Count each API message once

**Files:**
- Modify: `Sources/ClaudeVitals/Models.swift` (`Message`, `Effort`)
- Modify: `Sources/ClaudeVitals/TranscriptParser.swift` (`effort(path:)`, new `prune(keep:)`)
- Modify: `Sources/ClaudeVitals/Collector.swift` (`buildSnapshot`)
- Modify: `Sources/ClaudeVitals/Entry.swift` (`runSelfCheck`)

- [ ] **Step 1: Write the check.** In `runSelfCheck`, turn the existing temp-file code around `costIgnoresSyntheticModel` into a local helper `func effortOf(_ ls: [String]) -> Effort` (writes the lines joined by `"\n"` plus a trailing `"\n"` to a temp file, parses with a fresh `TranscriptParser()`, removes the file) and use it in that existing check. Then add:

```swift
let m1 = #"{"type":"assistant","message":{"id":"m1","model":"claude-opus-5-5","stop_reason":"end_turn","content":[{"type":"tool_use"}],"usage":{"output_tokens":1000000}}}"#
let m2 = #"{"type":"assistant","message":{"id":"m2","model":"claude-fable-5-2","stop_reason":"end_turn","usage":{"output_tokens":1000000}}}"#
let once = effortOf([m1, m1, m2, m1])   // split line, then a later replay
check("effortCountsEachMessageOnce", once.outTok == 2_000_000 && once.turns == 2 && once.tools == 3)
```

- [ ] **Step 2: Run it.** Expected: `FAIL effortCountsEachMessageOnce`.

- [ ] **Step 3: Decode the id and keep the seen set.** In `Message` add `let id: String?` (add `id` to `CodingKeys`, decode with `try?` like the other fields). In `Effort` add `var seen: Set<String> = []` with a short comment on why it is a set and not the last id.

- [ ] **Step 4: Gate the loop.** In `TranscriptParser.effort(path:)`, keep the `model` and `tools` lines first (tools stay per line: each split line carries different blocks), then `if let id = msg.id, !e.seen.insert(id).inserted { continue }` with a one-line WHY comment, then the token sums and the `end_turn` turn count below the gate. A line with no id is counted as today.

- [ ] **Step 5: Prune the parser cache.** The seen sets make `TranscriptParser.cache` heavier and it is never pruned. Add `func prune(keep: Set<String>) { cache = cache.filter { keep.contains($0.key) } }` and call `parser.prune(keep: candidates)` next to the existing `cache.parsed = cache.parsed.filter { ... }` line in `buildSnapshot`.

- [ ] **Step 6: Run the check.** Expected: `ok effortCountsEachMessageOnce`, every other check still `ok`, `exit=0`.

- [ ] **Step 7: Commit**

```bash
git add Sources/ClaudeVitals/Models.swift Sources/ClaudeVitals/TranscriptParser.swift Sources/ClaudeVitals/Collector.swift Sources/ClaudeVitals/Entry.swift
git commit -m "fix(parser): count each API message once"
```

### Task 2: Price each message at its model's current rate

**Files:**
- Modify: `Sources/ClaudeVitals/Models.swift` (`Usage`, `Effort`, `Block`, `Snapshot`)
- Modify: `Sources/ClaudeVitals/TranscriptParser.swift`
- Modify: `Sources/ClaudeVitals/Collector.swift` (`buildSnapshot`, formatting section)
- Modify: `Sources/ClaudeVitals/Views.swift` (header cost ~line 422, card cost ~line 496)
- Modify: `Sources/ClaudeVitals/Entry.swift` (`runDump`, `runSelfCheck`)
- Modify: `README.md` ("Effort/cost" bullet, "Cost is a public-rate estimate" bullet)
- Modify: `Tests/ClaudeVitalsTests/TransitionTests.swift` (`block(_:_:)` helper only)

- [ ] **Step 1: Write the checks** (after `effortCountsEachMessageOnce`; `costIgnoresSyntheticModel` must keep passing unchanged at $3.00):

```swift
func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }
check("costPricesEachMessageAtItsModel", near(once.cost, 60) && !once.estimated)      // $20 opus-5-5 + $40 fable-5-2
let split = #"{"type":"assistant","message":{"id":"c1","model":"claude-opus-5-5","usage":{"cache_creation_input_tokens":2000000,"cache_creation":{"ephemeral_5m_input_tokens":1000000,"ephemeral_1h_input_tokens":1000000}}}}"#
check("cost1hCacheWritesAt2x", near(effortOf([split]).cost, 13))                       // 1M x $5 + 1M x $8
let unsplit = #"{"type":"assistant","message":{"id":"c2","model":"claude-opus-5-5","usage":{"cache_creation_input_tokens":2000000}}}"#
check("costUnsplitCacheWritesAt5m", near(effortOf([unsplit]).cost, 10))
let unknown = effortOf([#"{"type":"assistant","message":{"id":"u1","model":"claude-sonnet-9","usage":{"input_tokens":1000000}}}"#])
check("costUnknownModelIsEstimate", unknown.estimated && near(unknown.cost, 4))       // Opus 5.5 rates, flagged
check("canonicalModelStripsSuffixes", canonicalModel("claude-haiku-4-5-20251001") == "claude-haiku-4-5"
      && canonicalModel("us.anthropic.claude-opus-5-5") == "claude-opus-5-5"
      && canonicalModel("claude-opus-4-5@20251101") == "claude-opus-4-5"
      && canonicalModel("claude-opus-5") == "claude-opus-5")
func haiku(_ n: Int) -> Double {
    effortOf([#"{"type":"assistant","message":{"id":"h","model":"claude-haiku-5-5","usage":{"input_tokens":\#(n)}}}"#]).cost
}
check("costHaikuLongPromptTier", near(haiku(100_000), 0.01) && near(haiku(200_000), 0.10))
let fast = effortOf([#"{"type":"assistant","message":{"id":"f","model":"claude-opus-5-5","usage":{"output_tokens":1000000,"speed":"fast"}}}"#])
check("costFastModeDoubles", near(fast.cost, 40))
let us = effortOf([#"{"type":"assistant","message":{"id":"g","model":"claude-opus-5-5","usage":{"input_tokens":1000000,"inference_geo":"us"}}}"#])
check("costUsGeoAdds10Pct", near(us.cost, 4.4))
let odd = effortOf([#"{"type":"assistant","message":{"id":"o","model":"claude-opus-5-5","usage":{"input_tokens":1000000,"speed":1,"cache_creation":"x"}}}"#])
check("usageToleratesOddShapes", odd.inTok == 1_000_000 && near(odd.cost, 4))
```

- [ ] **Step 2: Run them.** Expected: build failure (`estimated`, `canonicalModel` do not exist yet). That is the red state here.

- [ ] **Step 3: Decode the new usage fields tolerantly.** In `Models.swift` add `struct CacheCreation: Decodable { let ephemeral_1h_input_tokens: Int? }` and to `Usage` add `cache_creation: CacheCreation?`, `speed: String?`, `inference_geo: String?`. Give `Usage` a custom `init(from:)` that decodes every field with `try?`, the same pattern and comment style as `Message`. Add `var estimated = false` to `Effort`.

- [ ] **Step 4: Replace the pricing.** In `TranscriptParser.swift` delete `PRICING`, `modelFamily` and `tokenCost` (and the stale "Matches collector.py" comment) and add:
  - `let RATES: [String: (input: Double, output: Double, read: Double)]` with exactly the Global Constraints rows, a doc comment naming the source URL and the 2026-11-15 check date, and that writes are derived.
  - `func canonicalModel(_ model: String) -> String`: the first match of `#"claude-[a-z]+-\d+(-\d{1,2}(?!\d))?"#` (drops a Bedrock `us.anthropic.` prefix, a Vertex `@date` and a `-YYYYMMDD` suffix; the lookahead keeps `claude-opus-5-20260101` from becoming `claude-opus-5-20`), or `model` unchanged when nothing matches.
  - `func messageCost(model: String, usage u: Usage) -> (usd: Double, estimated: Bool)`: looks up `RATES[canonicalModel(model)]`, falling back to the `claude-opus-5-5` row with `estimated: true`. 1-hour writes = `min(ephemeral_1h, cache_creation_input_tokens)` at 2x input, the rest of `cache_creation_input_tokens` at 1.25x input. One multiplier `m`: x5 for `claude-haiku-5-5` when input + cache read + cache write > 100_000, x2 for `speed == "fast"`, x1.1 for `inference_geo == "us"`. One short comment per multiplier.

- [ ] **Step 5: Price inside the loop.** In `effort(path:)`, below the seen-id gate: `if let u = msg.usage { let c = messageCost(model: e.model, usage: u); e.cost += c.usd; if c.estimated { e.estimated = true } }` (`e.model` is already updated from this line). Delete the `e.cost = tokenCost(...)` line after the loop.

- [ ] **Step 6: Carry the flag to the UI.** Add `let estimated: Bool` to `Block` right after `cost`, and `let costEstimated: Bool` to `Snapshot` right after `totalCost` (update `Snapshot.empty`). Set them in `buildSnapshot` (`estimated: e.estimated`, `costEstimated: blocks.contains { $0.estimated }`) and add `estimated: false` to the `card(_:)` helper in `runSelfCheck` and to the `block(_:_:)` helper in `Tests/ClaudeVitalsTests/TransitionTests.swift` (never compiled here, so match the init by eye). In the formatting section of `Collector.swift`, next to `human`, add `func usd(_ v: Double, estimated: Bool) -> String { (estimated ? "~" : "") + String(format: "$%.2f", v) }` and use it at the three cost sites: `Views.swift` header and card, and `Entry.runDump`. When the figure is estimated, both tooltips append: `. ~ = a model missing from the price table, priced at Opus 5.5 rates`.

- [ ] **Step 7: README.** "Effort/cost" bullet: each API message priced once at its own model's rate, 1-hour cache writes included. Replace the "Cost is a public-rate estimate" bullet with: cost is an API list-price estimate (not what a subscription is billed), a `~` marks a model missing from the price table, and sub-agent transcripts are not included yet.

- [ ] **Step 8: Run the checks and the dump.** Expected: every new `ok <name>`, `ok costIgnoresSyntheticModel`, `exit=0`; `--dump` prints without crashing.

- [ ] **Step 9: Commit**

```bash
git add Sources/ClaudeVitals/Models.swift Sources/ClaudeVitals/TranscriptParser.swift Sources/ClaudeVitals/Collector.swift Sources/ClaudeVitals/Views.swift Sources/ClaudeVitals/Entry.swift README.md Tests/ClaudeVitalsTests/TransitionTests.swift
git commit -m "fix(pricing): price each message at its model's current rate and flag unknown models"
```
