import SwiftUI
#if os(iOS)
import MediaPlayer
import UIKit
#endif

/// Immersive full-window now-playing page: artwork-tinted gradient backdrop,
/// large artwork on the left, big synced lyrics on the right.
struct NowPlayingView: View {
    private enum ActiveSheet: String, Identifiable {
        case quality
        case comments
        case lyricsOptions
        case downloads
        case addToPlaylist
        case lyricPoster
        case customCover

        var id: String { rawValue }
    }

    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var lyricsCursor = PlayerService.shared.lyricsCursor
    @EnvironmentObject private var settings: SettingsManager
    @ObservedObject private var favorites = FavoritesStore.shared
    #if os(iOS)
    @ObservedObject private var backgroundStore = BackgroundImageStore.shared
    @ObservedObject private var customCovers = CustomSongCoverStore.shared
    private var customCoverView: AnyView? {
        if let entry = customCovers.entry(for: player.currentTrack) {
            return AnyView(CustomCoverMedia(entry: entry))
        }
        return nil
    }
    @ObservedObject private var dynamicWallpaper = DynamicWallpaperStore.shared
    @ObservedObject private var playerAmbience = PlayerAmbienceStore.shared
    @Environment(\.dismissNowPlayingAction) private var dismissNowPlayingAction
    @Environment(\.dismissNowPlayingDragAction) private var dismissNowPlayingDragAction
    #endif

    @State private var artworkImage: PlatformImage?
    @State private var colors: ArtworkColors = .fallback
    @State private var activeIndex: Int?
    @State private var isUserScrolling = false
    @State private var resumeTask: Task<Void, Never>?
    @State private var showLyricsOnMobile = false
    @State private var activeSheet: ActiveSheet?
    @State private var airPlayRequest = 0
    #if os(iOS)
    @ObservedObject private var playerLayout = PlayerLayoutStore.shared
    #endif
    #if os(iOS)
    @State private var showQueueOnMobile = false
    #endif

