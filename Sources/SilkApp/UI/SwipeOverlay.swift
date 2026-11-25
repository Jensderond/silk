import AppKit

/// The pill shown while a three-finger swipe between workspaces is in progress. It follows the fingers
/// sideways, fills a ring up to the commit threshold and turns accented past it (with a haptic tick each time
/// the threshold is crossed, either way), so it is clear whether lifting the fingers switches or not. When the
/// fingers move slowly it widens to name the workspace the swipe goes to and the apps on it.
///
/// Knows nothing about trackpads: `begin`, any number of `update`s, then `commit` or `cancel`. Each of those
/// is safe to call in any state, so an interrupted swipe never leaves the pill on screen.
@MainActor
final class SwipeOverlay {
    struct Target: Equatable {
        var name: String
        var appNames: [String]
    }

    // Tracking
    /// How far the pill moves at full progress; past the commit threshold it moves with resistance.
    static let maxOffset: CGFloat = 56
    static let resistance: CGFloat = 0.35
    // Revealing the target
    /// The swipe must have lasted this long, and be slower than `revealSpeed`, before the target shows.
    static let revealDelay: TimeInterval = 0.25
    /// Progress per second (1 = a quarter of the trackpad's width).
    static let revealSpeed: CGFloat = 1.2
    static let speedWindow: TimeInterval = 0.12
    // Layout
    static let height: CGFloat = 56
    static let ringInset: CGFloat = 8
    static let ringSize: CGFloat = 40
    static let maxTextWidth: CGFloat = 260
    static let margin: CGFloat = 24
    // Motion: one family of quick ease-outs, as for a small floating element
    static let easeOut = CAMediaTimingFunction(controlPoints: 0.165, 0.84, 0.44, 1)
    static let fadeIn: TimeInterval = 0.12
    static let dismiss: TimeInterval = 0.2
    static let reveal: TimeInterval = 0.22

    private var panel: NSPanel?
    private let track = NSView()
    private let pill = NSVisualEffectView()
    private let ring = RingView(frame: NSRect(x: 0, y: 0, width: SwipeOverlay.ringSize, height: SwipeOverlay.ringSize))
    private let nameLabel = NSTextField(labelWithString: "")
    private let appsLabel = NSTextField(labelWithString: "")

    private var left: Target?
    private var right: Target?
    /// The progress past which lifting the fingers switches; the ring is full there.
    private var threshold: CGFloat = 0.5
    private var progress: CGFloat = 0
    private var willCommit = false
    private var isTracking = false
    private var isRevealed = false
    private var began: TimeInterval = 0
    private var samples: [(time: TimeInterval, progress: CGFloat)] = []
    private var revealTimer: Timer?
    /// Bumped by every `begin`, so a fade-out that finishes late doesn't hide the next swipe's pill.
    private var generation = 0

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var target: Target? { progress < 0 ? left : right }

    /// Shows the pill centred on `screenFrame` (AppKit coordinates). `left`/`right`: where a swipe in that
    /// direction goes, nil when there is no workspace that way. `threshold`: the progress (0…1) past which
    /// lifting the fingers switches.
    func begin(on screenFrame: NSRect, left: Target?, right: Target?, threshold: CGFloat) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        generation += 1
        self.left = left
        self.right = right
        self.threshold = threshold
        progress = 0
        willCommit = false
        isTracking = true
        isRevealed = false
        began = ProcessInfo.processInfo.systemUptime
        samples = []

