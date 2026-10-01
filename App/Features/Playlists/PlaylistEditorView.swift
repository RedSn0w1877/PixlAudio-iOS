import PhotosUI
import PixlLibrary
import PixlModel
import SwiftUI

/// Create / edit a playlist (Android `CreatePlaylistScreen`: `CreatePlaylistContent` and `EditPlaylistContent`).
/// - The top bar (64 pt, `surfaceContainer`): the close / back circle and the centred title (24 pt bold, widened
///   1.2×): "New playlist", "New smart playlist", "Add Songs" or "Edit Playlist".
/// - Step 1, the form: the 240 pt preview (Default = the auto-collage tile, Image = the picked photo, Icon = the
///   colour + icon in the chosen shape, 180 pt), the name field, Manual / Smart (creating only) with the smart rule
///   chips, the Default / Image / Icon button group and, for Icon, the colours, icons, shapes and shape parameters.
/// - Step 2 (manual creation): the song picker with its bottom bar.
/// - The floating action (56 pt capsule, `tertiaryContainer`): Next / Create / Save.
struct PlaylistEditorView: View {
    /// nil = create a new playlist.
    let playlistId: String?

    @Environment(AppEnvironment.self) private var env
    @Environment(LibraryStore.self) private var library
    @Environment(Router.self) private var router
    @Environment(\.appTheme) private var theme

    @State private var form = PlaylistCoverForm()
    @State private var step = 0
    @State private var isSmart = false
    @State private var smartRule: SmartPlaylistRule = .topPlayed
    @State private var selectedSongs: Set<String> = []
    @State private var storageFilter: StorageFilter = .all
    @State private var photoItem: PhotosPickerItem?
    @State private var didLoad = false
    @State private var isSaving = false

