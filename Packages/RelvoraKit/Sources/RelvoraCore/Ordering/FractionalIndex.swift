/// Ordering for manually sorted items (columns, tasks, checklist items) using `Double` sort keys.
/// Inserting between two neighbours takes their midpoint, so a move updates one record. When the gap
/// between neighbours gets too small to split, the caller renormalizes the whole list in one transaction.
public enum FractionalIndex {
    /// Below this gap, midpoints lose meaningful precision.
    public static let minimumGap = 1e-9

    /// A sort key that orders between `lower` and `upper`. `nil` means "no neighbour on that side".
    public static func between(_ lower: Double?, _ upper: Double?) -> Double {
        switch (lower, upper) {
        case (nil, nil): 1
        case (let lower?, nil): lower + 1
        case (nil, let upper?): upper - 1
        case (let lower?, let upper?): lower + (upper - lower) / 2
        }
    }

    /// Whether `between(lower, upper)` would no longer produce a distinct key.
    public static func needsRenormalization(_ lower: Double?, _ upper: Double?) -> Bool {
        guard let lower, let upper else { return false }
        return upper - lower < minimumGap * 2
    }

    /// Evenly spaced keys `1, 2, 3, …` for `count` items, preserving their current order.
    public static func renormalized(count: Int) -> [Double] {
        (0..<max(count, 0)).map { Double($0 + 1) }
    }
}
