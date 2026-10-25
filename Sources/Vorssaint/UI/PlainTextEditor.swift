// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Carbon.HIToolbox
import SwiftUI

/// An AppKit text view configured as a pure plain-text surface: no smart
/// quotes or dashes, no substitutions, no rich paste, with undo. SwiftUI's
/// editor cannot switch all of that off, and its TextEditor(text:selection:)
/// would cover the caret tracking below but needs macOS 15, a version past
/// this app's floor.
struct PlainTextEditor: NSViewRepresentable {
    /// Both shared with callers that overlay their own text on the editor,
    /// so a placeholder can be positioned from the same numbers as the
    /// first line rather than from literals that drift apart.
    /// `lineFragmentPadding` sits inside the inset and is set on the text
    /// container below rather than assumed, so this stays the source of
    /// the number instead of a copy of AppKit's default.
    static let defaultFontSize: CGFloat = 13
    static let lineFragmentPadding: CGFloat = 5
    /// The lime tick of a checked scratchpad task.
    static let taskTickColor = NSColor(srgbRed: 182.0 / 255.0,
                                       green: 249.0 / 255.0,
                                       blue: 45.0 / 255.0,
                                       alpha: 1)
    /// A box that sits comfortably on a line of the current body size, and
    /// never gets too small to hit.
    static func taskBoxSize(for pointSize: CGFloat) -> CGFloat {
        max(12, (pointSize + 3).rounded())
    }

    /// The point size this editor draws at. Callers that overlay their own
    /// text pass the same number rather than the default, or the placeholder
    /// stops sitting on the first line as soon as the size is changed.
    var fontSize: CGFloat = PlainTextEditor.defaultFontSize

    /// The font family this editor draws with, or nil for the system face.
    /// Size is a preference and can change under a view that is already up,
    /// and so can the face: both are re-applied on update rather than only
    /// when the view is made, so a switch is live without reopening the pad.
    var fontFamily: String?

    /// The font this editor draws with at the given size. A family not
    /// installed on this Mac falls back to the system face rather than to a
    /// different size, so a setting cannot leave the pad in a face that is
    /// not there.
    static func font(for fontSize: CGFloat, fontFamily: String?) -> NSFont {
        if let fontFamily, let font = NSFont(name: fontFamily, size: fontSize) {
            return font
        }
        return NSFont.systemFont(ofSize: fontSize)
    }

    /// Whether the keyboard is in a find bar's search field rather than in
    /// the text it searches, so Esc can put the search away before the pad.
    static func findBarHasKeyboard(in window: NSWindow?) -> Bool {
        guard let field = window?.firstResponder as? NSTextView, field.isFieldEditor,
              let control = field.delegate as? NSView else { return false }
        return sequence(first: control, next: \.superview).contains { view in
            guard let bar = (view as? NSScrollView)?.findBarView else { return false }
            return control.isDescendant(of: bar)
        }
    }

    @Binding var text: String
    /// Character offsets rather than String.Index: an index computed
    /// against one version of the text is undefined behavior to read back
    /// against another, and this binding outlives the edit that produced
    /// it. Offsets can simply be clamped by whoever reads them.
    var selectedRange: Binding<Range<Int>?>?
    /// Colour is configuration applied when the view is made; the font above
    /// is the one property whose caller can change it live.
    var textColor: NSColor?
    var textContainerInset: NSSize?
    /// Turns on AppKit's own find bar: the real Command-F, with its counter,
    /// its highlighting and Command-G, none of which is worth rewriting.
    var usesFindBar = false
    /// Typing the `]` of `- [` makes it `- [ ]`, the empty checkbox of a
    /// Markdown task list, so the box never needs its space typed.
    var completesTaskBoxes = false
    /// Shift-Return carries a list on: the next line opens with the same bullet,
    /// box or number. Off, it adds a line as Return does.
    var continuesLists = false
    /// Draws task boxes over the plain text, and paints the value beside a
    /// line that is arithmetic. Neither writes anything into the text the
    /// document stores.
    var rendersTaskCheckboxes = false
    var rendersInlineMath = false
    /// Called with the UTF-16 offset of a task's `[` when its checkbox is
    /// clicked. The owner edits the text, so the click is one undo step.
    var onToggleTask: ((Int) -> Void)?
    /// Command-Return, which the caller takes for its own: the pad turns it into
    /// the formatted reading.
    var onCommandReturn: (() -> Void)?
    /// False while the editor sits under something else, as the pad's
    /// formatted reading covers it: it is then hidden, so its text cursor
    /// does not show over what is on top.
    var isActive = true
    /// Handed the text view once, for callers that need to reach it later.
    var onCreate: ((NSTextView) -> Void)?

