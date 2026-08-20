import XCTest

@testable import mai

nonisolated final class UnifiedDiffPerformanceTests: XCTestCase {
    func testMediumPatchParsingPerformance() {
        let patch = makePatch(files: 6, hunksPerFile: 6, linesPerHunk: 30)
        var parsedFileCount = 0

        measure(metrics: [XCTClockMetric()]) {
            parsedFileCount = UnifiedDiffParser.parseFiles(patch).count
        }

        XCTAssertEqual(parsedFileCount, 6)
    }

    func testLargePatchPresentationModelPerformance() {
        let patch = makePatch(files: 24, hunksPerFile: 18, linesPerHunk: 50)
        var rowCount = 0

        measure(metrics: [XCTClockMetric()]) {
            rowCount = UnifiedDiffParser.parse(patch).rows.count
        }

        XCTAssertGreaterThan(rowCount, 20_000)
    }

    private func makePatch(
        files: Int,
        hunksPerFile: Int,
        linesPerHunk: Int
    ) -> String {
        var output: [String] = []
        output.reserveCapacity(files * hunksPerFile * (linesPerHunk + 1))

        for fileIndex in 0..<files {
            let path = "Sources/Synthetic/File\(fileIndex).swift"
            output.append("diff --git a/\(path) b/\(path)")
            output.append("index 1111111..2222222 100644")
            output.append("--- a/\(path)")
            output.append("+++ b/\(path)")

            var oldStart = 1
            var newStart = 1
            for hunkIndex in 0..<hunksPerFile {
                var body: [String] = []
                body.reserveCapacity(linesPerHunk)
                var oldCount = 0
                var newCount = 0

                for lineIndex in 0..<linesPerHunk {
                    switch lineIndex % 3 {
                    case 0:
                        body.append(
                            " context \(fileIndex)-\(hunkIndex)-\(lineIndex) "
                                + String(repeating: "value ", count: 4)
                        )
                        oldCount += 1
                        newCount += 1
                    case 1:
                        body.append("-deleted \(fileIndex)-\(hunkIndex)-\(lineIndex)")
                        oldCount += 1
                    default:
                        body.append("+added \(fileIndex)-\(hunkIndex)-\(lineIndex)")
                        newCount += 1
                    }
                }

                output.append(
                    "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) "
                        + "@@ synthetic hunk \(hunkIndex)"
                )
                output.append(contentsOf: body)
                oldStart += oldCount + 3
                newStart += newCount + 3
            }
        }
        return output.joined(separator: "\n")
    }
}
