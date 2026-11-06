import SwiftUI
import MediaPlayer

private struct ReferenceLyricCenterKey: PreferenceKey {
    static var defaultValue: [UUID: CGFloat] = [:]

    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private struct ReferencePlaybackPresentationMetrics {
    static let headerTopSpacing: CGFloat = 20
}

struct ReferencePlaybackView: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var clock: PlaybackClock
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var localLibrary = LocalLibraryStore.shared
    @ObservedObject private var appleLayout = AppleMusicLayoutStore.shared

    let song: Song?
    let lyrics: [LyricLine]
    @Binding var showLyrics: Bool
    let onFavorite: () -> Void
    let onQueue: () -> Void
    let onComments: () -> Void
    let onSleepTimer: () -> Void
    let onAddToLocalPlaylist: () -> Void
    let onDownload: () -> Void
    let onPlayerSettings: () -> Void

    @AppStorage("beans.lyricOffset") private var lyricOffset = 0.0
    @AppStorage("beans.appleMusic.showVolume") private var showVolumeControl = false
    @AppStorage("beans.appleMusic.primaryHex") private var primaryHex = ""
    @AppStorage("beans.appleMusic.secondaryHex") private var secondaryHex = ""
    @AppStorage("beans.appleMusic.accentHex") private var accentHex = ""
    @AppStorage("beans.appleMusic.volumeHex") private var volumeHex = ""
    @AppStorage("beans.appleMusic.syncWallpaper") private var syncWallpaper = false
    @AppStorage("beans.appleMusic.wallpaperBlur") private var wallpaperBlur = 14.0
    @AppStorage("beans.showSongVIPBadge") private var showSongVIPBadge = true
    @AppStorage("beans.appleMusic.showLyricPreview") private var showLyricPreview = true
    private let downloadFeatureUnlocked = true
    @State private var lyricCenters: [UUID: CGFloat] = [:]
    @State private var focusedLyricID: UUID?
    @State private var lyricsViewportHeight: CGFloat = 0
    @State private var isDraggingLyrics = false
    @State private var resumeTask: Task<Void, Never>?
    /// 左右滑动切歌开关：与经典/黑胶播放器共用同一开关（播放器设置里“左右滑动切歌”），默认开启
    @AppStorage("beans.swipeSwitchSong") private var swipeSwitchSong = true
    /// 左右滑动切歌时封面/歌词区的跟手位移
    @State private var swipeOffset: CGFloat = 0
    /// 飞出/飞入动画进行中时忽略新的滑动，避免快速连续滑动时两次切歌互相打架、封面跳变。
    @State private var swipeFlying = false
    /// 封面轮播的手指拖动位移（静止时为 0，中间页居中）；落页动画进行中时忽略新的滑动。
    @State private var carouselDrag: CGFloat = 0
    @State private var carouselBusy = false