    private var isEditing: Bool { playlistId != nil }
    private var nameIsBlank: Bool { form.name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ZStack {
                if step == 0 {
                    PlaylistCoverFormView(form: $form, isEditing: isEditing, isSmart: $isSmart, smartRule: $smartRule,
                                          photoItem: $photoItem)
                        .transition(.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .leading))
                            .combined(with: .opacity))
                } else {
                    SongPickerPane(selection: $selectedSongs, storageFilter: $storageFilter)
                        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .trailing))
                            .combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.spring(response: 0.4, dampingFraction: 0.86), value: step)
        }
        .background(theme.surface.ignoresSafeArea())
        .overlay(alignment: .bottom) { bottomControls }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear(perform: load)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await importPhoto(item) }
        }
        .accessibilityIdentifier("screen.playlistEditor")
    }

    // MARK: Top bar

    private var title: String {
        if isEditing { return "Edit Playlist" }
        if step == 1 { return "Add Songs" }
        return isSmart ? "New smart playlist" : "New playlist"
    }

    private var topBar: some View {
        ZStack {
            Text(title)
                .pixlFont(.custom(size: 24, weight: .bold))
                .foregroundStyle(theme.onSurface)
                .scaleEffect(x: 1.2, y: 1)
                .lineLimit(1)
                .contentTransition(.opacity)
                .animation(PixlMotion.state, value: title)
                .accessibilityAddTraits(.isHeader)
            HStack {
                GlassCircleButton(systemImage: step == 1 ? "arrow.left" : "xmark", accessibilityLabel: "Back or Cancel",
                                  tint: theme.surfaceContainerLowest.opacity(GlassTint.container),
                                  foreground: theme.onSurface) {
                    if step == 1 { step = 0 } else { router.pop() }
                }
                .accessibilityIdentifier("editor.close")
                Spacer()
            }
            .padding(.leading, 10)
        }
        .frame(height: 64)
        .background(theme.surfaceContainer.ignoresSafeArea(edges: .top))
    }

    // MARK: Bottom

    @ViewBuilder
    private var bottomControls: some View {
        if step == 1 {
            SongPickerBottomBar(storageFilter: $storageFilter,
                                showsCloudFilter: library.songs.contains(where: LibrarySorting.isOnline),
                                title: "Create", confirmLabel: "Create") { save() }
        } else {
            HStack {
                Spacer()
                floatingAction
            }
            .padding(.trailing, 24)
            .padding(.bottom, 24)
        }
    }

    /// Android `MediumExtendedFloatingActionButton` (56 pt, capsule).
    private var floatingAction: some View {
        let isNext = !isEditing && !isSmart
        let disabled = nameIsBlank
        return Button {
            guard !disabled else { return }
            if isNext { step = 1 } else { save() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isNext ? "arrow.right" : "checkmark")
                    .font(.system(size: 20, weight: .semibold))
                Text(isEditing ? "Save" : (isNext ? "Next" : "Create"))
                    .pixlFont(.titleMedium, weight: .semibold)
            }
            .foregroundStyle(disabled ? theme.onSurfaceVariant.opacity(0.38) : theme.onTertiaryContainer)
            .padding(.horizontal, 24)
            .frame(height: 56)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: Capsule(),
                   tint: (disabled ? theme.surfaceContainerHighest : theme.tertiaryContainer).opacity(GlassTint.prominent),
                   interactive: !disabled)
        .animation(PixlMotion.state, value: disabled)
        .accessibilityIdentifier("editor.primaryAction")
    }

    // MARK: Load and save

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        form.colorArgb = UInt32(theme.argb(\.primaryContainer))
        if let playlistId, let playlist = library.playlist(id: playlistId) {
            form = PlaylistCoverForm(playlist: playlist, fallbackColor: theme.argb(\.primaryContainer))
        }
        if env.launch.screen == .playlistEdit {
            // UI tests: show the Icon tab with a star, the richest state of the form.
            form.tab = .icon
            form.shape = .star
        }
        storageFilter = library.songs.contains(where: LibrarySorting.isOnline) ? .offline : .all
    }

    private func save() {
        guard !nameIsBlank, !isSaving else { return }
        isSaving = true
        let editor = env.libraryEditor
        let name = form.name.trimmingCharacters(in: .whitespaces)
        let cover = form.coverFields
        if let playlistId, var playlist = library.playlist(id: playlistId) {
            playlist.name = name
            playlist.coverImageUri = cover.imageUri
            playlist.coverColorArgb = cover.colorArgb
            playlist.coverIconName = cover.iconName
            playlist.coverShapeType = cover.shapeType
            playlist.coverShapeDetail1 = cover.details[0]
            playlist.coverShapeDetail2 = cover.details[1]
            playlist.coverShapeDetail3 = cover.details[2]
            playlist.coverShapeDetail4 = cover.details[3]
            editor.updatePlaylist(playlist)
            router.pop()
            return
        }
        if isSmart {
            let rule = smartRule
            let songs = library.songs
            Task {
                let engagements = await editor.engagementEntries().map { (songId: $0.songId, stats: $0.stats) }
                let favorites = Set(songs.filter(\.isFavorite).map(\.id))
                let ids = SmartPlaylistBuilder.songIds(for: rule, allSongs: songs, engagements: engagements,
                                                       favoriteIds: favorites, nowMs: currentTimeMillis())
                editor.createPlaylist(name: name, songIds: ids, coverImageUri: cover.imageUri,
                                      coverColorArgb: cover.colorArgb, coverIconName: cover.iconName,
                                      coverShapeType: cover.shapeType, shapeDetails: cover.details,
                                      smartRuleKey: rule.storageKey)
                LibraryToast.shared.show("Playlist created")
                router.pop()
            }
            return
        }
        let ordered = LibrarySorting.sortSongs(library.songs.filter { selectedSongs.contains($0.id) }, by: .songTitleAZ)
        editor.createPlaylist(name: name, songIds: ordered.map(\.id), coverImageUri: cover.imageUri,
                              coverColorArgb: cover.colorArgb, coverIconName: cover.iconName,
                              coverShapeType: cover.shapeType, shapeDetails: cover.details)
        LibraryToast.shared.show("Playlist created")
        router.pop()
    }

    /// Copies the picked photo into Application Support (Android keeps the cropped copy in app storage).
    private func importPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        let isUITest = env.launch.isUITest
        let url = await Task.detached(priority: .userInitiated) { PlaylistCoverStore.save(data, temporary: isUITest) }.value
        guard let url else { return }
        withAnimation(PixlMotion.state) {
            form.imageUri = url.absoluteString
            form.tab = .image
        }
    }
}

// MARK: - Form state

