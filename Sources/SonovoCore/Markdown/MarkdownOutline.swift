import Foundation

/// Outline helpers over the heading index.
///
/// The outline is a persistent sidebar, not the in-document `[TOC]`; both read
/// the same index, so duplicate slugs and headings inside details behave the
/// same way.
public enum MarkdownOutline {
    public static func rows(_ index: HeadingIndex) -> [TOCRow] {
        index.rows
    }

    /// Keeps every match and its ancestor chain, so a filtered tree still
    /// shows the path to each hit.
    public static func filtered(
        _ rows: [TOCRow],
        query: String
    ) -> [TOCRow] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return rows }
        var keep = Set<Int>()
        var ancestors: [Int] = []
        for (index, row) in rows.enumerated() {
            while let last = ancestors.last, rows[last].level >= row.level {
                ancestors.removeLast()
            }
            if row.text.localizedCaseInsensitiveContains(trimmed) {
                keep.insert(index)
                for ancestor in ancestors {
                    keep.insert(ancestor)
                }
            }
            ancestors.append(index)
        }
        return rows.enumerated().compactMap { index, row in
            keep.contains(index) ? row : nil
        }
    }

    /// The heading whose range contains the caret, or the nearest preceding
    /// one. `nil` before the first heading.
    public static func activeIndex(
        _ rows: [TOCRow],
        caret: Int
    ) -> Int? {
        var result: Int?
        for (index, row) in rows.enumerated() {
            guard let range = row.range else { continue }
            if range.lowerBound <= caret {
                result = index
            } else {
                break
            }
        }
        return result
    }
}
