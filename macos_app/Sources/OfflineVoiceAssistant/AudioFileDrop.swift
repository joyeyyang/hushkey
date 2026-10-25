import AppKit
import ObjectiveC

/// Dragging an audio file onto a view.
///
/// One line to accept a dropped audio file:
///
///     transcriptPane.acceptAudioFileDrops { importer.importFile(at: $0, …) }
///
/// NSView already conforms to `NSDraggingDestination`, but its handlers are
/// open methods, which an extension cannot supply. So this puts a child view
/// behind the others to do the accepting. Behind, not on top: buttons and
/// text views keep their clicks, and a drop anywhere the host shows through
/// still lands.
private var audioDropCatcherKey: UInt8 = 0

extension NSView {
    /// Accepts a dropped audio file and hands its URL to `onDrop`.
    func acceptAudioFileDrops(onDrop: @escaping (URL) -> Void) {
        if let previous = objc_getAssociatedObject(self, &audioDropCatcherKey) as? AudioDropCatcher {
            previous.removeFromSuperview()
        }
        let catcher = AudioDropCatcher(onDrop: onDrop)
        objc_setAssociatedObject(self, &audioDropCatcherKey, catcher, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        catcher.translatesAutoresizingMaskIntoConstraints = false
        addSubview(catcher, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            catcher.leadingAnchor.constraint(equalTo: leadingAnchor),
            catcher.trailingAnchor.constraint(equalTo: trailingAnchor),
            catcher.topAnchor.constraint(equalTo: topAnchor),
            catcher.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

/// The view that actually receives the drag. One closure, no global state, so
/// two windows cannot confuse each other's drops.
private final class AudioDropCatcher: NSView {
    private var onDrop: ((URL) -> Void)?

    init(onDrop: @escaping (URL) -> Void) {
        self.onDrop = onDrop
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURL(from: sender) == nil ? [] : .copy
    }

    /// Repeated while the pointer moves, and what keeps showing `.copy` — left
    /// to NSView's default the cursor can fall back to "no drop" after entry.
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURL(from: sender) == nil ? [] : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        fileURL(from: sender) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = fileURL(from: sender) else { return false }
        onDrop?(url)
        return true
    }

    /// Only real files: a dragged image or a scrap of text carries no file URL
    /// and is refused here rather than surfacing later as an import error.
    private func fileURL(from info: NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL])?.first
    }
}
