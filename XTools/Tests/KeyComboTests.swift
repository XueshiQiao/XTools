import XCTest
import Carbon.HIToolbox

/// `KeyCombo` is what a recorded shortcut is saved as (the Tmux palette hotkey),
/// so two things must hold: it reads back exactly as written, and it shows the
/// user the glyphs macOS menus use, in the order macOS menus use them.
final class KeyComboTests: XCTestCase {

    func testModifierGlyphsFollowTheMenuOrder() {
        // Carbon's bit order is ⌘ ⇧ ⌥ ⌃; menus print ⌃ ⌥ ⇧ ⌘. The display must not
        // leak the bit order.
        let all = KeyCombo(keyCode: UInt32(kVK_ANSI_S),
                           carbonModifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey))
        XCTAssertEqual(all.display, "⌃⌥⇧⌘S")
    }

    func testNamedAndUnknownKeys() {
        XCTAssertEqual(KeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey)).display, "⌥Space")
        XCTAssertEqual(KeyCombo(keyCode: UInt32(kVK_F1), carbonModifiers: 0).display, "F1")
        // A key missing from the glyph table still shows something the user can act on.
        XCTAssertEqual(KeyCombo(keyCode: 999, carbonModifiers: UInt32(cmdKey)).display, "⌘Key 999")
    }

    func testSurvivesASaveAndLoad() throws {
        let combo = KeyCombo(keyCode: UInt32(kVK_ANSI_T), carbonModifiers: UInt32(cmdKey | controlKey))
        let data = try JSONEncoder().encode(combo)
        XCTAssertEqual(try JSONDecoder().decode(KeyCombo.self, from: data), combo)
    }
}
