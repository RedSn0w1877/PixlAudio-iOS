import PhotosUI
import PixlModel
import SwiftUI
import UIKit

/// "Edit song" (Android `EditSongSheet`), full screen: the "Edit song" title (`displaySmall`) with an info circle,
/// then — 16 pt margins, 12 pt apart — the cover-art card and the fields (title, artist, album, album artist, genre,
/// composer, track and disc number, ReplayGain track / album, lyrics), each a coloured label over a 10 pt rounded
/// field with a role-coloured icon; Cancel and Save float in a capsule at the bottom (hidden while typing).
/// Timed lyrics show their words read-only with "Change the words" / "Fix timing" (the sync editor). Saving goes
/// through `SongTagEditor` (override + file write-back).
struct EditSongSheet: View {
    let songId: String

    @Environment(AppEnvironment.self) private var env
    @Environment(LibraryStore.self) private var library
    @Environment(Router.self) private var router
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var form: SongEditForm?
    @State private var showsInfo = false
    @State private var showsPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var cropSource: CropSource?
    @State private var coverPreview: UIImage?
    @State private var isKeyboardVisible = false
    /// The words of timed lyrics (nil for plain lyrics), decoded when the lyrics text is set — not on every body
    /// pass (each keystroke in any field and each keyboard show / hide re-runs the form).
    @State private var timedWords: String?
    @State private var isApplyingCrop = false
    /// Set while Save writes the cover and applies the edit: a second tap is ignored (Save ran once, synchronously,
    /// before the cover write moved off the main thread).
    @State private var isSaving = false

