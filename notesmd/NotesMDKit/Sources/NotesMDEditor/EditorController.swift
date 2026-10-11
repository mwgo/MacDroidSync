import Combine
import Foundation
import NotesMDKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// What the toolbar and menus act on: the open note's editor, and what is
/// true at its caret, for buttons that light up.
@MainActor
public final class EditorController: ObservableObject {
    @Published public private(set) var active: Set<InlineKind> = []
    @Published public private(set) var block: Block = .paragraph
    @Published public private(set) var isEditing = false
    @Published public private(set) var tasks: (all: Int, open: Int) = (0, 0)
    /// Whether the caret is in the note's first line, its title.
    @Published public private(set) var inTitle = false
    /// Whether the note has headings to fold, and whether they all are.
    @Published public private(set) var canFoldAll = false
    @Published public private(set) var allFolded = false

    weak var view: NoteTextView?

    public init() {}

    var editing: NoteEditing? { view?.editing }

    func refresh() {
        guard let view, let editing = view.editing as NoteEditing? else { return }
        let selection = view.selection
        active = Set(InlineKind.all.filter { editing.isActive($0, selection: selection) })
        block = editing.block(at: selection.location)
        tasks = editing.tasks()
        inTitle = editing.paragraph(at: selection.location).location == 0
        canFoldAll = editing.canFoldAll
        allFolded = editing.allFolded
        isEditing = view.isEditingText
    }

    public func toggle(_ kind: InlineKind) { view?.perform { $0.toggle(kind, selection: $1) } }
    public func toggleBlock(_ type: BlockType) { view?.perform { $0.toggleBlock(type, selection: $1) } }
    public func cycleHeading() { view?.perform { $0.cycleHeading(selection: $1) } }
    public func indent() { view?.perform { $0.indent(selection: $1) } }
    public func outdent() { view?.perform { $0.outdent(selection: $1) } }

    /// A table, picture or file where the caret is.
    public func insert(_ source: String) {
        view?.perform(selecting: true) { $0.insertObject(source, at: $1) }
    }

    public func replaceObject(at location: Int, with source: String?) {
        view?.perform { editing, _ in editing.replaceObject(at: location, with: source) }
    }

    public func endEditing() { view?.stopEditing() }

    /// Folds every heading, or unfolds them all once they are.
    public func toggleAllFolds() { view?.fold { $0.toggleAllFolds() } }

    /// The note as it is now.
    public func markdown() -> String? { editing?.markdown() }
}

/// The text view of a note, the same rules on both platforms: changes go
/// through `NoteEditing` first, and what it does itself can be undone.
@MainActor
protocol NoteTextViewHost: AnyObject {
    func textChanged()
    func objectTapped(_ attachment: NoteAttachment, at location: Int)
}

#if os(macOS)
/// Top-down, as the text view is.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

public final class NoteTextView: NSTextView {
    public let editing: NoteEditing
    weak var host: NoteTextViewHost?
    weak var controller: EditorController?
    private var pending: (range: NSRange, replacement: String)?
    private var applyingOwnChange = false

