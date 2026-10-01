import PixlLibrary
import SwiftUI

/// Artist word delimiters (Android `WordDelimiterConfigScreen`): the same layout as the character delimiters, with
/// keywords (matched case-insensitively between spaces), an empty state, removable down to none, and the "How Word
/// Delimiters Work" help panel.
struct WordDelimiterConfigView: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let library = settings.library
        DelimiterEditor(
            screenID: "wordDelimiterConfig",
            texts: .init(title: L10n.wordDelimitersScreenTitle, currentTitle: L10n.wordDelimiterCurrentTitle,
                         currentSubtitle: L10n.wordDelimiterCurrentSubtitle, empty: L10n.wordDelimiterEmpty,
                         addTitle: L10n.wordDelimiterAddTitle, addHint: L10n.wordDelimiterAddHint,
                         addLabel: L10n.wordDelimiterCdAdd, added: L10n.wordDelimiterToastAdded,
                         invalid: L10n.wordDelimiterToastInvalid, resetTitle: L10n.wordDelimiterResetTitle,
                         resetMessage: L10n.wordDelimiterResetMessage, resetDone: L10n.wordDelimiterToastReset,
                         footerTitle: L10n.wordDelimiterHelpTitle, footerBody: L10n.wordDelimiterHelpBody),
            items: library.artistWordDelimiters,
            label: { $0 },
            canRemove: true,
            onAdd: { text in
                // Android `addWordDelimiter`: trimmed, non-empty, not present (case-insensitive).
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      !library.artistWordDelimiters.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
                else { return false }
                library.artistWordDelimiters.append(trimmed)
                library.artistSettingsRescanRequired = true
                return true
            },
            onRemove: { delimiter in
                library.artistWordDelimiters.removeAll { $0 == delimiter }
                library.artistSettingsRescanRequired = true
                return nil
            },
            onReset: {
                library.artistWordDelimiters = ArtistParsing.defaultWordDelimiters
                library.artistSettingsRescanRequired = true
            })
    }
}
