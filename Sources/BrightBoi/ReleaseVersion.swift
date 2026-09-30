import Foundation

/// A release version such as `1.10.0` or `v1.2`, comparable numerically.
///
/// A leading `v` is ignored and missing trailing components count as zero,
/// so `1.1` equals `1.1.0` and `1.10.0` is newer than `1.9.0`. Anything that
/// is not plain dot-separated numbers, such as `1.2.0-beta1`, has no version:
/// a pre-release is never offered as an update.
struct ReleaseVersion: Comparable, Hashable, Sendable {
    let components: [Int]

    init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber), let number = Int(part) else {
                return nil
            }
            numbers.append(number)
        }
        components = numbers
    }

    /// The version as shown to the user, without a `v` prefix.
    var displayString: String {
        components.map(String.init).joined(separator: ".")
    }

    /// Components padded with zeros to `count`.
    private func padded(to count: Int) -> [Int] {
        components + Array(repeating: 0, count: max(0, count - components.count))
    }

    static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        return lhs.padded(to: count) == rhs.padded(to: count)
    }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        return lhs.padded(to: count).lexicographicallyPrecedes(rhs.padded(to: count))
    }

    /// Equal versions hash alike whatever their trailing zeros.
    func hash(into hasher: inout Hasher) {
        var trimmed = components
        while trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }
}
