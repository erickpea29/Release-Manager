import Testing

/// Parent of every SwiftData suite. Serialized as a whole: a migration opens older schema versions, which must
/// never run concurrently with the current schema in the same process (M00 finding F1).
@Suite(.serialized)
enum StoreTests {}
