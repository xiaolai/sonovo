import AppKit
import SonovoCore

/// Display lines from TextKit 2's completed layout. Each line fragment's
/// `characterRange` names its slice of the fragment's paragraph text, so the
/// fragment's document base turns it into source offsets; the terminator is
/// stripped so a column counts visible characters.
struct TextKitLineProvider: CaretLineProvider {
    let lines: [CaretDisplayLine]

    init(lines: [CaretDisplayLine]) {
        self.lines = lines
    }

    @MainActor
    init(textView: NSTextView) {
        guard let layout = textView.textLayoutManager,
              let content = layout.textContentManager else {
            lines = []
            return
        }
        layout.ensureLayout(for: content.documentRange)
        let ns = textView.string as NSString
        var result: [CaretDisplayLine] = []
        layout.enumerateTextLayoutFragments(
            from: nil,
            options: [.ensuresLayout]
        ) { fragment in
            let base = content.offset(
                from: content.documentRange.location,
                to: fragment.rangeInElement.location
            )
            for line in fragment.textLineFragments {
                let range = line.characterRange
                let lower = base + range.location
                var upper = lower + range.length
                while upper > lower, ns.character(at: upper - 1) == 0x0A {
                    upper -= 1
                }
                result.append(CaretDisplayLine(range: lower..<upper))
            }
            return true
        }
        lines = result
    }

    func line(containing offset: Int) -> CaretDisplayLine? {
        var endingHere: CaretDisplayLine?
        for line in lines {
            if line.range.contains(offset) {
                return line
            }
            if line.range.upperBound == offset {
                endingHere = line
            }
        }
        return endingHere ?? lines.last
    }

    func line(above line: CaretDisplayLine) -> CaretDisplayLine? {
        guard let index = lines.firstIndex(of: line), index > 0 else {
            return nil
        }
        return lines[index - 1]
    }

    func line(below line: CaretDisplayLine) -> CaretDisplayLine? {
        guard let index = lines.firstIndex(of: line),
              index + 1 < lines.count else { return nil }
        return lines[index + 1]
    }
}