    var body: some View {
        Group {
            if let song = library.song(id: songId) {
                content(song)
            } else {
                Text("Song not found")
                    .pixlFont(.bodyLarge)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.surface.ignoresSafeArea())
        .accessibilityIdentifier("screen.editSong")
    }

    private func content(_ song: Song) -> some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                if form != nil {
                    VStack(spacing: 12) {
                        CoverArtEditorCard(song: song, preview: coverPreview, isDeleted: form?.cover == .deleted,
                                           onPick: { showsPhotoPicker = true },
                                           onDelete: {
                                               coverPreview = nil
                                               form?.cover = .deleted
                                           },
                                           onReset: {
                                               coverPreview = nil
                                               form?.cover = .unchanged
                                           })
                        fields(song)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, isKeyboardVisible ? 8 : 120)
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .overlay(alignment: .bottom) {
            if !isKeyboardVisible { bottomToolbar(song).transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .animation(PixlMotion.bars, value: isKeyboardVisible)
        // The form exists before the first frame, so the cover slides up with its fields instead of inserting the
        // card and eleven glass fields mid-presentation.
        .onAppear {
            if form == nil {
                form = SongEditForm(song: song)
                timedWords = Self.timedLyrics(form?.lyrics ?? "")
            }
        }
        .task(id: song.id) {
            if form == nil {
                form = SongEditForm(song: song)
                timedWords = Self.timedLyrics(form?.lyrics ?? "")
            }
            guard let tags = await SongEditForm.embeddedMetadata(for: song) else { return }
            if form?.lyrics.isEmpty == true, let lyrics = tags.lyrics, !lyrics.isEmpty {
                form?.lyrics = lyrics
                timedWords = Self.timedLyrics(lyrics)
            }
            if let composer = tags.composer, !composer.isEmpty { form?.composer = composer }
            form?.replayGainTrack = SongEditForm.replayGainText(tags.replayGainTrackGainDb)
            form?.replayGainAlbum = SongEditForm.replayGainText(tags.replayGainAlbumGainDb)
        }
        .photosPicker(isPresented: $showsPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                // Decoded off the main thread before the crop sheet presents (a 12–48 MP photo decoded on its first
                // draw stalled the presentation); full resolution, so the crop is the same.
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    LibraryToast.shared.show(String(localized: "Unable to load the selected image"))
                    return
                }
                cropSource = CropSource(image: await image.byPreparingForDisplay() ?? image)
                photoItem = nil
            }
        }
        .sheet(item: $cropSource) { source in
            CoverArtCropperSheet(image: source.image) { result in
                coverPreview = result.preview
                form?.cover = .replaced(result.jpeg)
                cropSource = nil
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .alert("Editing song metadata", isPresented: $showsInfo) {
            Button("Got it", role: .cancel) {}
        } message: {
            Text("Editing a song's metadata can affect how it's displayed and organized in your library. Changes are permanent and may not be reversible.")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
    }

    private var topBar: some View {
        HStack {
            Text("Edit song")
                .pixlFont(.displaySmall)
                .foregroundStyle(theme.onSurface)
                .padding(.leading, 10)
            Spacer()
            GlassCircleButton(systemImage: "info.circle.fill", accessibilityLabel: "Show information",
                              tint: theme.secondaryContainer.opacity(GlassTint.container),
                              foreground: theme.onSecondaryContainer) {
                showsInfo = true
            }
            .padding(.trailing, 10)
        }
        .padding(.horizontal, 8)
        .frame(height: 64)
    }

    // MARK: Fields

    @ViewBuilder
    private func fields(_ song: Song) -> some View {
        if let binding = Binding($form) {
            field("Title", text: binding.title, systemImage: "music.note", color: theme.tertiary)
            field("Artist", text: binding.artist, systemImage: "person.fill", color: theme.primary)
            field("Album", text: binding.album, systemImage: "opticaldisc", color: theme.tertiary)
            field("Album artist", text: binding.albumArtist, systemImage: "person.fill", color: theme.secondary)
            field("Genre", text: binding.genre, systemImage: "square.grid.2x2.fill", color: theme.secondary)
            field("Composer", text: binding.composer, systemImage: "music.note", color: theme.tertiary)
            field("Track number", text: binding.trackNumber, systemImage: "list.number", color: theme.secondary,
                  keyboard: .numberPad)
            field("Disc number", text: binding.discNumber, systemImage: "list.number", color: theme.secondary,
                  keyboard: .numberPad)
            field("ReplayGain track (dB)", text: binding.replayGainTrack, systemImage: "repeat.1",
                  color: theme.primary, placeholder: "-6.50", keyboard: .numbersAndPunctuation)
            field("ReplayGain album (dB)", text: binding.replayGainAlbum, systemImage: "repeat",
                  color: theme.tertiary, placeholder: "-8.20", keyboard: .numbersAndPunctuation)
            lyricsField(song, form: binding)
        }
    }

    private func field(_ label: LocalizedStringKey, text: Binding<String>, systemImage: String, color: Color,
                       placeholder: LocalizedStringKey? = nil, keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .pixlFont(.labelLarge)
                .foregroundStyle(color)
                .padding(.leading, 4)
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 24)
                TextField(placeholder ?? label, text: text)
                    .pixlFont(.bodyLarge)
                    .foregroundStyle(theme.onSurface)
                    .keyboardType(keyboard)
            }
            .padding(.horizontal, 14)
            .frame(height: 56)
            .pixlGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous),
                       tint: theme.surfaceContainerHigh.opacity(GlassTint.surface))
        }
    }

    @ViewBuilder
    private func lyricsField(_ song: Song, form: Binding<SongEditForm>) -> some View {
        let timed = timedWords
        VStack(alignment: .leading, spacing: 4) {
            Text("Lyrics")
                .pixlFont(.labelLarge)
                .foregroundStyle(theme.primary)
                .padding(.leading, 4)
            if let timed {
                lyricsBox {
                    Text(timed)
                        .pixlFont(.bodyLarge)
                        .foregroundStyle(theme.onSurface)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 8) {
                    syncButton("Change the words", systemImage: nil) { openSyncEditor(song, entry: .words) }
                    syncButton("Fix timing", systemImage: "hand.tap") { openSyncEditor(song, entry: .fixTiming) }
                }
            } else {
                HStack(spacing: 8) {
                    lyricsBox {
                        TextEditor(text: Binding(get: { form.wrappedValue.lyrics },
                                                 set: { text in
                                                     form.wrappedValue.lyrics = text
                                                     form.wrappedValue.lyricsEdited = true
                                                     // A pasted timed document turns into its words, as before.
                                                     if text.trimmingCharacters(in: .whitespacesAndNewlines)
                                                         .hasPrefix("{") {
                                                         timedWords = Self.timedLyrics(text)
                                                     }
                                                 }))
                            .pixlFont(.bodyLarge)
                            .foregroundStyle(theme.onSurface)
                            .scrollContentBackground(.hidden)
                    }
                    GlassCircleButton(systemImage: "magnifyingglass", accessibilityLabel: "Search lyrics on lrclib.net",
                                      tint: theme.secondaryContainer.opacity(GlassTint.container),
                                      foreground: theme.onSecondaryContainer) {
                        searchLyrics(form.wrappedValue)
                    }
                }
            }
        }
    }

    private func lyricsBox<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.primary)
                .frame(width: 24)
                .padding(.top, 8)
            ScrollView { content() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(height: 150)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous),
                   tint: theme.surfaceContainerHigh.opacity(GlassTint.surface))
    }

    private func syncButton(_ title: LocalizedStringKey, systemImage: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 15, weight: .semibold)) }
                Text(title).pixlFont(.labelLarge).lineLimit(1)
            }
            .foregroundStyle(theme.onSecondaryContainer)
            .frame(maxWidth: .infinity, minHeight: 40)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: Capsule(), tint: theme.secondaryContainer.opacity(GlassTint.prominent), interactive: true)
    }

    /// The words of a timed lyrics document (never its JSON).
    static func timedLyrics(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let doc = LyricsDocCodec.decode(trimmed) else { return nil }
        return doc.lines.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
    }

    private func openSyncEditor(_ song: Song, entry: SyncEntry) {
        dismiss()
        LyricsSyncEditorView.open(songId: song.id, router: router, entry: entry)
    }

    /// Android opens lrclib.net's search for the title and artist.
    private func searchLyrics(_ form: SongEditForm) {
        let query = "\(form.title) \(form.artist)"
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
        if let url = URL(string: "https://lrclib.net/search/\(encoded)") { openURL(url) }
    }

    // MARK: Toolbar

    private func bottomToolbar(_ song: Song) -> some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: {
                Text("Cancel")
                    .pixlFont(.labelLarge)
                    .foregroundStyle(theme.onSecondaryContainer)
                    .padding(.horizontal, 24)
                    .frame(height: 48)
                    .background(Capsule().fill(theme.secondaryContainer))
                    .contentShape(.capsule)
            }
            .buttonStyle(PressScaleButtonStyle(pressedScale: 0.95))
            Button {
                guard !isSaving else { return }
                guard let form else { dismiss(); return }
                // The new cover's JPEG is written off the main thread; the edit is applied and the cover dismissed
                // together right after, as before.
                isSaving = true
                Task {
                    let coverURL = await SongTagEditor.writeCover(form.cover, songId: song.id,
                                                                  temporary: env.launch.isUITest)
                    SongTagEditor(env: env).save(form, for: song, coverURL: coverURL)
                    dismiss()
                }
            } label: {
                Text("Save")
                    .pixlFont(.labelLarge)
                    .foregroundStyle(theme.onPrimary)
                    .padding(.horizontal, 24)
                    .frame(height: 48)
                    .background(Capsule().fill(theme.primary))
                    .contentShape(.capsule)
            }
            .buttonStyle(PressScaleButtonStyle(pressedScale: 0.95))
            .accessibilityIdentifier("editSong.save")
        }
        .padding(8)
        .pixlGlass(in: Capsule(), tint: theme.surfaceContainerLow.opacity(GlassTint.container))
        .padding(.bottom, 24)
    }
}

