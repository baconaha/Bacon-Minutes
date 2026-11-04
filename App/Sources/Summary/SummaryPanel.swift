import SwiftUI

/// Right-hand "智能纪要" tab (§6).
struct SummaryPanel: View {
    @Bindable var model: DetailModel

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(Color.divider).frame(height: 1)
            Text(L("智能纪要由 AI 生成，请谨慎使用"))
                .font(.system(size: 12))
                .foregroundStyle(Color.textTertiary)
                .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private var content: some View {
        if !model.isLoaded {
            Color.clear
        } else if case .generating(let text) = model.summaryState {
            GeneratingView(text: text) { model.cancelGeneration() }
        } else if let summary = model.summary {
            SummaryContent(model: model, summary: summary)
        } else if case .failed(let message) = model.summaryState {
            ScrollView {
                VStack(spacing: 16) {
                    ErrorCard(message: message) { model.generateSummary() }
                    if !model.settings.isLLMReady {
                        APISettingsForm(settings: model.settings, embedded: true)
                    }
                }
                .padding(20)
            }
        } else if model.transcript == nil {
            SummaryPlaceholder(icon: "text.bubble", title: L("还没有文字记录"),
                               message: L("导入 SRT 字幕后即可生成智能纪要")) {
                Button(L("导入 SRT 字幕")) { model.chooseAndImportSRT() }
                    .buttonStyle(PrimaryButtonStyle())
            }
        } else if !model.settings.isLLMReady {
            ScrollView {
                VStack(spacing: 18) {
                    SummaryPlaceholder(icon: "sparkles", title: L("配置 API 后即可生成智能纪要"),
                                       message: L("支持 OpenAI 兼容、Anthropic、Azure OpenAI 以及本地模型服务")) { EmptyView() }
                        .frame(height: 220)
                    APISettingsForm(settings: model.settings, embedded: true)
                    Button(L("保存并生成")) { model.generateSummary() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!model.settings.isLLMReady)
                }
                .padding(20)
            }
        } else {
            SummaryPlaceholder(icon: "sparkles", title: L("让 AI 帮你整理这段内容"),
                               message: L("将生成总述、要点、待办、章节与关键词")) {
                Button(L("生成智能纪要")) { model.generateSummary() }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }
}

private struct SummaryPlaceholder<Actions: View>: View {
    let icon: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            ZStack {
                Circle().fill(Color.aiCardTop).frame(width: 110, height: 110)
                Image(systemName: icon)
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Color.aiPurple)
            }
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.textPrimary)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Color.textTertiary)
                .multilineTextAlignment(.center)
            actions
            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
    }
}

private struct GeneratingView: View {
    let text: String
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text).font(.system(size: 13)).foregroundStyle(Color.textSecondary)
                Spacer()
                Button(L("取消"), action: cancel).buttonStyle(TextLinkButtonStyle())
            }
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 12) {
                    SkeletonBlock(width: 120, height: 14)
                    SkeletonBlock(height: 12)
                    SkeletonBlock(height: 12)
                    SkeletonBlock(width: 240, height: 12)
                    SkeletonBlock(height: 12)
                    SkeletonBlock(width: 180, height: 12)
                }
                .padding(16)
                .background(AICardBackground())
            }
            Spacer()
        }
        .padding(20)
    }
}

private struct ErrorCard: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.errorText)
                Text(L("生成失败")).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.textPrimary)
            }
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Color.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button(L("重试"), action: retry).buttonStyle(PrimaryButtonStyle(compact: true))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.warningFill))
    }
}

struct AICardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(LinearGradient(colors: [.aiCardTop, .card], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.divider.opacity(0.5)))
    }
}

// MARK: - Content

private struct SummaryContent: View {
    @Bindable var model: DetailModel
    let summary: Summary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("\(summary.model) · \(TimeFormat.createdDate(summary.generatedAt))")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.textTertiary)
                        .lineLimit(1)
                    Spacer()
                    MoreMenuButton {
                        [
                            .button(L("重新生成"), icon: "arrow.clockwise") { model.generateSummary() },
                            .button(L("复制为 Markdown"), icon: "doc.on.doc") { model.copySummaryMarkdown() },
                        ]
                    }
                }
                .padding(.bottom, -12)

                if case .failed(let message) = model.summaryState {
                    ErrorCard(message: message) { model.generateSummary() }
                }
                if model.isSummaryStale {
                    StaleBanner { model.generateSummary() }
                }
                MeetingCard(model: model, summary: summary)
                ChapterCard(model: model, summary: summary)
            }
            .padding(20)
        }
    }
}

private struct StaleBanner: View {
    let regenerate: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.warningText)
            Text(L("文字记录已变更，纪要可能过期 ·")).foregroundStyle(Color.warningText)
            Button(L("重新生成"), action: regenerate).buttonStyle(TextLinkButtonStyle(size: 12))
            Spacer()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.warningFill))
    }
}

private struct FeedbackButtons: View {
    let value: Int?
    let set: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button { set(1) } label: { Image(systemName: value == 1 ? "hand.thumbsup.fill" : "hand.thumbsup") }
                .buttonStyle(IconButtonStyle(size: 24, foreground: value == 1 ? .brand : .textTertiary))
                .help(L("有帮助"))
            Button { set(-1) } label: { Image(systemName: value == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown") }
                .buttonStyle(IconButtonStyle(size: 24, foreground: value == -1 ? .brand : .textTertiary))
                .help(L("没帮助"))
        }
    }
}

private struct CardTitle<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            AISparkle()
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.aiPurple)
            Spacer()
            trailing
        }
    }
}

