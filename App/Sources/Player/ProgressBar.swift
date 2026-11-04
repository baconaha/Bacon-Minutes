import SwiftUI

/// Chapter-segmented progress bar with hover preview and search markers (§3.2).
struct ProgressBar: View {
    @Bindable var model: DetailModel
    @State private var hoverX: CGFloat?
    @State private var dragging = false

    private var player: PlayerController { model.player }
    private static let gap: CGFloat = 4
    private static let barHeight: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let duration = max(model.duration, 0.001)
            let progress = CGFloat(min(max(player.currentTime / duration, 0), 1))
            let active = hoverX != nil || dragging
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    drawSegments(ctx: ctx, size: size, duration: duration, progress: progress,
                                 height: active ? 6 : Self.barHeight)
                }
                .frame(height: 12)

                Circle()
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.3), radius: 2)
                    .offset(x: progress * width - 6, y: 0)
                    .opacity(active ? 1 : 0.9)
                    .allowsHitTesting(false)

                if !model.searchHits.isEmpty {
                    Canvas { ctx, size in
                        drawMarkers(ctx: ctx, size: size, duration: duration)
                    }
                    .frame(height: 6)
                    .offset(y: 14)
                    .allowsHitTesting(false)
                }
            }
            .frame(height: 20, alignment: .top)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        dragging = true
                        hoverX = min(max(g.location.x, 0), width)
                        player.seek(to: time(at: g.location.x, width: width, duration: duration), precise: false)
                    }
                    .onEnded { g in
                        let t = time(at: g.location.x, width: width, duration: duration)
                        dragging = false
                        model.jump(toTime: t, play: player.isPlaying)
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    hoverX = min(max(p.x, 0), width)
                    if let thumbs = model.thumbnails {
                        thumbs.request(time: time(at: p.x, width: width, duration: duration))
                    }
                case .ended:
                    if !dragging { hoverX = nil }
                }
            }
            .overlay(alignment: .topLeading) {
                if let x = hoverX {
                    let t = time(at: x, width: width, duration: duration)
                    PreviewCard(image: model.minute.isAudioOnly ? nil : model.thumbnails?.image,
                                showImage: !model.minute.isAudioOnly && model.thumbnails != nil,
                                time: TimeFormat.timestamp(t, hours: model.useHours),
                                chapter: model.chapterTitle(at: t))
                        .fixedSize()
                        .alignmentGuide(.leading) { d in
                            let half = d.width / 2
                            return -min(max(x - half, 0), max(width - d.width, 0))
                        }
                        .alignmentGuide(.top) { d in d.height + 10 }
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: 20)
    }

    private func time(at x: CGFloat, width: CGFloat, duration: Double) -> Double {
        Double(min(max(x / width, 0), 1)) * duration
    }

    private func drawSegments(ctx: GraphicsContext, size: CGSize, duration: Double, progress: CGFloat, height: CGFloat) {
        let w = size.width
        var bounds: [Double] = [0]
        for c in model.chapterStarts.sorted() where c > 0.5 && c < duration - 0.5 {
            bounds.append(c)
        }
        bounds.append(duration)
        let y = (size.height - height) / 2
        let playedX = progress * w
        let count = bounds.count - 1
        for i in 0..<count {
            var x0 = CGFloat(bounds[i] / duration) * w
            var x1 = CGFloat(bounds[i + 1] / duration) * w
            if i > 0 { x0 += Self.gap / 2 }
            if i < count - 1 { x1 -= Self.gap / 2 }
            guard x1 > x0 else { continue }
            let rect = CGRect(x: x0, y: y, width: x1 - x0, height: height)
            ctx.fill(Path(roundedRect: rect, cornerRadius: height / 2), with: .color(.white.opacity(0.35)))
            if playedX > x0 {
                let played = CGRect(x: x0, y: y, width: min(x1, playedX) - x0, height: height)
                ctx.fill(Path(roundedRect: played, cornerRadius: height / 2), with: .color(.brand))
            }
        }
    }

    private func drawMarkers(ctx: GraphicsContext, size: CGSize, duration: Double) {
        let current = model.currentHitIndex
        let hits = model.searchHits
        for (i, h) in hits.enumerated() where i != current {
            let x = CGFloat(h.time / duration) * size.width
            ctx.fill(Path(ellipseIn: CGRect(x: x - 2.5, y: 0, width: 5, height: 5)), with: .color(Color(nsColor: Palette.searchHitCurrent)))
        }
        if current < hits.count {
            let x = CGFloat(hits[current].time / duration) * size.width
            ctx.fill(Path(ellipseIn: CGRect(x: x - 3, y: -0.5, width: 6, height: 6)), with: .color(.red))
        }
    }
}

private struct PreviewCard: View {
    let image: NSImage?
    let showImage: Bool
    let time: String
    let chapter: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showImage {
                ZStack(alignment: .bottomLeading) {
                    Group {
                        if let image {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Color.black.opacity(0.8)
                        }
                    }
                    .frame(width: 160, height: 90)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    Text(time)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.6)))
                        .padding(5)
                }
            } else {
                Text(time)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.textPrimary)
            }
            if let chapter {
                Text(chapter)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: 160, alignment: .leading)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
        .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 2)
        .environment(\.colorScheme, .light)
    }
}