    private func layoutEntry(_ part: AppleMusicLayoutPart) -> PlayerLayoutEntry {
        appleLayout.entry(for: part)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                playerBackground

                VStack(spacing: 0) {
                    Color.clear.frame(height: ReferencePlaybackPresentationMetrics.headerTopSpacing)

                    ZStack {
                        if showLyrics {
                            lyricsPage
                                .transition(.asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .move(edge: .top).combined(with: .opacity)
                                ))
                                // 歌词页仍用旧的飞出/飞入切歌（歌词纵向滚动要保留，轮播只做封面页）
                                .offset(x: swipeOffset)
                                .opacity(1 - min(abs(swipeOffset) / 260, 0.35))
                                .simultaneousGesture(swipeGesture)
                        } else {
                            coverCarousel(size: geometry.size)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .animation(.easeInOut(duration: 0.22), value: showLyrics)

                    playbackControls(bottomInset: geometry.safeAreaInsets.bottom)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background {
            HighRefreshConfigurator()
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
        .onDisappear { resumeTask?.cancel() }
    }

    @ViewBuilder
    private var playerBackground: some View {
        ZStack {
            // Full-screen covers need an opaque base so the home page cannot show through
            // while the cover image is loading or when a presentation uses a clear surface.
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            if syncWallpaper, let image = theme.customBackgroundImage(for: colorScheme) {
                WallpaperImage(image: image)
                    .blur(radius: CGFloat(wallpaperBlur))
                    .scaleEffect(wallpaperBlur > 0 ? 1.08 : 1)
                    .overlay(Color.black.opacity(colorScheme == .dark ? 0.44 : 0.16))
                    .ignoresSafeArea()
            } else if syncWallpaper, let color = theme.customBackground(for: colorScheme) {
                LinearGradient(
                    colors: [color.opacity(0.92), color.opacity(0.58), colorScheme == .dark ? .black.opacity(0.88) : .white.opacity(0.70)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .blur(radius: CGFloat(wallpaperBlur * 0.35))
                .ignoresSafeArea()
            } else {
                CoverBlurBackground(url: song?.coverURL, scheme: colorScheme)
                    .overlay(Color.black.opacity(colorScheme == .dark ? 0.48 : 0.14))
                    .ignoresSafeArea()
            }
        }
    }

    /// 封面轮播：上一首/当前/下一首三页横排，手指拖多远、下一页就跟进来多远，
    /// 松手后弹簧滑到整页再切歌——和苹果自带音乐一样的翻页手感。
    /// 旧的“飞出再飞入”之所以不丝滑，是因为拖的时候下一首封面根本不在屏幕上，
    /// 只能先飞走旧的、再凭空变出新的，看起来像跳切；轮播让下一首一直都在旁边等着。
    private func coverCarousel(size: CGSize) -> some View {
        let width = size.width
        return HStack(spacing: 0) {
            if let prev = player.songBeforeCurrent {
                coverPage(size: size, for: prev, isCurrent: false)
                    .frame(width: width)
            } else {
                Color.clear.frame(width: width)
            }
            coverPage(size: size, for: song, isCurrent: true)
                .frame(width: width)
            if let next = player.songAfterCurrent {
                coverPage(size: size, for: next, isCurrent: false)
                    .frame(width: width)
            } else {
                Color.clear.frame(width: width)
            }
        }
        .offset(x: carouselDrag)
        .gesture(carouselGesture(pageWidth: width))
    }

    /// 轮播手势：横向占优才跟手；朝没有邻居的方向拖给阻尼、滑不进空白页。
    private func carouselGesture(pageWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard swipeSwitchSong, !carouselBusy else { return }
                let x = value.translation.width
                guard abs(x) > abs(value.translation.height) else { return }
                if x < 0, player.songAfterCurrent == nil {
                    carouselDrag = x * 0.25
                } else if x > 0, player.songBeforeCurrent == nil {
                    carouselDrag = x * 0.25
                } else {
                    carouselDrag = x
                }
            }
            .onEnded { value in
                handleCarouselEnd(value: value, pageWidth: pageWidth)
            }
    }

    /// 松手判定：慢拖过 70pt 算切歌；快甩按速度预测（甩得快、拖得不远也算）。
    /// 先弹簧滑到整页，等弹簧落稳再切歌并把位移悄悄归零——归零那一刻中间页已是新歌，
    /// 看起来就是刚滑到的那一页，不会跳变。
    private func handleCarouselEnd(value: DragGesture.Value, pageWidth: CGFloat) {
        guard swipeSwitchSong, !carouselBusy else {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { carouselDrag = 0 }
            return
        }
        let translation = value.translation.width
        let predicted = value.predictedEndTranslation.width
        let goNext = (translation < -70 || predicted < -pageWidth * 0.25) && player.songAfterCurrent != nil
        let goPrev = (translation > 70 || predicted > pageWidth * 0.25) && player.songBeforeCurrent != nil
        if goNext {
            carouselBusy = true
            BeansHaptics.tap()
            withAnimation(.spring(response: 0.28, dampingFraction: 0.92)) { carouselDrag = -pageWidth }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
                player.next()
                carouselDrag = 0
                carouselBusy = false
            }
        } else if goPrev {
            carouselBusy = true
            BeansHaptics.tap()
            withAnimation(.spring(response: 0.28, dampingFraction: 0.92)) { carouselDrag = pageWidth }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
                player.previous()
                carouselDrag = 0
                carouselBusy = false
            }
        } else {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { carouselDrag = 0 }
        }
    }

    private func coverPage(size: CGSize, for displaySong: Song?, isCurrent: Bool) -> some View {
        let contentWidth = max(size.width - 64, 0)
        let artworkSize = min(contentWidth, min(size.height * 0.50, 390))

        return VStack(spacing: 0) {
            Spacer(minLength: 8)

            CoverImage(
                url: displaySong?.coverURL,
                size: artworkSize,
                cornerRadius: 18,
                emptyHint: isCurrent && player.isBuffering ? "等待开始播放…" : nil
            )
            .frame(width: artworkSize, height: artworkSize)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.46), radius: 36, y: 18)
            .scaleEffect(isCurrent ? (player.isPlaying ? 1 : 0.965) : 1)
            .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.cover)))
            .animation(.spring(response: 0.36, dampingFraction: 0.84), value: player.isPlaying)

            if showLyricPreview {
            VStack(spacing: 5) {
                HStack(spacing: 9) {
                    Text(displaySong?.name ?? "未在播放")
                        .font(BeansFont.appFont(22, .bold))
                        .foregroundStyle(primaryColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if showSongVIPBadge, displaySong?.isVIP == true {
                        Text("VIP")
                            .font(BeansFont.appFont(9, .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color(red: 0.93, green: 0.25, blue: 0.22), in: Capsule())
                    }
                }
                Text(subtitle(for: displaySong))
                    .font(BeansFont.appFont(13.5, .medium))
                    .foregroundStyle(secondaryColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: 420)
            .padding(.top, 22)
            .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.title)))

            if isCurrent {
                MiniLyricsPreview(lines: previewLyrics, primary: primaryColor, secondary: secondaryColor) {
                    guard !lyrics.isEmpty else { return }
                    BeansHaptics.tap()
                    showLyrics = true
                }
                .padding(.top, 18)
                .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.previewLyric)))
            } else {
                // 相邻页不显示“暂无歌词”，留出同样高度的空白，保持三页版式一致、滑动时不跳动。
                Color.clear
                    .frame(maxWidth: 420, minHeight: 92)
                    .padding(.top, 18)
            }
            } else {
                if isCurrent {
                    compactTrackHeader
                        .padding(.top, 22)
                } else {
                    staticTrackHeader(for: displaySong)
                        .padding(.top, 22)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
    }

    /// 相邻页的静态标题行（不带收藏/菜单按钮，避免在非当前歌曲上误操作）。
    private func staticTrackHeader(for displaySong: Song?) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(displaySong?.name ?? "未在播放")
                    .font(BeansFont.appFont(16, .semibold))
                    .foregroundStyle(primaryColor)
                    .lineLimit(1)
                Text(subtitle(for: displaySong))
                    .font(BeansFont.appFont(12, .medium))
                    .foregroundStyle(secondaryColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 420)
    }

    private var compactTrackHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(song?.name ?? "未在播放")
                    .font(BeansFont.appFont(16, .semibold))
                    .foregroundStyle(primaryColor)
                    .lineLimit(1)
                Text(subtitle)
                    .font(BeansFont.appFont(12, .medium))
                    .foregroundStyle(secondaryColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            compactActionButton(
                icon: localLibrary.containsSong(song) ? "heart.fill" : "heart",
                active: localLibrary.containsSong(song)
            ) { onFavorite() }
            Menu {
                Button("定时关闭", action: onSleepTimer)
                Button("添加到本地歌单", action: onAddToLocalPlaylist)
                if downloadFeatureUnlocked {
                    Button("下载歌曲", action: onDownload)
                }
                Button("播放器设置", action: onPlayerSettings)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(primaryColor.opacity(0.78))
                    .frame(width: 38, height: 38)
            }
        }
        .frame(maxWidth: 420)
    }

    private var lyricsPage: some View {
        VStack(spacing: 0) {
            lyricsHeader
                .padding(.horizontal, 24)
                .padding(.bottom, 10)

            if lyrics.isEmpty {
                emptyLyricsView
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 26) {
                            Color.clear.frame(height: max(88, lyricsViewportHeight * 0.30))
                            ForEach(lyrics) { line in
                                lyricLine(line, isFocused: line.id == currentVisualLyricID)
                                    .id(line.id)
                                    .background {
                                        GeometryReader { rowGeometry in
                                            Color.clear.preference(
                                                key: ReferenceLyricCenterKey.self,
                                                value: [line.id: rowGeometry.frame(in: .named("referenceLyricsViewport")).midY]
                                            )
                                        }
                                    }
                            }
                            Color.clear.frame(height: max(110, lyricsViewportHeight * 0.34))
                        }
                        .padding(.horizontal, 28)
                    }
                    .coordinateSpace(name: "referenceLyricsViewport")
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: .black, location: 0.12),
                                .init(color: .black, location: 0.84),
                                .init(color: .clear, location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .background {
                        GeometryReader { viewport in
                            Color.clear
                                .onAppear { lyricsViewportHeight = viewport.size.height }
                                .onChange(of: viewport.size.height) { lyricsViewportHeight = $0 }
                        }
                    }
                    .onPreferenceChange(ReferenceLyricCenterKey.self) { centers in
                        lyricCenters = centers
                        updateFocusedLyric(from: centers)
                    }
                    .simultaneousGesture(lyricsDragGesture(proxy: proxy))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                            scrollToPlaybackLyric(proxy: proxy, animated: false)
                        }
                    }
                    .onChange(of: currentPlaybackLyricID) { _ in
                        guard !isDraggingLyrics else { return }
                        scrollToPlaybackLyric(proxy: proxy, animated: true)
                    }
                }
            }
        }
    }

    private var lyricsHeader: some View {
        HStack(spacing: 12) {
            Button {
                BeansHaptics.tap()
                showLyrics = false
            } label: {
                CoverImage(url: song?.coverURL, size: 48, cornerRadius: 10)
                    .shadow(color: .black.opacity(0.26), radius: 9, y: 4)
            }
            .buttonStyle(GlassPressButtonStyle(scale: 0.94))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(song?.name ?? "未在播放")
                        .font(BeansFont.appFont(15, .semibold))
                        .foregroundStyle(primaryColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(subtitle)
                    .font(BeansFont.appFont(12, .medium))
                    .foregroundStyle(secondaryColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                compactActionButton(
                    icon: localLibrary.containsSong(song) ? "heart.fill" : "heart",
                    active: localLibrary.containsSong(song)
                ) {
                    onFavorite()
                }
                Menu {
                    Button("定时关闭", action: onSleepTimer)
                    Button("添加到本地歌单", action: onAddToLocalPlaylist)
                    if downloadFeatureUnlocked {
                        Button("下载歌曲", action: onDownload)
                    }
                    Button("播放器设置", action: onPlayerSettings)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(primaryColor.opacity(0.78))
                        .frame(width: 38, height: 38)
                        .contentShape(Rectangle())
                }
            }
        }
    }

    private func playbackControls(bottomInset: CGFloat) -> some View {
        VStack(spacing: 15) {
            ReferenceScrubber()
                .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.progress)))
            HStack(spacing: 28) {
                Button {
                    BeansHaptics.tap()
                    player.previous()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 25, weight: .semibold))
                }
                .buttonStyle(.plain)
                .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.previous)))

                Button {
                    BeansHaptics.tap()
                    player.togglePlayPause()
                } label: {
                    PlayPauseMorphIcon(isPlaying: player.isPlaying, size: 24)
                        .frame(width: 66, height: 66)
                        .foregroundStyle(primaryColor)
                }
                .buttonStyle(GlassPressButtonStyle(scale: 0.92))
                .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.play)))

                Button {
                    BeansHaptics.tap()
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 25, weight: .semibold))
                }
                .buttonStyle(.plain)
                .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.next)))
            }
            .foregroundStyle(primaryColor)
            .frame(maxWidth: 320)

            if showVolumeControl {
                ReferenceVolumeControl(accent: volumeColor, secondary: secondaryColor)
                    .frame(maxWidth: 420)
                    .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.volume)))
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            HStack(spacing: 48) {
                referenceActionButton(icon: "quote.bubble", active: showLyrics) {
                    guard !lyrics.isEmpty else { return }
                    showLyrics.toggle()
                }
                referenceActionButton(icon: player.playMode.icon, active: player.playMode == .shuffle) {
                    player.togglePlayMode()
                }
                referenceActionButton(icon: "list.bullet") {
                    onQueue()
                }
            }
            .frame(maxWidth: 420)
            .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.actions)))
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, max(14, bottomInset + 4))
        .gesture(commentsGesture)
    }

    private func referenceActionButton(icon: String, active: Bool = false, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button {
            BeansHaptics.tap()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(active ? accentColor : primaryColor.opacity(0.78))
                .frame(width: 58, height: 58)
                .background { BeansGlass(shape: Circle(), forceLiquid: true) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func compactActionButton(icon: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            BeansHaptics.tap()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(active ? accentColor : primaryColor.opacity(0.78))
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyLyricsView: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "quote.bubble")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.white.opacity(0.42))
            Text("暂无歌词")
                .font(BeansFont.appFont(15, .semibold))
                .foregroundStyle(.white.opacity(0.86))
            Text("点击封面区域返回歌曲页面")
                .font(BeansFont.appFont(12))
                .foregroundStyle(.white.opacity(0.46))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            BeansHaptics.tap()
            showLyrics = false
        }
    }

    private var previewLyrics: [LyricLine] {
        guard !lyrics.isEmpty else { return [] }
        let current = currentPlaybackLyricIndex ?? 0
        let start = max(current - 1, 0)
        let end = min(start + 3, lyrics.count)
        return Array(lyrics[start..<end])
    }

    private var currentPlaybackLyricIndex: Int? {
        guard !lyrics.isEmpty else { return nil }
        let progress = LyricTiming.effectiveProgress(clock.progress, userOffset: lyricOffset)
        var low = 0
        var high = lyrics.count - 1
        var answer: Int?
        while low <= high {
            let mid = (low + high) / 2
            if lyrics[mid].time <= progress {
                answer = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return answer
    }

    private var currentPlaybackLyricID: UUID? {
        guard let index = currentPlaybackLyricIndex, lyrics.indices.contains(index) else { return nil }
        return lyrics[index].id
    }

    private var currentVisualLyricID: UUID? {
        isDraggingLyrics ? focusedLyricID : (focusedLyricID ?? currentPlaybackLyricID)
    }

    private var subtitle: String { subtitle(for: song) }

    private func subtitle(for displaySong: Song?) -> String {
        guard let displaySong else { return "" }
        let parts = [displaySong.artists, displaySong.album].filter { !$0.isEmpty }
        return parts.isEmpty ? "未知歌曲" : parts.joined(separator: " · ")
    }

    private func lyricLine(_ line: LyricLine, isFocused: Bool) -> some View {
        Button {
            BeansHaptics.tap()
            player.seek(to: LyricTiming.seekTime(for: line, userOffset: lyricOffset))
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(BeansFont.appFont(isFocused ? 27 : 23, isFocused ? .bold : .semibold))
                        .foregroundStyle(primaryColor.opacity(isFocused ? 1 : 0.36))
                        .fixedSize(horizontal: false, vertical: true)
                    if isFocused && isDraggingLyrics {
                        Spacer(minLength: 8)
                        Text(beansTimeString(line.time))
                            .font(BeansFont.appFont(11, .semibold, .monospaced))
                            .foregroundStyle(secondaryColor.opacity(0.82))
                    }
                }
                if isFocused, let translation = line.translation, !translation.isEmpty {
                    Text(translation)
                        .font(BeansFont.appFont(15, .medium))
                        .foregroundStyle(secondaryColor.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .scaleEffect(isFocused ? 1.06 : 0.84, anchor: .leading)
            .blur(radius: isFocused ? 0 : 0.7)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: isFocused)
    }

    private func updateFocusedLyric(from centers: [UUID: CGFloat]) {
        guard lyricsViewportHeight > 0, !centers.isEmpty else { return }
        let center = lyricsViewportHeight / 2
        focusedLyricID = centers.min { abs($0.value - center) < abs($1.value - center) }?.key
    }

    private func scrollToPlaybackLyric(proxy: ScrollViewProxy, animated: Bool) {
        guard let id = currentPlaybackLyricID else { return }
        let action = { proxy.scrollTo(id, anchor: .center) }
        if animated {
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.38)) { action() }
        } else {
            action()
        }
    }

    private func lyricsDragGesture(proxy: ScrollViewProxy) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { _ in
                isDraggingLyrics = true
                resumeTask?.cancel()
                updateFocusedLyric(from: lyricCenters)
            }
            .onEnded { _ in
                resumeTask?.cancel()
                if let id = focusedLyricID {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
                resumeTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    guard !Task.isCancelled else { return }
                    isDraggingLyrics = false
                }
            }
    }

    private var commentsGesture: some Gesture {
        DragGesture(minimumDistance: 25)
            .onEnded { value in
                guard value.translation.height < -54, abs(value.translation.height) > abs(value.translation.width) else { return }
                BeansHaptics.medium()
                onComments()
            }
    }

    /// 歌词页的左右滑动切歌手势（封面页已改用三页轮播，不再走这里）。
    /// 用 simultaneousGesture，歌词上下滚动仍可用，只有横向占优时才跟手移动。
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 15)
            .onChanged { value in
                guard swipeSwitchSong, !swipeFlying else { return }
                let x = value.translation.width
                if abs(x) > abs(value.translation.height) {
                    swipeOffset = x
                }
            }
            .onEnded { value in
                handleSwipeEnd(horizontal: value.translation.width)
            }
    }

    /// 左右切歌：滑动超过 70pt 松手切歌，不足则弹回原位。左滑下一首，右滑上一首。
    private func handleSwipeEnd(horizontal: CGFloat) {
        guard swipeSwitchSong else {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { swipeOffset = 0 }
            return
        }
        guard !swipeFlying else { return }
        if horizontal < -70 {
            BeansHaptics.tap()
            flySwipe(direction: -1)
        } else if horizontal > 70 {
            BeansHaptics.tap()
            flySwipe(direction: 1)
        } else {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { swipeOffset = 0 }
        }
    }

    private func flySwipe(direction: CGFloat) {
        let flyOut: CGFloat = direction * 560
        let flyIn: CGFloat = -direction * 560
        swipeFlying = true
        // 1) 当前封面继续向滑动方向飞出（0.12s，比原来更快，减少松手后的等待感）
        withAnimation(.easeIn(duration: 0.12)) { swipeOffset = flyOut }
        // 2) 飞出后立即切歌，并把新封面放到对侧屏幕外，再用弹簧滑回中央。
        // 新封面已由播放器提前预取进内存，飞入时直接渲染，不用等网络现下。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            // 动画期间开关被关闭：直接复位，避免卡在屏幕外
            guard swipeSwitchSong else {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) { swipeOffset = 0 }
                swipeFlying = false
                return
            }
            if direction < 0 { player.next() } else { player.previous() }
            swipeOffset = flyIn
            // 等下一帧先渲染出新封面在屏幕外的位置，再动画滑回中央（否则动画会从旧位置开始，方向不对）
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) { swipeOffset = 0 }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { swipeFlying = false }
        }
    }

    private var primaryColor: Color {
        if primaryHex.hasPrefix("#"), let color = Color(hex: primaryHex) { return color }
        return .white
    }

    private var secondaryColor: Color {
        if secondaryHex.hasPrefix("#"), let color = Color(hex: secondaryHex) { return color }
        return .white.opacity(0.58)
    }

    private var accentColor: Color {
        if accentHex.hasPrefix("#"), let color = Color(hex: accentHex) { return color }
        return Color(red: 1.0, green: 0.28, blue: 0.36)
    }

    private var volumeColor: Color {
        if volumeHex.hasPrefix("#"), let color = Color(hex: volumeHex) { return color }
        return primaryColor
    }
}