/// The cover being edited (Android `CreatePlaylistContent` state): name, tab, image, colour, icon, shape and the
/// shape parameters, with Android's defaults (corner 20, smoothness 60; star 5 sides, curve 0.15, 0°, 1×).
nonisolated struct PlaylistCoverForm: Equatable, Sendable {
    nonisolated enum Tab: Int, CaseIterable, Sendable {
        case standard, image, icon

        var title: String {
            switch self {
            case .standard: "Default"
            case .image: "Image"
            case .icon: "Icon"
            }
        }
    }

    var name = ""
    var tab: Tab = .standard
    var imageUri: String?
    var colorArgb: UInt32 = 0xFFE8DEF8
    var iconName = "MusicNote"
    var shape: PlaylistShapeType = .circle
    var cornerRadius: Float = 20
    var smoothness: Float = 60
    var starSides: Int = 5
    var starCurve: Float = 0.15
    var starRotation: Float = 0
    var starScale: Float = 1

    init() {}

    /// Android `EditPlaylistContent`: image → Image tab, colour or icon → Icon tab, else Default.
    init(playlist: Playlist, fallbackColor: UInt32) {
        name = playlist.name
        imageUri = playlist.coverImageUri
        tab = playlist.coverImageUri != nil ? .image
            : (playlist.coverColorArgb != nil || playlist.coverIconName != nil ? .icon : .standard)
        colorArgb = playlist.coverColorArgb.map { UInt32(bitPattern: $0) } ?? fallbackColor
        iconName = playlist.coverIconName ?? "MusicNote"
        shape = playlist.coverShapeType.flatMap(PlaylistShapeType.init(rawValue:)) ?? .circle
        cornerRadius = playlist.coverShapeDetail1 ?? 20
        smoothness = playlist.coverShapeDetail2 ?? 60
        starCurve = playlist.coverShapeDetail1 ?? 0.15
        starRotation = playlist.coverShapeDetail2 ?? 0
        starScale = playlist.coverShapeDetail3 ?? 1
        starSides = Int(playlist.coverShapeDetail4 ?? 5)
    }

    /// What Android saves for the selected tab (`onCreate` / `onSave` arguments).
    var coverFields: (imageUri: String?, colorArgb: Int32?, iconName: String?, shapeType: String?, details: [Float?]) {
        let image = tab == .image ? imageUri : nil
        guard tab == .icon else { return (image, nil, nil, nil, [nil, nil, nil, nil]) }
        return (nil, Int32(bitPattern: colorArgb), iconName, shape.rawValue, shapeDetails)
    }

    /// `Quadruple(d1, d2, d3, d4)` per shape.
    var shapeDetails: [Float?] {
        switch shape {
        case .smoothRect: [cornerRadius, smoothness, 0, 0]
        case .star: [starCurve, starRotation, starScale, Float(starSides)]
        case .circle, .rotatedPill: [0, 0, 0, 0]
        }
    }
}

/// Picked cover photos, kept in Application Support/PlaylistCovers (temporary directory for UI tests).
nonisolated enum PlaylistCoverStore {
    static func save(_ data: Data, temporary: Bool) -> URL? {
        let base = temporary ? FileManager.default.temporaryDirectory
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let directory = base?.appendingPathComponent("PlaylistCovers", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString + ".img")
        return (try? data.write(to: url, options: .atomic)) != nil ? url : nil
    }
}

// MARK: - Form view

/// Android `PlaylistFormContent`.
private struct PlaylistCoverFormView: View {
    @Binding var form: PlaylistCoverForm
    let isEditing: Bool
    @Binding var isSmart: Bool
    @Binding var smartRule: SmartPlaylistRule
    @Binding var photoItem: PhotosPickerItem?

    @Environment(LibraryStore.self) private var library
    @Environment(\.appTheme) private var theme
    @State private var showsPhotoPicker = false

