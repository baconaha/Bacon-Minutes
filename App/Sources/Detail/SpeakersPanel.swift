import SwiftUI

/// "发言人 (N)" / "文件信息" tabs under the video (§4).
struct LeftBottomPanel: View {
    @Bindable var model: DetailModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 28) {
                UnderlineTab(title: "发言人 (\(model.transcript?.speakers.count ?? 0))",
                             selected: model.leftTab == .speakers, fontSize: 14) { model.leftTab = .speakers }
                UnderlineTab(title: "文件信息", selected: model.leftTab == .fileInfo, fontSize: 14) { model.leftTab = .fileInfo }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            Rectangle().fill(Color.divider).frame(height: 1)

            ScrollView {
                switch model.leftTab {
                case .speakers: SpeakersList(model: model)
                case .fileInfo: FileInfoView(model: model)
                }
            }
        }
        .background(Color.card)
    }
}

private struct SpeakersList: View {
    @Bindable var model: DetailModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let tr = model.transcript {
                ForEach(tr.speakers) { s in
                    SpeakerRow(model: model, speaker: s,
                               percent: model.percentages[s.id] ?? 0,
                               intervals: model.speakerIntervals[s.id] ?? [])
                }
            } else if model.isLoaded {
                Text("导入 SRT 后显示发言人与发言时段")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.textTertiary)
                    .padding(.top, 8)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SpeakerRow: View {
    @Bindable var model: DetailModel
    let speaker: Speaker
    let percent: Int
    let intervals: [ClosedRange<Double>]
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SpeakerAvatar(name: speaker.name, colorHex: speaker.colorHex, size: 22)
                if editing {
                    TextField("名字", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                        .frame(maxWidth: 200)
                        .focused($focused)
                        .onSubmit { commit() }
                        .onExitCommand { editing = false }
                        .onChange(of: focused) { if !focused && editing { commit() } }
                } else {
                    Text(speaker.name)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.textPrimary)
                        .onTapGesture { beginEditing() }
                        .help("点击重命名")
                }
                Text(verbatim: "\(percent)%")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Color.textTertiary)
                Spacer()
            }
            .contextMenu {
                Button("重命名") { beginEditing() }
            }
            SpeakerTrack(intervals: intervals, duration: model.duration, hours: model.useHours) { t in
                model.jump(toTime: t, play: model.player.isPlaying)
            }
        }
    }

    private func beginEditing() {
        draft = speaker.name
        editing = true
        focused = true
    }

    private func commit() {
        editing = false
        model.renameSpeaker(speaker.id, to: draft)
    }
}

/// Speaking-time track: blue where this speaker talks (§4.1).
private struct SpeakerTrack: View {
    let intervals: [ClosedRange<Double>]
    let duration: Double
    let hours: Bool
    let seek: (Double) -> Void
    @State private var hoverX: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let d = max(duration, 0.001)
            Canvas { ctx, size in
                let rect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(.trackIdle))
                for r in intervals {
                    let x0 = CGFloat(r.lowerBound / d) * size.width
                    let x1 = max(x0 + 1, CGFloat(r.upperBound / d) * size.width)
                    ctx.fill(Path(roundedRect: CGRect(x: x0, y: 0, width: x1 - x0, height: size.height), cornerRadius: 1),
                             with: .color(.brand))
                }
            }
            .frame(height: 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hoverX = min(max(p.x, 0), w)
                case .ended: hoverX = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0).onEnded { g in
                    seek(Double(min(max(g.location.x / w, 0), 1)) * d)
                }
            )
            .overlay(alignment: .topLeading) {
                if let x = hoverX {
                    Text(TimeFormat.timestamp(Double(x / w) * d, hours: hours))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Color.textPrimary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.card))
                        .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 1)
                        .fixedSize()
                        .alignmentGuide(.leading) { dim in -min(max(x - dim.width / 2, 0), max(w - dim.width, 0)) }
                        .alignmentGuide(.top) { dim in dim.height + 2 }
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: 14)
    }
}

private struct FileInfoView: View {
    @Bindable var model: DetailModel

    var body: some View {
        let m = model.minute
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
            row("媒体文件", m.mediaFileName)
            GridRow {
                label("媒体路径")
                Button {
                    model.revealMedia()
                } label: {
                    Text(m.mediaPath.isEmpty ? "—" : m.mediaPath)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                        .truncationMode(.middle)
                }
                .buttonStyle(TextLinkButtonStyle())
                .help("在 Finder 中显示")
            }
            row("时长", TimeFormat.durationCN(model.duration))
            row("SRT 文件", m.srtFileName ?? "未导入")
            row("字幕条数", "\(model.transcript?.cues.count ?? 0)")
            row("发言人数", "\(model.transcript?.speakers.count ?? 0)")
            row("创建时间", TimeFormat.createdDate(m.createdAt))
            row("最近打开", m.lastOpenedAt.map(TimeFormat.createdDate) ?? "—")
        }
        .font(.system(size: 13))
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func label(_ s: String) -> some View {
        Text(s).foregroundStyle(Color.textTertiary)
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            label(title)
            Text(value)
                .foregroundStyle(Color.textPrimary)
                .textSelection(.enabled)
                .lineLimit(3)
        }
    }
}
