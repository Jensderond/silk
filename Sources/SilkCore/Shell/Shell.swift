/// A parsed AeroSpace shell expression (AeroSpace 0.21 grammar): commands combined with `|`, `&&`, `||`, `;`
/// and parentheses.
indirect enum Shell<T> {
    case empty
    case cmd(T)
    // Listed in precedence order
    case pipe([Shell<T>])
    case and([Shell<T>])
    case or([Shell<T>])
    case seq([Shell<T>])

    static func compound(_ elements: [Shell<T>], _ constructor: ([Shell<T>]) -> Shell<T>) -> Shell<T> {
        switch elements.count {
            case 0: .empty
            case 1: elements[0]
            default: constructor(elements)
        }
    }

    func flatMap<R>(_ transform: (T) -> ParsedCmd<R>) -> ParsedCmd<Shell<R>> {
        func all(_ shells: [Shell<T>], _ constructor: ([Shell<R>]) -> Shell<R>) -> ParsedCmd<Shell<R>> {
            var result: [Shell<R>] = []
            for shell in shells {
                switch shell.flatMap(transform) {
                    case .cmd(let mapped): result.append(mapped)
                    case .help(let help): return .help(help)
                    case .failure(let failure): return .failure(failure)
                }
            }
            return .cmd(constructor(result))
        }
        switch self {
            case .empty: return .cmd(.empty)
            case .cmd(let value): return transform(value).map(Shell<R>.cmd)
            case .pipe(let shells): return all(shells, Shell<R>.pipe)
            case .and(let shells): return all(shells, Shell<R>.and)
            case .or(let shells): return all(shells, Shell<R>.or)
            case .seq(let shells): return all(shells, Shell<R>.seq)
        }
    }

    /// Every command, left to right.
    var commands: [T] {
        switch self {
            case .empty: []
            case .cmd(let value): [value]
            case .pipe(let shells), .and(let shells), .or(let shells), .seq(let shells): shells.flatMap(\.commands)
        }
    }

    /// Renders the expression back, parenthesizing lower-precedence children.
    func description(_ render: (T) -> String) -> String {
        let parentPrecedence = precedence
        func renderChild(_ child: Shell<T>) -> String {
            let text = child.description(render)
            return child.precedence < parentPrecedence ? "(\(text))" : text
        }
        return switch self {
            case .empty: ""
            case .cmd(let value): render(value)
            case .pipe(let shells): shells.map(renderChild).joined(separator: " | ")
            case .and(let shells): shells.map(renderChild).joined(separator: " && ")
            case .or(let shells): shells.map(renderChild).joined(separator: " || ")
            case .seq(let shells): shells.map(renderChild).joined(separator: "; ")
        }
    }

    private var precedence: Int {
        switch self {
            case .empty, .cmd: Int.max
            case .pipe: 4
            case .and: 3
            case .or: 2
            case .seq: 1
        }
    }
}

extension Shell: Equatable where T: Equatable {}