    var body: some View {
        GeometryReader { geo in
            let isCompact = geo.size.width < 720
            let phoneLandscape = isPhoneLandscape(size: geo.size)
            ZStack {
                backdrop

                if phoneLandscape {
                    phoneLandscapeLayout(size: geo.size)
                } else if isCompact {
                    compactLayout(size: geo.size)
                } else {
                    regularLayout(size: geo.size)
                }
            }
            // Pin to the screen width so an intrinsically-wide child can never
            // stretch the ZStack and push the corner overlays off-screen.
            .frame(width: geo.size.width)
            .overlay(alignment: .topLeading) {
                if showsClassicChrome(isCompact: isCompact) {
                    Button {
                        close()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 36, height: 36)
                            .background(.white.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.pressable)
                    .padding(.top, 20)
                    .padding(.leading, 20)
                }
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 8) {
                    if isCompact, showsClassicChrome(isCompact: isCompact) {
                        Button {
                            withAnimation(AppAnimation.standard) {
                                showLyricsOnMobile.toggle()
                            }
                        } label: {
                            Image(systemName: showLyricsOnMobile ? "music.note" : "quote.bubble")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(showLyricsOnMobile ? Theme.accent : .white.opacity(0.85))
                                .frame(width: 36, height: 36)
                                .background(.white.opacity(0.12), in: Circle())
                        }
                        .buttonStyle(.pressable)
                    }

                    if !(isCompact && settings.nowPlayingMode == .immersive) {
                        nowPlayingMoreMenu
                    }
                }
                .padding(.top, 20)
                .padding(.trailing, 20)
            }
            #if os(iOS)
            .overlay {
                if settings.nowPlayingMode == .minimal && showQueueOnMobile {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { showQueueOnMobile = false }
                        .accessibilityLabel("关闭播放列表")
                        .accessibilityAddTraits(.isButton)
                }
            }
            #endif
        }
        #if os(macOS)
        // The window toolbar is hidden while this page is up, but SwiftUI keeps
        // reserving its safe area, which pushed the whole immersive layout —
        // close button included — a toolbar's height down from the window top.
        // iOS keeps its safe area: there the inset is the status bar / notch.
        .ignoresSafeArea()
        #endif
        .preferredColorScheme(.dark)
        .task(id: player.currentTrack?.playbackKey) {
            await loadArtwork()
        }
        #if os(iOS)
        .onAppear {
            syncModePresentation()
        }
        .onChange(of: settings.nowPlayingMode) { _ in
            syncModePresentation()
        }
        .onChange(of: player.currentTrack?.id) { _ in
            if settings.nowPlayingMode == .minimal {
                showLyricsOnMobile = false
            }
        }
        #endif
        #if os(macOS)
        .onExitCommand {
            close()
        }
        #endif
        // One item-driven sheet prevents SwiftUI from trying to present
        // several sheets in the same update when the user taps transport,
        // comments and quality controls quickly in succession.
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .quality:
                QualityPickerSheet()
                    .environmentObject(player)
                    .environmentObject(settings)
            case .comments:
                if let track = player.currentTrack {
                    SongCommentsSheet(track: track)
                } else {
                    EmptyView()
                }
            case .lyricsOptions:
                LyricPresentationSheet()
                    .environmentObject(player)
                    .environmentObject(settings)
            case .downloads:
                #if os(iOS)
                if let track = player.currentTrack {
                    DownloadOptionsSheet(tracks: [track])
                } else {
                    EmptyView()
                }
                #else
                EmptyView()
                #endif
            case .addToPlaylist:
                if let track = player.currentTrack {
                    AddToPlaylistSheet(track: track)
                } else {
                    EmptyView()
                }
            case .lyricPoster:
                #if os(iOS)
                if let track = player.currentTrack {
                    LyricPosterSheet(track: track, lyrics: player.lyrics?.lines ?? [], currentTime: player.progress)
                } else {
                    EmptyView()
                }
                #else
                EmptyView()
                #endif
            case .customCover:
                #if os(iOS)
                if let track = player.currentTrack {
                    CustomCoverPickerSheet(track: track)
                } else {
                    EmptyView()
                }
                #else
                EmptyView()
                #endif
            }
        }
    }

    private var hasLyricsColumn: Bool {
        if let lyrics = player.lyrics, !lyrics.isEmpty { return true }
        return player.lyrics == nil // still loading — keep layout stable
    }

    private func close() {
        #if os(iOS)
        if let dismissNowPlayingAction {
            dismissNowPlayingAction()
        } else {
            withAnimation(NowPlayingPresentationMetrics.presentationAnimation) {
                player.showNowPlaying = false
            }
        }
        #else
        player.showNowPlaying = false
        #endif
    }

    private func showsClassicChrome(isCompact: Bool) -> Bool {
        #if os(iOS)
        return !isCompact || settings.nowPlayingMode == .classic
        #else
        return true
        #endif
    }


    /// Jump straight to the line the song is on. Used when the view appears,
    /// where waiting for the next line change would leave the lyrics parked at
    /// the top. Scrolling is deferred a turn: the list has not laid out yet
    /// while `onAppear` runs, and `scrollTo` on an unlaid list does nothing.
    private func adoptCursor(proxy: ScrollViewProxy) {
        let index = lyricsCursor.activeIndex
        activeIndex = index
        guard let index else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(index, anchor: .center)
        }
    }

    // MARK: - Backdrop

    private var backdrop: some View {
        ZStack {
            Color.black
#if os(iOS)
            if dynamicWallpaper.isEnabled, dynamicWallpaper.syncToPlayer {
                MoumusicDynamicWallpaperView(
                    kind: dynamicWallpaper.kind,
                    speed: dynamicWallpaper.speed,
                    intensity: dynamicWallpaper.intensity
                )
                .overlay(Color.black.opacity(0.18).ignoresSafeArea())
            } else if backgroundStore.syncToPlayer, let image = backgroundStore.image {
                MoumusicWallpaperView(
                    image: image,
                    blurRadius: backgroundStore.blurRadius,
                    dimAmount: 0.32
                )
            } else {
                artworkBackdrop
            }
#else
            artworkBackdrop
#endif
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: colors)
    }

    private var artworkBackdrop: some View {
        ZStack {
            LinearGradient(
                colors: [colors.primary, colors.secondary],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            #if os(iOS)
            MoumusicAmbientGlow(
                colors: colors,
                isPlaying: player.isPlaying,
                isEnabled: playerAmbience.isEnabled,
                breath: playerAmbience.breath,
                dustMode: playerAmbience.dustMode,
                dustDensity: playerAmbience.dustDensity,
                dustSize: playerAmbience.dustSize
            )
            #endif
            RadialGradient(
                colors: [.white.opacity(0.12), .clear],
                center: .topLeading, startRadius: 0, endRadius: 700
            )
            LinearGradient(
                colors: [.clear, .black.opacity(0.35)],
                startPoint: .top, endPoint: .bottom
            )
        }
    }

    private func loadArtwork() async {
        artworkImage = nil
        colors = .fallback
        guard let track = player.currentTrack else {
            return
        }
        let playbackKey = track.playbackKey
        var urlString = track.album.picUrl
        if urlString == nil {
            let query = [track.name, track.artistNames].filter { !$0.isEmpty }.joined(separator: " ")
            if let result = try? await NeteaseAPI.search(query, type: .songs, limit: 6),
               let match = result.songs?.first(where: { $0.name == track.name }) ?? result.songs?.first {
                urlString = match.album.picUrl
            }
        }
        guard let urlString, let url = urlString.resizedImageURL(768) else {
            return
        }
        if let loaded = await ImageCache.shared.image(for: url) {
            guard player.currentTrack?.playbackKey == playbackKey else { return }
            // Video covers (e.g. Bilibili 16:9) are center-cropped to a
            // square so they never overflow the artwork slot.
            let image: UIImage = {
                let w = loaded.size.width, h = loaded.size.height
                guard w > 0, h > 0, abs(w - h) / max(w, h) > 0.03,
                      let cg = loaded.cgImage else { return loaded }
                let s = loaded.scale
                let side = min(w, h) * s
                let rect = CGRect(x: (w * s - side) / 2, y: (h * s - side) / 2, width: side, height: side)
                guard let cropped = cg.cropping(to: rect) else { return loaded }
                return UIImage(cgImage: cropped, scale: s, orientation: loaded.imageOrientation)
            }()
            artworkImage = image
            colors = ArtworkPalette.extract(from: image, cacheKey: urlString)
        }
    }

    // MARK: - Layouts

    @ViewBuilder
    private func phoneLandscapeLayout(size: CGSize) -> some View {
        // Landscape iPhones have very little vertical space.  Keep the
        // title, content and transport areas bounded instead of allowing a
        // maxHeight spacer to push the controls below the visual centre.
        let headerHeight: CGFloat = 48
        let controlsHeight: CGFloat = 72
        let verticalSpacing: CGFloat = 8
        let contentHeight = max(
            132,
            size.height - headerHeight - controlsHeight - verticalSpacing * 3 - 16
        )
        let artworkSize = min(156, max(108, contentHeight - 18))

        VStack(spacing: verticalSpacing) {
            // All compact modes use this same title position.  It remains
            // stable when lyrics are toggled and when the device rotates.
            landscapeTrackHeader
                .frame(height: headerHeight, alignment: .leading)

            HStack(alignment: .center, spacing: 18) {
                artworkView(size: artworkSize)
                    .frame(maxWidth: .infinity, alignment: .center)

                if hasLyricsColumn {
                    lyricsColumn
                        .frame(maxWidth: .infinity, maxHeight: contentHeight)
                } else {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: contentHeight)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: contentHeight)

            VStack(spacing: 2) {
                NowPlayingScrubber(onShowQuality: { activeSheet = .quality })
                    .padding(.horizontal, 16)
                CompactTransportControls()
                    .frame(maxWidth: 360)
            }
            .frame(height: controlsHeight)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private func regularLayout(size: CGSize) -> some View {
        // Everything below the artwork needs ~300pt; shrink the artwork on
        // short displays (iPhone landscape) instead of clipping it.
        let artworkSize = max(120, min(340, size.width * 0.32, size.height - 300))
        return HStack(spacing: 0) {
            leftColumn(artworkSize: artworkSize)
                .frame(maxWidth: .infinity)
            if hasLyricsColumn {
                lyricsColumn
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 48)
        .padding(.vertical, size.height < 500 ? 16 : 24)
    }

    @ViewBuilder
    private func compactLayout(size: CGSize) -> some View {
        #if os(iOS)
        switch settings.nowPlayingMode {
        case .classic:
            classicCompactLayout(size: size)
        case .immersive:
            immersiveCompactLayout(size: size)
        case .minimal:
            minimalCompactLayout(size: size)
        case .lyrics:
            lyricsCompactLayout(size: size)
        case .amll:
            amllCompactLayout(size: size)
        case .vinyl:
            vinylCompactLayout(size: size)
        }
        #else
        classicCompactLayout(size: size)
        #endif
    }

    private func classicCompactLayout(size: CGSize) -> some View {
        let artworkDim = min(size.width - 64, size.height * 0.38, 300)
        return VStack(spacing: 20) {
            compactTrackMetaView
                .padding(.top, compactTitleTopPadding)
            if showLyricsOnMobile {
                // NetEase-style: a small cover on the lyric page returns to the cover page.
                Button {
                    withAnimation(AppAnimation.standard) {
                        showLyricsOnMobile = false
                    }
                } label: {
                    HStack(spacing: 12) {
                        Group {
                            if let customCoverView {
                                customCoverView
                            } else if let artworkImage {
                                Image(platformImage: artworkImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } else {
                                Color.white.opacity(0.1)
                            }
                        }
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        Text("点击封面返回")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.65))
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .accessibilityLabel("返回封面")
                lyricsColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            } else {
                VStack(spacing: 20) {
                    artworkView(size: artworkDim)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(AppAnimation.standard) {
                                showLyricsOnMobile = true
                            }
                        }
                    MiniLyricsView {
                        withAnimation(AppAnimation.standard) {
                            showLyricsOnMobile = true
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .transition(.opacity)
            }
            VStack(spacing: 12) {
                NowPlayingScrubber(onShowQuality: { activeSheet = .quality })
                    .padding(.horizontal, 24)
                CompactVolumeControl()
                    .padding(.horizontal, 24)
                CompactTransportControls()
            }
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 16)
    }

    private func lyricsCompactLayout(size: CGSize) -> some View {
        VStack(spacing: 14) {
            compactTrackMetaView
                .padding(.top, compactTitleTopPadding)
            lyricsColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            NowPlayingScrubber(onShowQuality: { activeSheet = .quality })
                .padding(.horizontal, 20)
            CompactVolumeControl()
                .padding(.horizontal, 20)
            CompactTransportControls()
                .padding(.bottom, 12)
        }
        .padding(.horizontal, 16)
    }

    /// AMLL is a player-page presentation, not a second global player mode.
    /// Keep its typography and controls recognisable while sharing the same
    /// real lyric cursor and source timing as the standard lyric layout.
    private func amllCompactLayout(size: CGSize) -> some View {
        VStack(spacing: 14) {
            // AMLL is a lyric rendering style, not a second song title. Use
            // the shared metadata header so the title never jumps between
            // player modes and remove the redundant small mode label.
            compactTrackMetaView
                .padding(.top, compactTitleTopPadding)

            lyricsColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 4)

            NowPlayingScrubber(onShowQuality: { activeSheet = .quality })
                .padding(.horizontal, 20)
            CompactVolumeControl()
                .padding(.horizontal, 20)
            CompactTransportControls()
                .padding(.bottom, 12)
        }
        .padding(.horizontal, 16)
    }

    private func vinylCompactLayout(size: CGSize) -> some View {
        let artworkDim = min(size.width - 72, size.height * 0.43, 310)
        return VStack(spacing: 16) {
            compactTrackMetaView
                .padding(.top, compactTitleTopPadding)
            VinylTurntableView(
                artworkImage: artworkImage,
                isPlaying: player.isPlaying,
                trackId: player.currentTrack?.id,
                size: artworkDim,
                onTap: {
                    withAnimation(AppAnimation.standard) {
                        showLyricsOnMobile = true
                    }
                },
                onNextTrack: player.next,
                onPreviousTrack: player.previous
            )
            .frame(maxWidth: .infinity)
            MiniLyricsView {
                showLyricsOnMobile = true
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            NowPlayingScrubber(onShowQuality: { activeSheet = .quality })
                .padding(.horizontal, 20)
            CompactTransportControls()
                .padding(.bottom, 12)
        }
        .padding(.horizontal, 16)
    }

    #if os(iOS)
    private func immersiveCompactLayout(size: CGSize) -> some View {
        let artworkDimension = min(size.width - 112, size.height * 0.3, 250)
        let showsExpandedArtwork = !showLyricsOnMobile && !showQueueOnMobile

        return VStack(spacing: 0) {
            Color.clear.frame(
                height: NowPlayingPresentationMetrics.immersiveHeaderTopInset
            )

            CompactTrackHeader(showsExpandedArtwork: showsExpandedArtwork)
                .padding(.bottom, 14)

            ZStack {
                immersiveArtworkContent(artworkDimension: artworkDimension)
                    .opacity(showsExpandedArtwork ? 1 : 0)
                    .allowsHitTesting(showsExpandedArtwork)
                    .accessibilityHidden(!showsExpandedArtwork)

                if showQueueOnMobile {
                    CompactQueueContent()
                        .transition(.opacity)
                } else {
                    IOSImmersiveLyricsColumn()
                        .opacity(showLyricsOnMobile ? 1 : 0)
                        .allowsHitTesting(showLyricsOnMobile)
                        .accessibilityHidden(!showLyricsOnMobile)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            immersiveControls
        }
        .frame(width: max(size.width - 64, 0))
        .padding(.horizontal, 32)
        .overlayPreferenceValue(ImmersiveArtworkFramePreferenceKey.self) { frames in
            GeometryReader { proxy in
                if let compactAnchor = frames[.compact],
                   let expandedAnchor = frames[.expanded] {
                    let compactFrame = proxy[compactAnchor]
                    let expandedFrame = proxy[expandedAnchor]
                    let targetFrame = showsExpandedArtwork ? expandedFrame : compactFrame
                    let targetCenterX = showsExpandedArtwork
                        ? size.width / 2
                        : compactFrame.midX

                    immersiveArtworkSurface(isExpanded: showsExpandedArtwork)
                        .frame(width: targetFrame.width, height: targetFrame.height)
                        .position(x: targetCenterX, y: targetFrame.midY)
                        .accessibilityIdentifier("immersiveArtwork")
                }
            }
            .allowsHitTesting(false)
        }
    }

    private var immersiveControls: some View {
        VStack(spacing: 17) {
            NowPlayingScrubber(onShowQuality: { activeSheet = .quality })
            CompactTransportControls()
            CompactVolumeControl()
            CompactSecondaryControls(
                showsLyrics: showLyricsOnMobile,
                showsQueue: showQueueOnMobile,
                onToggleLyrics: toggleImmersiveLyrics,
                onToggleQueue: toggleImmersiveQueue,
                onComments: { activeSheet = .comments }
            )
        }
        .padding(.top, 14)
        .padding(.bottom, 24)
        .accessibilityIdentifier("immersiveControls")
    }

    private func immersiveArtworkContent(artworkDimension: CGFloat) -> some View {
        VStack(spacing: 18) {
            Spacer(minLength: 8)
            Color.clear
                .frame(width: artworkDimension, height: artworkDimension)
                .anchorPreference(
                    key: ImmersiveArtworkFramePreferenceKey.self,
                    value: .bounds
                ) { [.expanded: $0] }
            MiniLyricsView(onOpen: showImmersiveLyrics)
                .frame(maxWidth: .infinity, maxHeight: 96)
            Spacer(minLength: 0)
        }
    }

    private func immersiveArtworkSurface(isExpanded: Bool) -> some View {
        Group {
            if let customCoverView {
                customCoverView
            } else if let artworkImage {
                Image(platformImage: artworkImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(.white.opacity(isExpanded ? 0.06 : 0.1))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: isExpanded ? 48 : 18, weight: .light))
                            .foregroundStyle(.white.opacity(isExpanded ? 0.3 : 0.45))
                    }
            }
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: isExpanded ? 18 : 12,
                style: .continuous
            )
        )
        .shadow(
            color: .black.opacity(isExpanded ? 0.45 : 0.22),
            radius: isExpanded ? 36 : 10,
            y: isExpanded ? 18 : 4
        )
    }

    private func toggleImmersiveLyrics() {
        withAnimation(ImmersiveArtworkTransition.animation) {
            if showQueueOnMobile {
                showQueueOnMobile = false
                showLyricsOnMobile = true
            } else {
                showLyricsOnMobile.toggle()
            }
        }
    }

    private func showImmersiveLyrics() {
        withAnimation(ImmersiveArtworkTransition.animation) {
            showQueueOnMobile = false
            showLyricsOnMobile = true
        }
    }

    private func toggleImmersiveQueue() {
        withAnimation(ImmersiveArtworkTransition.animation) {
            showQueueOnMobile.toggle()
        }
    }

    private func syncModePresentation() {
        // Only immersive mode owns the floating lyrics/queue overlay state.
        // The other modes render their own dedicated layout below.
        showLyricsOnMobile = settings.nowPlayingMode == .immersive
        showQueueOnMobile = false
    }

    private func minimalCompactLayout(size: CGSize) -> some View {
        let contentWidth = max(size.width - 64, 0)
        let artworkDimension = min(contentWidth, size.height * 0.52, 378)

        return VStack(spacing: 0) {
            // Keep the title in the same top-left position as the other
            // compact modes.  The old metadata-only row appeared only after
            // opening lyrics and was centred, which made rotation/mode
            // changes look like a different player page.
            compactTrackMetaView
                .padding(.top, compactTitleTopPadding)

            ZStack(alignment: .top) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: toggleMinimalLyrics)

                artworkView(size: artworkDimension)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: toggleMinimalLyrics)
                    .accessibilityIdentifier("immersiveArtwork")
                    .accessibilityLabel("显示歌词")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { toggleMinimalLyrics() }
                    .opacity(showLyricsOnMobile ? 0 : 1)
                    .allowsHitTesting(!showLyricsOnMobile)

                IOSMinimalLyricsColumn {
                    showLyricsOnMobile = false
                }
                .opacity(showLyricsOnMobile ? 1 : 0)
                .allowsHitTesting(showLyricsOnMobile)
                .accessibilityHidden(!showLyricsOnMobile)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .simultaneousGesture(
                minimalDismissGesture,
                including: showLyricsOnMobile ? .none : .all
            )
            .padding(.bottom, 12)

            minimalControls
        }
        .frame(width: contentWidth)
        .padding(.horizontal, 32)
        .padding(.bottom, 12)
        .animation(.easeInOut(duration: 0.22), value: showLyricsOnMobile)
    }

    private var compactTitleTopPadding: CGFloat {
        #if os(iOS)
        return NowPlayingPresentationMetrics.immersiveHeaderTopInset
        #else
        return 18
        #endif
    }

    private var minimalControls: some View {
        VStack(spacing: 14) {
            NowPlayingScrubber(onShowQuality: { activeSheet = .quality })
                .padding(.horizontal, 2)
                .padding(.top, 8)
            CompactVolumeControl()
                .padding(.horizontal, 2)
            MinimalTransportControls(
                backdrop: colors,
                showQueue: $showQueueOnMobile
            )
                .padding(.horizontal, 2)
        }
        .accessibilityIdentifier("immersiveControls")
    }

    private func toggleMinimalLyrics() {
        guard showLyricsOnMobile || player.lyrics?.isEmpty == false else { return }
        showLyricsOnMobile.toggle()
    }

    private var minimalDismissGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                guard let dismissNowPlayingDragAction else { return }
                let translation = value.translation
                let isDownward = translation.height > 0
                    && abs(translation.height) > abs(translation.width)
                dismissNowPlayingDragAction.onChanged(isDownward ? translation.height : 0)
            }
            .onEnded { value in
                guard let dismissNowPlayingDragAction else { return }
                let translation = value.translation
                let isDownward = translation.height > 0
                    && abs(translation.height) > abs(translation.width)
                dismissNowPlayingDragAction.onEnded(
                    isDownward ? translation.height : 0,
                    isDownward ? value.predictedEndTranslation.height : 0
                )
            }
    }
    #endif

    // MARK: - Views

    private func sourceName(_ source: String?) -> String {
        LXCatalogPlatform.displayName(for: source)
    }

    private func isPhoneLandscape(size: CGSize) -> Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone
            && size.width > size.height
        #else
        return false
        #endif
    }

    private func artworkView(size: CGFloat) -> some View {
        Group {
            if let customCoverView {
                customCoverView
            } else if let artworkImage {
                Image(platformImage: artworkImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(.white.opacity(0.06))
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 48, weight: .light))
                            .foregroundStyle(.white.opacity(0.3))
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 36, y: 18)
        .scaleEffect(player.isPlaying ? 1 : 0.95)
        .animation(AppAnimation.bouncy, value: player.isPlaying)
        #if os(iOS)
        .moumusicPlayerLayout(playerLayout.entry(for: .artwork, mode: settings.nowPlayingMode))
        #endif
    }

    private var trackMetaView: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(player.currentTrack?.name ?? "")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if player.currentTrack?.fee == 1 {
                    VIPBadge()
                }
            }
            Text("\(player.currentTrack?.artistNames ?? "") — \(player.currentTrack?.album.name ?? "")")
                .font(.system(size: 13.5))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)

        }
        .frame(maxWidth: 400, alignment: .leading)
        #if os(iOS)
        .moumusicPlayerLayout(playerLayout.entry(for: .metadata, mode: settings.nowPlayingMode))
        #endif
    }

    /// Compact player metadata deliberately omits the source/album helper
    /// line.  The source is still shown in the quality sheet, while the
    /// player keeps one stable large title + artist header in every mode.
    private var compactTrackMetaView: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(player.currentTrack?.name ?? "")
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if player.currentTrack?.fee == 1 {
                        VIPBadge()
                    }
                }
                PlayerArtistLink(font: .system(size: 13.5), opacity: 0.65)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(iOS)
        .moumusicPlayerLayout(playerLayout.entry(for: .metadata, mode: settings.nowPlayingMode))
        #endif
    }

    /// The landscape header intentionally contains only the stable song
    /// identity.  Action capsules belong to the transport area; putting them
    /// under the artwork made the title wrap and pushed the controls down.
    private var landscapeTrackHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(player.currentTrack?.name ?? "")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if player.currentTrack?.fee == 1 {
                    VIPBadge()
                }
            }
            PlayerArtistLink(font: .system(size: 13.5), opacity: 0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Beans-style overflow menu for the non-immersive player layouts.  The
    /// heart is intentionally local so every LX track can be saved without a
    /// provider login; provider account likes remain a separate feature.
    private var nowPlayingMoreMenu: some View {
        Menu {
            if let track = player.currentTrack {
                let liked = favorites.contains(track)
                Button {
                    let isLiked = favorites.toggle(track)
                    ToastCenter.shared.show(isLiked ? "已加入本地收藏" : "已取消本地收藏")
                } label: {
                    Label(liked ? "取消收藏" : "收藏歌曲", systemImage: liked ? "heart.fill" : "heart")
                }

                Button {
                    player.addToPlayNext(track)
                } label: {
                    Label("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward")
                }

                Button {
                    activeSheet = .addToPlaylist
                } label: {
                    Label("加入歌单…", systemImage: "music.note.list")
                }

                Button {
                    activeSheet = .comments
                } label: {
                    Label("查看评论", systemImage: "text.bubble")
                }

#if os(iOS)
                Button {
                    activeSheet = .lyricPoster
                } label: {
                    Label("分享歌词海报", systemImage: "text.quote")
                }
                Button {
                    activeSheet = .customCover
                } label: {
                    Label("自定义封面…", systemImage: "photo")
                }
#endif

                PlayerPlaybackModeMenu()

                Button {
                    airPlayRequest += 1
                } label: {
                    Label("AirPlay", systemImage: "airplayaudio")
                }

                Menu {
                    ForEach(LyricsDisplayStyle.allCases) { style in
                        Button {
                            withAnimation(AppAnimation.standard) {
                                settings.lyricsDisplayStyle = style
                            }
                        } label: {
                            HStack {
                                Text(style.displayName)
                                if style == settings.lyricsDisplayStyle {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Label("歌词样式：\(settings.lyricsDisplayStyle.displayName)", systemImage: "textformat")
                }

                Button {
                    activeSheet = .lyricsOptions
                } label: {
                    Label("歌词设置…", systemImage: "slider.horizontal.3")
                }
                Toggle("逐字歌词", isOn: $settings.verbatimLyrics)

#if os(iOS)
                Button {
                    activeSheet = .downloads
                } label: {
                    Label("下载歌曲", systemImage: "arrow.down.circle")
                }
#endif

                Button { player.queueSimilarSongs() } label: { Label("播放相似歌曲", systemImage: "wand.and.stars") }
                SleepTimerMenu(player: player)

                Divider()

                Button {
                    Platform.copyToPasteboard(
                        string: "https://music.163.com/#/song?id=\(track.id)"
                    )
                    ToastCenter.shared.show(String(localized: "链接已复制"))
                } label: {
                    Label("复制链接", systemImage: "link")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.12), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("更多播放操作")
        .accessibilityHint("收藏、歌词样式、评论、歌单和下载")
        .background {
            RoutePickerButton(
                diameter: 1, glyphSize: 1, request: airPlayRequest,
                tint: .clear, background: .clear
            )
            .opacity(0.01)
        }
    }

    private func leftColumn(artworkSize: CGFloat) -> some View {
        VStack(spacing: 26) {
            artworkView(size: artworkSize)
            trackMetaView

            VStack(spacing: 14) {
                NowPlayingScrubber(onShowQuality: { activeSheet = .quality })
                    .frame(maxWidth: 380)
                controls
            }

        }
        .frame(maxHeight: .infinity, alignment: .center)
        .padding(.trailing, hasLyricsColumn ? 30 : 0)
    }

    private var controls: some View {
        // Keep the bottom row focused on transport. Shuffle, repeat, AirPlay,
        // lyrics and collection actions live in the top-right overflow menu.
        HStack(spacing: 0) {
            if player.isFMMode {
                circleButton(icon: "trash", size: 14) {
                    player.fmTrash()
                }
                .frame(maxWidth: .infinity)
            } else {
                circleButton(icon: "backward.fill", size: 16) {
                    player.previous()
                }
                .frame(maxWidth: .infinity)
            }

            playPauseButton
                .frame(maxWidth: .infinity)

            circleButton(icon: "forward.fill", size: 16) {
                player.next()
            }
            .frame(maxWidth: .infinity)
        }
        #if os(iOS)
        .moumusicPlayerLayout(playerLayout.entry(for: .controls, mode: settings.nowPlayingMode))
        #endif
    }

    private var playPauseButton: some View {
        Button {
            player.togglePlayPause()
        } label: {
            ZStack {
                Circle()
                    .fill(.white)
                    .frame(width: 58, height: 58)
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(.black.opacity(0.85))
                    .contentTransition(.opacity)
            }
        }
        .buttonStyle(.pressable)
    }

    private func circleButton(icon: String, size: CGFloat,
                              tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(tint ?? .white.opacity(0.8))
                .frame(width: 40, height: 40)
                .background(.white.opacity(0.1), in: Circle())
        }
        .buttonStyle(.pressable)
    }

    // MARK: - Lyrics column

    @ViewBuilder
    private var lyricsColumn: some View {
        if let lyrics = player.lyrics, !lyrics.isEmpty {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 26) {
                        Color.clear.frame(height: 200)
                        ForEach(lyrics.lines) { line in
                            bigLyricLine(line, isActive: line.id == activeIndex)
                                .id(line.id)
                        }
                        Color.clear.frame(height: 240)
                    }
                    .padding(.horizontal, 24)
                }
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.12),
                            .init(color: .black, location: 0.85),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .onChange(of: lyricsCursor.activeIndex) { index in
                    guard index != activeIndex else { return }
                    activeIndex = index
                    guard !isUserScrolling, let index else { return }
                    withAnimation(.spring(response: 0.8, dampingFraction: 0.85)) {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
                .onAppear {
                    // The cursor only fires on a line change, which can be many
                    // seconds away — on re-entering the page, adopt where the
                    // song already is instead of waiting for the next line.
                    adoptCursor(proxy: proxy)
                }
                .onChange(of: player.currentTrack?.id) { _ in
                    activeIndex = nil
                }
                .simultaneousGesture(
                    DragGesture().onChanged { _ in
                        isUserScrolling = true
                        resumeTask?.cancel()
                        resumeTask = Task {
                            try? await Task.sleep(for: .seconds(3))
                            guard !Task.isCancelled else { return }
                            isUserScrolling = false
                        }
                    }
                )
                .onLongPressGesture(minimumDuration: 0.45) {
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                        settings.lyricsDisplayStyle.toggle()
                    }
                    ToastCenter.shared.show(settings.lyricsDisplayStyle.displayName)
                }
            }
        } else if player.lyrics != nil, player.lyrics?.isInstrumental != true {
            VStack(spacing: 10) {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.white.opacity(0.45))
                Text("暂无歌词")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if player.lyrics?.isInstrumental == true {
            VStack(spacing: 10) {
                Image(systemName: "music.quarternote.3")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.white.opacity(0.4))
                Text("纯音乐，请欣赏")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func bigLyricLine(_ line: LyricLine, isActive: Bool) -> some View {
        Button {
            player.seek(to: line.time)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                LyricMainText(
                    line: line, isActive: isActive,
                    font: .system(size: isActive ? 26 : 20, weight: isActive ? .bold : .semibold),
                    verbatim: settings.verbatimLyrics
                )
                LyricSupplementalText(line: line, isActive: isActive)
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .blur(radius: settings.lyricsDisplayStyle == .amll ? 0 : (isActive ? 0 : 0.6))
            .scaleEffect(1, anchor: .leading)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isActive)
    }
}

#if os(iOS)
private extension View {
    /// Applies the user-authored Beans-style component adjustment after the
    /// native layout has calculated its safe-area spacing.
    func moumusicPlayerLayout(_ entry: PlayerLayoutEntry) -> some View {
        offset(x: entry.horizontalOffset, y: entry.verticalOffset)
            .scaleEffect(entry.scale)
            .animation(.spring(response: 0.28, dampingFraction: 0.84), value: entry)
    }
}
#endif

/// The main lyric line. Renders karaoke-style word/run highlighting from
/// verbatim (`yrc`/`lxlyric`) timings, driven live by the player, when the line
/// is active and real verbatim data exists; otherwise a plain line.
struct LyricMainText: View {
    let line: LyricLine
    let isActive: Bool
    let font: Font
    let verbatim: Bool
    var inactiveOpacity: Double = 0.45
    var rubySize: CGFloat = 20

    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var settings: SettingsManager

    var body: some View {
        if settings.lyricsDisplayStyle == .amll {
            AMLLyricText(
                line: line,
                isActive: isActive,
                font: font,
                verbatim: verbatim,
                inactiveOpacity: inactiveOpacity
            )
        } else if settings.lyricsAnnotation == .furigana, let segments = line.furigana, !segments.isEmpty,
           isActive, verbatim, line.hasVerbatimTimings, let words = line.words {
            TimelineView(.animation(paused: !player.isPlaying)) { _ in
                RubyText(
                    segments: segments,
                    size: rubySize,
                    weight: .bold,
                    color: .white,
                    alphas: karaokeAlphas(words, at: player.livePlaybackTime + settings.effectiveLyricsOffset)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if settings.lyricsAnnotation == .furigana, let segments = line.furigana, !segments.isEmpty {
            RubyText(
                segments: segments,
                size: rubySize,
                weight: isActive ? .bold : .semibold,
                color: .white.opacity(isActive ? 1 : inactiveOpacity)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if isActive, verbatim, line.hasVerbatimTimings, let words = line.words {
            TimelineView(.animation(paused: !player.isPlaying)) { _ in
                karaoke(words, at: player.livePlaybackTime + settings.effectiveLyricsOffset).font(font)
                    .minimumScaleFactor(0.72)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(line.text.isEmpty ? "♪" : line.text)
                .font(font)
                .foregroundStyle(.white.opacity(isActive ? 1 : inactiveOpacity))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .minimumScaleFactor(0.72)
        }
    }

      /// One concatenated `Text` (so it wraps) with the exact opacity of each
      /// source-timed word/run. LX/NetEase verbatim data already contains the
      /// timing for each run; subdividing it by character creates drift.
    private func karaoke(_ words: [LyricWord], at time: TimeInterval) -> Text {
          let unsung = 0.28
          var out = Text(verbatim: "")
          for word in words {
              let fraction = word.duration > 0
                  ? min(max((time - word.start) / word.duration, 0), 1)
                  : (time >= word.start ? 1 : 0)
              let alpha = unsung + (1 - unsung) * fraction
              out = out + Text(verbatim: word.text)
                  .foregroundColor(.white.opacity(alpha))
          }
          return out
      }

      private func karaokeAlphas(_ words: [LyricWord], at time: TimeInterval) -> [Double] {
          let unsung = 0.28
          return words.flatMap { word in
              let fraction = word.duration > 0
                  ? min(max((time - word.start) / word.duration, 0), 1)
                  : (time >= word.start ? 1 : 0)
              let alpha = unsung + (1 - unsung) * fraction
              return Array(repeating: alpha, count: word.text.count)
          }
      }
}

/// Apple Music-like lyric rendering without depending on a private or
/// reverse-engineered implementation. It reuses the source-provided word
/// timings, keeps the full line visible underneath, and fills the sung words
/// over it in real time.
private struct AMLLyricText: View {
    let line: LyricLine
    let isActive: Bool
    let font: Font
    let verbatim: Bool
    let inactiveOpacity: Double

    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var settings: SettingsManager

    var body: some View {
        Group {
            if isActive, verbatim, line.hasVerbatimTimings, let words = line.words {
                TimelineView(.animation(paused: !player.isPlaying)) { _ in
                    ZStack(alignment: .leading) {
                        Text(line.text)
                            .foregroundStyle(.white.opacity(0.28))
                        timedText(words, at: player.livePlaybackTime + settings.effectiveLyricsOffset)
                    }
                }
            } else {
                Text(line.text.isEmpty ? " " : line.text)
                    .foregroundStyle(.white.opacity(isActive ? 1 : inactiveOpacity))
            }
        }
        .font(font.weight(isActive ? .bold : .semibold))
        .lineSpacing(isActive ? 5 : 1)
        .tracking(isActive ? 0.15 : 0)
        .minimumScaleFactor(0.64)
        .fixedSize(horizontal: false, vertical: true)
        .scaleEffect(isActive ? 1.06 : 0.90, anchor: .leading)
        .opacity(isActive ? 1 : 0.56)
        .blur(radius: isActive ? 0 : 0.55)
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: isActive)
    }

    private func timedText(_ words: [LyricWord], at time: TimeInterval) -> Text {
        var output = Text(verbatim: "")
        for word in words {
            let progress = word.duration > 0
                ? min(max((time - word.start) / word.duration, 0), 1)
                : (time >= word.start ? 1 : 0)
            let opacity = 0.34 + 0.66 * progress
            output = output + Text(verbatim: word.text)
                .foregroundColor(.white.opacity(opacity))
        }
        return output
    }
}

/// Shared secondary lyric rows. Keeping this in one view prevents the full,
/// immersive and compact player modes from drifting apart when the user
/// changes translation or Japanese annotation settings.
private struct LyricSupplementalText: View {
    let line: LyricLine
    let isActive: Bool

    @EnvironmentObject private var settings: SettingsManager

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if settings.lyricsAnnotation == .romaji,
               let romaji = line.romaji,
               !romaji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(romaji)
                    .font(.system(size: isActive ? 15 : 13, weight: .medium))
                    .foregroundStyle(.white.opacity(isActive ? 0.7 : 0.35))
            }
            if settings.showLyricsTranslation,
               let translation = line.translation,
               !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(translation)
                    .font(.system(size: isActive ? 16 : 14, weight: .medium))
                    .foregroundStyle(.white.opacity(isActive ? 0.7 : 0.35))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Player-page lyric controls.  These belong next to the lyrics because the
/// useful choice is per listening session, not a buried global setting.
private struct LyricPresentationSheet: View {
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var settings: SettingsManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    glassSection {
                        Text("歌词样式")
                            .font(.headline)

                        ForEach(LyricsDisplayStyle.allCases) { style in
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    settings.lyricsDisplayStyle = style
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: style == .amll ? "text.quote" : "text.alignleft")
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundStyle(style == settings.lyricsDisplayStyle ? Theme.accent : .secondary)
                                        .frame(width: 28)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(style.displayName)
                                            .font(.body.weight(.semibold))
                                        Text(style.explanation)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .multilineTextAlignment(.leading)
                                    }
                                    Spacer(minLength: 8)
                                    if style == settings.lyricsDisplayStyle {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Theme.accent)
                                    }
                                }
                                .contentShape(Rectangle())
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    glassSection {
                        Toggle("逐字歌词（仅使用真实时间轴）", isOn: $settings.verbatimLyrics)
                        Toggle("显示歌词翻译", isOn: $settings.showLyricsTranslation)

                        Picker("日文歌词注音", selection: $settings.lyricsAnnotation) {
                            ForEach(LyricsAnnotation.allCases) { annotation in
                                Text(annotation.displayName).tag(annotation)
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("歌词同步")
                                Spacer()
                                Text(String(format: "%+.2f 秒", settings.lyricsOffset))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Slider(value: $settings.lyricsOffset, in: -2...2, step: 0.05)
                            HStack(spacing: 10) {
                                Button("歌词提前 0.1 秒") {
                                    settings.lyricsOffset = min(2, settings.lyricsOffset + 0.1)
                                }
                                Button("歌词延后 0.1 秒") {
                                    settings.lyricsOffset = max(-2, settings.lyricsOffset - 0.1)
                                }
                                Button("重置") { settings.lyricsOffset = 0 }
                            }
                            .font(.footnote)
                            .buttonStyle(.bordered)
                            Text("正值提前，负值延后。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    glassSection {
                        Label(
                            player.lyrics?.hasVerbatimTimings == true
                                ? "当前歌曲已提供逐字时间轴"
                                : "当前歌曲没有逐字时间轴",
                            systemImage: player.lyrics?.hasVerbatimTimings == true
                                ? "checkmark.circle"
                                : "info.circle"
                        )
                        .foregroundStyle(player.lyrics?.hasVerbatimTimings == true ? .green : .secondary)
                        Text("AMLL 负责显示样式；逐字进度只使用音源真实返回的 YRC/LX 时间轴。没有真实时间轴时不会按字符平均切分，避免歌词越播越错位。网易云没有时会优先回退到 QQ 音乐歌词。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
            }
            .navigationTitle("歌词设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .onChange(of: settings.lyricsOffset) { _ in
            player.refreshLyricsCursor()
        }
    }

    @ViewBuilder
    private func glassSection<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(16)
            .mouMaterialBackground(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.white.opacity(0.16), lineWidth: 1)
            }
    }
}

private struct QualityPickerSheet: View {
    /// Two catalogue tiers can share one label ("320 kbps"): list each label once.
    static func uniqueTiers(_ tiers: [AudioQuality]) -> [AudioQuality] {
        var seen = Set<String>()
        return tiers.filter { seen.insert($0.lxType).inserted }
    }

    @EnvironmentObject private var player: PlayerService
    @Environment(\.dismiss) private var dismiss
    @State private var available: [AudioQuality] = []
    @State private var loading = true

    private var qualityTaskID: String {
        "\(player.currentTrack?.playbackKey ?? "none")|\(player.servedQuality ?? "")"
    }

    private var servedQualityIsDowngraded: Bool {
        guard player.servedQualityTrackKey == player.currentTrack?.playbackKey,
              let served = player.servedQuality,
              let actualRank = AudioQuality.resolvedRank(served),
              let requestedRank = AudioQuality.resolvedRank(player.currentQuality.lxType) else {
            return false
        }
        return actualRank < requestedRank
    }

    private var isNativeNeteaseTrack: Bool {
        let source = (player.currentTrack?.source
            ?? player.currentTrack?.sourceMetadata["source"]
            ?? "").lowercased()
        return source.isEmpty || ["wy", "163", "netease", "neteasecloudmusic", "cloudmusic"].contains(source)
    }

    private var nonVIPNeteaseWarning: String? {
        guard isNativeNeteaseTrack, AccountStore.shared.hasAuthCookie else { return nil }
        guard AccountStore.shared.vipStatusKnown else {
            return "警告：网易云账号 VIP 状态尚未确认，高级音质按非 VIP 安全策略处理。"
        }
        guard !AccountStore.shared.hasActiveVIP else { return nil }
        return "警告：当前网易云账号不是 VIP。"
    }

    private var qualityWarningText: String {
        let requested = player.currentQuality.sourceDisplayName
        let source = player.servedSourceLabel ?? "未知音源"
        let accountWarning = nonVIPNeteaseWarning ?? ""
        guard let served = player.servedQuality else {
            return "\(accountWarning)请求音质：\(requested)。实际音质尚未返回。"
        }
        if AudioQuality.isUnknownResolvedQuality(served) {
            return "\(accountWarning)请求音质：\(requested)；实际音质未知。实际来源：\(source)。音源没有返回可验证的码率或格式字段。"
        }
        let actual = AudioQuality.resolvedDisplayName(served)
        if !servedQualityIsDowngraded {
            return "\(accountWarning)接口实际返回：\(actual)。实际来源：\(source)。这是音源返回的元数据，不是对音频文件做的独立编码检测。"
        }
        return "\(accountWarning)请求音质：\(requested)；接口实际返回：\(actual)，实际来源：\(source)，已自动降级。"
    }

    var body: some View {
        NavigationStack {
            List {
                Section("当前歌曲") {
                    Text(player.currentTrack?.name ?? "未播放歌曲")
                        .lineLimit(2)
                    Text("可用音质会随当前平台和音源变化")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if player.servedQualityTrackKey == player.currentTrack?.playbackKey,
                       let servedQuality = player.servedQuality,
                       !servedQuality.isEmpty {
                        Label {
                            Text(qualityWarningText)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .font(.footnote)
                        .foregroundStyle(
                            AudioQuality.isUnknownResolvedQuality(servedQuality)
                                || servedQualityIsDowngraded ? .orange : .secondary
                        )
                    }
                }

                if !available.isEmpty {
                    Section("选择音质") {
                        ForEach(available) { quality in
                            Button {
                                player.selectQuality(quality)
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(quality.sourceDisplayName)
                                            .font(.body.weight(.medium))
                                        if quality.isPlatformSpecific {
                                            Text("由当前播放来源实时探测，最终以返回地址为准")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if player.currentQuality == quality {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Theme.accent)
                                    }
                                }
                            }
                            .foregroundStyle(.primary)
                            .frame(minHeight: 44)
                        }
                    }
                } else if !loading {
                    Section("选择音质") {
                        Text("当前播放来源没有返回可用音质，请检查账号状态或音源是否支持该平台。")
                            .foregroundStyle(.secondary)
                    }
                }

                if loading {
                    ProgressView("正在读取音源支持的音质")
                }

                Section {
                    Text("如果选定音质不可用，自动模式会先尝试账号能力，再回退到已启用的第三方音源。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("播放音质")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task(id: qualityTaskID) {
            let trackKey = player.currentTrack?.playbackKey
            loading = true
            // Playback may have finished resolving this track before the
            // sheet is presented. Show that verified result immediately;
            // network probing below can add other tiers without hiding it.
            available = player.servedQualityTrackKey == trackKey
                ? [player.servedQuality].compactMap { value in
                    guard let value else { return nil }
                    return AudioQuality(lxType: value)
                }
                : []
            let result = await player.availableQualitiesForCurrentTrack()
            guard !Task.isCancelled,
                  player.currentTrack?.playbackKey == trackKey else { return }
            var merged = result
            if player.servedQualityTrackKey == player.currentTrack?.playbackKey,
               let servedQuality = player.servedQuality,
               let actual = AudioQuality(lxType: servedQuality),
               !merged.contains(actual) {
                merged.append(actual)
            }
            available = Self.uniqueTiers(AudioQuality.allCases.filter { merged.contains($0) })
            loading = false
            // Live refresh: the first pass can miss tiers (a source still waking up, a request that failed
            // once). Keep asking a few more times while the sheet is open and add what turns up; the list
            // only ever grows, so rows appear as soon as the next answer arrives.
            for delay in [1_200_000_000, 2_500_000_000, 4_000_000_000] as [UInt64] {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled, player.currentTrack?.playbackKey == trackKey else { return }
                let later = await player.availableQualitiesForCurrentTrack(forceRefresh: true)
                guard !Task.isCancelled, player.currentTrack?.playbackKey == trackKey else { return }
                let grown = Self.uniqueTiers(AudioQuality.allCases.filter { available.contains($0) || later.contains($0) })
                if grown != available { available = grown }
            }
        }
    }
}

#if os(iOS)
private struct IOSImmersiveLyricsColumn: View {
    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var lyricsCursor = PlayerService.shared.lyricsCursor
    @EnvironmentObject private var settings: SettingsManager

    @State private var activeIndex: Int?
    @State private var isUserScrolling = false
    @State private var resumeTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let lyrics = player.lyrics, !lyrics.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 22) {
                            Color.clear.frame(height: 72)
                            ForEach(lyrics.lines) { line in
                                lyricLine(line, isActive: line.id == activeIndex)
                                    .id(line.id)
                            }
                            Color.clear.frame(height: 96)
                        }
                        .padding(.horizontal, 2)
                    }
                    .mask(edgeMask)
                    .accessibilityIdentifier("syncedLyricsScroll")
                    .onChange(of: lyricsCursor.activeIndex) { index in
                        guard index != activeIndex else { return }
                        activeIndex = index
                        guard !isUserScrolling, let index else { return }
                        withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.38)) {
                            proxy.scrollTo(index, anchor: .center)
                        }
                    }
                    .onAppear {
                        adoptCursor(proxy: proxy)
                    }
                    .onChange(of: player.currentTrack?.id) { _ in
                        activeIndex = nil
                    }
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { _ in
                                guard !isUserScrolling else { return }
                                resumeTask?.cancel()
                                isUserScrolling = true
                            }
                            .onEnded { _ in
                                resumeTask?.cancel()
                                resumeTask = Task {
                                    try? await Task.sleep(for: .seconds(3))
                                    guard !Task.isCancelled else { return }
                                    isUserScrolling = false
                                }
                            }
                    )
                    .onLongPressGesture(minimumDuration: 0.45) {
                        withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                            settings.lyricsDisplayStyle.toggle()
                        }
                        ToastCenter.shared.show(settings.lyricsDisplayStyle.displayName)
                    }
                }
            } else if player.lyrics != nil, player.lyrics?.isInstrumental != true {
                VStack(spacing: 10) {
                    Image(systemName: "quote.bubble")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.white.opacity(0.45))
                    Text("暂无歌词")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if player.lyrics?.isInstrumental == true {
                VStack(spacing: 10) {
                    Image(systemName: "music.quarternote.3")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.white.opacity(0.4))
                    Text("纯音乐，请欣赏")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onDisappear {
            resumeTask?.cancel()
        }
    }


    /// Jump straight to the line the song is on. Used when the view appears,
    /// where waiting for the next line change would leave the lyrics parked at
    /// the top. Scrolling is deferred a turn: the list has not laid out yet
    /// while `onAppear` runs, and `scrollTo` on an unlaid list does nothing.
    private func adoptCursor(proxy: ScrollViewProxy) {
        let index = lyricsCursor.activeIndex
        activeIndex = index
        guard let index else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(index, anchor: .center)
        }
    }

    private var edgeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.12),
                .init(color: .black, location: 0.85),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func lyricLine(_ line: LyricLine, isActive: Bool) -> some View {
        Button {
            player.seek(to: line.time)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                LyricMainText(
                    line: line, isActive: isActive,
                    font: .system(size: 27, weight: isActive ? .bold : .semibold),
                    verbatim: settings.verbatimLyrics
                )
                LyricSupplementalText(line: line, isActive: isActive)
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // Keep the focused line at its natural width. Scaling a long
            // English line by 7% makes it clip at the phone edge.
            .scaleEffect(isActive ? 1.0 : 0.82, anchor: .leading)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: isActive)
    }
}

// MARK: - Compact now-playing sections

private enum ImmersiveArtworkTransition {
    /// A time-based ease-out curve stays fluid at the display's native refresh rate.
    static let animation = Animation.timingCurve(
        0.16,
        1,
        0.3,
        1,
        duration: 0.42
    )
    static let compactArtworkDimension: CGFloat = 62
    static let compactHeaderSpacing: CGFloat = 13
    static let expandedMetadataOffset = -(
        compactArtworkDimension + compactHeaderSpacing
    )
}

private enum ImmersiveArtworkFrame: Hashable {
    case compact
    case expanded
}

private struct ImmersiveArtworkFramePreferenceKey: PreferenceKey {
    static var defaultValue: [ImmersiveArtworkFrame: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [ImmersiveArtworkFrame: Anchor<CGRect>],
        nextValue: () -> [ImmersiveArtworkFrame: Anchor<CGRect>]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

/// Compact action menu shared by the full player and the immersive header.
/// Transport stays visually quiet while shuffle/repeat remain one tap away.
private struct PlayerPlaybackModeMenu: View {
    @EnvironmentObject private var player: PlayerService

    var body: some View {
        Menu {
            Button {
                player.toggleShuffle()
            } label: {
                Label(
                    player.shuffleEnabled ? "关闭随机播放" : "随机播放",
                    systemImage: "shuffle"
                )
            }
            Button {
                player.cycleRepeatMode()
            } label: {
                Label(
                    player.repeatMode == .off ? "开启循环播放" : "切换循环模式",
                    systemImage: player.repeatMode == .one ? "repeat.1" : "repeat"
                )
            }
        } label: {
            Label("播放模式", systemImage: "shuffle")
        }
    }
}

private struct CompactTrackHeader: View {
    private enum ActiveSheet: String, Identifiable {
        case addToPlaylist
        case comments
        case lyricsOptions
        case downloads
        case lyricPoster
        case customCover

        var id: String { rawValue }
    }

    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var settings: SettingsManager
    @ObservedObject private var favorites = FavoritesStore.shared
    @State private var activeSheet: ActiveSheet?

    let showsExpandedArtwork: Bool

    var body: some View {
        HStack(spacing: ImmersiveArtworkTransition.compactHeaderSpacing) {
            Color.clear
                .frame(
                    width: ImmersiveArtworkTransition.compactArtworkDimension,
                    height: ImmersiveArtworkTransition.compactArtworkDimension
                )
                .anchorPreference(
                    key: ImmersiveArtworkFramePreferenceKey.self,
                    value: .bounds
                ) { [.compact: $0] }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(player.currentTrack?.name ?? "")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if player.currentTrack?.fee == 1 {
                        VIPBadge()
                    }
                }
                PlayerArtistLink(font: .subheadline, opacity: 0.62)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .offset(
                x: showsExpandedArtwork
                    ? ImmersiveArtworkTransition.expandedMetadataOffset
                    : 0
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("immersiveTrackMetadata")

            if let track = player.currentTrack {
                Menu {
                    let liked = favorites.contains(track)
                    Button {
                        let isLiked = favorites.toggle(track)
                        ToastCenter.shared.show(isLiked ? "已加入本地收藏" : "已取消本地收藏")
                    } label: {
                        Label(liked ? "取消收藏" : "收藏歌曲", systemImage: liked ? "heart.fill" : "heart")
                    }

                    Button {
                        player.addToPlayNext(track)
                    } label: {
                        Label("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }

                    Button {
                        activeSheet = .addToPlaylist
                    } label: {
                        Label("加入歌单…", systemImage: "music.note.list")
                    }

                    Button {
                        activeSheet = .comments
                    } label: {
                        Label("查看评论", systemImage: "text.bubble")
                    }

#if os(iOS)
                    Button {
                        activeSheet = .lyricPoster
                    } label: {
                        Label("分享歌词海报", systemImage: "text.quote")
                    }
                    Button {
                        activeSheet = .customCover
                    } label: {
                        Label("自定义封面…", systemImage: "photo")
                    }
#endif

                    Menu {
                        ForEach(LyricsDisplayStyle.allCases) { style in
                            Button {
                                withAnimation(AppAnimation.standard) {
                                    settings.lyricsDisplayStyle = style
                                }
                            } label: {
                                HStack {
                                    Text(style.displayName)
                                    if style == settings.lyricsDisplayStyle {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        Label("歌词样式：\(settings.lyricsDisplayStyle.displayName)", systemImage: "textformat")
                    }

                    PlayerPlaybackModeMenu()

#if os(iOS)
                    Button {
                        activeSheet = .downloads
                    } label: {
                        Label("下载", systemImage: "arrow.down.circle")
                    }
#endif

                    Button {
                        activeSheet = .lyricsOptions
                    } label: {
                        Label("歌词设置", systemImage: "textformat")
                    }

                    Button { player.queueSimilarSongs() } label: { Label("播放相似歌曲", systemImage: "wand.and.stars") }
                SleepTimerMenu(player: player)

                    Divider()

                    Button {
                        Platform.copyToPasteboard(
                            string: "https://music.163.com/#/song?id=\(track.id)"
                        )
                        ToastCenter.shared.show(String(localized: "链接已复制"))
                    } label: {
                        Label("复制链接", systemImage: "link")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(.white.opacity(0.88))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("更多操作")
                .accessibilityIdentifier("immersiveMoreMenu")
            }
        }
        .accessibilityElement(children: .contain)
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.45) {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                settings.lyricsDisplayStyle.toggle()
            }
            ToastCenter.shared.show(settings.lyricsDisplayStyle.displayName)
        }
        .accessibilityHint(String(localized: "长按歌曲信息切换歌词样式"))
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .addToPlaylist:
                if let track = player.currentTrack {
                    AddToPlaylistSheet(track: track)
                } else {
                    EmptyView()
                }
            case .lyricPoster:
                #if os(iOS)
                if let track = player.currentTrack {
                    LyricPosterSheet(track: track, lyrics: player.lyrics?.lines ?? [], currentTime: player.progress)
                } else {
                    EmptyView()
                }
                #else
                EmptyView()
                #endif
            case .customCover:
                #if os(iOS)
                if let track = player.currentTrack {
                    CustomCoverPickerSheet(track: track)
                } else {
                    EmptyView()
                }
                #else
                EmptyView()
                #endif
            case .comments:
                if let track = player.currentTrack {
                    SongCommentsSheet(track: track)
                } else {
                    EmptyView()
                }
            case .lyricsOptions:
                LyricPresentationSheet()
                    .environmentObject(player)
                    .environmentObject(settings)
            case .downloads:
                #if os(iOS)
                if let track = player.currentTrack {
                    DownloadOptionsSheet(tracks: [track])
                } else {
                    EmptyView()
                }
                #else
                EmptyView()
                #endif
            }
        }
    }
}

private struct CompactTransportControls: View {
    @EnvironmentObject private var player: PlayerService

    var body: some View {
        HStack(spacing: 0) {
            Button(action: player.isFMMode ? player.fmTrash : player.previous) {
                Image(systemName: player.isFMMode ? "trash" : "backward.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 58)
            }
            .accessibilityLabel(player.isFMMode ? "不喜欢" : "上一首")

            Button(action: player.togglePlayPause) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 36, weight: .bold))
                    .contentTransition(.opacity)
                    .frame(maxWidth: .infinity, minHeight: 64)
            }
            .accessibilityLabel(player.isPlaying ? "暂停" : "播放")

            Button(action: player.next) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 58)
            }
            .accessibilityLabel("下一首")
        }
        .foregroundStyle(.white)
        .buttonStyle(.pressable)
    }
}

private struct CompactVolumeControl: View {
#if os(iOS)
    @EnvironmentObject private var settings: SettingsManager
    @ObservedObject private var playerLayout = PlayerLayoutStore.shared

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "speaker.fill")
                .font(.caption2)
            MPSystemVolumeSlider()
                .frame(height: 28)
            Image(systemName: "speaker.wave.3.fill")
                .font(.caption)
        }
        .foregroundStyle(.white.opacity(0.7))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("系统音量")
        .moumusicPlayerLayout(playerLayout.entry(for: .volume, mode: settings.nowPlayingMode))
    }
#else
    @EnvironmentObject private var player: PlayerService
    @State private var isDragging = false

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "speaker.fill")
                .font(.caption2)
            // One GeometryReader with the gesture on the ZStack. A nested
            // GeometryReader (the old TranslucentSliderTrack) silently dropped
            // the drag, so the volume slider did nothing (#37).
            GeometryReader { geo in
                let width = geo.size.width
                let fraction = min(max(CGFloat(player.volume), 0), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.28))
                    Capsule().fill(.white.opacity(0.78))
                        .frame(width: width * fraction)
                }
                .frame(height: isDragging ? 10 : 6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            updateVolume(at: value.location.x, width: width)
                        }
                        .onEnded { value in
                            updateVolume(at: value.location.x, width: width)
                            isDragging = false
                        }
                )
                .animation(.spring(response: 0.24, dampingFraction: 0.82), value: isDragging)
            }
            .frame(height: 24)
            .accessibilityElement()
            .accessibilityLabel("音量")
            .accessibilityValue("\(Int((player.volume * 100).rounded()))%")
            .accessibilityAdjustableAction(adjustVolume)
            Image(systemName: "speaker.wave.3.fill")
                .font(.caption)
        }
        .foregroundStyle(.white.opacity(0.7))
    }

    private func updateVolume(at location: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        player.volume = Float(min(max(location / width, 0), 1))
    }

    private func adjustVolume(_ direction: AccessibilityAdjustmentDirection) {
        let step: Float = 0.05
        switch direction {
        case .increment:
            player.volume = min(player.volume + step, 1)
        case .decrement:
            player.volume = max(player.volume - step, 0)
        @unknown default:
            break
        }
    }