        let size = NSSize(width: Self.ringInset * 2 + Self.ringSize + Self.maxTextWidth + 24 + Self.maxOffset * 2 + Self.margin * 2,
                          height: Self.height + Self.margin * 2)
        panel.setFrame(NSRect(x: (screenFrame.midX - size.width / 2).rounded(), y: (screenFrame.midY - size.height / 2).rounded(),
                              width: size.width, height: size.height), display: false)
        for view in [track, pill, nameLabel, appsLabel] { view.layer?.removeAllAnimations() }
        track.frame = panel.contentView!.bounds
        nameLabel.alphaValue = 0
        appsLabel.alphaValue = 0
        layoutPill(width: Self.height, textWidth: 0, animated: false)
        ring.set(progress: 0, willCommit: false, hasTarget: true, animated: false)
        ring.setDirection(left: true) // Where a swipe to the right goes, as for progress 0

        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeIn
            context.timingFunction = Self.easeOut
            panel.animator().alphaValue = 1
        }

        revealTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkReveal() }
        }
        RunLoop.main.add(timer, forMode: .common)
        revealTimer = timer
    }

    /// `progress`: −1…1, negative to the left. `willCommit`: whether lifting the fingers now switches.
    func update(progress: CGFloat, willCommit: Bool) {
        guard isTracking else { return }
        let sideChanged = (progress < 0) != (self.progress < 0)
        let crossed = willCommit != self.willCommit
        self.progress = progress
        self.willCommit = willCommit
        samples.append((ProcessInfo.processInfo.systemUptime, progress))

        // The pill is the fingers: written directly, no animation.
        track.setFrameOrigin(NSPoint(x: offset(for: progress), y: 0))
        if sideChanged {
            // Towards the workspace the swipe goes to, which slides in from the side the fingers move away from.
            ring.setDirection(left: progress >= 0)
            if isRevealed { showTarget(animated: true) }
        }
        ring.set(progress: min(abs(progress) / threshold, 1), willCommit: willCommit,
                 hasTarget: target != nil, animated: false)
        if crossed {
            ring.pop(growing: willCommit, reduceMotion: reduceMotion)
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    /// The swipe switched workspaces: the pill carries on the way it was going and fades.
    func commit() {
        guard finishTracking() else { return }
        let push = reduceMotion ? 0 : (progress < 0 ? -1 : 1) * Self.maxOffset * 0.5
        fadeOut(trackX: track.frame.minX + push)
    }

    /// The swipe didn't switch: the pill returns to the middle and fades.
    func cancel() {
        guard finishTracking() else { return }
        ring.set(progress: 0, willCommit: false, hasTarget: target != nil, animated: true)
        fadeOut(trackX: reduceMotion ? track.frame.minX : 0)
    }

    /// Hides the pill at once, e.g. when Silk stops.
    func close() {
        _ = finishTracking()
        generation += 1
        panel?.orderOut(nil)
    }

    // MARK: Tracking

    /// 1:1 up to the commit threshold, then with resistance, so the pill never runs off.
    private func offset(for progress: CGFloat) -> CGFloat {
        let threshold = self.threshold
        let resisted = { (value: CGFloat) in value <= threshold ? value : threshold + (value - threshold) * Self.resistance }
        return (progress < 0 ? -1 : 1) * resisted(abs(progress)) / resisted(1) * Self.maxOffset
    }

    private func checkReveal() {
        guard isTracking, !isRevealed else { return }
        let now = ProcessInfo.processInfo.systemUptime
        samples.append((now, progress))
        samples.removeAll { now - $0.time > Self.speedWindow * 2 }
        guard now - began >= Self.revealDelay,
              let reference = samples.first(where: { now - $0.time <= Self.speedWindow }),
              let oldest = samples.first, now - oldest.time >= Self.speedWindow * 0.8 else { return }
        let speed = abs(progress - reference.progress) / max(now - reference.time, 0.001)
        guard speed < Self.revealSpeed else { return }
        isRevealed = true
        showTarget(animated: true)
    }

    private func showTarget(animated: Bool) {
        let target = self.target
        nameLabel.stringValue = target?.name ?? "No workspace this way"
        appsLabel.stringValue = target.map { $0.appNames.isEmpty ? "Empty" : $0.appNames.joined(separator: " · ") } ?? ""
        // The labels' own size can be stale while they're squeezed; measure the text (plus the cell's padding).
        let measure = { (label: NSTextField) in label.attributedStringValue.size().width + 6 }
        let textWidth = min(max(measure(nameLabel), measure(appsLabel)), Self.maxTextWidth)
        let width = Self.ringInset + Self.ringSize + 10 + textWidth.rounded(.up) + 18
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated && !reduceMotion ? Self.reveal : 0
            context.timingFunction = Self.easeOut
            layoutPill(width: width, textWidth: textWidth, animated: true)
            nameLabel.animator().alphaValue = 1
            appsLabel.animator().alphaValue = appsLabel.stringValue.isEmpty ? 0 : 1
        }
    }

    private func finishTracking() -> Bool {
        revealTimer?.invalidate()
        revealTimer = nil
        guard isTracking else { return false }
        isTracking = false
        return true
    }

    private func fadeOut(trackX: CGFloat) {
        guard let panel else { return }
        let generation = self.generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.dismiss
            context.timingFunction = Self.easeOut
            track.animator().setFrameOrigin(NSPoint(x: trackX, y: 0))
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation, !self.isTracking else { return }
                self.panel?.orderOut(nil)
            }
        }
    }

    // MARK: Views

    /// Sizes the pill around its centre; the labels sit at their final place and the pill uncovers them.
    private func layoutPill(width: CGFloat, textWidth: CGFloat, animated: Bool) {
        let bounds = track.bounds
        let frame = NSRect(x: (bounds.midX - width / 2).rounded(), y: (bounds.midY - Self.height / 2).rounded(),
                           width: width, height: Self.height)
        (animated ? pill.animator() : pill).frame = frame
        let textX = Self.ringInset + Self.ringSize + 10
        nameLabel.frame = NSRect(x: textX, y: Self.height / 2 + 1, width: max(textWidth, 1), height: 18)
        appsLabel.frame = NSRect(x: textX, y: Self.height / 2 - 17, width: max(textWidth, 1), height: 16)
        if appsLabel.stringValue.isEmpty { nameLabel.frame.origin.y = (Self.height - 18) / 2 }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = true

        let content = NSView()
        content.wantsLayer = true
        panel.contentView = content
        track.autoresizingMask = [.height]
        content.addSubview(track)

        pill.material = .hudWindow
        pill.blendingMode = .behindWindow
        pill.state = .active
        pill.appearance = NSAppearance(named: .vibrantDark)
        pill.wantsLayer = true
        pill.layer?.cornerRadius = Self.height / 2
        pill.layer?.cornerCurve = .continuous
        pill.layer?.masksToBounds = true
        pill.layer?.borderWidth = 0.5
        pill.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        track.addSubview(pill)

        ring.frame.origin = NSPoint(x: Self.ringInset, y: (Self.height - Self.ringSize) / 2)
        pill.addSubview(ring)

        nameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        nameLabel.textColor = .labelColor
        appsLabel.font = .systemFont(ofSize: 12)
        appsLabel.textColor = .secondaryLabelColor
        for label in [nameLabel, appsLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.wantsLayer = true
            pill.addSubview(label)
        }
        return panel
    }
}

