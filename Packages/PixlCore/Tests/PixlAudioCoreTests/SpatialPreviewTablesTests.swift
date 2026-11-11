import Foundation
import Testing
import PixlModel
@testable import PixlAudioCore

/// The on-device stage's table file and its golden file (cloud audio spec of 2026-11-10, section 7).
/// `Fixtures/spatial/` holds byte-identical copies of `cloud/runpod-worker/schema/v1/spatial/` (the worker generates
/// them; `ci/check-spatial-fixtures.sh` fails when a copy drifts). The stage's own tests read the same two files
/// through `SpatialFixtures`.
enum SpatialFixtures {
    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/spatial"))
        return try Data(contentsOf: url)
    }

    static func tables() throws -> SpatialPreviewTables {
        try SpatialPreviewTables.decode(try data(SpatialPreviewTables.resourceName))
    }

    static func golden() throws -> SpatialPreviewGolden {
        try SpatialPreviewGolden.decode(try data(SpatialPreviewGolden.resourceName))
    }

    /// The table file as a JSON tree, for tests that break one thing in it.
    static func tree() throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: try data(SpatialPreviewTables.resourceName))
        return try #require(object as? [String: Any])
    }

    static func encode(_ tree: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: tree)
    }
}

@Suite("Spatial preview tables")
struct SpatialPreviewTablesTests {
    @Test func theFileNamesAreTheSpecs() {
        #expect(SpatialPreviewTables.resourceName == "spatial_preview_v1")
        #expect(SpatialPreviewGolden.resourceName == "spatial_preview_golden_v1")
        #expect(SpatialPreviewTables.schemaName == "pixl.spatial.preview")
        #expect(SpatialPreviewTables.sampleRates == [44_100, 48_000])
    }

    @Test func theFileDecodesWithEveryProfileAtBothRates() throws {
        let tables = try SpatialFixtures.tables()
        #expect(tables.engine == "pixl-spatial-1")
        #expect(tables.headroomDb == 4.0)
        for profile in SpatialProfile.allCases {
            for rate in SpatialPreviewTables.sampleRates {
                let table = try #require(tables.table(for: profile, sampleRate: rate))
                #expect(table.xoverHz == 120.0)
                #expect(table.taps == 192)
                #expect(table.direct.count == 192 && table.cross.count == 192)
                #expect(table.lowDelay >= 0 && table.lowDelay < table.taps)
                #expect(table.sparseL.count == 40 && table.sparseR.count == 40)
                // The two ears' rooms differ on purpose.
                #expect(table.sparseL != table.sparseR)
                #expect(table.gain > 0.3 && table.gain < 0.8)
                #expect(table.maxDelay == table.maxSparseDelay)
                // The low band's delay is where the same-side FIR peaks.
                let peak = table.direct.indices.max { abs(table.direct[$0]) < abs(table.direct[$1]) }
                #expect(peak == table.lowDelay)
            }
        }
    }

    /// Every number of the decoded tables is the file's own (read a second time as a plain JSON tree). The worker
    /// regenerates the file whenever the renderer is tuned, so no value is written down here.
    @Test func theDecodedNumbersAreTheFilesOwn() throws {
        let tables = try SpatialFixtures.tables()
        let tree = try SpatialFixtures.tree()
        let profiles = try #require(tree["profiles"] as? [String: Any])
        // A JSON number, however this platform's JSONSerialization hands it over.
        func number(_ value: Any?) throws -> Double {
            if let value = value as? Double { return value }
            if let value = value as? Int { return Double(value) }
            return try #require((value as? NSNumber)?.doubleValue)
        }
        func numbers(_ value: Any?) throws -> [Double] {
            let list = try #require(value as? [Any])
            return try list.map { try number($0) }
        }
        for profile in SpatialProfile.allCases {
            let rates = try #require(profiles[profile.rawValue] as? [String: Any])
            for rate in SpatialPreviewTables.sampleRates {
                let raw = try #require(rates[String(rate)] as? [String: Any])
                let table = try #require(tables.table(for: profile, sampleRate: rate))
                let scalars = [try number(raw["xoverHz"]), try number(raw["lowDelay"]), try number(raw["taps"]),
                               try number(raw["gain"])]
                #expect(scalars == [table.xoverHz, Double(table.lowDelay), Double(table.taps), table.gain])
                let direct = try numbers(raw["direct"])
                let cross = try numbers(raw["cross"])
                #expect(table.direct == direct)
                #expect(table.cross == cross)
                for (name, taps) in [("sparseL", table.sparseL), ("sparseR", table.sparseR)] {
                    let rows = try #require(raw[name] as? [Any])
                    let flat = try rows.flatMap { try numbers($0) }
                    #expect(flat == taps.flatMap { [Double($0.delay), $0.gainFromLeft, $0.gainFromRight] })
                }
            }
        }
    }