#endif
}

#if os(iOS)
private struct MPSystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsRouteButton = false
        view.showsVolumeSlider = true
        view.tintColor = .white
        if let slider = view.subviews.compactMap({ $0 as? UISlider }).first {
            slider.minimumTrackTintColor = .white
            slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.28)
            slider.accessibilityLabel = "系统音量"
        }
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
#endif

private struct CompactSecondaryControls: View {
    let showsLyrics: Bool
    let showsQueue: Bool
    let onToggleLyrics: () -> Void
    let onToggleQueue: () -> Void
    var onComments: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 0) {
            secondaryButton(
                icon: showsLyrics && !showsQueue ? "quote.bubble.fill" : "quote.bubble",
                label: showsLyrics ? "显示封面" : "显示歌词",
                isActive: showsLyrics && !showsQueue
            ) { onToggleLyrics() }

            if let onComments {
                secondaryButton(icon: "text.bubble", label: "评论") { onComments() }
            }

            RoutePickerButton(diameter: 44, glyphSize: 17)
                .frame(maxWidth: .infinity)

            secondaryButton(
                icon: "list.bullet",
                label: showsQueue ? "关闭播放队列" : "显示播放队列",
                isActive: showsQueue
            ) { onToggleQueue() }
        }
    }

    private func secondaryButton(
        icon: String,
        label: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(isActive ? Theme.accent : .white.opacity(0.72))
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.08), in: Circle())
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