/// A ring that fills up to the commit threshold around a chevron pointing towards the target workspace; past the
/// threshold it fills with the accent colour.
private final class RingView: NSView {
    private let content = CALayer()
    private let trackRing = CAShapeLayer()
    private let progressRing = CAShapeLayer()
    private let fill = CAShapeLayer()
    private let chevron = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let bounds = CGRect(origin: .zero, size: frame.size)
        content.frame = bounds
        layer?.addSublayer(content)

        trackRing.path = CGPath(ellipseIn: bounds.insetBy(dx: 2, dy: 2), transform: nil)
        fill.path = CGPath(ellipseIn: bounds.insetBy(dx: 1, dy: 1), transform: nil)
        fill.fillColor = NSColor.controlAccentColor.cgColor
        fill.opacity = 0
        for ring in [trackRing, progressRing] {
            ring.fillColor = nil
            ring.lineWidth = 3
            ring.lineCap = .round
        }
        trackRing.strokeColor = NSColor.white.withAlphaComponent(0.16).cgColor
        progressRing.strokeColor = NSColor.white.withAlphaComponent(0.7).cgColor
        progressRing.strokeEnd = 0

        chevron.frame = bounds
        chevron.fillColor = nil
        chevron.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
        chevron.lineWidth = 2.5
        chevron.lineCap = .round
        chevron.lineJoin = .round
        for sublayer in [fill, trackRing, progressRing, chevron] { content.addSublayer(sublayer) }
        setDirection(left: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Points the chevron left or right; the ring fills from the top towards that side.
    func setDirection(left: Bool) {
        let arc = CGMutablePath()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        // The layer's y axis points up, so `clockwise` reads as on screen.
        arc.addArc(center: center, radius: bounds.width / 2 - 2, startAngle: .pi / 2,
                   endAngle: left ? .pi / 2 + 2 * .pi : .pi / 2 - 2 * .pi, clockwise: !left)
        let mid = bounds.midX, midY = bounds.midY, arm: CGFloat = 6
        let tip = left ? mid - arm / 2 - 1 : mid + arm / 2 + 1
        let back = left ? tip + arm : tip - arm
        let path = CGMutablePath()
        path.move(to: CGPoint(x: back, y: midY + arm))
        path.addLine(to: CGPoint(x: tip, y: midY))
        path.addLine(to: CGPoint(x: back, y: midY - arm))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chevron.path = path
        progressRing.path = arc
        CATransaction.commit()
    }

    /// `fraction`: how far to the commit threshold, 0…1.
    func set(progress fraction: CGFloat, willCommit: Bool, hasTarget: Bool, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(SwipeOverlay.dismiss)
        progressRing.strokeEnd = fraction
        CATransaction.commit()

        // State colours change with a short fade, never per frame.
        let fillOpacity: Float = willCommit ? 1 : 0
        let chevronAlpha: CGFloat = hasTarget ? (willCommit ? 1 : 0.85) : 0.3
        guard fill.opacity != fillOpacity || chevron.opacity != Float(chevronAlpha) else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        fill.opacity = fillOpacity
        chevron.opacity = Float(chevronAlpha)
        progressRing.opacity = willCommit ? 0 : (hasTarget ? 1 : 0.3)
        CATransaction.commit()
    }

    /// A small scale pop when crossing into "will switch", a settle when crossing back.
    func pop(growing: Bool, reduceMotion: Bool) {
        guard !reduceMotion else { return }
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = growing ? 1.18 : 0.92
        spring.toValue = 1
        spring.damping = 12
        spring.stiffness = 300
        spring.mass = 1
        spring.duration = spring.settlingDuration
        content.add(spring, forKey: "pop")
    }
}
