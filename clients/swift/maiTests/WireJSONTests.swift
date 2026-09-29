import Foundation
import Testing
@testable import mai

struct WireJSONTests {
    nonisolated private struct Envelope: Codable {
        let date: Date
    }

    @Test
    func fractionalAndWholeSecondsRetainTheirInstant() throws {
        print("WIRE_JSON_RUNTIME \(ProcessInfo.processInfo.operatingSystemVersionString) simulator=\(ProcessInfo.processInfo.environment["SIMULATOR_UDID"] ?? "none")")
        let fractions = ["", ".1", ".123", ".123456", ".123456789"]
        for fraction in fractions {
            let expected = Double("0" + fraction) ?? 0
            for timestamp in [
                "2001-01-01T00:00:00\(fraction)Z",
                "2000-12-31T20:00:00\(fraction)-04:00",
                "2001-01-01T05:30:00\(fraction)+05:30"
            ] {
                let data = Data("{\"date\":\"\(timestamp)\"}".utf8)
                let actual = try WireJSON.makeDecoder().decode(Envelope.self, from: data).date
                #expect(abs(actual.timeIntervalSinceReferenceDate - expected) < 0.000001)
            }
        }
    }

    @Test
    func capturedDaemonTimestampRetainsMicroseconds() throws {
        let data = Data(#"{"date":"2026-09-24T00:26:41.437657-04:00"}"#.utf8)
        let actual = try WireJSON.makeDecoder().decode(Envelope.self, from: data).date
        #expect(abs(actual.timeIntervalSince1970 - 1_790_224_001.437657) < 0.000001)
    }

    @Test
    func malformedDatesFailAtTheirField() throws {
        for value in [#""not a date""#, #""""#, #""2026-09-24""#, "123", "null"] {
            do {
                _ = try WireJSON.makeDecoder().decode(Envelope.self, from: Data("{\"date\":\(value)}".utf8))
                Issue.record("Invalid wire date was accepted: \(value)")
            } catch let DecodingError.dataCorrupted(context) {
                #expect(context.codingPath.map(\.stringValue) == ["date"])
            } catch let DecodingError.typeMismatch(_, context) {
                #expect(context.codingPath.map(\.stringValue) == ["date"])
            } catch let DecodingError.valueNotFound(_, context) {
                #expect(context.codingPath.map(\.stringValue) == ["date"])
            }
        }
    }

    @Test
    func existingWholeSecondEncoderRemainsCompatible() throws {
        let input = Envelope(date: Date(timeIntervalSinceReferenceDate: 123))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(input)
        let actual = try WireJSON.makeDecoder().decode(Envelope.self, from: data)
        #expect(actual.date == input.date)
    }
}