    var body: some View {
        VStack(spacing: 0) {
            preview
                .frame(height: 240)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .padding(.bottom, 4)
            ScrollView {
                VStack(spacing: 4) {
                    nameField
                        .padding(.horizontal, 22)
                    Spacer().frame(height: 8)
                    if !isEditing {
                        modeSelector
                            .padding(.horizontal, 22)
                        if isSmart {
                            smartRules
                                .padding(.horizontal, 22)
                                .padding(.vertical, 6)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    tabGroup
                        .padding(.horizontal, 22)
                        .padding(.top, 4)
                    if form.tab == .icon {
                        iconControls
                            .padding(.top, 14)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    Spacer().frame(height: 100)
                }
                .animation(PixlMotion.state, value: isSmart)
                .animation(PixlMotion.state, value: form.tab)
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .photosPicker(isPresented: $showsPhotoPicker, selection: $photoItem, matching: .images)
        .accessibilityIdentifier("editor.form")
    }

    // MARK: Preview

    @ViewBuilder
    private var preview: some View {
        ZStack {
            switch form.tab {
            case .standard:
                VStack(spacing: 16) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 64, weight: .regular))
                        .foregroundStyle(theme.onSurfaceVariant.opacity(0.5))
                        .frame(width: 180, height: 180)
                        .background(RoundedRectangle(cornerRadius: 32, style: .continuous).fill(theme.surfaceContainerHighest))
                    Text("Auto-generated collage")
                        .pixlFont(.bodySmall)
                        .foregroundStyle(theme.onSurfaceVariant)
                }
            case .image:
                imagePreview
            case .icon:
                // The editor shows raw corner points at 180 pt (Android's preview); covers scale from a 200 pt base.
                PlaylistCoverArt(imageUri: nil, colorArgb: Int32(bitPattern: form.colorArgb), iconName: form.iconName,
                                 shapeType: form.shape.rawValue, details: previewDetails, songs: [], size: 180)
                    .id(form.shape)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: form.tab)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: form.shape)
    }

    private var previewDetails: [Float?] {
        var details = form.shapeDetails
        if form.shape == .smoothRect { details[0] = form.cornerRadius * 200 / 180 }
        return details
    }

    @ViewBuilder
    private var imagePreview: some View {
        if let uri = form.imageUri, let source = ArtworkSource(uriString: uri) {
            VStack(spacing: 12) {
                ArtworkView(source: source, size: 180, cornerRadius: 32)
                HStack(spacing: 8) {
                    Button { showsPhotoPicker = true } label: {
                        smallActionLabel("Change", systemImage: "photo.badge.plus")
                    }
                    .buttonStyle(.plain)
                    .pixlGlass(in: Capsule(), tint: theme.secondaryContainer.opacity(GlassTint.prominent), interactive: true)
                    Button {
                        withAnimation(PixlMotion.state) { form.imageUri = nil }
                    } label: {
                        smallActionLabel("Remove", systemImage: "trash")
                    }
                    .buttonStyle(.plain)
                    .pixlGlass(in: Capsule(), tint: theme.errorContainer.opacity(GlassTint.prominent), interactive: true)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: 260)
            }
        } else {
            Button { showsPhotoPicker = true } label: {
                VStack(spacing: 12) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 48, weight: .regular))
                    Text("Pick Image").pixlFont(.titleSmall)
                }
                .foregroundStyle(theme.onSurfaceVariant)
                .frame(width: 180, height: 180)
                .background(RoundedRectangle(cornerRadius: 32, style: .continuous).fill(theme.surfaceContainerHighest))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add Photo")
        }
    }

