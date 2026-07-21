import Foundation

/// Turns a raw model identifier from an agent's transcript into a short, human display
/// name — e.g. `claude-opus-4-8` → "Opus 4.8", `gpt-5.6-codex` → "GPT-5.6 Codex",
/// `gemini-2.5-pro` → "Gemini 2.5 Pro", `grok-4` → "Grok 4".
///
/// Best-effort and pure: an unrecognized id degrades to a tidied-up version of the raw
/// string rather than being dropped, so a new model always shows *something* readable.
enum ModelName {
    /// Map a raw id to a display name, or nil for an empty/absent id.
    static func pretty(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()

        if lower.contains("opus") || lower.contains("sonnet")
            || lower.contains("haiku") || lower.contains("fable") {
            return claude(lower)
        }
        if lower.hasPrefix("gpt") { return gpt(lower) }
        // OpenAI reasoning models ("o3", "o4-mini") are already short and clean.
        if lower.hasPrefix("o1") || lower.hasPrefix("o3") || lower.hasPrefix("o4") {
            return trimmed
        }
        if lower.hasPrefix("gemini") { return branded("Gemini", lower) }
        if lower.hasPrefix("grok") { return branded("Grok", lower) }
        return branded(nil, lower)
    }

    // MARK: - Helpers

    private static let separators = CharacterSet(charactersIn: "-_")

    private static func tokens(_ id: String) -> [String] {
        id.components(separatedBy: separators).filter { !$0.isEmpty }
    }

    /// A trailing date stamp (`20251001`) rather than a version number — 6+ digits.
    private static func isDateStamp(_ token: String) -> Bool {
        token.count >= 6 && token.allSatisfy(\.isNumber)
    }

    /// A version token: digits (optionally already dotted, e.g. `4.5`), but not a date
    /// stamp. Accepts both dash-delimited (`4`, `8`) and dotted (`4.5`) forms.
    private static func isVersionToken(_ token: String) -> Bool {
        guard !isDateStamp(token) else { return false }
        return token.contains(where: \.isNumber)
            && token.allSatisfy { $0.isNumber || $0 == "." }
    }

    private static let noise: Set<String> = ["latest", "preview"]

    /// Title-case a word, but keep version-ish tokens (anything with a digit) verbatim
    /// so "4o", "2.5", and "4.1" aren't mangled.
    private static func cap(_ token: String) -> String {
        guard !token.contains(where: \.isNumber) else { return token }
        return token.prefix(1).uppercased() + token.dropFirst()
    }

    /// Claude ids carry the family (opus/sonnet/haiku/fable) plus version digits, in
    /// either order: new `claude-opus-4-8` or legacy `claude-3-5-sonnet-20241022`. The
    /// family always leads the display name; version digits join with dots.
    private static func claude(_ id: String) -> String {
        let families = ["opus": "Opus", "sonnet": "Sonnet", "haiku": "Haiku", "fable": "Fable"]
        let parts = tokens(id)
        let family = parts.compactMap { families[$0] }.first ?? "Claude"
        let version = parts
            .filter(isVersionToken)
            .joined(separator: ".")
        return version.isEmpty ? family : "\(family) \(version)"
    }

    /// `gpt-5.6-codex` → "GPT-5.6 Codex"; `gpt-4o` → "GPT-4o"; `gpt-4.1-mini` →
    /// "GPT-4.1 Mini". First meaningful token after `gpt` is the version core; the rest
    /// are qualifiers (mini/nano/codex/turbo).
    private static func gpt(_ id: String) -> String {
        var core: String?
        var qualifiers: [String] = []
        for token in tokens(id).dropFirst() {
            if isDateStamp(token) || noise.contains(token) { continue }
            if core == nil { core = token } else { qualifiers.append(cap(token)) }
        }
        let head = "GPT-\(core ?? "")"
        return qualifiers.isEmpty ? head : head + " " + qualifiers.joined(separator: " ")
    }

    /// Generic "Brand Rest" formatting for the remaining agents, and the fallback for
    /// unknown ids (brand nil). Drops date stamps and marketing noise, title-cases words.
    private static func branded(_ brand: String?, _ id: String) -> String {
        var parts = tokens(id)
        if let brand, parts.first == brand.lowercased() { parts.removeFirst() }
        let rest = parts
            .filter { !isDateStamp($0) && !noise.contains($0) }
            .map(cap)
            .joined(separator: " ")
        guard let brand else { return rest.isEmpty ? id : rest }
        return rest.isEmpty ? brand : "\(brand) \(rest)"
    }
}
