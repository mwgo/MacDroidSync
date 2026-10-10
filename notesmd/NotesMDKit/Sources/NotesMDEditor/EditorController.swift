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
        container.lineFragmentPadding = 6
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
        textContainerInset = CGSize(width: 22, height: 18)
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

    /// A box of a checklist ticks; a picture, table or file opens.
    private func handleTap(at point: CGPoint) -> Bool {
        guard let layout = layoutManager as? NoteLayoutManager, let container = textContainer else { return false }
        let inContainer = CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        for p in editing.paragraphs {
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
        container.lineFragmentPadding = 6
        layout.addTextContainer(container)
        editing = NoteEditing(storage: storage, style: style, maker: AttachmentMaker(style: style, resolve: resolve))
        super.init(frame: .zero, textContainer: container)
        editing.layout = layout
        delegate = self
        alwaysBounceVertical = true
        keyboardDismissMode = .interactive
        textContainerInset = UIEdgeInsets(top: 12, left: 14, bottom: 40, right: 14)
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

    var selection: NSRange { selectedRange }

    var isEditingText: Bool { isFirstResponder }

    func stopEditing() { resignFirstResponder() }

    public func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard !applyingOwnChange else { return true }
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

    public func textViewDidChangeSelection(_ textView: UITextView) {
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
        for p in editing.paragraphs {
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
        for p in editing.paragraphs {
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