private struct CompactQueueContent: View {
    @EnvironmentObject private var player: PlayerService

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 10) {
                modeButton(
                    icon: "arrow.right",
                    label: "顺序播放",
                    isActive: !player.shuffleEnabled && player.repeatMode == .off,
                    action: enableSequentialPlayback
                )
                modeButton(
                    icon: "shuffle",
                    label: player.shuffleEnabled ? "关闭随机播放" : "随机播放",
                    isActive: player.shuffleEnabled,
                    action: player.toggleShuffle
                )
                modeButton(
                    icon: "repeat",
                    label: "列表循环",
                    isActive: player.repeatMode == .all
                ) {
                    player.repeatMode = player.repeatMode == .all ? .off : .all
                }
                modeButton(
                    icon: "repeat.1",
                    label: "单曲循环",
                    isActive: player.repeatMode == .one
                ) {
                    player.repeatMode = player.repeatMode == .one ? .off : .one
                }
            }

            HStack(alignment: .firstTextBaseline) {
                Text("继续播放")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(player.upcomingTracks.count) 首")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.46))
            }

            if player.upcomingTracks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 28, weight: .light))
                    Text("播放队列是空的")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 4) {
                        ForEach(
                            Array(player.upcomingTracks.prefix(100).enumerated()),
                            id: \.offset
                        ) { _, track in
                            CompactQueueRow(track: track)
                        }
                    }
                }
                .mask(
                    LinearGradient(
                        colors: [.black, .black, .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
        }
        .padding(.top, 6)
    }

    private func modeButton(
        icon: String,
        label: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isActive ? Color.black.opacity(0.76) : .white.opacity(0.76))
                .frame(maxWidth: .infinity, minHeight: 42)
                .background(
                    isActive ? AnyShapeStyle(.white.opacity(0.66)) : AnyShapeStyle(.white.opacity(0.1)),
                    in: Capsule()
                )
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func enableSequentialPlayback() {
        if player.shuffleEnabled {
            player.toggleShuffle()
        }
        player.repeatMode = .off
    }
}

