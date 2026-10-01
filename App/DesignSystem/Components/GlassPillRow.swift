import SwiftUI

/// A horizontal row of glass capsules with one selected (Android `TabAnimation` tabs in Library, segmented filters,
/// chip rows). The selected capsule is tinted glass that glides to the newly selected item: its glass carries one
/// shared `glassEffectID` inside a `GlassEffectContainer`, so the effect morphs between positions instead of fading.
///
/// Geometry defaults to Library's tab row: 48 pt capsules, 16 pt text padding, 10 pt between capsules, 17 pt edge
/// padding, upper-case `labelLarge` (bold when selected). Colours: selected = `primary` tint / `onPrimary` text,
/// others = plain glass / `onSurface` 90 %.
struct GlassPillRow<ID: Hashable & Sendable>: View {
    struct Item: Identifiable {
        let id: ID
        let title: String
        var systemImage: String?

        init(id: ID, title: String, systemImage: String? = nil) {
            self.id = id
            self.title = title
            self.systemImage = systemImage
        }
    }

    let items: [Item]
    @Binding var selection: ID
    var uppercase = true
    var height: CGFloat = Tokens.Tabs.height
    var textPadding: CGFloat = Tokens.Tabs.textHorizontalPadding
    var spacing: CGFloat = Tokens.Tabs.outerPadding * 2
    var edgePadding: CGFloat = Tokens.Tabs.edgePadding + Tokens.Tabs.outerPadding
    /// Tint of the selected capsule (defaults to the theme's `primary`).
    var selectedTint: Color?
    var accessibilityIdentifierPrefix = "pill"
    /// A trailing action capsule after the items (Library's "Edit" tab that opens the reorder sheet).
    var accessory: Accessory?

    /// An icon-only capsule at the end of the row, never selected.
    struct Accessory {
        let systemImage: String
        let accessibilityLabel: String
        let action: () -> Void
    }

    @Environment(\.appTheme) private var theme
    @Namespace private var glassNamespace

    nonisolated private enum GlassID: Hashable, Sendable {
        case selection
        case item(ID)
        case accessory
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                // Container spacing below the gap: capsules never blend at rest, yet the selection still morphs.
                GlassEffectContainer(spacing: spacing * 0.4) {
                    HStack(spacing: spacing) {
                        ForEach(items) { item in
                            pill(item)
                                .id(item.id)
                        }
                        if let accessory {
                            accessoryPill(accessory)
                        }
                    }
                    .padding(.horizontal, edgePadding)
                    .padding(.vertical, Tokens.Tabs.outerPadding)
                }
            }
            .scrollClipDisabled()
            // Like Android's scrollable tab row: the selected tab scrolls into view.
            .onChange(of: selection) { _, newValue in
                withAnimation(PixlMotion.selection) { proxy.scrollTo(newValue, anchor: .center) }
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func accessoryPill(_ accessory: Accessory) -> some View {
        Button(action: accessory.action) {
            Image(systemName: accessory.systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.onSurface.opacity(0.9))
                .padding(.horizontal, textPadding)
                .frame(height: height)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(Glass.regular.interactive(), in: Capsule())
        .glassEffectID(GlassID.accessory, in: glassNamespace)
        .accessibilityLabel(accessory.accessibilityLabel)
        .accessibilityIdentifier("\(accessibilityIdentifierPrefix).accessory")
    }

    private func pill(_ item: Item) -> some View {
        let isSelected = item.id == selection
        let title = uppercase ? item.title.uppercased() : item.title
        return Button {
            withAnimation(PixlMotion.selection) { selection = item.id }
        } label: {
            HStack(spacing: 6) {
                if let symbol = item.systemImage {
                    Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
                }
                Text(title)
                    .pixlFont(.labelLarge, weight: isSelected ? .bold : .medium)
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? theme.onPrimary : theme.onSurface.opacity(0.9))
            .padding(.horizontal, textPadding)
            .frame(height: height)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(
            isSelected
                ? Glass.regular.tint((selectedTint ?? theme.primary).opacity(GlassTint.prominent)).interactive()
                : Glass.regular.interactive(),
            in: Capsule()
        )
        .glassEffectID(isSelected ? GlassID.selection : GlassID.item(item.id), in: glassNamespace)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("\(accessibilityIdentifierPrefix).\(item.title)")
    }
}
