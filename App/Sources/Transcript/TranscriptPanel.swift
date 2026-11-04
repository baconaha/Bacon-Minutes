import SwiftUI

/// Right-hand "文字记录" tab (§5).
struct TranscriptPanel: View {
    @Bindable var model: DetailModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        if model.transcript == nil {
            EmptyTranscriptView { model.chooseAndImportSRT() }
        } else {
            VStack(spacing: 0) {
                toolbar
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .zIndex(2)
                ZStack(alignment: .bottomTrailing) {
                    TranscriptTextView(model: model)
                    if !model.isFollowing && model.currentCueID != nil {
                        BackToCurrentButton(up: model.currentCueAbove) { model.resumeFollowing() }
                            .padding(.trailing, 24)
                            .padding(.bottom, 24)
                            .transition(.opacity)
                    }
                }
                .zIndex(1)
            }
            .onChange(of: model.searchFocusToken) { searchFocused = true }
            .onChange(of: searchFocused) { model.searchFieldFocused = searchFocused }
            .onChange(of: model.searchQuery) { model.scheduleSearch() }
        }
    }

    private var hitCounter: String {
        model.searchHits.isEmpty ? "0/0" : "\(model.currentHitIndex + 1)/\(model.searchHits.count)"
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.textTertiary)
                TextField("搜索", text: $model.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searchFocused)
                if !model.searchQuery.isEmpty {
                    Text(verbatim: hitCounter)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Color.textTertiary)
                        .fixedSize()
                    Button { model.previousHit() } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(IconButtonStyle(size: 22))
                        .disabled(model.searchHits.isEmpty)
                    Button { model.nextHit() } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(IconButtonStyle(size: 22))
                        .disabled(model.searchHits.isEmpty)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.searchFill))
            .overlay(alignment: .topLeading) {
                if searchFocused && model.searchQuery.isEmpty, let keywords = model.summary?.keywords, !keywords.isEmpty {
                    KeywordSuggestions(keywords: keywords) { k in model.search(keyword: k) }
                        .offset(y: 38)
                }
            }

            if !model.searchQuery.isEmpty {
                Button("取消") {
                    model.clearSearch()
                    searchFocused = false
                }
                .buttonStyle(TextLinkButtonStyle())
            }

            MoreMenuButton(help: "导出文字记录") { exportMenuItems(for: model) }
        }
    }
}

private struct KeywordSuggestions: View {
    let keywords: [String]
    let pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("推荐关键词")
                .font(.system(size: 12))
                .foregroundStyle(Color.textTertiary)
            FlowLayout(spacing: 8) {
                ForEach(keywords, id: \.self) { k in
                    Button { pick(k) } label: {
                        Text(k)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.searchFill))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.card))
        .shadow(color: .black.opacity(0.14), radius: 12, x: 0, y: 4)
    }
}

/// Wraps children onto multiple lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += lineHeight + spacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += lineHeight + spacing
                x = bounds.minX
                lineHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// 40pt round "回到当前播放位置" button (§5.5).
private struct BackToCurrentButton: View {
    let up: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: -5) {
                Image(systemName: up ? "chevron.up" : "chevron.down")
                Image(systemName: up ? "chevron.up" : "chevron.down")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(hovering ? Color.brand : Color.textSecondary)
            .frame(width: 40, height: 40)
            .background(Circle().fill(Color.card))
            .shadow(color: .black.opacity(0.16), radius: 8, x: 0, y: 2)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("回到当前播放位置")
    }
}

private struct EmptyTranscriptView: View {
    let importAction: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            ZStack {
                Circle().fill(Color.selectionFill).frame(width: 120, height: 120)
                Image(systemName: "text.bubble")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(Color.brand)
            }
            Text("还没有文字记录")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.textPrimary)
            Button("导入 SRT 字幕", action: importAction)
                .buttonStyle(PrimaryButtonStyle())
            Text("支持 .srt，可直接拖入窗口")
                .font(.system(size: 12))
                .foregroundStyle(Color.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
