/// A line-based diff (longest common subsequence), used to show what a change did to `myst.yml`.
public enum LineDiff {
    public enum Line: Equatable {
        case same(String)
        case removed(String)
        case added(String)
    }

    public static func diff(_ before: String, _ after: String) -> [Line] {
        let a = before.components(separatedBy: "\n")
        let b = after.components(separatedBy: "\n")
        // lengths[i][j]: LCS length of a[i...] and b[j...]
        var lengths = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lengths[i][j] = a[i] == b[j] ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        var result: [Line] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                result.append(.same(a[i])); i += 1; j += 1
            } else if i < a.count, j == b.count || lengths[i + 1][j] >= lengths[i][j + 1] {
                result.append(.removed(a[i])); i += 1 // removals before additions, as in `diff`
            } else {
                result.append(.added(b[j])); j += 1
            }
        }
        return result
    }

    /// Only the changed lines plus `context` unchanged lines around them; `nil` marks skipped lines.
    public static func hunks(_ lines: [Line], context: Int = 2) -> [Line?] {
        let changed = lines.indices.filter { if case .same = lines[$0] { return false } else { return true } }
        var keep = Set<Int>()
        for i in changed { keep.formUnion(max(0, i - context)...min(lines.count - 1, i + context)) }
        var result: [Line?] = []
        var last = -1
        for i in keep.sorted() {
            if i > last + 1 { result.append(nil) }
            result.append(lines[i])
            last = i
        }
        return result
    }
}