    @Test func oneRingServesEveryTable() throws {
        let tables = try SpatialFixtures.tables()
        var longest = 0
        for profile in SpatialProfile.allCases {
            for rate in SpatialPreviewTables.sampleRates {
                longest = max(longest, try #require(tables.table(for: profile, sampleRate: rate)).maxDelay)
            }
        }
        #expect(tables.maxDelay == longest)
        // The spec's "about 8600 samples (Concert Hall at 48 kHz)": well under a second, well over a few FIR lengths.
        #expect(longest > 1_000 && longest < 48_000)
        #expect(tables.table(for: .hall, sampleRate: 48_000)?.maxSparseDelay == longest)
        // The smallest power of two that holds the longest history plus the current sample.
        let capacity = tables.ringCapacity
        #expect(capacity & (capacity - 1) == 0)
        #expect(capacity >= longest + 1)
        #expect(capacity / 2 < longest + 1)
    }

    @Test func anyOtherRateHasNoTableSoTheStageIsBypassed() throws {
        let tables = try SpatialFixtures.tables()
        #expect(tables.table(for: .studio, sampleRate: 96_000) == nil)
        #expect(tables.table(for: .studio, sampleRate: 22_050) == nil)
        #expect(tables.table(for: .studio, sampleRate: 44_100.0) != nil)
        #expect(tables.table(for: .studio, sampleRate: 47_999.8) != nil)
        #expect(tables.table(for: .studio, sampleRate: 44_056.0) == nil)
        #expect(SpatialPreviewTables.supportedRate(48_000.2) == 48_000)
        #expect(SpatialPreviewTables.supportedRate(88_200) == nil)
    }

    @Test func aFileThatIsNotTheTablesIsRefused() throws {
        #expect(throws: SpatialPreviewError.self) { try SpatialPreviewTables.decode(Data("[]".utf8)) }
        #expect(throws: SpatialPreviewError.self) { try SpatialPreviewTables.decode(Data()) }

        var tree = try SpatialFixtures.tree()
        tree["schema"] = "pixl.spatial.preview.golden"
        #expect(throws: SpatialPreviewError.wrongSchema("pixl.spatial.preview.golden")) {
            try SpatialPreviewTables.decode(SpatialFixtures.encode(tree))
        }
        tree = try SpatialFixtures.tree()
        tree["v"] = 2
        #expect(throws: SpatialPreviewError.unsupportedVersion(2)) {
            try SpatialPreviewTables.decode(SpatialFixtures.encode(tree))
        }
        tree = try SpatialFixtures.tree()
        tree["engine"] = "pixl-spatial-2"
        #expect(throws: SpatialPreviewError.wrongEngine("pixl-spatial-2")) {
            try SpatialPreviewTables.decode(SpatialFixtures.encode(tree))
        }
    }

    @Test func aMissingProfileOrRateIsRefused() throws {
        var tree = try SpatialFixtures.tree()
        var profiles = try #require(tree["profiles"] as? [String: Any])
        profiles["night"] = nil
        tree["profiles"] = profiles
        #expect(throws: SpatialPreviewError.missingProfile("night")) {
            try SpatialPreviewTables.decode(SpatialFixtures.encode(tree))
        }

        tree = try SpatialFixtures.tree()
        profiles = try #require(tree["profiles"] as? [String: Any])
        var wide = try #require(profiles["wide"] as? [String: Any])
        wide["48000"] = nil
        profiles["wide"] = wide
        tree["profiles"] = profiles
        #expect(throws: SpatialPreviewError.missingRate(profile: "wide", rate: 48_000)) {
            try SpatialPreviewTables.decode(SpatialFixtures.encode(tree))
        }
    }

    @Test func aProfileThisBuildDoesNotKnowIsSkipped() throws {
        var tree = try SpatialFixtures.tree()
        var profiles = try #require(tree["profiles"] as? [String: Any])
        profiles["cathedral"] = profiles["hall"]
        tree["profiles"] = profiles
        let tables = try SpatialPreviewTables.decode(SpatialFixtures.encode(tree))
        let expected = try SpatialFixtures.tables()
        #expect(tables == expected)
    }

    @Test func aTableWhoseNumbersDoNotHoldTogetherIsRefused() throws {
        func broken(_ change: (inout [String: Any]) -> Void) throws -> Data {
            var tree = try SpatialFixtures.tree()
            var profiles = try #require(tree["profiles"] as? [String: Any])
            var studio = try #require(profiles["studio"] as? [String: Any])
            var table = try #require(studio["44100"] as? [String: Any])
            change(&table)
            studio["44100"] = table
            profiles["studio"] = studio
            tree["profiles"] = profiles
            return try SpatialFixtures.encode(tree)
        }
        func refused(_ detail: String, _ change: (inout [String: Any]) -> Void) throws {
            let data = try broken(change)
            #expect(throws: SpatialPreviewError.malformedTable(profile: "studio", rate: 44_100, detail: detail)) {
                try SpatialPreviewTables.decode(data)
            }
        }
        try refused("taps") { $0["taps"] = 191 }
        try refused("taps") { $0["cross"] = [0.5, 0.25] }
        try refused("lowDelay") { $0["lowDelay"] = 192 }
        try refused("gain") { $0["gain"] = 0 }
        try refused("xoverHz") { $0["xoverHz"] = 30_000 }
        try refused("sparseL") { $0["sparseL"] = [[417, 0.03]] }
        try refused("sparseR") { $0["sparseR"] = [[-1, 0.03, 0.02]] }
        try refused("sparseR") { $0["sparseR"] = [[10.5, 0.03, 0.02]] }
    }
}