    private func smallActionLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 15, weight: .semibold))
            Text(title).pixlFont(.labelLarge).lineLimit(1)
        }
        .foregroundStyle(theme.onSurface)
        .frame(maxWidth: .infinity, minHeight: 40)
        .contentShape(.capsule)
    }

    // MARK: Fields

    /// Android `OutlinedTextField` (16 pt corners, `surfaceContainerHigh`, no outline): label and placeholder.
    private var nameField: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Playlist Name")
                .pixlFont(.bodySmall)
                .foregroundStyle(theme.onSurfaceVariant)
            TextField("My awesome mix", text: $form.name)
                .pixlFont(.bodyLarge)
                .foregroundStyle(theme.onSurface)
                .submitLabel(.done)
                .accessibilityIdentifier("editor.name")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                   tint: theme.surfaceContainerHigh.opacity(GlassTint.surface))
    }

    /// Android `SingleChoiceSegmentedButtonRow` (Manual | Smart): connected segments, the selected one
    /// `secondaryContainer` with a check.
    private var modeSelector: some View {
        GlassEffectContainer(spacing: 1) {
            HStack(spacing: 2) {
                segment("Manual", selected: !isSmart, leading: 20, trailing: 4) { isSmart = false }
                segment("Smart", selected: isSmart, leading: 4, trailing: 20) { isSmart = true }
            }
        }
    }

    private func segment(_ title: String, selected: Bool, leading: CGFloat, trailing: CGFloat,
                         action: @escaping () -> Void) -> some View {
        SegmentedGlassButton(title: title, systemImage: selected ? "checkmark" : "circle.dashed",
                             accessibilityLabel: title, leading: leading, trailing: trailing, height: 40,
                             horizontalPadding: 12, iconSize: selected ? 16 : 0,
                             tint: (selected ? theme.secondaryContainer : theme.surfaceContainerLow)
                                 .opacity(selected ? GlassTint.prominent : GlassTint.surface),
                             foreground: selected ? theme.onSecondaryContainer : theme.onSurface,
                             titleStyle: .labelLarge, action: action)
            .frame(maxWidth: .infinity)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("editor.mode.\(title)")
    }

    private var smartRules: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Smart Rule")
                .pixlFont(.titleSmall)
                .foregroundStyle(theme.onSurfaceVariant)
            ScrollView(.horizontal, showsIndicators: false) {
                GlassEffectContainer(spacing: 3) {
                    HStack(spacing: 8) {
                        ForEach(SmartPlaylistRule.allCases, id: \.self) { rule in
                            ruleChip(rule)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .scrollClipDisabled()
            Text(smartRule.subtitle)
                .pixlFont(.bodySmall)
                .foregroundStyle(theme.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Android `FilterChip` (capsule; selected `secondaryContainer` with a check).
    private func ruleChip(_ rule: SmartPlaylistRule) -> some View {
        let selected = smartRule == rule
        return Button { withAnimation(PixlMotion.selection) { smartRule = rule } } label: {
            HStack(spacing: 6) {
                if selected { Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)) }
                Text(rule.title).pixlFont(.labelLarge)
            }
            .foregroundStyle(selected ? theme.onSecondaryContainer : theme.onSurfaceVariant)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: Capsule(), tint: selected ? theme.secondaryContainer.opacity(GlassTint.prominent) : nil,
                   interactive: true)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// Android `ExpressiveButtonGroup`: three equal 48 pt buttons, 4 pt apart; the selected one a `primary` capsule
    /// with a check, the others 10 pt `surfaceContainerHigh` tiles.
    private var tabGroup: some View {
        GlassEffectContainer(spacing: 2) {
            HStack(spacing: 4) {
                ForEach(PlaylistCoverForm.Tab.allCases, id: \.self) { tab in
                    let selected = form.tab == tab
                    let radius: CGFloat = selected ? 24 : 10
                    SegmentedGlassButton(title: tab.title, systemImage: "checkmark", accessibilityLabel: tab.title,
                                         leading: radius, trailing: radius, height: 48, horizontalPadding: 8,
                                         iconSize: selected ? 18 : 0,
                                         tint: (selected ? theme.primary : theme.surfaceContainerHigh)
                                             .opacity(selected ? GlassTint.prominent : GlassTint.container),
                                         foreground: selected ? theme.onPrimary : theme.onSurface,
                                         titleStyle: .labelLarge.weight(selected ? .bold : .medium)) {
                        withAnimation(PixlMotion.selection) { form.tab = tab }
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("editor.tab.\(tab.title)")
                }
            }
        }
    }

    // MARK: Icon tab

    private var iconControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Background Color")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 52, maximum: 52), spacing: 12)], alignment: .leading,
                      spacing: 12) {
                ForEach(colorChoices, id: \.self) { argb in
                    colorCell(argb)
                }
            }
            .padding(.horizontal, 18)
            Spacer().frame(height: 0)
            sectionTitle("Icon Symbol")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 52, maximum: 52), spacing: 12)], alignment: .leading,
                      spacing: 12) {
                ForEach(PlaylistIcons.names, id: \.self) { name in
                    iconCell(name)
                }
            }
            .padding(.horizontal, 18)
            Spacer().frame(height: 8)
            sectionTitle("Shape Style")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(PlaylistShapeType.allCases, id: \.self) { shape in
                        shapeCell(shape)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
            }
            shapeParameters
        }
    }

    /// Android's palette: primary, primaryContainer, secondary, secondaryContainer, tertiary, tertiaryContainer, error,
    /// errorContainer, surfaceContainerHigh, inverseSurface.
    private var colorChoices: [UInt32] {
        [\ColorRoles.primary, \.primaryContainer, \.secondary, \.secondaryContainer, \.tertiary, \.tertiaryContainer,
         \.error, \.errorContainer, \.surfaceContainerHigh, \.inverseSurface].map { theme.argb($0) }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .pixlFont(.titleSmall)
            .foregroundStyle(theme.onSurfaceVariant)
            .padding(.leading, 22)
    }

    /// Android: a 52 pt cell; selected = 12 pt corners with a 3 pt ring of the colour around a 42 pt swatch.
    private func colorCell(_ argb: UInt32) -> some View {
        let selected = form.colorArgb == argb
        let radius: CGFloat = selected ? 12 : 24
        return Button { withAnimation(PixlMotion.state) { form.colorArgb = argb } } label: {
            RoundedRectangle(cornerRadius: selected ? 8 : radius, style: .continuous)
                .fill(Color(argb: argb))
                .frame(width: selected ? 42 : 48, height: selected ? 42 : 48)
                .frame(width: 52, height: 52)
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .stroke(Color(argb: argb), lineWidth: 3)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityLabel("Colour")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func iconCell(_ name: String) -> some View {
        let selected = form.iconName == name
        return Button { withAnimation(PixlMotion.state) { form.iconName = name } } label: {
            Image(systemName: PlaylistIcons.symbol(for: name))
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(selected ? theme.onPrimaryContainer : theme.onSurface)
                .frame(width: 52, height: 52)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: RoundedRectangle(cornerRadius: selected ? 12 : 24, style: .continuous),
                   tint: (selected ? theme.primaryContainer : theme.surfaceContainer)
                       .opacity(selected ? GlassTint.prominent : GlassTint.surface),
                   interactive: true)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func shapeCell(_ shape: PlaylistShapeType) -> some View {
        let selected = form.shape == shape
        let previewDetails: [Float?] = shape == .smoothRect ? [12 * 200 / 50, 60, 0, 0]
            : (shape == .star ? [0.15, 0, 1, 5] : [0, 0, 0, 0])
        return Button { withAnimation(PixlMotion.state) { form.shape = shape } } label: {
            Rectangle()
                .fill(selected ? theme.primary : theme.onSurfaceVariant)
                .frame(width: 50, height: 50)
                .clipShape(PlaylistCoverShape(type: shape.rawValue, size: 50, details: previewDetails))
                .rotationEffect(.degrees(shape == .rotatedPill ? 45 : 0))
                .padding(12)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: RoundedRectangle(cornerRadius: selected ? 12 : 24, style: .continuous),
                   tint: (selected ? theme.primaryContainer : theme.surfaceContainer)
                       .opacity(selected ? GlassTint.prominent : GlassTint.surface),
                   interactive: true)
        .accessibilityLabel(shape.rawValue)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("editor.shape.\(shape.rawValue)")
    }

    @ViewBuilder
    private var shapeParameters: some View {
        switch form.shape {
        case .smoothRect:
            parameterGroup {
                ShapeParameterCard(title: "Corner Radius", value: $form.cornerRadius, range: 0...50) { "\(Int($0))" }
                ShapeParameterCard(title: "Smoothness", value: $form.smoothness, range: 0...100) { "\(Int($0))%" }
            }
        case .star:
            parameterGroup {
                ShapeParameterCard(title: "Sides", value: Binding(get: { Float(form.starSides) },
                                                                  set: { form.starSides = Int($0.rounded()) }),
                                   range: 3...20, step: 1) { "\(Int($0))" }
                ShapeParameterCard(title: "Curve", value: $form.starCurve, range: 0...0.5) { String(format: "%.2f", $0) }
                ShapeParameterCard(title: "Rotation", value: $form.starRotation, range: 0...360) { "\(Int($0))°" }
                ShapeParameterCard(title: "Scale", value: $form.starScale, range: 0.5...1.5) { String(format: "%.1fx", $0) }
            }
        case .circle, .rotatedPill:
            EmptyView()
        }
    }

    private func parameterGroup<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Shape parameters")
                .pixlFont(.titleSmall)
                .foregroundStyle(theme.onSurfaceVariant)
            content()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
    }
}

/// Android `ShapeParameterCard`: a 16 pt `surfaceContainerLow` card, 16 pt padding, the label (`labelMedium`) and the
/// value (`labelLarge` bold) above the slider (`primary`).
private struct ShapeParameterCard: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var step: Float?
    let display: (Float) -> String

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(title)
                    .pixlFont(.labelMedium)
                    .foregroundStyle(theme.onSurfaceVariant)
                Spacer()
                Text(display(value))
                    .pixlFont(.labelLarge, weight: .bold)
                    .foregroundStyle(theme.onSurface)
                    .monospacedDigit()
            }
            if let step {
                Slider(value: $value, in: range, step: step)
            } else {
                Slider(value: $value, in: range)
            }
        }
        .tint(theme.primary)
        .padding(16)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                   tint: theme.surfaceContainerLow.opacity(GlassTint.surface))
    }
}
