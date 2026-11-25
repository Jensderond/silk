import AppKit
import SilkConfig
import SwiftUI

/// The Settings window (menu bar → Settings…).
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let store: SettingsStore
    /// Names of the workspaces that exist right now, for the workspace pickers.
    private let workspaces: () -> [String]

    init(store: SettingsStore, workspaces: @escaping () -> [String]) {
        self.store = store
        self.workspaces = workspaces
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Silk Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: SettingsView(store: store, workspaces: workspaces()))
        window.setContentSize(NSSize(width: 700, height: 620))
        window.contentMinSize = NSSize(width: 640, height: 360)
        window.center()
        return window
    }
}

private struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    let workspaces: [String]
    /// The rule being dragged to another place, if any.
    @State private var drag = ReorderDrag()
    /// The rule whose drag handle the pointer holds. When that ends with the rule still lifted, the drag was cancelled.
    @GestureState private var held: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                rulesSection
                trackpadSection
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Rules for where apps go").font(.system(size: 15, weight: .semibold))
                Text("Rules are checked from top to bottom and the first match wins.")
                    .foregroundStyle(.secondary)
            }
            if !store.settings.rules.isEmpty {
                VStack(spacing: ReorderDrag.spacing) {
                    ForEach(Array(store.settings.rules.enumerated()), id: \.element.id) { index, rule in
                        RuleCard(
                            rule: binding(for: rule.id, fallback: rule),
                            number: drag.number(at: index),
                            workspaces: workspaces,
                            handle: handleGesture(for: rule.id),
                            step: { move(rule.id, by: $0) },
                            delete: { store.settings.rules.removeAll { $0.id == rule.id } }
                        )
                        .modifier(Reorderable(id: rule.id, drag: drag))
                    }
                }
                .background(alignment: .top) { DropSlot(drag: drag) }
                // A lifted card passes over the buttons below the list, not under them.
                .zIndex(1)
                .coordinateSpace(.named(Self.rulesSpace))
                .onChange(of: held) { was, _ in
                    if let was { drag.cancel(was) }
                }
            }
            HStack(spacing: 8) {
                AddRuleButton(title: "Send an app to a workspace", detail: "Its windows open there every time.") {
                    add(.sendToWorkspace)
                }
                AddRuleButton(title: "Leave a window alone", detail: "Windows with a certain title are never tiled.") {
                    add(.leaveAlone)
                }
            }
        }
    }

    private var trackpadSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trackpad").font(.system(size: 15, weight: .semibold))
            HStack(spacing: 16) {
                SwipeGlyph()
                VStack(alignment: .leading, spacing: 3) {
                    Text("Next or previous workspace").fontWeight(.semibold)
                    Text("Three-finger swipe: left for the next workspace, right for the previous one.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Toggle("Three-finger swipe between workspaces", isOn: $store.settings.swipeBetweenWorkspaces)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .padding(14)
            .card()
            Text("macOS uses the same swipe to switch between full-screen apps. To keep it from reacting too, set that gesture to four fingers in System Settings › Trackpad › More Gestures.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A binding to the rule with `id` that stays valid while rows are added, removed and moved.
    private func binding(for id: UUID, fallback: AppSettings.Rule) -> SwiftUI.Binding<AppSettings.Rule> {
        SwiftUI.Binding(
            get: { store.settings.rules.first { $0.id == id } ?? fallback },
            set: { new in
                guard let index = store.settings.rules.firstIndex(where: { $0.id == id }) else { return }
                store.settings.rules[index] = new
            }
        )
    }

    private func add(_ kind: AppSettings.Rule.Kind) {
        var rule = AppSettings.Rule(kind: kind)
        rule.workspace = workspaces.first ?? ""
        store.settings.rules.append(rule)
    }

    private static let rulesSpace = "rules"

    /// Dragging a rule's handle: the card follows the pointer, and the order changes once, when it is let go.
    private func handleGesture(for id: UUID) -> some Gesture {
        // Measured in the list, not in the card: the card moves with the pointer.
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.rulesSpace))
            .updating($held) { _, held, _ in held = id }
            .onChanged { value in
                if drag.lifted != id { drag.begin(id, in: store.settings.rules.map(\.id)) }
                drag.move(by: value.translation.height)
            }
            .onEnded { value in
                drag.end(velocity: value.velocity.height, reduceMotion: reduceMotion) { from, to in
                    var rules = store.settings.rules
                    rules.insert(rules.remove(at: from), at: to)
                    store.settings.rules = rules
                }
            }
    }

    /// Moves a rule one place up (-1) or down (1), for those who can't drag.
    private func move(_ id: UUID, by step: Int) {
        var rules = store.settings.rules
        guard let from = rules.firstIndex(where: { $0.id == id }), rules.indices.contains(from + step) else { return }
        rules.swapAt(from, from + step)
        withAnimation(.snappy(duration: 0.25)) { store.settings.rules = rules }
    }
}

/// One drag of a rule to another place in the list.
///
/// While the pointer is down the lifted card sits exactly under it and the list itself keeps its order: the other
/// cards only shift aside, and `DropSlot` marks where the card would land. Letting go changes the order.
@MainActor @Observable
private final class ReorderDrag {
    static let spacing: CGFloat = 8

    /// The rule that is lifted.
    private(set) var lifted: UUID?
    /// How far the lifted card is from its own place. Only that card reads this, so only it updates per pointer move.
    private(set) var translation: CGFloat = 0
    /// The index the lifted rule gets when it is let go now.
    private(set) var target = 0
    /// The rule that was lifted last; it stays in front of the others while it settles.
    private(set) var last: UUID?

    /// Card heights, as laid out.
    @ObservationIgnored var heights: [UUID: CGFloat] = [:]
    @ObservationIgnored private var order: [UUID] = []
    @ObservationIgnored private var from = 0
    /// Top and height of every card as the drag began.
    @ObservationIgnored private var tops: [CGFloat] = []
    @ObservationIgnored private var sizes: [CGFloat] = []

    private static let shift = Animation.interpolatingSpring(duration: 0.3, bounce: 0)

    func begin(_ id: UUID, in order: [UUID]) {
        guard let index = order.firstIndex(of: id) else { return }
        self.order = order
        from = index
        sizes = order.map { heights[$0] ?? 56 }
        tops = sizes.indices.map { sizes[..<$0].reduce(0, +) + CGFloat($0) * Self.spacing }
        translation = 0
        target = index
        last = id
        lifted = id
        NSCursor.closedHand.push()
    }

    /// Follows the pointer, `distance` from where the drag began.
    func move(by distance: CGFloat) {
        guard lifted != nil else { return }
        translation = Self.rubberBand(distance, within: -tops[from]...(tops[tops.count - 1] + sizes[sizes.count - 1] - tops[from] - sizes[from]))
        // The card takes a neighbour's place once its leading edge is past the middle of that neighbour.
        let top = tops[from] + translation, bottom = top + sizes[from]
        var new = from
        while new > 0, top < tops[new - 1] + sizes[new - 1] / 2 { new -= 1 }
        if new == from {
            while new < order.count - 1, bottom > tops[new + 1] + sizes[new + 1] / 2 { new += 1 }
        }
        if new != target { withAnimation(Self.shift) { target = new } }
    }

    /// Lets go: the rule moves to `target` through `commit(from, to)` and the card settles there, leaving the pointer
    /// at the speed it had.
    func end(velocity: CGFloat, reduceMotion: Bool, commit: (Int, Int) -> Void) {
        guard lifted != nil else { return }
        let distance = slotTop - (tops[from] + translation)
        // The spring wants the speed as a share of the distance to go per second.
        let speed = reduceMotion || abs(distance) < 1 ? 0 : min(max(velocity / distance, -15), 15)
        let settle = reduceMotion
            ? Animation.interpolatingSpring(duration: 0.2, bounce: 0)
            : Animation.interpolatingSpring(duration: 0.35, bounce: 0.2, initialVelocity: speed)
        // One transaction for the new order and the dropped offsets: a neighbour's new place makes up for the shift
        // it loses, so only the lifted card is seen to move.
        withAnimation(settle) {
            if target != from { commit(from, target) }
            lifted = nil
        }
        NSCursor.pop()
    }

    /// Puts the card of `id` back if it is still lifted; the order stays as it was.
    func cancel(_ id: UUID) {
        guard lifted == id else { return }
        withAnimation(Self.shift) { lifted = nil }
        NSCursor.pop()
    }

    /// Top and height of the place the lifted card would land in.
    var slot: (top: CGFloat, height: CGFloat)? {
        lifted == nil ? nil : (slotTop, sizes[from])
    }

    private var slotTop: CGFloat {
        target <= from ? tops[target] : tops[target] + sizes[target] - sizes[from]
    }

    /// How far the card of `id` stands aside for the lifted one.
    func shift(for id: UUID) -> CGFloat {
        guard lifted != nil, let index = order.firstIndex(of: id) else { return 0 }
        let step = sizes[from] + Self.spacing
        if from < index, index <= target { return -step }
        if target <= index, index < from { return step }
        return 0
    }

    /// The number the rule at `index` gets if the lifted one is let go now.
    func number(at index: Int) -> Int {
        guard lifted != nil else { return index + 1 }
        if index == from { return target + 1 }
        if from < index, index <= target { return index }
        if target <= index, index < from { return index + 2 }
        return index + 1
    }

    /// `value` within `limits`; past them it gives way less and less, so the ends of the list feel like ends.
    private static func rubberBand(_ value: CGFloat, within limits: ClosedRange<CGFloat>) -> CGFloat {
        let give: CGFloat = 60
        func resist(_ over: CGFloat) -> CGFloat { give * (1 - 1 / (over * 0.5 / give + 1)) }
        if value < limits.lowerBound { return limits.lowerBound - resist(limits.lowerBound - value) }
        if value > limits.upperBound { return limits.upperBound + resist(value - limits.upperBound) }
        return value
    }
}

/// Makes a rule card take part in a drag: lifted and under the pointer, or standing aside for the lifted one.
private struct Reorderable: ViewModifier {
    let id: UUID
    let drag: ReorderDrag
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let lifted = drag.lifted == id
        content
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { drag.heights[id] = $0 }
            .animation(.snappy(duration: 0.18)) { card in
                card
                    .scaleEffect(lifted && !reduceMotion ? 1.015 : 1)
                    .shadow(color: .black.opacity(lifted ? 0.22 : 0), radius: lifted ? 14 : 0, y: lifted ? 6 : 0)
            }
            .offset(y: lifted ? drag.translation : drag.shift(for: id))
            // Under the pointer the card is never animated: it is where the pointer is.
            .transaction { if lifted { $0.animation = nil } }
            .zIndex(lifted ? 2 : drag.last == id ? 1 : 0)
    }
}