    init(style: EditorStyle, resolve: @escaping (String) -> URL?) {
        let storage = NSTextStorage()
        let layout = NoteLayoutManager(style: style)
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = EditorStyle.gutter
        layout.addTextContainer(container)
        editing = NoteEditing(storage: storage, style: style, maker: AttachmentMaker(style: style, resolve: resolve))
        super.init(frame: CGRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        editing.layout = layout
        isRichText = true
        importsGraphics = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        smartInsertDeleteEnabled = false
        textContainerInset = CGSize(width: 28 - EditorStyle.gutter, height: 18)
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        usesFindBar = true
        isIncrementalSearchingEnabled = true
    }

    required init?(coder: NSCoder) {
        fatalError("not coded")
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        fatalError("use init(style:resolve:)")
    }

    var selection: NSRange { selectedRange() }

    var isEditingText: Bool { window?.firstResponder === self }

    func stopEditing() { window?.makeFirstResponder(nil) }

    public override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard !applyingOwnChange else { return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString) }
        let replacement = replacementString ?? ""
        if replacementString != nil {
            editing.unfold(forChange: affectedCharRange, replacement: replacement)
            let before = snapshot()
            if let selection = editing.intercept(range: affectedCharRange, replacement: replacement) {
                registerUndo(before)
                finish(selection)
                return false
            }
        }
        guard super.shouldChangeText(in: affectedCharRange, replacementString: replacementString) else { return false }
        if replacementString != nil { pending = (affectedCharRange, replacement) }
        return true
    }

    public override func didChangeText() {
        super.didChangeText()
        guard let change = pending else { return }
        pending = nil
        let edited = NSRange(location: change.range.location, length: (change.replacement as NSString).length)
        if let selection = editing.didChange(edited: edited, replacement: change.replacement, selection: selectedRange()) {
            setSelectedRange(selection)
        }
        typingAttributes = editing.typingAttributes(at: selectedRange().location)
        host?.textChanged()
        controller?.refresh()
    }

    /// A command of the toolbar or a menu, undoable as one step.
    func perform(selecting: Bool = false, _ action: (NoteEditing, NSRange) -> NSRange?) {
        let before = snapshot()
        let result = action(editing, selectedRange())
        registerUndo(before)
        finish(selecting ? (result ?? selectedRange()) : selectedRange())
    }

    func perform(_ action: (NoteEditing, NSRange) -> Void) {
        perform(selecting: false) { editing, selection in
            action(editing, selection)
            return nil
        }
    }

    /// Folding or unfolding: no change to the note, so nothing to save or
    /// undo. What is below `heading` slides over its section or away from it;
    /// with no heading, everything the fold changed fades from before to after.
    func fold(around heading: NSRange? = nil, _ action: (NoteEditing) -> Void) {
        guard let layout = layoutManager as? NoteLayoutManager, let container = textContainer else { return action(editing) }
        layout.ensureLayout(for: container)
        let before = layout.usedRect(for: container).height
        let visible = visibleRect
        let top = heading.flatMap { layout.bottom(ofParagraph: $0) }.map { $0 + textContainerOrigin.y } ?? visible.minY
        let region = CGRect(x: visible.minX, y: max(top, visible.minY), width: visible.width, height: visible.maxY - max(top, visible.minY))
        let old = region.height > 1 ? image(of: region) : nil

        action(editing)
        let caret = selectedRange()
        if caret.length == 0 { setSelectedRange(NSRange(location: editing.visibleCaret(caret.location, forward: false), length: 0)) }
        layout.ensureLayout(for: container)
        needsDisplay = true
        controller?.refresh()

        let delta = layout.usedRect(for: container).height - before
        guard let old, abs(delta) > 0.5, let new = image(of: region) else { return }
        let overlay = FlippedView(frame: region)
        overlay.wantsLayer = true
        overlay.layer?.masksToBounds = true
        let bounds = CGRect(origin: .zero, size: region.size)
        let fade = heading == nil
        let folding = delta < 0
        let under = NSImageView(frame: bounds)
        let over = NSImageView(frame: bounds)
        for (view, image) in [(under, fade || !folding ? new : old), (over, fade || !folding ? old : new)] {
            view.image = image
            view.imageScaling = .scaleAxesIndependently
            overlay.addSubview(view)
        }
        if !fade, folding { over.setFrameOrigin(CGPoint(x: 0, y: -delta)) }
        addSubview(overlay)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            if fade {
                over.animator().alphaValue = 0
            } else {
                over.animator().setFrameOrigin(CGPoint(x: 0, y: folding ? 0 : delta))
            }
        } completionHandler: {
            overlay.removeFromSuperview()
        }
    }

    /// The view as drawn now within `rect`.
    private func image(of rect: CGRect) -> NSImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        cacheDisplay(in: rect, to: rep)
        let image = NSImage(size: rect.size)
        image.addRepresentation(rep)
        return image
    }

    private func finish(_ selection: NSRange) {
        setSelectedRange(NSRange(location: min(selection.location, textStorage?.length ?? 0), length: selection.length))
        typingAttributes = editing.typingAttributes(at: selectedRange().location)
        needsDisplay = true
        host?.textChanged()
        controller?.refresh()
    }

    private struct Snapshot {
        var text: NSAttributedString
        var trailing: Block
        var selection: NSRange
    }

    private func snapshot() -> Snapshot {
        Snapshot(text: NSAttributedString(attributedString: editing.storage), trailing: editing.trailingBlock, selection: selectedRange())
    }

    private func registerUndo(_ before: Snapshot) {
        guard let undoManager else { return }
        let after = snapshot()
        undoManager.registerUndo(withTarget: self) { view in
            view.restore(before, redo: after)
        }
        breakUndoCoalescing()
    }

    private func restore(_ snapshot: Snapshot, redo: Snapshot) {
        applyingOwnChange = true
        editing.storage.setAttributedString(snapshot.text)
        editing.trailingBlock = snapshot.trailing
        applyingOwnChange = false
        undoManager?.registerUndo(withTarget: self) { view in view.restore(redo, redo: snapshot) }
        editing.layout?.invalidateDecorations()
        finish(snapshot.selection)
    }

    public override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        let previous = selectedRange().location
        var ranges = ranges
        // The caret steps over a folded section rather than into it.
        if ranges.count == 1, let caret = ranges.first?.rangeValue, caret.length == 0 {
            let visible = editing.visibleCaret(caret.location, forward: caret.location > previous)
            if visible != caret.location { ranges = [NSValue(range: NSRange(location: visible, length: 0))] }
        }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
        if !stillSelectingFlag {
            if editing.typingInline != nil, selectedRange().length > 0 { editing.typingInline = nil }
            typingAttributes = editing.typingAttributes(at: selectedRange().location)
            controller?.refresh()
        }
    }

    public override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        controller?.refresh()
        return result
    }

    public override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        DispatchQueue.main.async { [weak self] in self?.controller?.refresh() }
        return result
    }

    // MARK: - Clicks and keys

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if handleTap(at: point) { return }
        super.mouseDown(with: event)
    }

    /// The arrow of a heading folds it; a box of a checklist ticks; a picture, table or file opens.
    private func handleTap(at point: CGPoint) -> Bool {
        guard let layout = layoutManager as? NoteLayoutManager, let container = textContainer else { return false }
        let inContainer = CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        if let heading = editing.foldArrow(at: inContainer) {
            fold(around: heading) { $0.toggleFold(paragraph: heading) }
            return true
        }
        for p in editing.paragraphs where !layout.isHidden(p.location) {
            let block = editing.block(of: p)
            if block.type == .checkbox, let marker = layout.markerRect(ofParagraph: p, block: block), marker.insetBy(dx: -4, dy: -2).contains(inContainer) {
                perform { editing, _ in editing.toggleCheckbox(paragraph: p) }
                return true
            }
        }
        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(for: inContainer, in: container, fractionOfDistanceThroughGlyph: &fraction)
        let index = layout.characterIndexForGlyph(at: glyph)
        guard let attachment = editing.object(at: index) else { return false }
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard rect.contains(inContainer) else { return false }
        host?.objectTapped(attachment, at: index)
        return true
    }

    public override func insertTab(_ sender: Any?) {
        if editing.canIndent(selection: selectedRange()) {
            perform { $0.indent(selection: $1) }
        } else {
            super.insertTab(sender)
        }
    }

    public override func insertBacktab(_ sender: Any?) {
        if editing.canIndent(selection: selectedRange()) {
            perform { $0.outdent(selection: $1) }
        } else {
            super.insertBacktab(sender)
        }
    }

    // Pasted text comes in as plain text, then takes the place's style.
    public override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    public override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }
}
#else
public final class NoteTextView: UITextView, UITextViewDelegate {
    public let editing: NoteEditing
    weak var host: NoteTextViewHost?
    weak var controller: EditorController?
    private var pending: (range: NSRange, replacement: String)?
    private var applyingOwnChange = false

