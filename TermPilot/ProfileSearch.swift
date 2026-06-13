import Foundation

enum ProfileSearch {
    static func matches(_ query: String, fields: [String]) -> Bool {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return true }

        return fields.contains {
            $0.range(
                of: trimmedQuery,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil
        }
    }
}
