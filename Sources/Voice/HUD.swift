import AppKit

@MainActor
enum HUDState: String {
    case listening
    case transcribing
    case cleaning
    case done
    case cleanedLocally = "cleaned locally"
}

@MainActor
final class HUD {
    private enum Metrics {
        static let width: CGFloat = 520
        static let horizontalPadding: CGFloat = 18
        static let topPadding: CGFloat = 13
        static let bottomPadding: CGFloat = 14
        static let stateHeight: CGFloat = 14
        static let stateSpacing: CGFloat = 6
        static let maximumLines: CGFloat = 5
    }

    private let panel: HUDPanel
    private let stateLabel: NSTextField
    private let auroraView: AuroraView
    private let textView: NSTextView
    private let scrollView: NSScrollView
    private let placement: HUDPlacement
    private var dismissalTask: Task<Void, Never>?

    init(bottomInset: CGFloat) {
        let initialHeight: CGFloat = 70
        panel = HUDPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Metrics.width,
                height: initialHeight
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        stateLabel = NSTextField(labelWithString: HUDState.listening.rawValue)
        auroraView = AuroraView(frame: .zero)
        textView = NSTextView(frame: .zero)
        scrollView = NSScrollView(frame: .zero)
        placement = HUDPlacement(
            window: panel,
            bottomInset: bottomInset
        )

        configurePanel()
        configureContent()
    }

    func show(state: HUDState, text: String = "") {
        dismissalTask?.cancel()
        dismissalTask = nil
        panel.alphaValue = 1
        update(state: state, text: text)
        placement.prepareForShow()
        panel.orderFrontRegardless()
        auroraView.startAnimating()
    }

    func update(state: HUDState, text: String, showsWarning: Bool = false) {
        stateLabel.stringValue = showsWarning
            ? "⚠︎ \(state.rawValue)"
            : state.rawValue
        auroraView.setState(state)
        textView.string = text
        resizeForText(text)
        textView.scrollToEndOfDocument(nil)
    }

    func dismissAfterPaste() {
        dismissalTask?.cancel()
        dismissalTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(900))
            } catch {
                return
            }
            guard let self else {
                return
            }

            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.45
                self.panel.animator().alphaValue = 0
            }
            guard !Task.isCancelled else {
                return
            }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
            self.auroraView.stopAnimating()
        }
    }

    func hide() {
        dismissalTask?.cancel()
        dismissalTask = nil
        panel.orderOut(nil)
        panel.alphaValue = 1
        auroraView.stopAnimating()
    }

    func setLevel(_ rms: Float) {
        auroraView.setLevel(rms)
    }

    func update(bottomInset: CGFloat) {
        placement.update(bottomInset: bottomInset)
    }

    func resetPosition() {
        placement.resetCurrentPosition()
    }

    private func configurePanel() {
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
    }

    private func configureContent() {
        let background = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.appearance = NSAppearance(named: .darkAqua)
        background.wantsLayer = true
        background.layer?.cornerRadius = 18
        background.layer?.masksToBounds = true
        background.autoresizingMask = [.width, .height]
        panel.contentView = background

        stateLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        stateLabel.textColor = .secondaryLabelColor
        stateLabel.translatesAutoresizingMaskIntoConstraints = false

        auroraView.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.font = .systemFont(ofSize: 15)
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(stateLabel)
        background.addSubview(auroraView)
        background.addSubview(scrollView)

        NSLayoutConstraint.activate([
            stateLabel.leadingAnchor.constraint(
                equalTo: background.leadingAnchor,
                constant: Metrics.horizontalPadding
            ),
            stateLabel.trailingAnchor.constraint(
                equalTo: background.trailingAnchor,
                constant: -Metrics.horizontalPadding
            ),
            stateLabel.topAnchor.constraint(
                equalTo: background.topAnchor,
                constant: Metrics.topPadding
            ),
            stateLabel.heightAnchor.constraint(equalToConstant: Metrics.stateHeight),
            auroraView.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            auroraView.centerYAnchor.constraint(equalTo: stateLabel.centerYAnchor),
            auroraView.widthAnchor.constraint(equalToConstant: 64),
            auroraView.heightAnchor.constraint(equalToConstant: Metrics.stateHeight),
            scrollView.leadingAnchor.constraint(
                equalTo: background.leadingAnchor,
                constant: Metrics.horizontalPadding
            ),
            scrollView.trailingAnchor.constraint(
                equalTo: background.trailingAnchor,
                constant: -Metrics.horizontalPadding
            ),
            scrollView.topAnchor.constraint(
                equalTo: stateLabel.bottomAnchor,
                constant: Metrics.stateSpacing
            ),
            scrollView.bottomAnchor.constraint(
                equalTo: background.bottomAnchor,
                constant: -Metrics.bottomPadding
            ),
        ])
    }

    private func resizeForText(_ text: String) {
        let font = textView.font ?? .systemFont(ofSize: 15)
        let textWidth = Metrics.width - Metrics.horizontalPadding * 2
        let measuredText = text.isEmpty ? " " : text
        let bounds = (measuredText as NSString).boundingRect(
            with: NSSize(
                width: textWidth,
                height: .greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let textHeight = min(
            max(lineHeight, ceil(bounds.height)),
            lineHeight * Metrics.maximumLines
        )
        let panelHeight = Metrics.topPadding
            + Metrics.stateHeight
            + Metrics.stateSpacing
            + textHeight
            + Metrics.bottomPadding

        var frame = panel.frame
        frame.size = NSSize(width: Metrics.width, height: panelHeight)
        panel.setFrame(frame, display: true)
        panel.contentView?.layoutSubtreeIfNeeded()

        let viewport = scrollView.contentSize
        textView.frame = NSRect(
            origin: .zero,
            size: NSSize(
                width: viewport.width,
                height: max(viewport.height, ceil(bounds.height))
            )
        )
    }
}

@MainActor
private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