    init(style: EditorStyle, resolve: @escaping (String) -> URL?) {
        let storage = NSTextStorage()
        let layout = NoteLayoutManager(style: style)
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = EditorStyle.gutter
        layout.addTextContainer(container)
        editing = NoteEditing(storage: storage, style: style, maker: AttachmentMaker(style: style, resolve: resolve))
        super.init(frame: .zero, textContainer: container)
        editing.layout = layout
        delegate = self
        alwaysBounceVertical = true
        // Its text starts below the bars it reaches under, and scrolls on beneath them.
        contentInsetAdjustmentBehavior = .always
        if #available(iOS 26.0, *) {
            topEdgeEffect.style = .soft
            bottomEdgeEffect.style = .soft
        }
        keyboardDismissMode = .interactive
        textContainerInset = UIEdgeInsets(top: 12, left: 20 - EditorStyle.gutter, bottom: 40, right: 20 - EditorStyle.gutter)
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        adjustsFontForContentSizeCategory = true
        backgroundColor = .systemBackground
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) {
        fatalError("not coded")
    }

    /// The bars of the screen learn that this is what scrolls under them, so
    /// that their glass reacts to it, as it does over a list.
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let controller = next as? UIViewController {
                controller.setContentScrollView(self, for: .top)
                controller.setContentScrollView(self, for: .bottom)
                break
            }
            responder = next
        }
    }

    var selection: NSRange { selectedRange }

    var isEditingText: Bool { isFirstResponder }

    func stopEditing() { resignFirstResponder() }

    public func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard !applyingOwnChange else { return true }
        editing.unfold(forChange: range, replacement: text)
        let before = snapshot()
        if let selection = editing.intercept(range: range, replacement: text) {
            registerUndo(before)
            finish(selection)
            return false
        }
        pending = (range, text)
        return true
    }

    public func textViewDidChange(_ textView: UITextView) {
        guard let change = pending else { return }
        pending = nil
        let edited = NSRange(location: change.range.location, length: (change.replacement as NSString).length)
        if let selection = editing.didChange(edited: edited, replacement: change.replacement, selection: selectedRange) {
            selectedRange = selection
        }
        typingAttributes = editing.typingAttributes(at: selectedRange.location)
        host?.textChanged()
        controller?.refresh()
    }

    /// Where the caret was, to tell which way it went past a folded section.
    private var lastCaret = 0

    public func textViewDidChangeSelection(_ textView: UITextView) {
        if selectedRange.length == 0 {
            let visible = editing.visibleCaret(selectedRange.location, forward: selectedRange.location > lastCaret)
            lastCaret = visible
            if visible != selectedRange.location {
                selectedRange = NSRange(location: visible, length: 0)
                return
            }
        }
        if editing.typingInline != nil, selectedRange.length > 0 { editing.typingInline = nil }
        typingAttributes = editing.typingAttributes(at: selectedRange.location)
        controller?.refresh()
    }

    public func textViewDidBeginEditing(_ textView: UITextView) { controller?.refresh() }
    public func textViewDidEndEditing(_ textView: UITextView) { controller?.refresh() }

    func perform(selecting: Bool = false, _ action: (NoteEditing, NSRange) -> NSRange?) {
        let before = snapshot()
        let result = action(editing, selectedRange)
        registerUndo(before)
        finish(selecting ? (result ?? selectedRange) : selectedRange)
    }

    func perform(_ action: (NoteEditing, NSRange) -> Void) {
        perform(selecting: false) { editing, selection in
            action(editing, selection)
            return nil
        }
    }

    /// As on the Mac: what is below `heading` slides over its section or away
    /// from it; with no heading, the fold fades from before to after.
    func fold(around heading: NSRange? = nil, _ action: (NoteEditing) -> Void) {
        let layout = self.layoutManager
        layout.ensureLayout(for: textContainer)
        let before = layout.usedRect(for: textContainer).height
        let visible = bounds
        let top = heading.flatMap { (layout as? NoteLayoutManager)?.bottom(ofParagraph: $0) }.map { $0 + textContainerInset.top } ?? visible.minY
        let region = CGRect(x: visible.minX, y: max(top, visible.minY), width: visible.width, height: visible.maxY - max(top, visible.minY))
        let old = region.height > 1 ? resizableSnapshotView(from: region, afterScreenUpdates: false, withCapInsets: .zero) : nil

        action(editing)
        if selectedRange.length == 0 { selectedRange = NSRange(location: editing.visibleCaret(selectedRange.location, forward: false), length: 0) }
        layout.ensureLayout(for: textContainer)
        setNeedsDisplay()
        controller?.refresh()

        let delta = layout.usedRect(for: textContainer).height - before
        guard let old, abs(delta) > 0.5, let new = resizableSnapshotView(from: region, afterScreenUpdates: true, withCapInsets: .zero) else { return }
        let overlay = UIView(frame: region)
        overlay.clipsToBounds = true
        overlay.isUserInteractionEnabled = false
        overlay.backgroundColor = backgroundColor
        let fade = heading == nil
        let folding = delta < 0
        let under = fade || !folding ? new : old
        let over = fade || !folding ? old : new
        for view in [under, over] {
            view.frame = CGRect(origin: .zero, size: region.size)
            overlay.addSubview(view)
        }
        if !fade, folding { over.frame.origin.y = -delta }
        over.backgroundColor = backgroundColor
        addSubview(overlay)
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut]) {
            if fade {
                over.alpha = 0
            } else {
                over.frame.origin.y = folding ? 0 : delta
            }
        } completion: { _ in
            overlay.removeFromSuperview()
        }
    }

    private func finish(_ selection: NSRange) {
        selectedRange = NSRange(location: min(selection.location, textStorage.length), length: selection.length)
        typingAttributes = editing.typingAttributes(at: selectedRange.location)
        setNeedsDisplay()
        host?.textChanged()
        controller?.refresh()
    }

    private struct Snapshot {
        var text: NSAttributedString
        var trailing: Block
        var selection: NSRange
    }

    private func snapshot() -> Snapshot {
        Snapshot(text: NSAttributedString(attributedString: editing.storage), trailing: editing.trailingBlock, selection: selectedRange)
    }

    private func registerUndo(_ before: Snapshot) {
        guard let undoManager else { return }
        let after = snapshot()
        undoManager.registerUndo(withTarget: self) { view in view.restore(before, redo: after) }
    }

    private func restore(_ snapshot: Snapshot, redo: Snapshot) {
        applyingOwnChange = true
        editing.storage.setAttributedString(snapshot.text)
        editing.trailingBlock = snapshot.trailing
        applyingOwnChange = false
        undoManager?.registerUndo(withTarget: self) { view in view.restore(redo, redo: snapshot) }
        editing.layout?.invalidateDecorations()
        finish(snapshot.selection)
    }

    // MARK: - Taps and keys

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        _ = handleTap(at: gesture.location(in: self))
    }

    private func handleTap(at point: CGPoint) -> Bool {
        guard let layout = layoutManager as? NoteLayoutManager else { return false }
        let inContainer = CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
        if let heading = editing.foldArrow(at: inContainer) {
            fold(around: heading) { $0.toggleFold(paragraph: heading) }
            return true
        }
        for p in editing.paragraphs where !layout.isHidden(p.location) {
            let block = editing.block(of: p)
            if block.type == .checkbox, let marker = layout.markerRect(ofParagraph: p, block: block), marker.insetBy(dx: -8, dy: -4).contains(inContainer) {
                perform { editing, _ in editing.toggleCheckbox(paragraph: p) }
                return true
            }
        }
        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(for: inContainer, in: textContainer, fractionOfDistanceThroughGlyph: &fraction)
        let index = layout.characterIndexForGlyph(at: glyph)
        guard let attachment = editing.object(at: index) else { return false }
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard rect.contains(inContainer) else { return false }
        host?.objectTapped(attachment, at: index)
        return true
    }

    public override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(tabKey)),
            UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(backtabKey)),
            UIKeyCommand(input: "b", modifierFlags: .command, action: #selector(boldKey)),
            UIKeyCommand(input: "i", modifierFlags: .command, action: #selector(italicKey)),
            UIKeyCommand(input: "u", modifierFlags: .command, action: #selector(underlineKey)),
        ]
    }

    @objc private func tabKey() {
        if editing.canIndent(selection: selectedRange) { perform { $0.indent(selection: $1) } } else { insertText("\t") }
    }

    @objc private func backtabKey() { perform { $0.outdent(selection: $1) } }
    @objc private func boldKey() { perform { $0.toggle(.bold, selection: $1) } }
    @objc private func italicKey() { perform { $0.toggle(.italic, selection: $1) } }
    @objc private func underlineKey() { perform { $0.toggle(.underline, selection: $1) } }

    public override func paste(_ sender: Any?) {
        guard let text = UIPasteboard.general.string else { return }
        insertText(text)
    }
}

extension NoteTextView: UIGestureRecognizerDelegate {
    public override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer is UITapGestureRecognizer, gestureRecognizer.view === self, gestureRecognizer.delegate === self else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        let point = gestureRecognizer.location(in: self)
        guard let layout = layoutManager as? NoteLayoutManager else { return false }
        let inContainer = CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
        if editing.foldArrow(at: inContainer) != nil { return true }
        for p in editing.paragraphs where !layout.isHidden(p.location) {
            let block = editing.block(of: p)
            if block.type == .checkbox, let marker = layout.markerRect(ofParagraph: p, block: block), marker.insetBy(dx: -8, dy: -4).contains(inContainer) {
                return true
            }
        }
        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(for: inContainer, in: textContainer, fractionOfDistanceThroughGlyph: &fraction)
        let index = layout.characterIndexForGlyph(at: glyph)
        guard editing.object(at: index) != nil else { return false }
        return layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer).contains(inContainer)
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }
}
#endif
