import AppKit
import Testing
@testable import SilkAnimation

@MainActor
@Suite struct AnimatorTests {
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func disabledAnimatorSnapsAndReportsCompletionOnMain() async throws {
        let sink = RecordingSink()
        let animator = Animator(sink: sink, settings: AnimationSettings(isEnabled: false))
        var completions: [AnimationCompletion] = []
        var frames: [UInt32: CGRect] = [:]
        animator.onComplete = { window, epoch in
            MainActor.assumeIsolated { completions.append(AnimationCompletion(window: window, epoch: epoch)) }
        }
        animator.onFrame = { window, frame in
            MainActor.assumeIsolated { frames[window] = frame }
        }
        let to = CGRect(x: 100, y: 100, width: 400, height: 300)
        animator.apply(AnimationRequest(epoch: 5, moves: [
            .init(window: 9, pid: 1, from: .zero, to: to, kind: .layout, displayID: 0),
        ]))
        try await waitUntil { !completions.isEmpty }
        #expect(sink.writes == [FrameWrite(window: 9, frame: to, epoch: 5, mode: .final)])
        #expect(completions == [AnimationCompletion(window: 9, epoch: 5)])
        #expect(frames == [9: to])
        #expect(animator.presentedFrame(window: 9) == nil)
    }

    /// Display links do not fire while the display sleeps; the watchdog must still end the
    /// tween with its final write shortly after the deadline.
    @Test func everyMoveEndsWithItsFinalWrite() async throws {
        let sink = RecordingSink()
        let animator = Animator(sink: sink, settings: AnimationSettings(duration: 0.1, curve: .easeOut, respectReduceMotion: false))
        let to = CGRect(x: 600, y: 100, width: 400, height: 300)
        let screen = (NSScreen.screens.first?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        animator.apply(AnimationRequest(epoch: 1, moves: [
            .init(window: 3, pid: 1, from: CGRect(x: 0, y: 100, width: 300, height: 300), to: to, kind: .layout, displayID: screen),
        ]))
        try await waitUntil { sink.writes.last?.isFinal == true }
        #expect(sink.writes.last == FrameWrite(window: 3, frame: to, epoch: 1, mode: .final))
        #expect(sink.writes.filter(\.isFinal).count == 1)
    }
}

@Suite struct CornerRadiusTests {
    private func bitmap(radius: CGFloat, scale: Int) -> NSBitmapImageRep {
        let points = 80
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: points * scale, pixelsHigh: points * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = NSSize(width: points, height: points)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: points, height: points), xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    @Test(arguments: [(8.0, 1), (12.0, 2), (16.0, 2), (26.0, 2), (26.0, 4)])
    func scanRecoversRadius(radius: Double, scale: Int) throws {
        let measured = try #require(WindowCornerRadius.cornerRadius(scanning: bitmap(radius: radius, scale: scale)))
        #expect(abs(Double(measured) - radius) <= 0.5)
    }

    @Test func squareCornerYieldsNil() {
        #expect(WindowCornerRadius.cornerRadius(scanning: bitmap(radius: 0, scale: 2)) == nil)
    }

    @MainActor
    @Test func systemDefaultIsPlausible() {
        let titlebar = WindowCornerRadius.systemDefault(for: .titlebar)
        let toolbar = WindowCornerRadius.systemDefault(for: .toolbar)
        #expect(titlebar >= 4 && titlebar <= 40)
        #expect(toolbar >= titlebar)
    }
}
