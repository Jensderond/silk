import AppKit

/// A small titled window with a heading, scrollable monospaced body and buttons.
/// Used for config problems and the Accessibility onboarding.
final class MessageWindow: NSObject, NSWindowDelegate {
    struct Button {
        var title: String
        var isDefault = false
        var action: () -> Void
    }

    private var window: NSWindow?
    private var buttonActions: [() -> Void] = []
    private let textView = NSTextView()
    private let headingLabel = NSTextField(wrappingLabelWithString: "")

    /// Shows (or updates, if already visible) the window and brings it to the front.
    func show(title: String, heading: String, body: String, buttons: [Button]) {
        let window = self.window ?? makeWindow()
        self.window = window
        window.title = title
        headingLabel.stringValue = heading
        textView.string = body
        install(buttons, in: window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    var isVisible: Bool { window?.isVisible == true }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 380),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 420, height: 240)
        window.center()

        headingLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        headingLabel.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(headingLabel)
        content.addSubview(scroll)
        window.contentView = content
        NSLayoutConstraint.activate([
            headingLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            headingLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            headingLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: headingLabel.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -56),
        ])
        return window
    }

    private func install(_ buttons: [Button], in window: NSWindow) {
        guard let content = window.contentView else { return }
        content.subviews.filter { $0 is NSStackView }.forEach { $0.removeFromSuperview() }
        buttonActions = buttons.map(\.action)
        let views: [NSView] = buttons.enumerated().map { index, spec in
            let button = NSButton(title: spec.title, target: self, action: #selector(buttonPressed(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            if spec.isDefault { button.keyEquivalent = "\r" }
            return button
        }
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        guard buttonActions.indices.contains(sender.tag) else { return }
        buttonActions[sender.tag]()
    }
}
