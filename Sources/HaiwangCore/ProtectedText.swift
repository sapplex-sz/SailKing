import Foundation

/// Business identifiers must never silently become translated words.
public enum ProtectedText {
    public static func entities(in text: String) -> [String] {
        let pattern = #"https?://[^\s<>\"']+|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|(?<![A-Za-z0-9_])(?:[A-Z][A-Z0-9]*(?:[-_][A-Z0-9]+)+|(?=[A-Z0-9]*[0-9])[A-Z][A-Z0-9]{2,})(?![A-Za-z0-9_])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard let range = Range($0.range, in: text) else { return nil }
            let value = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;!?。 ，；！？”）)"))
            return value
        }
    }
    public static func validate(source: String, output: String) throws {
        let expected = Dictionary(grouping: entities(in: source), by: { $0 }).mapValues(\.count)
        let actual = Dictionary(grouping: entities(in: output), by: { $0 }).mapValues(\.count)
        guard expected.allSatisfy({ actual[$0.key, default: 0] >= $0.value }) else { throw EngineError.protectedTextChanged }
    }
}