/// The ghost of the lifted card: a dashed outline in the place it lands when let go.
private struct DropSlot: View {
    let drag: ReorderDrag

    var body: some View {
        if let slot = drag.slot {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                )
                .frame(height: slot.height)
                .offset(y: slot.top)
                .transition(.opacity)
                .accessibilityHidden(true)
        }
    }
}

/// One rule as a numbered card that reads as a sentence.
private struct RuleCard<Handle: Gesture>: View {
    @SwiftUI.Binding var rule: AppSettings.Rule
    let number: Int
    let workspaces: [String]
    /// The drag that moves this rule, for its handle.
    let handle: Handle
    /// Moves this rule one place up (-1) or down (1).
    let step: (Int) -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // As tall as the card and wider than the glyph: an easy target.
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .frame(width: 30)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(handle)
                .onHover { inside in
                    if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
                }
                .help("Drag to change the order")
                .accessibilityLabel("Rule \(number), drag to change the order")
                .accessibilityAction(named: "Move up") { step(-1) }
                .accessibilityAction(named: "Move down") { step(1) }
            Text("\(number)")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.primary.opacity(0.08)))
            sentence
            Spacer(minLength: 0)
            Button(action: delete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this rule")
            .accessibilityLabel("Delete rule \(number)")
        }
        .padding(.leading, 2)
        .padding(.trailing, 12)
        .frame(minHeight: 56)
        .fixedSize(horizontal: false, vertical: true)
        .card()
    }

    @ViewBuilder private var sentence: some View {
        switch rule.kind {
            case .sendToWorkspace:
                HStack(spacing: 6) {
                    Text("When")
                    appMenu
                    Text("opens, send it to workspace")
                    Picker("Workspace", selection: $rule.workspace) {
                        ForEach(workspaceChoices, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            case .leaveAlone:
                HStack(spacing: 6) {
                    Text("Leave a window alone when its title contains")
                        .fixedSize()
                    TextField("Title", text: $rule.title, prompt: Text("Part of the title"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                }
        }
    }

    /// The existing workspaces, plus the rule's own when it names one that doesn't exist (yet).
    private var workspaceChoices: [String] {
        workspaces.contains(rule.workspace) || rule.workspace.isEmpty ? workspaces : workspaces + [rule.workspace]
    }

    private var appMenu: some View {
        Menu {
            ForEach(Self.runningApps, id: \.id) { app in
                Button(app.name) { choose(id: app.id, name: app.name) }
            }
            Divider()
            Button("Other…") { chooseFromDisk() }
        } label: {
            if let icon = Self.icon(forApp: rule.appId) { Image(nsImage: icon) }
            Text(rule.appId.isEmpty ? "Choose App" : (rule.appName.isEmpty ? rule.appId : rule.appName))
        }
        .fixedSize()
    }

    private func choose(id: String, name: String) {
        rule.appId = id
        rule.appName = name
    }

    private func chooseFromDisk() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        choose(id: id, name: FileManager.default.displayName(atPath: url.path(percentEncoded: false)).replacingOccurrences(of: ".app", with: ""))
    }

    /// The app's icon at menu size; nil when the app isn't installed (or none is chosen).
    private static func icon(forApp bundleId: String) -> NSImage? {
        guard !bundleId.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    /// Apps with a Dock icon that are running now, by name.
    private static var runningApps: [(id: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in app.bundleIdentifier.map { (id: $0, name: app.localizedName ?? $0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// A dashed tile that adds one kind of rule and says what that kind does.
private struct AddRuleButton: View {
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Label(title, systemImage: "plus")
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.accentColor)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
        }
        .buttonStyle(.plain)
    }
}

/// A small trackpad with three fingers and arrows to both sides.
private struct SwipeGlyph: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.left").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Circle().fill(Color.accentColor).frame(width: 8, height: 8)
            Circle().fill(Color.accentColor).frame(width: 8, height: 8).offset(y: -4)
            Circle().fill(Color.accentColor).frame(width: 8, height: 8)
            Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
        }
        .frame(width: 84, height: 58)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1.5))
        .accessibilityHidden(true)
    }
}

private extension View {
    /// The white rounded box rules and the trackpad row sit in.
    func card() -> some View {
        background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}
