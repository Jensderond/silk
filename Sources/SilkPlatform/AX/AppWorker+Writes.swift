import ApplicationServices

/// Frame writes. `scheduleDrain` is called from any thread; everything else runs on the worker thread.
extension AppWorker {
    /// `AXEnhancedUserInterface` is restored after this long without writes.
    static let enhancedUserInterfaceRestoreDelay: TimeInterval = 0.3

    func scheduleDrain(_ drain: @escaping () -> Void) -> Bool {
        perform(drain)
    }

    func performFrameWrites(_ writes: [FrameWrite]) {
        beginWriteBurst()
        for write in writes {
            guard let window = windows[write.window] else { continue }
            if !apply(write, to: window) { windowGone(write.window) }
        }
        endWriteBurst()
    }

    func performBlockingRestore(_ frames: [(UInt32, CGRect)], completion: @escaping (Set<UInt32>) -> Void) {
        // A stopped worker (its app just quit) never runs the block; don't keep the caller waiting.
        let accepted = perform { [self] in
            beginWriteBurst()
            var written = Set<UInt32>()
            for (id, frame) in frames {
                guard let window = windows[id] else { continue }
                window.echo.record(frame, at: MonotonicClock.now())
                if writeFinal(frame, to: window.element) { written.insert(id) }
            }
            cancel(&enhancedUserInterfaceRestoreTimer)
            if isEnhancedUserInterfaceCleared { restoreEnhancedUserInterface() }
            completion(written)
        }
        if !accepted { completion([]) }
    }

    /// Returns false when the window turned out to be gone.
    private func apply(_ write: FrameWrite, to window: TrackedWindow) -> Bool {
        let element = window.element
        window.echo.record(write.frame, at: MonotonicClock.now())
        switch write.mode {
            case .final:
                guard writeFinal(write.frame, to: element) else { return false }
                let (error, readBack) = element.frame()
                if error == .invalidUIElement { return false }
                if let readBack {
                    window.echo.record(readBack, at: MonotonicClock.now())
                    window.snapshot.frame = readBack
                    environment.emit(.frameApplied(window.id, readBack))
                }
                return true
            case .intermediate(let setSize, let sizeFirst):
                if setSize && sizeFirst, timedWrite(.size, write.frame, element) == .invalidUIElement { return false }
                if timedWrite(.position, write.frame, element) == .invalidUIElement { return false }
                if setSize && !sizeFirst, timedWrite(.size, write.frame, element) == .invalidUIElement { return false }
                window.snapshot.frame = write.frame
                return true
        }
    }

    /// `size, position, size` (AeroSpace #143, #335: the first size write makes room so the
    /// position isn't clamped; the second applies the size the position may have clamped).
    private func writeFinal(_ frame: CGRect, to element: AXUIElement) -> Bool {
        timedWrite(.size, frame, element) != .invalidUIElement &&
            timedWrite(.position, frame, element) != .invalidUIElement &&
            timedWrite(.size, frame, element) != .invalidUIElement
    }

    private func timedWrite(_ attribute: FrameWriteAttribute, _ frame: CGRect, _ element: AXUIElement) -> AXError {
        let start = MonotonicClock.now()
        let error = switch attribute {
            case .position: element.setPosition(frame.origin)
            case .size: element.setSize(frame.size)
        }
        let elapsed = MonotonicClock.now() - start
        let timedOut = error == .cannotComplete && elapsed >= Double(axMessagingTimeout) * 0.5
        environment.writer.recordLatency(pid: pid, attribute: attribute, milliseconds: elapsed * 1000, timedOut: timedOut)
        return error
    }

    // MARK: - AXEnhancedUserInterface

    /// Apps with `AXEnhancedUserInterface` on (set by assistive tools) animate every frame change.
    /// It is read once per app, cleared on the first write of a burst and restored after
    /// ``enhancedUserInterfaceRestoreDelay`` without writes.
    private func beginWriteBurst() {
        cancel(&enhancedUserInterfaceRestoreTimer)
        if enhancedUserInterfaceWasOn == nil {
            enhancedUserInterfaceWasOn = appElement.bool(AXAttribute.enhancedUserInterface) ?? false
        }
        if enhancedUserInterfaceWasOn == true && !isEnhancedUserInterfaceCleared {
            appElement.set(AXAttribute.enhancedUserInterface, kCFBooleanFalse)
            isEnhancedUserInterfaceCleared = true
        }
    }

    private func endWriteBurst() {
        guard isEnhancedUserInterfaceCleared else { return }
        enhancedUserInterfaceRestoreTimer = schedule(after: Self.enhancedUserInterfaceRestoreDelay) { [self] in
            enhancedUserInterfaceRestoreTimer = nil
            restoreEnhancedUserInterface()
        }
    }

    func restoreEnhancedUserInterface() {
        appElement.set(AXAttribute.enhancedUserInterface, kCFBooleanTrue)
        isEnhancedUserInterfaceCleared = false
    }
}
