import XCTest
@testable import Turnip

/// `SourceContribution.splitByVocabulary` and `LabelCandidates.batch` pin
/// (`BACKEND_DESIGN.md` §1.2.25, `docs/CONTRIBUTION_DESIGN.md` §4): only vocabulary names are
/// contributed, a clip left with none isn't, and the rest are suggested within the farm's limits.
final class VocabularyLabelsTests: XCTestCase {
    private static let videoID = String(repeating: "ab", count: 32)

    private static func clip(_ names: [ClipName]) -> ClipContribution {
        ClipContribution(
            clipID: UUID(), window: TrickWindow(startTime: 1, endTime: 2), autoDetected: true, names: names)
    }

    private static func source(_ clips: [ClipContribution]) -> SourceContribution {
        SourceContribution(
            videoID: videoID,
            pose: ContributionPose(
                sampleRate: 10, slots: Array(repeating: Array(repeating: 0.5, count: 51), count: 30)),
            clips: clips)
    }

    func testOnlyVocabularyNamesStayAndEachNewNameIsListedOnce() throws {
        let first = Self.clip([ClipName(name: "Corkscrew", origin: .typed), ClipName(name: "raiz", origin: .typed)])
        let second = Self.clip([ClipName(name: "RAIZ", origin: .typed), ClipName(name: "b twist", origin: .typed)])
        let third = Self.clip([ClipName(name: "hook", origin: .vocabulary)])

        let split = Self.source([first, second, third]).splitByVocabulary(.seed)

        XCTAssertEqual(split.unknown, ["raiz", "b twist"])
        let known = try XCTUnwrap(split.known)
        XCTAssertEqual(known.clips.map(\.clipID), [first.clipID, third.clipID], "the second clip has no known name")
        XCTAssertEqual(known.clips.map { $0.names.map(\.name) }, [["Corkscrew"], ["hook"]])
        XCTAssertEqual(known.videoID, Self.videoID)
    }

    func testNoClipWithAKnownNameLeavesNothingToContribute() {
        let split = Self.source([Self.clip([ClipName(name: "raiz", origin: .typed)])]).splitByVocabulary(.seed)
        XCTAssertNil(split.known)
        XCTAssertEqual(split.unknown, ["raiz"])
    }

    func testAllKnownNamesSuggestNothing() {
        let source = Self.source([Self.clip([ClipName(name: "cork", origin: .model)])])
        let split = source.splitByVocabulary(.seed)
        XCTAssertEqual(split.known, source)
        XCTAssertEqual(split.unknown, [])
    }

    func testDroppingNamesIgnoresCaseAndSpacing() throws {
        let source = Self.source([
            Self.clip([ClipName(name: "cork", origin: .typed), ClipName(name: "Hook", origin: .typed)])
        ])
        let dropped = try XCTUnwrap(source.droppingNames(["  hook "]))
        XCTAssertEqual(dropped.clips.first?.names.map(\.name), ["cork"])
        XCTAssertNil(source.droppingNames(["cork", "HOOK"]))
    }

    func testCandidateBatchesStayWithinTheFarmsLimits() {
        let long = String(repeating: "x", count: LabelCandidates.maximumLength + 1)
        let edge = String(repeating: "y", count: LabelCandidates.maximumLength)
        XCTAssertEqual(LabelCandidates.batch([" raiz ", "", "   ", "RAIZ", long, edge]), ["raiz", edge])

        let many = (0..<30).map { "name \($0)" }
        XCTAssertEqual(LabelCandidates.batch(many), Array(many.prefix(LabelCandidates.maximumCount)))
    }
}