    init(text: Binding<String>,
         fontSize: CGFloat = PlainTextEditor.defaultFontSize,
         fontFamily: String? = nil,
         selectedRange: Binding<Range<Int>?>? = nil,
         textColor: NSColor? = nil,
         textContainerInset: NSSize? = nil,
         usesFindBar: Bool = false,
         completesTaskBoxes: Bool = false,
         continuesLists: Bool = false,
         rendersTaskCheckboxes: Bool = false,
         rendersInlineMath: Bool = false,
         onToggleTask: ((Int) -> Void)? = nil,
         onCommandReturn: (() -> Void)? = nil,
         isActive: Bool = true,
         onCreate: ((NSTextView) -> Void)? = nil) {
        self._text = text
        self.fontSize = fontSize
        self.fontFamily = fontFamily
        self.selectedRange = selectedRange
        self.textColor = textColor
        self.textContainerInset = textContainerInset
        self.usesFindBar = usesFindBar
        self.completesTaskBoxes = completesTaskBoxes
        self.continuesLists = continuesLists
        self.rendersTaskCheckboxes = rendersTaskCheckboxes
        self.rendersInlineMath = rendersInlineMath
        self.onToggleTask = onToggleTask
        self.onCommandReturn = onCommandReturn
        self.isActive = isActive
        self.onCreate = onCreate
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.drawsBackground = false
        textView.font = Self.font(for: fontSize, fontFamily: fontFamily)
        textView.textContainer?.lineFragmentPadding = Self.lineFragmentPadding
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        if usesFindBar {
            textView.usesFindBar = true
            textView.isIncrementalSearchingEnabled = true
        }
        if let textColor {
            textView.textColor = textColor
        }
        if let textContainerInset {
            textView.textContainerInset = textContainerInset
        }
        textView.string = text
        // Delegate last: assigning .string posts a selection notification
        // synchronously, and makeNSView runs inside SwiftUI's update pass,
        // where writing state is undefined behavior.
        textView.delegate = context.coordinator
        context.coordinator.completesTaskBoxes = completesTaskBoxes
        context.coordinator.continuesLists = continuesLists
        context.coordinator.onCommandReturn = onCommandReturn
        context.coordinator.rendersTaskCheckboxes = rendersTaskCheckboxes
        context.coordinator.rendersInlineMath = rendersInlineMath
        context.coordinator.textColor = textColor
        context.coordinator.installOverlay(on: textView,
                                          rendersTasks: rendersTaskCheckboxes,
                                          rendersMath: rendersInlineMath,
                                          onToggleTask: onToggleTask)
        context.coordinator.restyle(textView)
        context.coordinator.installLineMoveMonitor(for: textView)
        onCreate?(textView)
        return scroll
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.removeLineMoveMonitor()
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        context.coordinator.continuesLists = continuesLists
        context.coordinator.onCommandReturn = onCommandReturn
        // Hidden, not disabled: it keeps its text and undo history, and can
        // still be cleared through, but a hidden view has no cursor rects.
        if nsView.isHidden == isActive { nsView.isHidden = !isActive }
        // Size and face are preferences that can change under a view that is
        // already up, so they are applied before the text guard below rather
        // than after it. Comparing the resolved font covers both: a named
        // face and the system face have different names at the same size.
        let resolvedFont = Self.font(for: fontSize, fontFamily: fontFamily)
        let fontChanged = textView.font?.fontName != resolvedFont.fontName
            || textView.font?.pointSize != resolvedFont.pointSize
        if fontChanged {
            textView.font = resolvedFont
        }
        let drawingChanged = context.coordinator.rendersTaskCheckboxes != rendersTaskCheckboxes
            || context.coordinator.rendersInlineMath != rendersInlineMath
        context.coordinator.rendersTaskCheckboxes = rendersTaskCheckboxes
        context.coordinator.rendersInlineMath = rendersInlineMath
        context.coordinator.textColor = textColor
        if context.coordinator.overlay == nil,
           rendersTaskCheckboxes || rendersInlineMath {
            context.coordinator.installOverlay(on: textView,
                                              rendersTasks: rendersTaskCheckboxes,
                                              rendersMath: rendersInlineMath,
                                              onToggleTask: onToggleTask)
        } else {
            context.coordinator.overlay?.rendersTasks = rendersTaskCheckboxes
            context.coordinator.overlay?.rendersMath = rendersInlineMath
            context.coordinator.overlay?.textColor = textColor ?? .labelColor
            context.coordinator.overlay?.onToggleTask = onToggleTask
        }
        guard textView.string != text, !textView.hasMarkedText() else {
            if fontChanged || drawingChanged { context.coordinator.restyle(textView) }
            return
        }
        // Setting .string posts a selection notification, and answering it
        // here would write state from inside a view update.
        context.coordinator.isApplyingExternalText = true
        textView.string = text
        context.coordinator.isApplyingExternalText = false
        context.coordinator.restyle(textView)
        // Programmatic replaces (load, retention, restore) invalidate undo
        // entries recorded against the old storage; replaying one would
        // resurrect cleared text or throw a range exception.
        textView.undoManager?.removeAllActions()
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(text: $text, selectedRange: selectedRange)
        coordinator.rendersTaskCheckboxes = rendersTaskCheckboxes
        coordinator.rendersInlineMath = rendersInlineMath
        coordinator.textColor = textColor
        return coordinator
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        private let selectedRange: Binding<Range<Int>?>?
        var isApplyingExternalText = false
        var completesTaskBoxes = false
        var continuesLists = false
        var rendersTaskCheckboxes = false
        var rendersInlineMath = false
        var textColor: NSColor?
        var onCommandReturn: (() -> Void)?
        var overlay: ScratchpadEditorOverlay?
        private weak var textView: NSTextView?
        private var lineMoveMonitor: Any?

        init(text: Binding<String>, selectedRange: Binding<Range<Int>?>?) {
            self.text = text
            self.selectedRange = selectedRange
        }

        /// Puts the editor's drawing surface over its text. It answers only
        /// the points that hold a checkbox, so a click anywhere else reaches
        /// the text view and editing is exactly as it was.
        func installOverlay(on textView: NSTextView,
                            rendersTasks: Bool,
                            rendersMath: Bool,
                            onToggleTask: ((Int) -> Void)?) {
            guard overlay == nil else { return }
            let overlay = ScratchpadEditorOverlay(textView: textView,
                                                  rendersTasks: rendersTasks,
                                                  rendersMath: rendersMath,
                                                  textColor: textColor ?? .labelColor,
                                                  onToggleTask: onToggleTask)
            overlay.frame = textView.bounds
            overlay.autoresizingMask = [.width, .height]
            textView.addSubview(overlay)
            self.overlay = overlay
        }

        /// Hides a task's marker under the box the overlay draws, and strikes
        /// a checked task through. This is the only place the editor writes
        /// attributes; the characters the document stores never change.
        func restyle(_ textView: NSTextView) {
            guard let storage = textView.textStorage, !textView.hasMarkedText() else { return }
            let baseFont = textView.font ?? NSFont.systemFont(ofSize: PlainTextEditor.defaultFontSize)
            let baseColor = textColor ?? .labelColor
            let base: [NSAttributedString.Key: Any] = [
                .font: baseFont,
                .foregroundColor: baseColor
            ]
            storage.beginEditing()
            storage.setAttributes(base, range: NSRange(location: 0, length: storage.length))
            if rendersTaskCheckboxes {
                let ns = textView.string as NSString
                let boxSize = PlainTextEditor.taskBoxSize(for: baseFont.pointSize)
                for task in ScratchpadSupport.taskLines(in: textView.string) {
                    let marker = NSRange(location: task.box, length: task.markerLength)
                    guard NSMaxRange(marker) <= ns.length else { continue }
                    // A list's bullet goes with the box: the box takes the
                    // bullet's place rather than following it. The characters
                    // stay, but they lose their colour and their advance.
                    if let bullet = task.bulletRange, bullet.length > 0,
                       NSMaxRange(bullet) <= ns.length {
                        storage.addAttribute(.foregroundColor, value: NSColor.clear,
                                             range: bullet)
                        // Each character narrows by its own advance. Setting
                        // one large negative kern is clamped at the glyph
                        // before it, which would leave the bullet's width.
                        for offset in 0..<bullet.length {
                            let character = NSRange(location: bullet.location + offset,
                                                    length: 1)
                            let width = (ns.substring(with: character) as NSString)
                                .size(withAttributes: [.font: baseFont]).width
                            storage.addAttribute(.kern, value: -width, range: character)
                        }
                    }
                    // The marker keeps its characters, so the caret and the
                    // document agree, but it gives exactly the box's width to
                    // the line and draws nothing itself.
                    let natural = (ns.substring(with: marker) as NSString)
                        .size(withAttributes: [.font: baseFont]).width
                    let kern = (boxSize - natural) / CGFloat(max(1, task.markerLength))
                    storage.addAttributes([.foregroundColor: NSColor.clear, .kern: kern],
                                          range: marker)
                    if task.checked, task.textRange.length > 0,
                       NSMaxRange(task.textRange) <= ns.length {
                        storage.addAttributes([
                            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                            .foregroundColor: baseColor.withAlphaComponent(0.55)
                        ], range: task.textRange)
                    }
                }
            }
            storage.endEditing()
            textView.typingAttributes = base
            overlay?.rendersTasks = rendersTaskCheckboxes
            overlay?.rendersMath = rendersInlineMath
            overlay?.textColor = baseColor
            overlay?.needsDisplay = true
            overlay?.invalidateCursorRects()
        }

        /// Option-Up/Down moves the current line (or every line a selection
        /// touches) past its neighbor, as in most code editors. AppKit has
        /// no default key binding for it, so it is caught here rather than
        /// through a selector NSTextView would otherwise never resolve.
        func installLineMoveMonitor(for textView: NSTextView) {
            self.textView = textView
            lineMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if let self, let textView = self.textView,
                   event.window === textView.window,
                   textView.window?.firstResponder === textView,
                   !textView.hasMarkedText(),
                   [kVK_Return, kVK_ANSI_KeypadEnter].contains(Int(event.keyCode)) {
                    let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
                    if flags == .shift, self.continuesLists {
                        self.continueList(in: textView)
                        return nil
                    }
                    if flags == .command, let onCommandReturn = self.onCommandReturn {
                        onCommandReturn()
                        return nil
                    }
                }
                guard let self, let textView = self.textView,
                      event.window === textView.window,
                      textView.window?.firstResponder === textView,
                      !textView.hasMarkedText(),
                      event.modifierFlags.intersection([.command, .option, .shift, .control]) == .option
                else { return event }
                let direction: PlainTextLineMover.Direction
                switch Int(event.keyCode) {
                case kVK_UpArrow: direction = .up
                case kVK_DownArrow: direction = .down
                default: return event
                }
                return self.moveLine(direction, in: textView) ? nil : event
            }
        }