@Suite("Spatial preview golden file")
struct SpatialPreviewGoldenTests {
    @Test func theGoldenFileCoversEveryProfileAndRate() throws {
        let golden = try SpatialFixtures.golden()
        #expect(golden.frames == 1024)
        #expect(golden.tolerance == 1e-4)
        #expect(golden.input.left.count == 1024 && golden.input.right.count == 1024)
        // An impulse on the left at frame 0, one on the right at frame 300, noise from frame 600.
        #expect(golden.input.left[0] == 0.5 && golden.input.right[0] == 0)
        #expect(golden.input.right[300] == 0.5 && golden.input.left[300] == 0)
        #expect(golden.input.left[1..<600].allSatisfy { $0 == 0 })
        #expect(golden.input.left[600...].contains { $0 != 0 })
        for profile in SpatialProfile.allCases {
            for rate in SpatialPreviewTables.sampleRates {
                let output = try #require(golden.output(for: profile, sampleRate: rate))
                #expect(output.left.count == golden.frames && output.right.count == golden.frames)
            }
        }
        #expect(golden.output(for: .studio, sampleRate: 96_000) == nil)
    }

    /// Before the high band's FIR has anything to say the output is the first taps of the same-side FIR times the
    /// impulse and the gain (the low band is still delayed, the sparse room has not started): a cheap check that the
    /// tables and the golden file belong together, without the stage.
    @Test func theFirstOutputSampleIsTheImpulseThroughTheFirstTap() throws {
        let tables = try SpatialFixtures.tables()
        let golden = try SpatialFixtures.golden()
        for profile in SpatialProfile.allCases {
            for rate in SpatialPreviewTables.sampleRates {
                let table = try #require(tables.table(for: profile, sampleRate: rate))
                let output = try #require(golden.output(for: profile, sampleRate: rate))
                // hi[0] = x[0] - lo[0], and lo[0] = b0² · x[0] for two biquads in series from a zero state.
                let w0 = 2.0 * Double.pi * table.xoverHz / Double(rate)
                let alpha = sin(w0) / (2.0 * (1.0 / 2.0.squareRoot()))
                let b0 = (1.0 - cos(w0)) / 2.0 / (1.0 + alpha)
                let high = 0.5 - b0 * b0 * 0.5
                #expect(abs(output.left[0] - table.gain * table.direct[0] * high) < golden.tolerance)
                #expect(abs(output.right[0] - table.gain * table.cross[0] * high) < golden.tolerance)
            }
        }
    }

    @Test func aGoldenFileOfTheWrongShapeIsRefused() throws {
        #expect(throws: SpatialPreviewError.self) { try SpatialPreviewGolden.decode(Data("{}".utf8)) }
        let tables = try SpatialFixtures.data(SpatialPreviewTables.resourceName)
        #expect(throws: SpatialPreviewError.self) { try SpatialPreviewGolden.decode(tables) }
    }
}