private struct ReferenceScrubber: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var clock: PlaybackClock
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let total = max(max(clock.duration, player.currentSong?.duration ?? 0), 1)
                let progress = min(max((scrubbing ? scrubValue : clock.progress) / total, 0), 1)
                let width = geometry.size.width

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.18))
                        .frame(height: 4)
                    Capsule()
                        .fill(.white.opacity(0.88))
                        .frame(width: width * progress, height: 4)
                    Circle()
                        .fill(.white)
                        .frame(width: scrubbing ? 18 : 12, height: scrubbing ? 18 : 12)
                        .shadow(color: .white.opacity(scrubbing ? 0.55 : 0.28), radius: scrubbing ? 10 : 3)
                        .offset(x: max(0, min(width - (scrubbing ? 18 : 12), width * progress - (scrubbing ? 9 : 6))))
                }
                .frame(height: 30)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !scrubbing {
                                scrubValue = clock.progress
                                BeansHaptics.medium()
                            }
                            scrubbing = true
                            scrubValue = min(max(value.location.x / max(width, 1), 0), 1) * total
                        }
                        .onEnded { _ in
                            player.seek(to: scrubValue)
                            scrubbing = false
                            BeansHaptics.tap()
                        }
                )
                .overlay(alignment: .topLeading) {
                    if scrubbing {
                        Text(beansTimeString(scrubValue))
                            .font(BeansFont.appFont(11, .semibold, .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.44), in: Capsule())
                            .offset(x: max(0, min(width - 62, width * progress - 31)), y: -28)
                            .transition(.scale(scale: 0.92).combined(with: .opacity))
                    }
                }
            }
            .frame(height: 30)

            HStack {
                Text(beansTimeString(scrubbing ? scrubValue : clock.progress))
                Spacer()
                Text(beansTimeString(max(clock.duration, player.currentSong?.duration ?? 0)))
            }
            .font(BeansFont.appFont(11, .regular, .monospaced))
            .foregroundStyle(.white.opacity(0.52))
        }
        .frame(maxWidth: 420)
        .animation(.spring(response: 0.24, dampingFraction: 0.82), value: scrubbing)
    }
}