        /// Shift-Return: the next list item, or a plain line.
        private func continueList(in textView: NSTextView) {
            let edit = ScratchpadSupport.lineBreakEdit(in: textView.string, selection: textView.selectedRange())
            textView.breakUndoCoalescing()
            textView.insertText(edit.replacement, replacementRange: edit.range)
            textView.setSelectedRange(NSRange(location: edit.caret, length: 0))
            textView.scrollRangeToVisible(textView.selectedRange())
        }

        func removeLineMoveMonitor() {
            if let lineMoveMonitor {
                NSEvent.removeMonitor(lineMoveMonitor)
                self.lineMoveMonitor = nil
            }
        }

        private func moveLine(_ direction: PlainTextLineMover.Direction, in textView: NSTextView) -> Bool {
            let before = textView.selectedRange()
            guard let result = PlainTextLineMover.moving(direction, in: textView.string, selection: before)
            else { return false }
            // Only the two neighbours trade places, in a span that keeps its
            // length, so only that span is replaced: undo then restores two
            // lines rather than the whole note.
            let full = textView.string as NSString
            let block = full.lineRange(for: before)
            let span = direction == .up
                ? NSUnionRange(full.lineRange(for: NSRange(location: block.location - 1, length: 0)), block)
                : NSUnionRange(block, full.lineRange(for: NSRange(location: NSMaxRange(block), length: 0)))
            let replacement = (result.text as NSString).substring(with: span)
            if replacement != full.substring(with: span) {
                guard textView.isEditable else { return false }
                textView.breakUndoCoalescing()
                // Undo leaves the caret at the end of what it restored;
                // these put the selection back on both sides of the step.
                // The first goes in before the text view's own undo, so it
                // runs after it.
                Self.keepSelection(before, whenUndoing: true, in: textView)
                guard textView.shouldChangeText(in: span, replacementString: replacement) else { return false }
                textView.textStorage?.replaceCharacters(in: span, with: replacement)
                textView.didChangeText()
                Self.keepSelection(result.selection, whenUndoing: false, in: textView)
            }
            textView.setSelectedRange(result.selection)
            textView.scrollRangeToVisible(result.selection)
            return true
        }

