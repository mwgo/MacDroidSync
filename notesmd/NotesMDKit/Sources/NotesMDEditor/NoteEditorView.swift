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
            view.heightMayHaveChanged()
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
/// On the Mac the note scrolls in SwiftUI's scroll view, which takes its
/// height from the text view: so the toolbar over it is glass, the text going
/// on beneath it as the system draws it for its own scroll views.
extension NoteEditorView: View {
    public var body: some View {
        NoteScroll(editor: self)
    }
}

/// The text at least as tall as what shows of it, so that a click anywhere below the end lands in it.
private struct NoteScroll: View {
    var editor: NoteEditorView
    @State private var viewport: CGFloat = 0

    var body: some View {
        ScrollView(.vertical) {
            NoteTextHost(editor: editor)
                .frame(minHeight: viewport, alignment: .top)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewport = $0 }
        .modifier(SoftEdge())
    }
}

/// The text fading softly under the bar's glass, as Notes has it.
private struct SoftEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            content
        }
    }
}

struct NoteTextHost: NSViewRepresentable {
    var editor: NoteEditorView

    func makeCoordinator() -> NoteEditorView.Coordinator { editor.makeCoordinator() }

    func makeNSView(context: Context) -> NoteTextView {
        let view = NoteTextView(style: editor.style, resolve: editor.resolve)
        view.host = context.coordinator
        view.controller = editor.controller
        editor.controller.view = view
        return view
    }

    func updateNSView(_ view: NoteTextView, context: Context) {
        context.coordinator.parent = editor
        editor.controller.view = view
        view.controller = editor.controller
        view.isEditable = editor.editable
        (view.layoutManager as? NoteLayoutManager)?.info = editor.info
        context.coordinator.load(view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NoteTextView, context: Context) -> CGSize? {
        // Before the width is known the text would be laid out a point wide.
        guard let width = proposal.width ?? (view.frame.width > 0 ? view.frame.width : nil), width > 2 * view.textContainerInset.width + 20 else { return nil }
        return CGSize(width: width, height: view.height(forWidth: width))
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
