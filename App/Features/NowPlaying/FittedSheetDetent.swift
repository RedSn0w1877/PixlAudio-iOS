import SwiftUI

/// Android's player sheets (`TimerOptionsBottomSheet`, `PlayerArtistPickerBottomSheet`, `CastBottomSheet`) are
/// `ModalBottomSheet`s that wrap their content (`skipPartiallyExpanded`): the sheet is exactly as tall as what it
/// holds. SwiftUI sheets take detents, so these sheets measure their natural content height
/// (`onGeometryChange` inside their scroll view) and size a `.height` detent to it — the system caps it at the
/// large height and the scroll view takes over when the content is taller than the screen.
extension View {
    /// The wrap-content detent for a measured content height (`nil` until the first layout pass).
    func fittedSheetDetent(_ contentHeight: CGFloat?) -> some View {
        presentationDetents([contentHeight.map { .height(max($0, 120)) } ?? .medium])
            .presentationDragIndicator(.visible)
    }

    /// Reports the view's laid-out height once per change (no per-frame work).
    func measuringHeight(_ height: Binding<CGFloat?>) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.size.height } action: { newValue in
            let rounded = newValue.rounded(.up)
            if height.wrappedValue != rounded { height.wrappedValue = rounded }
        }
    }
}
