import Foundation
import Testing
@testable import Voice

struct SemanticVersionTests {
    @Test func preReleaseSortsBeforeItsFinalRelease() {
        #expect(SemanticVersion.compare("0.8.0-beta.1", "0.8.0") == .orderedAscending)
        #expect(SemanticVersion.compare("0.8.0", "0.8.0-beta.1") == .orderedDescending)
    }

    @Test func preReleaseSortsAfterEarlierRelease() {
        #expect(SemanticVersion.compare("0.7.2", "0.8.0-beta.1") == .orderedAscending)
    }

    @Test func preReleasesOrderNumerically() {
        #expect(SemanticVersion.compare("0.8.0-beta.2", "0.8.0-beta.10") == .orderedAscending)
        #expect(SemanticVersion.compare("0.8.0-alpha.1", "0.8.0-beta.1") == .orderedAscending)
    }

    @Test func equalVersionsIgnoreTrailingZerosPrefixAndBuildMetadata() {
        #expect(SemanticVersion.compare("1.0", "1.0.0") == .orderedSame)
        #expect(SemanticVersion.compare("v0.8.0", "0.8.0") == .orderedSame)
        #expect(SemanticVersion.compare("0.8.0+42", "0.8.0") == .orderedSame)
    }
}
