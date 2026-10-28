import AppKit

/// The source editor's comment margin.
///
/// One dot per anchored thread: filled for an open thread, hollow once it is
/// resolved. A click reports the thread so the panel can reveal it. Markers
/// are drawn only for the visible range; the ruler redraws as the text
/// scrolls.
final class ReviewMarkerRulerView: NSRulerView {
    struct Marker: Equatable {
        let id: UUID
        let offset: Int
        let resolved: Bool
        let anchored: Bool
    }

    var commentMarkers: [Marker] = [] {
        didSet {
            if oldValue != commentMarkers {
                needsDisplay = true
            }
        }
    }

    /// When on, the gutter shows source line numbers to the left of the
    /// comment markers. The editor reuses the code viewer's line iterator
    /// and drawing rules so wrapped lines number once.
    var showsLineNumbers = false {
        didSet {
            guard oldValue != showsLineNumbers else { return }
            updateThickness()
            needsDisplay = true
        }
    }

    /// The line-fragment top for a UTF-16 offset, in client-view coordinates.
    var lineTop: ((Int) -> CGFloat?)?
    /// Batched variant: computes every marker's top in one viewport pass.
    /// The per-offset callback forces TextKit layout per marker, so a draw
    /// with many comments paid for that layout once per comment.
    var lineTops: (([Int]) -> [Int: CGFloat])?
    /// The visible visual lines, in client-view coordinates.
    var visibleLines: (() -> [CodeLineLayout])?
    /// The 1-based source line number for a UTF-16 offset.
    var lineNumberProvider: ((Int) -> Int?)?
    var onSelect: ((UUID) -> Void)?

    init() {
        super.init(scrollView: nil, orientation: .verticalRuler)
        ruleThickness = AppTheme.MarkdownChrome.Comments.gutterWidth
        setAccessibilityRole(.ruler)
        setAccessibilityLabel("Comments")
        setAccessibilityHelp("Marks lines with review comments.")
    }

    private func updateThickness() {
        let width = showsLineNumbers
            ? AppTheme.Code.lineNumberWidth
                + AppTheme.MarkdownChrome.Comments.gutterWidth
            : AppTheme.MarkdownChrome.Comments.gutterWidth
        if ruleThickness != width {
            ruleThickness = width
        }
        setAccessibilityLabel(
            showsLineNumbers ? "Line numbers and comments" : "Comments"
        )
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// One drawable marker per visual line. Several threads can anchor to
    /// the same line; they share a single dot whose fill reflects whether any
    /// thread is still open, and a click offers the threads by name instead
    /// of silently selecting the first.
    private struct MarkerGroup {
        var markers: [Marker]
        var rect: NSRect
    }

    private var menuMarkers: [UUID] = []

    private var markerGroups: [MarkerGroup] {
        guard let clientView else { return [] }
        let diameter = AppTheme.MarkdownChrome.Comments.markerDiameter
        let inset = AppTheme.Spacing.s3
        let visible = bounds.insetBy(dx: -inset, dy: -inset)
        let gutter = AppTheme.MarkdownChrome.Comments.gutterWidth
        let centerX = showsLineNumbers
            ? ruleThickness - gutter
                + gutter
                    / AppTheme.MarkdownChrome.Comments.markerCenterDivisor
            : ruleThickness
                / AppTheme.MarkdownChrome.Comments.markerCenterDivisor
        let anchored = commentMarkers.filter(\.anchored)
        // One batched viewport pass for every distinct offset, in sorted
        // order. Without the batch callback, fall back to per-marker lookups.
        let tops: [Int: CGFloat]
        if let lineTops {
            let offsets = Array(Set(anchored.map(\.offset))).sorted()
            tops = lineTops(offsets)
        } else {
            var resolved: [Int: CGFloat] = [:]
            for marker in anchored {
                if let top = lineTop?(marker.offset) {
                    resolved[marker.offset] = top
                }
            }
            tops = resolved
        }
        var groups: [MarkerGroup] = []
        for marker in anchored {
            guard let top = tops[marker.offset] else { continue }
            let origin = convert(NSPoint(x: 0, y: top), from: clientView)
            let rect = NSRect(
                x: centerX - diameter / AppTheme.MarkdownChrome.Comments.markerCenterDivisor,
                y: origin.y,
                width: diameter,
                height: diameter
            )
            guard rect.intersects(visible) else { continue }
            if let last = groups.indices.last,
               groups[last].rect.origin.y == rect.origin.y {
                groups[last].markers.append(marker)
            } else {
                groups.append(MarkerGroup(markers: [marker], rect: rect))
            }
        }
        return groups
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setStroke()
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: bounds.maxX, y: bounds.minY))
        divider.line(to: NSPoint(x: bounds.maxX, y: bounds.maxY))
        divider.lineWidth = AppTheme.BorderWidth.hairline
        divider.stroke()

        if showsLineNumbers {
            drawLineNumbers()
        }
        for group in markerGroups {
            let resolved = group.markers.allSatisfy(\.resolved)
            let color = resolved
                ? AppTheme.MarkdownChrome.Comments.resolved
                : AppTheme.MarkdownChrome.Comments.open
            let path = NSBezierPath(
                ovalIn: group.rect.insetBy(
                    dx: AppTheme.BorderWidth.hairline,
                    dy: AppTheme.BorderWidth.hairline
                )
            )
            NSColor(color).setStroke()
            NSColor(color).setFill()
            path.lineWidth = AppTheme.BorderWidth.medium
            if resolved {
                path.stroke()
            } else {
                path.fill()
            }
        }
    }

    private func drawLineNumbers() {
        guard let visibleLines else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(
                ofSize: AppTheme.Code.lineNumberFontSize,
                weight: .regular
            ),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        var lastNumber: Int?
        for line in visibleLines() {
            let number = lineNumberProvider?(line.documentOffset) ?? 1
            // A wrapped source line has several visual fragments; number it
            // once, at the first fragment's top.
            guard number != lastNumber else { continue }
            lastNumber = number
            let text = "\(number)" as NSString
            let size = text.size(withAttributes: attributes)
            let origin = convert(line.rect.origin, from: clientView)
            let y = origin.y + (line.rect.height - size.height) / 2
            let x = AppTheme.Code.lineNumberWidth
                - AppTheme.Code.lineNumberInset
                - size.width
            text.draw(
                at: NSPoint(x: max(0, x), y: y),
                withAttributes: attributes
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hitRadius = AppTheme.MarkdownChrome.Comments.markerHitRadius
        guard let group = markerGroups.first(where: {
            $0.rect.insetBy(dx: -hitRadius, dy: -hitRadius)
                .contains(point)
        }) else {
            super.mouseDown(with: event)
            return
        }
        if group.markers.count == 1 {
            onSelect?(group.markers[0].id)
            return
        }
        // Several threads share this visual line: let the user pick one
        // instead of always selecting the first marker in scan order.
        let menu = NSMenu()
        menuMarkers = group.markers.map(\.id)
        for (index, marker) in group.markers.enumerated() {
            let item = NSMenuItem(
                title: marker.resolved
                    ? "Resolved comment \(index + 1)"
                    : "Open comment \(index + 1)",
                action: #selector(selectMarker(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: point, in: self)
    }

    @objc private func selectMarker(_ sender: NSMenuItem) {
        guard menuMarkers.indices.contains(sender.tag) else { return }
        onSelect?(menuMarkers[sender.tag])
    }
}
