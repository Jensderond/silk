import CoreGraphics

struct ResizeCommand: ParsableCommand {
    enum Dimension: String, CaseIterable {
        case width, height, smart
        case smartOpposite = "smart-opposite"
    }

    enum Units: Equatable {
        case set(UInt)
        case add(UInt)
        case subtract(UInt)
    }

    static let kind = CommandKind.resize
    static let help = HelpText.resize
    static let parser = ArgParser<Self>(
        flags: ["--window-id": .windowId],
        positional: [
            .mandatory(\.dimension, placeholder: "(smart|smart-opposite|width|height)", parseEnumArg(Dimension.self)),
            .mandatory(\.units, placeholder: "[+|-]<number>") { input in
                guard let number = UInt(input.arg.removingPrefix("+").removingPrefix("-")) else {
                    return .failure("<number> argument must be a number", advanceBy: 1)
                }
                if input.arg.hasPrefix("+") { return .success(.add(number), advanceBy: 1) }
                if input.arg.hasPrefix("-") { return .success(.subtract(number), advanceBy: 1) }
                return .success(.set(number), advanceBy: 1)
            },
        ]
    )

    var common: CommonArgs
    var dimension = Dimension.smart
    var units = Units.set(0)
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    static func parse(_ args: [String]) -> ParsedCmd<ResizeCommand> {
        parser.parse(ResizeCommand(rawArgs: args), args, help: help, isNegativeNumberAllowed: true)
    }

    func run(_ context: CommandContext) -> Int32 {
        guard let target = context.resolveTarget(common) else { return ExitCode.fail }
        let candidates = target.window?.parentsWithSelf.filter { ($0.parent as? TilingContainer)?.layout == .tiles } ?? []
        func parentOrientation(_ node: TreeNode) -> Orientation? { (node.parent as? TilingContainer)?.orientation }

        let orientation: Orientation?
        let node: TreeNode?
        switch dimension {
            case .width:
                orientation = .h
                node = candidates.first { parentOrientation($0) == .h }
            case .height:
                orientation = .v
                node = candidates.first { parentOrientation($0) == .v }
            case .smart:
                node = candidates.first
                orientation = node.flatMap(parentOrientation)
            case .smartOpposite:
                orientation = candidates.first.flatMap(parentOrientation)?.opposite
                node = candidates.first { parentOrientation($0) == orientation }
        }
        guard let node, let parent = node.parent as? TilingContainer else {
            return context.io.fail("resize command doesn't support floating windows yet https://github.com/nikitabobko/AeroSpace/issues/9")
        }
        guard let orientation else { return ExitCode.fail }
        let diff: CGFloat = switch units {
            case .set(let value): CGFloat(value) - node.getWeight(orientation)
            case .add(let value): CGFloat(value)
            case .subtract(let value): -CGFloat(value)
        }
        guard let childDiff = diff.divided(by: parent.children.count - 1) else { return ExitCode.fail }
        for sibling in parent.children where sibling !== node {
            sibling.setWeight(parent.orientation, sibling.getWeight(parent.orientation) - childDiff)
        }
        node.setWeight(orientation, node.getWeight(orientation) + diff)
        return ExitCode.success
    }
}