        /// Selects `selection` when the step is undone (or redone), and
        /// registers itself again each time so the pair survives any number
        /// of round trips.
        private static func keepSelection(_ selection: NSRange, whenUndoing: Bool, in textView: NSTextView) {
            textView.undoManager?.registerUndo(withTarget: textView) { textView in
                if textView.undoManager?.isUndoing == whenUndoing { textView.setSelectedRange(selection) }
                keepSelection(selection, whenUndoing: whenUndoing, in: textView)
            }
        }

        /// The attributes a newly typed character gets. Reading them from the
        /// caret is wrong here: the caret can sit against a hidden task
        /// marker or a struck-through line, and neither should be inherited.
        private func typingAttributes(for textView: NSTextView) -> [NSAttributedString.Key: Any] {
            [.font: textView.font ?? NSFont.systemFont(ofSize: PlainTextEditor.defaultFontSize),
             .foregroundColor: textColor ?? .labelColor]
        }

        /// Typing `]` right after `- [` puts the box's space in with it. Only
        /// typing does: deleting the space leaves `[]` as it was left.
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange,
                      replacementString: String?) -> Bool {
            textView.typingAttributes = typingAttributes(for: textView)
            guard completesTaskBoxes, replacementString == "]", range.length == 0,
                  !textView.hasMarkedText() else { return true }
            let full = textView.string as NSString
            guard range.location <= full.length else { return true }
            let line = full.lineRange(for: NSRange(location: range.location, length: 0))
            let before = full.substring(with: NSRange(location: line.location, length: range.location - line.location))
            guard ScratchpadSupport.completesEmptyTaskBox(before: before) else { return true }
            textView.insertText(" ]", replacementRange: range)
            return false
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalText, let textView = notification.object as? NSTextView else { return }
            let current = textView.string
            if text.wrappedValue != current { text.wrappedValue = current }
            restyle(textView)
            publishSelection(of: textView, in: current)
        }

        /// Publishes the caret only. Never writes the text binding: a caret
        /// move would then republish whatever the view currently holds,
        /// which for a caller that reloads its text out-of-band means
        /// writing stale content back over the fresh content.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplyingExternalText, let textView = notification.object as? NSTextView else { return }
            textView.typingAttributes = typingAttributes(for: textView)
            guard selectedRange != nil else { return }
            publishSelection(of: textView, in: textView.string)
        }

        private func publishSelection(of textView: NSTextView, in current: String) {
            guard let selectedRange else { return }
            // A selection that will not convert leaves the last known caret
            // alone, since nil here would read as "caret at the end".
            guard let converted = Range(textView.selectedRange(), in: current) else { return }
            selectedRange.wrappedValue =
                current.distance(from: current.startIndex, to: converted.lowerBound)
                    ..< current.distance(from: current.startIndex, to: converted.upperBound)
        }
    }
}