private struct CompactQueueRow: View {
    let track: Track

    @EnvironmentObject private var player: PlayerService

    var body: some View {
        Button {
            player.jumpTo(track)
        } label: {
            HStack(spacing: 11) {
                CachedAsyncImage(url: track.album.picUrl?.resizedImageURL(120), animated: false)
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    Text(track.artistNames)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Text(Formatters.duration(track.duration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.36))
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(track.name)，\(track.artistNames)")
    }
}



private struct IOSMinimalLyricsColumn: View {
    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var clock = PlayerService.shared.clock
    @ObservedObject private var lyricsCursor = PlayerService.shared.lyricsCursor
    @EnvironmentObject private var settings: SettingsManager

    let onClose: () -> Void

    @State private var activeIndex: Int?
    @State private var selectedIndex: Int?
    @State private var nearestIndex: Int?
    @State private var lineCenters: [Int: CGFloat] = [:]
    @State private var isDragging = false
    @State private var suppressesAutoScroll = false
    @State private var scrollSettleTask: Task<Void, Never>?
    @State private var selectionTimeoutTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let lyrics = player.lyrics, !lyrics.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators: false) {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                Color.clear.frame(height: geometry.size.height / 2)
                                ForEach(lyrics.lines) { line in
                                    lyricLine(
                                        line,
                                        isActive: line.id == activeIndex,
                                        isSelected: line.id == selectedIndex,
                                        availableWidth: geometry.size.width
                                    ) {
                                        guard let selectedIndex else {
                                            closeLyrics()
                                            return
                                        }
                                        guard selectedIndex == line.id else {
                                            returnToActiveLine(proxy: proxy)
                                            return
                                        }
                                        selectionTimeoutTask?.cancel()
                                        selectionTimeoutTask = nil
                                        suppressesAutoScroll = true
                                        player.seek(to: line.time) {
                                            suppressesAutoScroll = false
                                        }
                                        activeIndex = line.id
                                        self.selectedIndex = nil
                                        nearestIndex = nil
                                    }
                                    .id(line.id)
                                    .background {
                                        GeometryReader { lineGeometry in
                                            Color.clear.preference(
                                                key: MinimalLyricCentersKey.self,
                                                value: [
                                                    line.id: lineGeometry.frame(
                                                        in: .named("immersiveLyrics")
                                                    ).midY
                                                ]
                                            )
                                        }
                                    }
                                }
                                Color.clear.frame(height: geometry.size.height / 2)
                            }
                            .padding(.horizontal, 2)
                        }
                        .coordinateSpace(name: "immersiveLyrics")
                        .mask(edgeMask)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: closeLyrics)
                        .onLongPressGesture(minimumDuration: 0.45) {
                            withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                                settings.lyricsDisplayStyle.toggle()
                            }
                            ToastCenter.shared.show(settings.lyricsDisplayStyle.displayName)
                        }
                        .accessibilityIdentifier("syncedLyricsScroll")
                        .onPreferenceChange(MinimalLyricCentersKey.self) { centers in
                            lineCenters = centers
                            guard isDragging || scrollSettleTask != nil else { return }
                            nearestIndex = nearestLine(
                                to: geometry.size.height / 2,
                                in: centers
                            )
                            guard !isDragging else { return }
                            scheduleScrollSelection(
                                guideY: geometry.size.height / 2,
                                proxy: proxy
                            )
                        }
                        .onAppear {
                            activeIndex = lyricsCursor.activeIndex
                            if let activeIndex {
                                Task { @MainActor in
                                    await Task.yield()
                                    proxy.scrollTo(activeIndex, anchor: .center)
                                }
                            }
                        }
                        .onChange(of: lyricsCursor.activeIndex) { index in
                            guard index != activeIndex else { return }
                            activeIndex = index
                            guard !suppressesAutoScroll,
                                  !isDragging, scrollSettleTask == nil,
                                  selectedIndex == nil, let index else { return }
                            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.38)) {
                                proxy.scrollTo(index, anchor: .center)
                            }
                        }
                        .onChange(of: player.currentTrack?.id) { _ in
                            activeIndex = nil
                            selectedIndex = nil
                            nearestIndex = nil
                            suppressesAutoScroll = false
                            scrollSettleTask?.cancel()
                            scrollSettleTask = nil
                            selectionTimeoutTask?.cancel()
                            selectionTimeoutTask = nil
                        }
                        .simultaneousGesture(
                            DragGesture()
                                .onChanged { _ in
                                    if !isDragging {
                                        scrollSettleTask?.cancel()
                                        scrollSettleTask = nil
                                        selectionTimeoutTask?.cancel()
                                        selectionTimeoutTask = nil
                                        selectedIndex = nil
                                        isDragging = true
                                    }
                                    nearestIndex = nearestLine(
                                        to: geometry.size.height / 2,
                                        in: lineCenters
                                    )
                                }
                                .onEnded { _ in
                                    isDragging = false
                                    scheduleScrollSelection(
                                        guideY: geometry.size.height / 2,
                                        proxy: proxy
                                    )
                                }
                        )
                        .overlay {
                            selectionGuide(lyrics: lyrics)
                        }
                    }
                } else if player.lyrics != nil, player.lyrics?.isInstrumental != true {
                    VStack(spacing: 10) {
                        Image(systemName: "quote.bubble")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(.white.opacity(0.45))
                        Text("暂无歌词")
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                } else if player.lyrics?.isInstrumental == true {
                    VStack(spacing: 10) {
                        Image(systemName: "music.quarternote.3")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(.white.opacity(0.4))
                        Text("纯音乐，请欣赏")
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: closeLyrics)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onDisappear {
            scrollSettleTask?.cancel()
            selectionTimeoutTask?.cancel()
        }
    }

    @ViewBuilder
    private func selectionGuide(lyrics: ParsedLyrics) -> some View {
        let isScrolling = isDragging || scrollSettleTask != nil
        if let index = isScrolling ? nearestIndex : selectedIndex,
           lyrics.lines.indices.contains(index) {
            HStack(spacing: 8) {
                if isScrolling {
                    Canvas { context, size in
                        var path = Path()
                        path.move(to: CGPoint(x: 0, y: size.height / 2))
                        path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                        context.stroke(
                            path,
                            with: .color(.white.opacity(0.45)),
                            style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                        )
                    }
                    .frame(height: 1)
                } else {
                    Spacer()
                }

                Text(Formatters.duration(lyrics.lines[index].time))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.72))
                    .offset(x: 25)
            }
            .padding(.horizontal, 2)
            .allowsHitTesting(false)
        }
    }

    private func nearestLine(to guideY: CGFloat, in centers: [Int: CGFloat]) -> Int? {
        centers.min { abs($0.value - guideY) < abs($1.value - guideY) }?.key
    }

    private func scheduleScrollSelection(guideY: CGFloat, proxy: ScrollViewProxy) {
        scrollSettleTask?.cancel()
        // ponytail: iOS 16 has no scroll phase API; replace with onScrollPhaseChange
        // when the deployment target reaches iOS 18.
        scrollSettleTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let selection = nearestLine(to: guideY, in: lineCenters) ?? nearestIndex
            selectedIndex = selection
            nearestIndex = selection
            scrollSettleTask = nil
            guard let selection else { return }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                proxy.scrollTo(selection, anchor: .center)
            }
            scheduleSelectionTimeout(proxy: proxy)
        }
    }

    private func scheduleSelectionTimeout(proxy: ScrollViewProxy) {
        selectionTimeoutTask?.cancel()
        selectionTimeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, selectedIndex != nil else { return }
            returnToActiveLine(proxy: proxy)
        }
    }

    private func returnToActiveLine(proxy: ScrollViewProxy) {
        selectionTimeoutTask?.cancel()
        selectionTimeoutTask = nil
        selectedIndex = nil
        nearestIndex = nil
        guard let activeIndex else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            proxy.scrollTo(activeIndex, anchor: .center)
        }
    }

    private func closeLyrics() {
        scrollSettleTask?.cancel()
        scrollSettleTask = nil
        selectionTimeoutTask?.cancel()
        selectionTimeoutTask = nil
        selectedIndex = nil
        nearestIndex = nil
        isDragging = false
        onClose()
    }

    private var edgeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.12),
                .init(color: .black, location: 0.85),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func lyricLine(
        _ line: LyricLine,
        isActive: Bool,
        isSelected: Bool,
        availableWidth: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                LyricMainText(
                    line: line, isActive: isActive,
                    font: .system(size: 17, weight: .bold),
                    verbatim: settings.verbatimLyrics
                )
                    .fixedSize(horizontal: false, vertical: true)
                    .scaleEffect(isActive ? 1 : 16.0 / 17.0, anchor: .leading)
                LyricSupplementalText(line: line, isActive: isActive)
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(isSelected ? 0.14 : 0))
            )
            .contentShape(Rectangle())
            .padding(.trailing, 0)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: isActive)
        .animation(.easeOut(duration: 0.18), value: isSelected)
    }
}

