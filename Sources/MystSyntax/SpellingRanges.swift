import Foundation

/// The parts of a page that spell checking skips, as sorted, merged ranges.
public struct SpellingExclusions: Equatable, Sendable {
    public private(set) var ranges: [NSRange] = []

    public init(tokens: [MystToken] = []) {
        let sorted = tokens.filter { !$0.checksSpelling }.map(\.range).sorted { $0.location < $1.location }
        for range in sorted {
            if let last = ranges.last, range.location <= NSMaxRange(last) {
                ranges[ranges.count - 1] = NSUnionRange(last, range)
            } else {
                ranges.append(range)
            }
        }
    }

    /// True when `range` overlaps any excluded range (binary search).
    public func excludes(_ range: NSRange) -> Bool {
        var low = 0
        var high = ranges.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(ranges[mid]) <= range.location { low = mid + 1 } else { high = mid }
        }
        return low < ranges.count && ranges[low].location < NSMaxRange(range)
    }
}
