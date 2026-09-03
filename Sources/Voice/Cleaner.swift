protocol Cleaner: Sendable {
    func clean(_ raw: String) async throws -> String
}