/// An image picked for the cover, waiting to be cropped.
private struct CropSource: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// Android `CoverArtEditorCard`: "Cover art", the current / new cover (up to 220 pt, 22 pt corners, a light scrim),
/// the hint, then Change cover art and Delete cover art (or Reset after a change).
private struct CoverArtEditorCard: View {
    let song: Song
    let preview: UIImage?
    let isDeleted: Bool
    let onPick: () -> Void
    let onDelete: () -> Void
    let onReset: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 14) {
            Text("Cover art")
                .pixlFont(.titleMedium, weight: .semibold)
                .foregroundStyle(theme.onSurface)
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(theme.surfaceContainerHighest)
                if isDeleted {
                    Image(systemName: "music.note")
                        .font(.system(size: 60, weight: .semibold))
                        .foregroundStyle(theme.onSurfaceVariant)
                } else if let preview {
                    Image(uiImage: preview).resizable().scaledToFill()
                } else {
                    ArtworkView(song: song, size: 220, cornerRadius: 22)
                }
                LinearGradient(colors: [.clear, theme.surface.opacity(0.25)], startPoint: .top, endPoint: .bottom)
            }
            .frame(width: 220, height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            Text("Select a square image and fine-tune it so your cover art looks great across the app.")
                .pixlFont(.bodySmall)
                .foregroundStyle(theme.onSurfaceVariant)
                .multilineTextAlignment(.center)
            VStack(spacing: 8) {
                pill("Change cover art", systemImage: "photo", fill: theme.secondaryContainer,
                     foreground: theme.onSecondaryContainer, action: onPick)
                if preview != nil || isDeleted {
                    Button(action: onReset) {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                            .pixlFont(.labelLarge)
                            .foregroundStyle(theme.primary)
                            .frame(minHeight: 40)
                    }
                    .buttonStyle(.plain)
                } else if song.albumArtUriString != nil {
                    pill("Delete cover art", systemImage: "trash", fill: theme.errorContainer,
                         foreground: theme.onErrorContainer, action: onDelete)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                   tint: theme.surfaceContainerHigh.opacity(GlassTint.surface))
    }

    private func pill(_ title: LocalizedStringKey, systemImage: String, fill: Color, foreground: Color,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).font(.system(size: 16, weight: .semibold))
                Text(title).pixlFont(.labelLarge).lineLimit(1)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 24)
            .frame(minHeight: 40)
            .background(Capsule().fill(fill))
            .contentShape(.capsule)
        }
        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.95))
    }
}

