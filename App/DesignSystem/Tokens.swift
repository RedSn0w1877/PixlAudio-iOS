import SwiftUI

/// Layout constants shared across screens. Colours come from the system (semantic styles) and the
/// asset catalog's AccentColor; typography is always the system font (SF Pro) via text styles.
enum Tokens {
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Artwork {
        static let rowSize: CGFloat = 48
        static let rowCornerRadius: CGFloat = 8
        static let tileCornerRadius: CGFloat = 14
    }
}