private struct MinimalLyricCentersKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]

    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

// MARK: - Minimal track info row

private struct MinimalTrackInfoRow: View {
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var settings: SettingsManager
    @ObservedObject private var favorites = FavoritesStore.shared
    @State private var showAddToPlaylist = false
    @State private var showComments = false
    @State private var showLyricsOptions = false
#if os(iOS)
    @State private var showDownloads = false
#endif
    @State private var airPlayRequest = 0
    var metadataOnly = false
    var actionsOnly = false

    var body: some View {
        Group {
            if metadataOnly {
                metadata(alignment: .center, textAlignment: .center)
                    .padding(.horizontal, 48)
            } else if actionsOnly {
                if let track = player.currentTrack {
                    HStack {
                        Spacer()
                        moreMenu(for: track)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    metadata(alignment: .leading, textAlignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let track = player.currentTrack {
                        moreMenu(for: track)
                    }
                }
            }
        }
        .sheet(isPresented: $showAddToPlaylist) {
            if let track = player.currentTrack {
                AddToPlaylistSheet(track: track)
            }
        }
        .sheet(isPresented: $showComments) {
            if let track = player.currentTrack {
                SongCommentsSheet(track: track)
            }
        }
        .sheet(isPresented: $showLyricsOptions) {
            LyricPresentationSheet()
                .environmentObject(player)
                .environmentObject(settings)
        }
#if os(iOS)
        .sheet(isPresented: $showDownloads) {
            if let track = player.currentTrack {
                DownloadOptionsSheet(tracks: [track])
            }
        }
#endif
    }

    private func metadata(
        alignment: HorizontalAlignment,
        textAlignment: TextAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            HStack(spacing: 6) {
                Text(player.currentTrack?.name ?? "")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if player.currentTrack?.fee == 1 {
                    VIPBadge()
                }
            }
            PlayerArtistLink(font: .footnote, opacity: 0.62)
        }
        .multilineTextAlignment(textAlignment)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("immersiveTrackMetadata")
    }

    private func moreMenu(for track: Track) -> some View {
        Menu {
            let liked = favorites.contains(track)
            Button {
                let isLiked = favorites.toggle(track)
                ToastCenter.shared.show(isLiked ? "已加入本地收藏" : "已取消本地收藏")
            } label: {
                Label(liked ? "取消收藏" : "收藏歌曲", systemImage: liked ? "heart.fill" : "heart")
            }

            Button {
                airPlayRequest += 1
            } label: {
                Label("AirPlay", systemImage: "airplayaudio")
            }

            Button {
                player.addToPlayNext(track)
            } label: {
                Label("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward")
            }

            Button {
                showAddToPlaylist = true
            } label: {
                Label("加入歌单…", systemImage: "music.note.list")
            }

            Button {
                showComments = true
            } label: {
                Label("查看评论", systemImage: "text.bubble")
            }

            PlayerPlaybackModeMenu()

            Menu {
                ForEach(LyricsDisplayStyle.allCases) { style in
                    Button {
                        withAnimation(AppAnimation.standard) {
                            settings.lyricsDisplayStyle = style
                        }
                    } label: {
                        HStack {
                            Text(style.displayName)
                            if style == settings.lyricsDisplayStyle {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label("歌词样式", systemImage: "textformat")
            }

            Button {
                showLyricsOptions = true
            } label: {
                Label("歌词设置…", systemImage: "slider.horizontal.3")
            }

#if os(iOS)
            Button {
                showDownloads = true
            } label: {
                Label("下载歌曲", systemImage: "arrow.down.circle")
            }
#endif

            Menu {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                    Button {
                        player.playbackRate = Float(rate)
                    } label: {
                        HStack {
                            Text("\(rate)×")
                            if abs(Double(player.playbackRate) - rate) < 0.01 {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label("播放速度", systemImage: "speedometer")
            }

            Button { player.queueSimilarSongs() } label: { Label("播放相似歌曲", systemImage: "wand.and.stars") }
                SleepTimerMenu(player: player)

            Divider()

            Button {
                Platform.copyToPasteboard(
                    string: "https://music.163.com/#/song?id=\(track.id)"
                )
                ToastCenter.shared.show(String(localized: "链接已复制"))
            } label: {
                Label("复制链接", systemImage: "link")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("更多操作")
        .accessibilityIdentifier("immersiveMoreMenu")
        .background {
            RoutePickerButton(
                diameter: 1, glyphSize: 1, request: airPlayRequest,
                tint: .clear, background: .clear
            )
            .opacity(0.01)
        }
    }
}

private struct MinimalTransportControls: View {
    @EnvironmentObject private var player: PlayerService
    let backdrop: ArtworkColors
    @Binding var showQueue: Bool

    var body: some View {
        HStack(spacing: 0) {
            Button {
                showQueue = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .accessibilityLabel("播放列表")
            .accessibilityIdentifier("immersivePlaylistButton")
                .frame(maxWidth: .infinity)

            Button(action: player.isFMMode ? player.fmTrash : player.previous) {
                Image(systemName: player.isFMMode ? "trash" : "backward.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 58)
            }
            .accessibilityLabel(player.isFMMode ? "不喜欢" : "上一首")

            Button(action: player.togglePlayPause) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 38, weight: .bold))
                    .contentTransition(.opacity)
                    .frame(maxWidth: .infinity, minHeight: 64)
            }
            .accessibilityLabel(player.isPlaying ? "暂停" : "播放")

            Button(action: player.next) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 58)
            }
            .accessibilityLabel("下一首")
        }
        .foregroundStyle(.white)
        .buttonStyle(.pressable)
        .sheet(isPresented: $showQueue) {
            queueSheet
        }
    }

    @ViewBuilder
    private var queueSheet: some View {
        if #available(iOS 16.4, *) {
            MinimalQueueSheet(backdrop: backdrop)
                .presentationDetents([.fraction(0.5)])
                .presentationBackgroundInteraction(.enabled)
        } else {
            MinimalQueueSheet(backdrop: backdrop)
                .presentationDetents([.fraction(0.5)])
        }
    }

}

private struct MinimalQueueSheet: View {
    @EnvironmentObject private var player: PlayerService
    let backdrop: ArtworkColors

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    if let current = player.currentTrack {
                        MinimalQueueSectionLabel("正在播放")
                        MinimalQueueRow(track: current, isCurrent: true)

                        if !player.upcomingTracks.isEmpty {
                            MinimalQueueSectionLabel("即将播放")
                                .padding(.top, 10)
                            ForEach(
                                Array(player.upcomingTracks.prefix(100).enumerated()),
                                id: \.offset
                            ) { _, track in
                                MinimalQueueRow(track: track, isCurrent: false)
                            }
                        }
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "list.bullet")
                                .font(.system(size: 28, weight: .light))
                            Text("播放队列是空的")
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 240)
                    }
                }
                .padding(10)
            }
            .navigationTitle("播放列表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Text("\(player.upcomingTracks.count + (player.hasCurrentTrack ? 1 : 0)) 首")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .background(queueBackdrop)
    }

    private var queueBackdrop: some View {
        ZStack {
            LinearGradient(
                colors: [backdrop.primary, backdrop.secondary],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Color.black.opacity(0.45)
        }
        .ignoresSafeArea()
    }
}

private struct MinimalQueueSectionLabel: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }
}

private struct MinimalQueueRow: View {
    let track: Track
    let isCurrent: Bool

