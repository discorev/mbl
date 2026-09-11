import Foundation

/// Orders release tags the way git and GitHub already do: numeric components
/// first, then a pre-release such as `beta.1` sorts before the final release
/// of the same version. Sparkle's own comparator stops at the first dash, so
/// without this a beta build would never be offered the release it precedes.
enum SemanticVersion {
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = parse(lhs)
        let right = parse(rhs)

        let numbers = compareNumbers(left.numbers, right.numbers)
        guard numbers == .orderedSame else {
            return numbers
        }

        switch (left.preRelease.isEmpty, right.preRelease.isEmpty) {
        case (true, true): return .orderedSame
        case (false, true): return .orderedAscending
        case (true, false): return .orderedDescending
        case (false, false): return comparePreRelease(left.preRelease, right.preRelease)
        }
    }

    private static func parse(_ version: String) -> (numbers: [Int], preRelease: [String]) {
        var text = Substring(version.trimmingCharacters(in: .whitespacesAndNewlines))
        if text.hasPrefix("v") {
            text = text.dropFirst()
        }
        if let plus = text.firstIndex(of: "+") {
            text = text[..<plus]
        }
        let dash = text.firstIndex(of: "-")
        let core = dash.map { text[..<$0] } ?? text
        let preRelease = dash.map { text[text.index(after: $0)...] } ?? ""
        return (
            core.split(separator: ".").map { Int($0) ?? 0 },
            preRelease.split(separator: ".").map(String.init)
        )
    }

    private static func compareNumbers(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right {
                return left < right ? .orderedAscending : .orderedDescending
            }
        }
        return .orderedSame
    }

    private static func comparePreRelease(_ lhs: [String], _ rhs: [String]) -> ComparisonResult {
        for (left, right) in zip(lhs, rhs) {
            switch (Int(left), Int(right)) {
            case let (l?, r?) where l != r:
                return l < r ? .orderedAscending : .orderedDescending
            case (nil, _?):
                return .orderedDescending
            case (_?, nil):
                return .orderedAscending
            case (nil, nil) where left != right:
                return left < right ? .orderedAscending : .orderedDescending
            default:
                continue
            }
        }
        if lhs.count != rhs.count {
            return lhs.count < rhs.count ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }
}