private struct MeetingCard: View {
    @Bindable var model: DetailModel
    let summary: Summary

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(title: L("会议纪要")) {
                Rectangle().fill(Color.divider).frame(width: 1, height: 14)
                FeedbackButtons(value: summary.feedback) { model.setFeedback($0, chapters: false) }
            }

            Collapsible(maxHeight: 8 * 24) {
                VStack(alignment: .leading, spacing: 10) {
                    if !summary.overview.isEmpty {
                        Text(summary.overview)
                            .font(.system(size: 14))
                            .foregroundStyle(Color.textPrimary)
                            .lineSpacing(5)
                            .textSelection(.enabled)
                    }
                    ForEach(Array(summary.keyPoints.enumerated()), id: \.offset) { _, kp in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(Color.brand).frame(width: 6, height: 6)
                                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }
                            keyPointText(kp)
                                .lineSpacing(5)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L("待办"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                if summary.todos.isEmpty {
                    Text(L("本场会议无待办内容"))
                        .font(.system(size: 13))
                        .foregroundStyle(Color.textTertiary)
                } else {
                    ForEach(Array(summary.todos.enumerated()), id: \.offset) { _, todo in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "square")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.textTertiary)
                            Text(todo.content)
                                .font(.system(size: 14))
                                .foregroundStyle(Color.textPrimary)
                                .textSelection(.enabled)
                            Text("· \(todo.owner) ·")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.textTertiary)
                                .fixedSize()
                            Button(TimeFormat.timestamp(todo.time, hours: model.useHours)) {
                                model.jump(toTime: todo.time)
                            }
                            .buttonStyle(TextLinkButtonStyle(size: 13))
                            .monospacedDigit()
                            .fixedSize()
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(AICardBackground())
    }

    private func keyPointText(_ kp: KeyPoint) -> Text {
        let body = Text(kp.content)
            .font(.system(size: 14))
            .foregroundStyle(Color.textPrimary)
        guard !kp.title.isEmpty else { return body }
        let title = Text(kp.title + L("："))
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.textPrimary)
        return title + body
    }
}

/// Clips content to `maxHeight` with "展开 ⌄ / 收起 ⌃" when it is taller (§6.1).
private struct Collapsible<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder var content: Content
    @State private var expanded = false
    @State private var fullHeight: CGFloat = 0

    private var needsCollapse: Bool { fullHeight > maxHeight + 4 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { g in
                        Color.clear
                            .onAppear { fullHeight = g.size.height }
                            .onChange(of: g.size.height) { _, h in fullHeight = h }
                    }
                )
                .frame(maxHeight: needsCollapse && !expanded ? maxHeight : nil, alignment: .top)
                .clipped()
                .mask(
                    LinearGradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: needsCollapse && !expanded ? 0.75 : 1),
                        .init(color: needsCollapse && !expanded ? .clear : .black, location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                )
            if needsCollapse {
                Button(expanded ? L("收起 ⌃") : L("展开 ⌄")) {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                }
                .buttonStyle(TextLinkButtonStyle())
            }
        }
    }
}

private struct ChapterCard: View {
    @Bindable var model: DetailModel
    let summary: Summary
    @State private var expandAll = false
    @State private var expanded: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(title: L("章节纪要")) {
                Button(expandAll ? L("收起全部") : L("展开全部")) {
                    expandAll.toggle()
                    expanded = []
                }
                .buttonStyle(TextLinkButtonStyle(size: 12))
                Rectangle().fill(Color.divider).frame(width: 1, height: 14)
                FeedbackButtons(value: summary.chaptersFeedback) { model.setFeedback($0, chapters: true) }
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(summary.chapters.enumerated()), id: \.offset) { i, chapter in
                    ChapterRow(chapter: chapter,
                               time: TimeFormat.timestamp(chapter.time, hours: model.useHours),
                               isLast: i == summary.chapters.count - 1,
                               expanded: expandAll || expanded.contains(i),
                               toggle: {
                                   if expanded.contains(i) { expanded.remove(i) } else { expanded.insert(i) }
                               },
                               jump: { model.jump(toTime: chapter.time) })
                }
            }
        }
        .padding(16)
        .background(AICardBackground())
    }
}

private struct ChapterRow: View {
    let chapter: Chapter
    let time: String
    let isLast: Bool
    let expanded: Bool
    let toggle: () -> Void
    let jump: () -> Void
    @State private var hovering = false

    private static let timeWidth: CGFloat = 62

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(time)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Color.textTertiary)
                .frame(width: Self.timeWidth, alignment: .leading)
                .padding(.top, 11)
            Circle()
                .fill(Color.brand)
                .frame(width: 7, height: 7)
                .padding(.top, 15)
            VStack(alignment: .leading, spacing: 4) {
                Button(action: jump) {
                    Text(chapter.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(hovering ? Color.brand : Color.textPrimary)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .help(L("跳到本章节并播放"))
                Text(chapter.summary)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.textSecondary)
                    .lineSpacing(3)
                    .lineLimit(expanded ? nil : 2)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                if hovering || expanded {
                    Button(expanded ? L("收起") : L("展开"), action: toggle)
                        .buttonStyle(TextLinkButtonStyle(size: 12))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.hoverFill : Color.clear))
        }
        .overlay(alignment: .topLeading) {
            if !isLast {
                VerticalLine()
                    .stroke(Color.brand.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(width: 1)
                    .padding(.top, 24)
                    .padding(.bottom, -14)
                    .offset(x: Self.timeWidth + 10 + 3)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