    @EnvironmentObject private var player: PlayerService

    var body: some View {
        Button {
            guard !isCurrent else { return }
            player.jumpTo(track)
        } label: {
            HStack(spacing: 10) {
                CachedAsyncImage(url: track.album.picUrl?.resizedImageURL(96), animated: false)
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(isCurrent ? Theme.accent : .primary)
                        .lineLimit(1)
                    Text(track.artistNames)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if isCurrent {
                    PlayingIndicator(animating: player.isPlaying)
                } else {
                    Text(Formatters.duration(track.duration))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#endif


// MARK: - Scrubber (white-on-dark variant)

struct NowPlayingScrubber: View {
    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var clock = PlayerService.shared.clock
    #if os(iOS)
    @EnvironmentObject private var settings: SettingsManager
    @ObservedObject private var playerLayout = PlayerLayoutStore.shared
    #endif
    let onShowQuality: (() -> Void)?

    @State private var isHovering = false
    @State private var isDragging = false
    @State private var dragProgress: Double = 0

    init(onShowQuality: (() -> Void)? = nil) {
        self.onShowQuality = onShowQuality
    }

    private var fraction: Double {
        guard player.duration > 0 else { return 0 }
        let value = isDragging ? dragProgress : clock.progress
        return min(max(value / player.duration, 0), 1)
    }

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.25))
                        .frame(height: 4)
                    Capsule()
                        .fill(.white)
                        .frame(width: max(4, width * fraction), height: 4)
                    Circle()
                        .fill(.white)
                        .frame(width: thumbDiameter, height: thumbDiameter)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .offset(x: width * fraction - thumbDiameter / 2)
                        .opacity(isHovering || isDragging ? 1 : 0)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard player.duration > 0 else { return }
                            isDragging = true
                            player.isScrubbing = true
                            dragProgress = min(max(value.location.x / width, 0), 1) * player.duration
                        }
                        .onEnded { _ in
                            player.seek(to: dragProgress)
                            isDragging = false
                            player.isScrubbing = false
                        }
                )
            }
            .frame(height: 14)
            .onHover { hovering in
                withAnimation(AppAnimation.quick) { isHovering = hovering }
            }

