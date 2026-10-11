import Foundation
import NotesMDKit
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The editor of one note in SwiftUI. `key` names what is shown - the note
/// and the version of it read from disk - and the text is loaded again only
/// when it changes, so that the note's own edits never reload it.
public struct NoteEditorView {
    public var key: String
    public var markdown: String
    public var editable: Bool
    /// When and where, shown under the title.
    public var info: NoteInfo?
    public var style: EditorStyle
    public var resolve: (String) -> URL?
    public var controller: EditorController
    public var onChange: (String) -> Void
    public var onObjectTap: (NoteAttachment, Int) -> Void

    public init(
        key: String,
        markdown: String,
        editable: Bool = true,
        info: NoteInfo? = nil,
        style: EditorStyle = EditorStyle(),
        resolve: @escaping (String) -> URL?,
        controller: EditorController,
        onChange: @escaping (String) -> Void,
        onObjectTap: @escaping (NoteAttachment, Int) -> Void
    ) {
        self.key = key
        self.markdown = markdown
        self.editable = editable
        self.info = info
        self.style = style
        self.resolve = resolve
        self.controller = controller
        self.onChange = onChange
        self.onObjectTap = onObjectTap
    }

    @MainActor
    public final class Coordinator: NSObject, NoteTextViewHost {
        var parent: NoteEditorView
        var loadedKey: String?

        init(_ parent: NoteEditorView) {
            self.parent = parent
        }

        func textChanged() {
            guard let view = parent.controller.view else { return }
            parent.onChange(view.editing.markdown())
        }

        func objectTapped(_ attachment: NoteAttachment, at location: Int) {
            parent.onObjectTap(attachment, location)
        }

        func load(_ view: NoteTextView) {
            guard loadedKey != parent.key else { return }
            loadedKey = parent.key
            view.editing.maker.resolve = parent.resolve
            view.editing.load(parent.markdown)
            #if os(macOS)
            view.setSelectedRange(NSRange(location: 0, length: 0))
            view.typingAttributes = view.editing.typingAttributes(at: 0)
            #else
            view.typingAttributes = view.editing.typingAttributes(at: 0)
            view.setContentOffset(.zero, animated: false)
            #endif
            parent.controller.refresh()
        }
    }

    @MainActor
    public func makeCoordinator() -> Coordinator { Coordinator(self) }
}

#if os(macOS)
extension NoteEditorView: NSViewRepresentable {
    public func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let view = NoteTextView(style: style, resolve: resolve)
        view.minSize = .zero
        view.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.host = context.coordinator
        view.controller = controller
        controller.view = view
        scroll.documentView = view
        return scroll
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NoteTextView else { return }
        controller.view = view
        view.controller = controller
        view.isEditable = editable
        (view.layoutManager as? NoteLayoutManager)?.info = info
        context.coordinator.load(view)
    }
}
#else
extension NoteEditorView: UIViewRepresentable {
    public func makeUIView(context: Context) -> NoteTextView {
        let view = NoteTextView(style: style, resolve: resolve)
        view.host = context.coordinator
        view.controller = controller
        controller.view = view
        return view
    }

    public func updateUIView(_ view: NoteTextView, context: Context) {
        context.coordinator.parent = self
        controller.view = view
        view.controller = controller
        view.isEditable = editable
        (view.layoutManager as? NoteLayoutManager)?.info = info
        context.coordinator.load(view)
    }
}
#endif
