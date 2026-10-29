import Foundation

/// Pages chosen from one PDF. Custom text uses the PDF's own 1-based page numbers,
/// such as `1-15, 21-30` or `21-end`. The text is kept while All is selected so
/// switching back restores the previous entry, but it is ignored until Custom is chosen.
public struct PageSelection: Equatable, Sendable {
    public var isCustom: Bool
    public var text: String
    public init(isCustom: Bool = false, text: String = "") { self.isCustom = isCustom; self.text = text }
    public static let all = PageSelection()
    public static func custom(_ text: String) -> PageSelection { PageSelection(isCustom: true, text: text) }

    /// Zero-based page indices in document order, without duplicates.
    public func pages(of pageCount: Int) throws -> [Int] {
        guard pageCount > 0 else { throw PrintError.message("This PDF has no pages.") }
        guard isCustom else { return Array(0..<pageCount) }
        return try Self.parse(text, pageCount: pageCount)
    }
    public func validationMessage(pageCount: Int) -> String? {
        do { _ = try pages(of: pageCount); return nil } catch { return error.localizedDescription }
    }

    /// Accepts comma-separated pages and inclusive ranges, optional whitespace, hyphens,
    /// en or em dashes, and `end` for the last page. Anything else is rejected, never ignored.
    public static func parse(_ text: String, pageCount: Int) throws -> [Int] {
        guard pageCount > 0 else { throw PrintError.message("This PDF has no pages.") }
        let entries = text.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard entries.contains(where: { !$0.isEmpty }) else { throw PrintError.message("Enter pages to print, such as 1-3, 8.") }
        var selected = [Bool](repeating: false, count: pageCount)
        for entry in entries {
            guard !entry.isEmpty else { throw PrintError.message("Remove the empty entry between commas.") }
            let bounds = entry.split(omittingEmptySubsequences: false) { "-–—".contains($0) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard bounds.count <= 2 else { throw PrintError.message("“\(entry)” isn’t a page or range. Use a form like 4 or 2-6.") }
            if bounds.count == 2 && bounds[0].isEmpty && !bounds[1].isEmpty {
                throw PrintError.message("Page numbers start at 1.")
            }
            let first = try page(bounds[0], entry: entry, pageCount: pageCount)
            let last = bounds.count == 2 ? try page(bounds[1], entry: entry, pageCount: pageCount) : first
            guard first <= last else { throw PrintError.message("Write “\(entry)” in ascending order.") }
            for index in (first - 1)..<last { selected[index] = true }
        }
        return selected.indices.filter { selected[$0] }
    }

    private static func page(_ text: String, entry: String, pageCount: Int) throws -> Int {
        if text.lowercased() == "end" { return pageCount }
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw PrintError.message("“\(entry)” isn’t a page or range. Use a form like 4 or 2-6.")
        }
        // Overflowing values are simply past the end of any PDF.
        guard let number = Int(text) else { throw PrintError.message("That page number is past the last page (\(pageCount)).") }
        guard number > 0 else { throw PrintError.message("Page numbers start at 1.") }
        guard number <= pageCount else { throw PrintError.message("Page \(number) is past the last page (\(pageCount)).") }
        return number
    }
}

public enum CopyCount {
    public static let range = 1...999
    /// Parses a typed copy count. Returns nil for empty, non-integer, or out-of-range text.
    public static func parse(_ text: String) -> Int? {
        let digits = text.trimmingCharacters(in: .whitespaces)
        guard !digits.isEmpty, digits.count <= 6, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(digits), range.contains(value) else { return nil }
        return value
    }
}
