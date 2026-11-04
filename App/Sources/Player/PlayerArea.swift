import AppKit
import AVFoundation
import SwiftUI

/// Video (or audio cover) with custom overlay controls (§3).
struct PlayerArea: View {
    @Bindable var model: DetailModel
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var flashIcon: String?
    @State private var flashTask: Task<Void, Never>?
    @State private var menuOpen = false

    private var player: PlayerController { model.player }
    private var showControls: Bool { controlsVisible || !player.isPlaying || menuOpen }

    var body: some View {
        ZStack {
            Color.black
            surface

            // Click on the picture toggles playback (§3.3).
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    guard model.mediaState == .ready else { return }
                    player.togglePlay()
                    flash(player.isPlaying ? "play.fill" : "pause.fill")
                }

            if let icon = flashIcon {
                Circle()
                    .fill(Color.black.opacity(0.45))
                    .frame(width: 64, height: 64)
                    .overlay(Image(systemName: icon).font(.system(size: 26)).foregroundStyle(.white))
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            if model.settings.general.ccEnabled { subtitles }

            VStack(spacing: 0) {
                Spacer()
                ZStack(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 110)
                        .allowsHitTesting(false)
                    PlayerControls(model: model, menuOpen: $menuOpen)
                }
            }
            .opacity(showControls && model.mediaState == .ready ? 1 : 0)
            .allowsHitTesting(showControls && model.mediaState == .ready)
            .animation(.easeInOut(duration: 0.25), value: showControls)

            if !showControls && model.mediaState == .ready {
                VStack {
                    Spacer()
                    ThinProgressLine(player: player)
                }
                .allowsHitTesting(false)
            }
        }
        .clipped()
        .onContinuousHover { phase in
            switch phase {
            case .active:
                controlsVisible = true
                scheduleHide(after: 3)
            case .ended:
                scheduleHide(after: 2)
            }
        }
    }

    @ViewBuilder
    private var surface: some View {
        switch model.mediaState {
        case .loading:
            ProgressView().controlSize(.small).tint(.white)
        case .missing:
            MissingMediaView(fileName: model.minute.mediaFileName) { model.relocateMedia() }
        case .ready:
            if model.minute.isAudioOnly {
                AudioCover(title: model.minute.mediaFileName)
            } else {
                VideoSurface(player: player.player)
            }
        }
    }

    private var subtitles: some View {
        VStack {
            Spacer()
            if let cue = model.cue(model.activeCueID), !cue.text.isEmpty {
                Text(cue.text)
                    .font(.system(size: model.isVideoFullscreen ? 28 : 20))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.6)))
                    .padding(.horizontal, 40)
            }
        }
        .padding(.bottom, showControls ? 84 : 24)
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.2), value: showControls)
    }

    private func scheduleHide(after seconds: Double) {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if Task.isCancelled { return }
            controlsVisible = false
        }
    }

    private func flash(_ icon: String) {
        flashTask?.cancel()
        withAnimation(.easeOut(duration: 0.1)) { flashIcon = icon }
        flashTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            withAnimation(.easeIn(duration: 0.25)) { flashIcon = nil }
        }
    }
}

// MARK: - Surfaces

struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.playerLayer.player = player
        return v
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        if nsView.playerLayer.player !== player { nsView.playerLayer.player = player }
    }
}

final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct AudioCover: View {
    let title: String

    var body: some View {
        ZStack {
            LinearGradient(colors: [.audioCoverTop, .audioCoverBottom], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 14) {
                AppLogo(size: 56)
                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
    }
}

struct MissingMediaView: View {
    let fileName: String
    let relocate: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(Color.white.opacity(0.8))
            Text("找不到媒体文件")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
            Text(fileName)
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 40)
            Button("重新定位", action: relocate)
                .buttonStyle(PrimaryButtonStyle(compact: true))
            Text("文字记录与纪要仍可正常使用")
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.5))
        }
    }
}

struct ThinProgressLine: View {
    let player: PlayerController

    var body: some View {
        GeometryReader { geo in
            let d = max(player.duration, 0.001)
            let w = geo.size.width * CGFloat(min(max(player.currentTime / d, 0), 1))
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.25))
                Rectangle().fill(Color.brand).frame(width: w)
            }
        }
        .frame(height: 2)
    }
}

// MARK: - Controls (§3.1)

struct PlayerControls: View {
    @Bindable var model: DetailModel
    @Binding var menuOpen: Bool
    @State private var showRate = false
    @State private var showMore = false

    private var player: PlayerController { model.player }