            HStack(alignment: .center, spacing: 8) {
                Text(Formatters.duration(isDragging ? dragProgress : clock.progress))
                Spacer()
                if let onShowQuality {
                    Button(action: onShowQuality) {
                        Label(qualityDisplayName, systemImage: "waveform")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.78))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("选择播放音质，当前为\(qualityDisplayName)")
                }
                Spacer()
                Text(Formatters.duration(player.duration))
            }
            .font(.system(size: 10.5).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
        }
        #if os(iOS)
        .moumusicPlayerLayout(playerLayout.entry(for: .progress, mode: settings.nowPlayingMode))
        #endif
    }

    private var thumbDiameter: CGFloat {
        isDragging ? 13 : (isHovering ? 11 : 9)
    }

    private var qualityDisplayName: String {
        // A resolver finishes asynchronously.  Do not let a late result from
        // the previous track leak into the compact player while the new URL
        // is still being resolved.
        if player.servedQualityTrackKey == player.currentTrack?.playbackKey,
           let served = player.servedQuality {
            return AudioQuality.resolvedDisplayName(served)
        }
        return "检测中"
    }
}

// MARK: - Mini lyrics (compact now-playing)

/// Three synced lyric lines (previous / current / next) filling the gap
/// between the track meta and the transport controls on compact layouts.
/// Tapping opens the full lyrics page.
struct MiniLyricsView: View {
    let onOpen: () -> Void

    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var settings: SettingsManager
    @ObservedObject private var lyricsCursor = PlayerService.shared.lyricsCursor
    #if os(iOS)
    @ObservedObject private var playerLayout = PlayerLayoutStore.shared
    #endif

    private var lines: (previous: LyricLine?, current: LyricLine?, next: LyricLine?) {
        guard let lyrics = player.lyrics, !lyrics.isEmpty else { return (nil, nil, nil) }
        guard let index = lyricsCursor.activeIndex else {
            return (nil, nil, lyrics.lines.first)
        }
        let all = lyrics.lines
        return (
            index > 0 ? all[index - 1] : nil,
            all[index],
            index + 1 < all.count ? all[index + 1] : nil
        )
    }

    var body: some View {
        let (previous, current, next) = lines
        Group {
            if current != nil || next != nil {
                VStack(spacing: 12) {
                    line(previous, emphasized: false)
                    line(current, emphasized: true)
                    line(next, emphasized: false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpen)
                .onLongPressGesture(minimumDuration: 0.45) {
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                        settings.lyricsDisplayStyle.toggle()
                    }
                    ToastCenter.shared.show(settings.lyricsDisplayStyle.displayName)
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: current?.id)
            } else {
                Color.clear
            }
        }
        #if os(iOS)
        .moumusicPlayerLayout(playerLayout.entry(for: .lyrics, mode: settings.nowPlayingMode))
        #endif
    }

    @ViewBuilder
    private func line(_ line: LyricLine?, emphasized: Bool) -> some View {
        Group {
            if let line, !line.text.isEmpty {
                // The compact player used to render plain Text here, so long
                // pressing to switch Apple Music/AMLL style only changed the
                // full lyrics page. Reuse the same renderer in every player
                // surface.
                LyricMainText(
                    line: line,
                    isActive: emphasized,
                    font: .system(size: emphasized ? 17 : 14,
                                   weight: emphasized ? .bold : .medium),
                    verbatim: settings.verbatimLyrics,
                    inactiveOpacity: 0.45,
                    rubySize: 13
                )
            } else {
                Text(" ")
                    .font(.system(size: emphasized ? 17 : 14,
                                  weight: emphasized ? .bold : .medium))
                    .foregroundStyle(.white.opacity(emphasized ? 1 : 0.45))
            }
        }
        .font(.system(size: emphasized ? 17 : 14,
                      weight: emphasized ? .bold : .medium))
        .foregroundStyle(.white.opacity(emphasized ? 1 : 0.45))
        .lineLimit(1)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 28)
        .id(line?.id)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

/// The artist line of the player: one tap opens the artist page (a menu when there are several).
struct PlayerArtistLink: View {
    @EnvironmentObject private var player: PlayerService
    let font: Font
    let opacity: Double

    var body: some View {
        if let track = player.currentTrack, !track.artists.isEmpty {
            let label = Text(track.artistNames)
                .font(font)
                .foregroundStyle(.white.opacity(opacity))
                .lineLimit(1)
            if track.artists.count == 1 {
                Button { player.openArtist(track.artists[0], for: track) } label: { label }
                    .buttonStyle(.plain)
                    .accessibilityHint("打开歌手页")
            } else {
                Menu {
                    ForEach(track.artists) { artist in
                        Button(artist.name) { player.openArtist(artist, for: track) }
                    }
                } label: { label }
                .accessibilityHint("选择歌手并打开歌手页")
            }
        } else {
            Text("")
        }
    }
}
