// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit

/// The part of the scratchpad editor that is not text: task boxes and the
/// result of a calculation. It draws over the plain text view, so neither a
/// box nor a number takes a character, moves the caret or changes what the
/// document saves. Only the boxes answer the mouse; everywhere else the
/// overlay lets the click through to the text.
final class ScratchpadEditorOverlay: NSView {
    weak var textView: NSTextView?
    var rendersTasks: Bool
    var rendersMath: Bool
    var textColor: NSColor
    var onToggleTask: ((Int) -> Void)?

    init(textView: NSTextView,
         rendersTasks: Bool,
         rendersMath: Bool,
         textColor: NSColor,
         onToggleTask: ((Int) -> Void)?) {
        self.textView = textView
        self.rendersTasks = rendersTasks
        self.rendersMath = rendersMath
        self.textColor = textColor
        self.onToggleTask = onToggleTask
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    /// The text view is flipped, and a subview does not inherit that, so the
    /// drawing below can use the same top-left coordinates as the text.
    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.01, superview != nil else { return nil }
        let local = convert(point, from: superview)
        return taskBoxRects().contains { $0.rect.contains(local) } ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for box in taskBoxRects() where box.rect.contains(point) {
            onToggleTask?(box.line.box)
            return
        }
        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for box in taskBoxRects() {
            addCursorRect(box.rect, cursor: .pointingHand)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
        invalidateCursorRects()
    }

    /// Cursor rects belong to the window, so a box that appears, moves or
    /// disappears has to ask it to measure them again.
    func invalidateCursorRects() {
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        if rendersTasks {
            for box in taskBoxRects() where box.rect.intersects(dirtyRect) {
                drawBox(box.rect, checked: box.line.checked)
            }
        }
        if rendersMath {
            drawMath(in: dirtyRect)
        }
    }

    private func taskBoxRects() -> [(line: ScratchpadTaskLine, rect: NSRect)] {
        guard let textView, let layout = textView.layoutManager,
              let container = textView.textContainer else { return [] }
        layout.ensureLayout(for: container)
        let origin = textView.textContainerOrigin
        let font = textView.font ?? NSFont.systemFont(ofSize: PlainTextEditor.defaultFontSize)
        let size = PlainTextEditor.taskBoxSize(for: font.pointSize)
        var boxes: [(line: ScratchpadTaskLine, rect: NSRect)] = []
        for line in ScratchpadSupport.taskLines(in: textView.string) {
            let characters = NSRange(location: line.box, length: line.markerLength)
            let glyphs = layout.glyphRange(forCharacterRange: characters,
                                           actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            let glyph = glyphs.location
            let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let bounds = layout.boundingRect(forGlyphRange: glyphs, in: container)
            let rect = NSRect(x: origin.x + bounds.minX,
                              y: origin.y + fragment.minY + (fragment.height - size) / 2,
                              width: size,
                              height: size)
            boxes.append((line, rect))
        }
        return boxes
    }

    private func drawBox(_ rect: NSRect, checked: Bool) {
        let box = rect.insetBy(dx: 0.5, dy: 0.5)
        let outline = NSBezierPath(roundedRect: box,
                                   xRadius: min(4, box.width * 0.26),
                                   yRadius: min(4, box.width * 0.26))
        textColor.withAlphaComponent(0.38).setStroke()
        outline.lineWidth = 1.2
        outline.stroke()
        guard checked else { return }
        // A check that runs down and then up, drawn inside the same square.
        let tick = NSBezierPath()
        tick.move(to: NSPoint(x: box.minX + box.width * 0.25,
                              y: box.minY + box.height * 0.52))
        tick.line(to: NSPoint(x: box.minX + box.width * 0.43,
                              y: box.minY + box.height * 0.71))
        tick.line(to: NSPoint(x: box.minX + box.width * 0.76,
                              y: box.minY + box.height * 0.30))
        tick.lineWidth = max(1.6, box.width * 0.12)
        tick.lineCapStyle = .round
        tick.lineJoinStyle = .round
        PlainTextEditor.taskTickColor.setStroke()
        tick.stroke()
    }

    private func drawMath(in dirtyRect: NSRect) {
        guard let textView, let layout = textView.layoutManager,
              let container = textView.textContainer else { return }
        layout.ensureLayout(for: container)
        let origin = textView.textContainerOrigin
        let font = textView.font ?? NSFont.systemFont(ofSize: PlainTextEditor.defaultFontSize)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: PlainTextEditor.taskTickColor
        ]
        let containerWidth = container.size.width
        guard containerWidth > 0 else { return }
        // The answer keeps the column's right margin whatever the expression
        // is, so a page of sums reads as one column of results. The visible
        // edge wins when the container is wider than the view: a result cut
        // by the window would read as a broken number.
        let rightEdge = min(origin.x + containerWidth, bounds.maxX)
            - PlainTextEditor.lineFragmentPadding
        for line in ScratchpadSupport.mathLines(in: textView.string) {
            guard line.range.length > 0 else { continue }
            let glyphs = layout.glyphRange(forCharacterRange: line.range,
                                           actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            let lastGlyph = NSMaxRange(glyphs) - 1
            let used = layout.lineFragmentUsedRect(forGlyphAt: lastGlyph, effectiveRange: nil)
            let result = "= \(line.result)" as NSString
            let size = result.size(withAttributes: attributes)
            let x = rightEdge - size.width
            // A line that already reaches the result's column would hide its
            // own words; leaving the calculation out is quieter.
            guard x >= origin.x + used.maxX + 8 else { continue }
            let y = origin.y + used.minY + (used.height - size.height) / 2
            let drawRect = NSRect(x: x, y: y, width: size.width, height: size.height)
            guard drawRect.intersects(dirtyRect) else { continue }
            result.draw(at: drawRect.origin, withAttributes: attributes)
        }
    }
}