    var body: some View {
        VStack(spacing: 6) {
            ProgressBar(model: model)
                .padding(.horizontal, 20)
            HStack(spacing: 6) {
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(PlayerIconStyle())
                .help(player.isPlaying ? "暂停" : "播放")

                Button { player.skip(by: -15) } label: { Image(systemName: "gobackward.15") }
                    .buttonStyle(PlayerIconStyle())
                    .help("后退 15 秒")
                Button { player.skip(by: 15) } label: { Image(systemName: "goforward.15") }
                    .buttonStyle(PlayerIconStyle())
                    .help("前进 15 秒")

                VolumeControl(model: model)

                TimeLabel(player: player, hours: model.useHours)
                    .padding(.leading, 6)

                Spacer()

                DropdownButton(placement: .above, alignment: .center, style: .dark, minWidth: 96,
                               onOpenChange: { showRate = $0 }, items: {
                    PlayerController.rates.map { r in
                        DropdownItem.button(RateMenu.label(r), selected: r == player.rate) {
                            player.setRate(r)
                            model.settings.general.playbackRate = r
                        }
                    }
                }) { _ in
                    Text(verbatim: RateMenu.label(player.rate))
                        .font(.system(size: 13, weight: .semibold))
                        .frame(minWidth: 36)
                }
                .buttonStyle(PlayerIconStyle(width: 44))
                .help("播放倍率")

                Button { model.settings.general.ccEnabled.toggle() } label: {
                    CCBadge(on: model.settings.general.ccEnabled)
                }
                .buttonStyle(PlayerIconStyle(width: 36))
                .help(model.settings.general.ccEnabled ? "关闭字幕" : "显示字幕")

                DropdownButton(placement: .above, alignment: .trailing, style: .dark, minWidth: 180,
                               onOpenChange: { showMore = $0 }, items: {
                    [
                        .toggle("跳过空白片段", icon: "forward.end", isOn: model.settings.general.skipBlankEnabled) {
                            model.settings.general.skipBlankEnabled.toggle()
                        },
                    ]
                }) { _ in
                    Image(systemName: "ellipsis")
                }
                .buttonStyle(PlayerIconStyle())
                .help("更多")

                Button { model.toggleFullscreen() } label: {
                    Image(systemName: model.isVideoFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(PlayerIconStyle())
                .help(model.isVideoFullscreen ? "退出全屏" : "全屏")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .onChange(of: showRate) { menuOpen = showRate || showMore }
        .onChange(of: showMore) { menuOpen = showRate || showMore }
    }
}

private struct TimeLabel: View {
    let player: PlayerController
    let hours: Bool

    var body: some View {
        Text("\(TimeFormat.timestamp(player.currentTime, hours: hours)) / \(TimeFormat.timestamp(player.duration, hours: hours))")
            .font(.system(size: 12, design: .default).monospacedDigit())
            .foregroundStyle(.white)
            .fixedSize()
    }
}

private struct CCBadge: View {
    let on: Bool

    var body: some View {
        Text("CC")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(on ? Color.black : Color.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(on ? Color.white : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.white, lineWidth: 1.2))
    }
}

private struct RateMenu: View {
    let current: Float
    let select: (Float) -> Void

    static func label(_ r: Float) -> String {
        r == r.rounded() ? "\(Int(r))x" : "\(r)x"
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(PlayerController.rates, id: \.self) { r in
                Button { select(r) } label: {
                    Text(verbatim: RateMenu.label(r))
                        .font(.system(size: 13, weight: r == current ? .semibold : .regular))
                        .foregroundStyle(r == current ? Color.brand : Color.textPrimary)
                        .frame(width: 72, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
    }
}

struct PlayerIconStyle: ButtonStyle {
    var width: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        PlayerIconBody(configuration: configuration, width: width)
    }

    private struct PlayerIconBody: View {
        let configuration: ButtonStyleConfiguration
        let width: CGFloat
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 16))
                .foregroundStyle(.white)
                .frame(width: width, height: 32)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(hovering ? 0.15 : 0)))
                .opacity(configuration.isPressed ? 0.7 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// Mute toggle with a vertical slider that appears on hover (§3.1).
private struct VolumeControl: View {
    @Bindable var model: DetailModel
    @State private var visible = false
    @State private var hideTask: Task<Void, Never>?

    private var player: PlayerController { model.player }

    var body: some View {
        Button { player.toggleMute() } label: {
            Image(systemName: player.isMuted || player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
        }
        .buttonStyle(PlayerIconStyle())
        .onHover { hovering($0) }
        .overlay(alignment: .bottom) {
            if visible {
                VerticalSlider(value: Double(player.isMuted ? 0 : player.volume)) { v in
                    player.setVolume(Float(v))
                    model.settings.general.volume = Float(v)
                }
                .frame(width: 30, height: 100)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.75)))
                .offset(y: -36)
                .onHover { hovering($0) }
            }
        }
    }

    private func hovering(_ inside: Bool) {
        hideTask?.cancel()
        if inside {
            visible = true
        } else {
            hideTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
                visible = false
            }
        }
    }
}

private struct VerticalSlider: View {
    let value: Double
    let onChange: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let filled = h * CGFloat(min(max(value, 0), 1))
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.white.opacity(0.3)).frame(width: 4)
                Capsule().fill(Color.brand).frame(width: 4, height: filled)
                Circle().fill(Color.white).frame(width: 12, height: 12)
                    .offset(y: -filled + 6)
            }
            .frame(width: geo.size.width, height: h)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        onChange(Double(min(max(1 - g.location.y / max(h, 1), 0), 1)))
                    }
            )
        }
    }
}
