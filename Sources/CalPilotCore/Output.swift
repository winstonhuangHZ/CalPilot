import Foundation

/// Small console helpers: ANSI colors, CJK-aware table layout, and prompts.
public enum Console {
    public static var useColor: Bool = isatty(fileno(stdout)) == 1
        && ProcessInfo.processInfo.environment["NO_COLOR"] == nil

    public static func bold(_ s: String) -> String { useColor ? "\u{001B}[1m\(s)\u{001B}[0m" : s }
    public static func dim(_ s: String) -> String { useColor ? "\u{001B}[2m\(s)\u{001B}[0m" : s }
    public static func red(_ s: String) -> String { useColor ? "\u{001B}[31m\(s)\u{001B}[0m" : s }
    public static func green(_ s: String) -> String { useColor ? "\u{001B}[32m\(s)\u{001B}[0m" : s }
    public static func yellow(_ s: String) -> String { useColor ? "\u{001B}[33m\(s)\u{001B}[0m" : s }
    public static func cyan(_ s: String) -> String { useColor ? "\u{001B}[36m\(s)\u{001B}[0m" : s }

    /// Visual width, counting CJK/fullwidth characters as two columns.
    public static func width(_ s: String) -> Int {
        var total = 0
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
                 0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1F64F,
                 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
                total += 2
            case 0x0300...0x036F:
                total += 0
            default:
                total += 1
            }
        }
        return total
    }

    public static func pad(_ s: String, to width: Int, right: Bool = false) -> String {
        let padCount = max(0, width - Self.width(s))
        let filler = String(repeating: " ", count: padCount)
        return right ? filler + s : s + filler
    }

    public static func table(headers: [String], rows: [[String]]) {
        guard !rows.isEmpty else {
            print(dim("(nothing to show)"))
            return
        }
        var widths = headers.map { width($0) }
        for row in rows {
            for (index, cell) in row.enumerated() where index < widths.count {
                widths[index] = max(widths[index], width(cell))
            }
        }
        let headerLine = zip(headers, widths).map { pad($0, to: $1) }.joined(separator: "  ")
        print(bold(headerLine))
        print(dim(widths.map { String(repeating: "─", count: $0) }.joined(separator: "  ")))
        for row in rows {
            let line = row.enumerated().map { index, cell in
                pad(cell, to: widths[min(index, widths.count - 1)])
            }.joined(separator: "  ")
            print(line)
        }
    }

    public static func heading(_ s: String) {
        print()
        print(bold(s))
    }

    public static func note(_ s: String) {
        print(dim(s))
    }

    public static func warn(_ s: String) {
        print(yellow("warning: ") + s)
    }

    public static func error(_ s: String) {
        FileHandle.standardError.write(Data((red("error: ") + s + "\n").utf8))
    }

    public static func success(_ s: String) {
        print(green("✓ ") + s)
    }

    /// Yes/no prompt reading from stdin. Non-interactive input returns the default.
    public static func confirm(_ question: String, default defaultValue: Bool = false) -> Bool {
        let suffix = defaultValue ? "[Y/n] " : "[y/N] "
        print("\(question) \(suffix)", terminator: "")
        guard let line = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else {
            print("")
            return defaultValue
        }
        if line.isEmpty { return defaultValue }
        return line == "y" || line == "yes" || line == "是"
    }
}