/// The crop result: a preview and the JPEG written into the tags.
nonisolated struct CoverArtCrop: Sendable {
    let preview: UIImage
    let jpeg: Data
}

/// Android `CoverArtCropperDialog`: "Adjust your cover art", a square (up to 320 pt, 32 pt corners) to pinch (1–4×)
/// and drag the image in, a 3×3 grid, the hint, Cancel / Apply cover art. The crop is rendered at 1000 px (JPEG 95 %).
struct CoverArtCropperSheet: View {
    let image: UIImage
    let onConfirm: (CoverArtCrop) -> Void

    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @State private var side: CGFloat = 320
    @State private var isRendering = false

    var body: some View {
        VStack(spacing: 18) {
            Text("Adjust your cover art")
                .pixlFont(.headlineSmall)
                .foregroundStyle(theme.onSurface)
                .multilineTextAlignment(.center)
            ZStack {
                theme.surfaceDim
                let display = displaySize(side: side)
                Image(uiImage: image)
                    .resizable()
                    .frame(width: display.width, height: display.height)
                    .offset(offset)
                Canvas { context, size in
                    let color = theme.onSurface.opacity(0.18)
                    for i in 1..<3 {
                        let x = size.width / 3 * CGFloat(i)
                        var vertical = Path()
                        vertical.move(to: CGPoint(x: x, y: 0))
                        vertical.addLine(to: CGPoint(x: x, y: size.height))
                        context.stroke(vertical, with: .color(color), lineWidth: 1)
                        var horizontal = Path()
                        horizontal.move(to: CGPoint(x: 0, y: x))
                        horizontal.addLine(to: CGPoint(x: size.width, y: x))
                        context.stroke(horizontal, with: .color(color), lineWidth: 1)
                    }
                    context.stroke(Path(CGRect(origin: .zero, size: size)), with: .color(color), lineWidth: 1.5)
                }
                .allowsHitTesting(false)
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            .contentShape(.rect)
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        scale = min(max(baseScale * value.magnification, 1), 4)
                        offset = clamped(offset, scale: scale)
                    }
                    .onEnded { _ in baseScale = scale }
                    .simultaneously(with: DragGesture()
                        .onChanged { value in
                            offset = clamped(CGSize(width: baseOffset.width + value.translation.width,
                                                    height: baseOffset.height + value.translation.height),
                                             scale: scale)
                        }
                        .onEnded { _ in baseOffset = offset })
            )
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { side = min($0, 320) }
            Text("Use pinch and drag gestures to find the perfect framing.")
                .pixlFont(.bodySmall)
                .foregroundStyle(theme.onSurfaceVariant)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.glass)
                Button("Apply cover art") {
                    // Drawn and encoded off the main thread; then preview and dismiss, in the same order as before.
                    isRendering = true
                    let image = self.image, side = self.side, offset = self.offset
                    let display = displaySize(side: side)
                    Task {
                        let crop = await Task.detached(priority: .userInitiated) {
                            Self.render(image: image, side: side, offset: offset, display: display)
                        }.value
                        isRendering = false
                        if let crop { onConfirm(crop) }
                    }
                }
                .buttonStyle(.glassProminent)
                .tint(theme.primary)
                .disabled(isRendering)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
        .accessibilityIdentifier("sheet.coverCrop")
    }

    /// The image at "crop" fill for the square, times the pinch.
    private func displaySize(side: CGFloat) -> CGSize {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return CGSize(width: side, height: side) }
        let fill = max(side / size.width, side / size.height) * scale
        return CGSize(width: size.width * fill, height: size.height * fill)
    }

    /// Android `clampOffset`: the image always covers the square.
    private func clamped(_ value: CGSize, scale: CGFloat) -> CGSize {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return .zero }
        let fill = max(side / size.width, side / size.height) * scale
        let maxX = max(0, (size.width * fill - side) / 2)
        let maxY = max(0, (size.height * fill - side) / 2)
        return CGSize(width: min(max(value.width, -maxX), maxX), height: min(max(value.height, -maxY), maxY))
    }

    nonisolated private static func render(image: UIImage, side: CGFloat, offset: CGSize,
                                           display: CGSize) -> CoverArtCrop? {
        let output: CGFloat = 1000
        let k = output / max(side, 1)
        let origin = CGPoint(x: ((side - display.width) / 2 + offset.width) * k,
                             y: ((side - display.height) / 2 + offset.height) * k)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: output, height: output), format: format)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: origin, size: CGSize(width: display.width * k, height: display.height * k)))
        }
        guard let jpeg = rendered.jpegData(compressionQuality: 0.95) else { return nil }
        return CoverArtCrop(preview: rendered, jpeg: jpeg)
    }
}