private struct ReferenceVolumeControl: View {
    let accent: Color
    let secondary: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(secondary.opacity(0.84))
            ReferenceSystemVolumeView(accent: accent, secondary: secondary)
                .frame(height: 32)
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(secondary.opacity(0.84))
        }
        .frame(height: 34)
    }
}

private struct ReferenceSystemVolumeView: UIViewRepresentable {
    let accent: Color
    let secondary: Color

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsRouteButton = false
        styleVolumeSlider(in: view)
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        styleVolumeSlider(in: uiView)
    }

    private func styleVolumeSlider(in view: MPVolumeView) {
        let applyStyle = {
            let sliders = allSubviews(in: view).compactMap { $0 as? UISlider }
            sliders.forEach { slider in
                slider.minimumTrackTintColor = UIColor(accent.opacity(0.88))
                slider.maximumTrackTintColor = UIColor(secondary.opacity(0.32))
                slider.thumbTintColor = UIColor(accent)
            }
        }

        // MPVolumeView creates its internal slider during layout, so apply the tint once more after it settles.
        applyStyle()
        DispatchQueue.main.async {
            applyStyle()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                applyStyle()
            }
        }
    }

    private func allSubviews(in view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap { allSubviews(in: $0) }
    }
}

private struct MiniLyricsPreview: View {
    let lines: [LyricLine]
    let primary: Color
    let secondary: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                if lines.isEmpty {
                    Text("暂无歌词")
                        .font(BeansFont.appFont(15, .semibold))
                        .foregroundStyle(secondary.opacity(0.54))
                } else {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(BeansFont.appFont(index == 1 ? 17 : 15, index == 1 ? .semibold : .medium))
                            .foregroundStyle((index == 1 ? primary : secondary).opacity(index == 1 ? 0.86 : 0.5))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                }
            }
            .frame(maxWidth: 420, minHeight: 92)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
