import Foundation
import PixlLibrary
import PixlModel
import XCTest
@testable import PixlAudio

/// The app-side pieces of the Pixl ring code: the words under the receiver's camera, the lookup with no source, the accent colour's
/// palette and the slots' identity. The rules, the scanner and the flow are tested in PixlCore (`RingFlowTests`, `RingScanSessionTests`,
/// `RingCodeCameraTests`); the camera, the drawing and the screens run only on a phone.
final class RingCodeAppTests: XCTestCase {
    func testTheLineUnderTheCameraSaysWhatTheScanIsDoing() {
        let scanning = RingScanView(stage: .scanning, qrOffered: false, message: .none)
        XCTAssertEqual(SongTapStrings.ringScanLine(scanning, hasCamera: true, waiting: true), SongTapStrings.ringScanHint)
        XCTAssertNil(SongTapStrings.ringScanLine(scanning, hasCamera: true, waiting: false))
        let looking = RingScanView(stage: .resolving, qrOffered: false, message: .none)
        XCTAssertEqual(SongTapStrings.ringScanLine(looking, hasCamera: true, waiting: true), SongTapStrings.ringLookingUp)
        let expired = RingScanView(stage: .scanning, qrOffered: true, message: .expired)
        XCTAssertEqual(SongTapStrings.ringScanLine(expired, hasCamera: true, waiting: true), SongTapStrings.ringExpired)
        let failed = RingScanView(stage: .unavailable, qrOffered: true, message: .none)
        XCTAssertEqual(SongTapStrings.ringScanLine(failed, hasCamera: true, waiting: true), SongTapStrings.ringCameraFailed)
        XCTAssertEqual(SongTapStrings.ringScanLine(failed, hasCamera: false, waiting: true), SongTapStrings.ringNoCamera)
    }

    func testALookupWithNoSourceIsNilNotACrash() async {
        let song = await AppRingCodeLookup(source: nil).resolve(videoId: "dQw4w9WgXcQ", nowMs: 1)
        XCTAssertNil(song)
    }

    @MainActor
    func testTheAccentsPaletteKeepsTheContrastRuleAndIsWorkedOutOnce() {
        let violet: UInt32 = 0xFF6750A4
        let palette = RingPalettes.palette(for: violet)
        XCTAssertGreaterThanOrEqual(palette.contrast, RingCodeStyle.minContrast - 0.05)
        XCTAssertEqual(palette.marker, RingPalettes.palette(for: violet).marker)
        // A pale accent is darkened, never the plate lightened.
        let pale = RingPalettes.palette(for: 0xFFFFE08A)
        XCTAssertGreaterThanOrEqual(pale.contrast, RingCodeStyle.minContrast - 0.05)
    }

    func testTwoCodesAreTheSameCodeOnlyWhenTheirSerialIs() {
        let bits = [UInt8](repeating: 0, count: RingCodeLayout.slots)
        XCTAssertEqual(RingCodeSlots(bits: bits, serial: 3), RingCodeSlots(bits: bits, serial: 3))
        XCTAssertNotEqual(RingCodeSlots(bits: bits, serial: 3), RingCodeSlots(bits: bits, serial: 4))
    }
}
