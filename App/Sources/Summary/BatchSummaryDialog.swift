import SwiftUI

/// "生成纪要" for the minutes selected in the list: picks a model, then queues them all.
struct BatchSummaryDialog: View {
    let app: AppModel
    let ids: [UUID]
    @State private var closing = false
    @State private var confirmed = false
    @State private var includeExisting = false
    @State private var modelID: String?

    private var minutes: [Minute] { ids.compactMap { app.library.minute($0) }.filter { $0.deletedAt == nil } }
    private var noTranscript: Int { minutes.filter { !$0.hasTranscript }.count }
    private var busy: Int { minutes.filter { $0.hasTranscript && app.summaryJobs[$0.id]?.isActive == true }.count }
    private var existing: Int {
        minutes.filter { $0.hasTranscript && $0.hasSummary && app.summaryJobs[$0.id]?.isActive != true }.count
    }

    private var eligible: Int {
        minutes.filter { m in
            m.hasTranscript && app.summaryJobs[m.id]?.isActive != true && (includeExisting || !m.hasSummary)
        }.count
    }

    private var hasModel: Bool { app.settings.isLLMReady || !app.settings.favorites.isEmpty }

    private var favorite: FavoriteModel? {
        guard let id = modelID else { return nil }
        return app.settings.favorites.first { $0.id == id }
    }

    /// The default model cannot run without an endpoint; pick a starred one then.
    private var modelUsable: Bool { favorite != nil || app.settings.isLLMReady }

    var body: some View {
        FlipDialog(width: 460, onClosed: finish, closeRequest: $closing) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.aiCardTop)
                            .frame(width: 40, height: 40)
                        Image(systemName: "sparkles")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Color.aiPurple)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("为 {0} 个妙记生成智能纪要", minutes.count))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(L("在后台逐个生成，同时最多 {0} 个。期间可以照常使用，关闭窗口也会继续。", AppModel.batchConcurrency))
                            .font(.system(size: 13))
                            .foregroundStyle(Color.textSecondary)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    if noTranscript > 0 {
                        note(icon: "captions.bubble", text: L("其中 {0} 个还没有字幕，会跳过", noTranscript))
                    }
                    if busy > 0 {
                        note(icon: "hourglass", text: L("其中 {0} 个已经在生成或排队，会跳过", busy))
                    }
                    if existing > 0 {
                        Button {
                            includeExisting.toggle()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: includeExisting ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 15))
                                    .foregroundStyle(includeExisting ? Color.brand : Color.textTertiary)
                                Text(L("已有纪要的 {0} 个也再生成一份（原有版本会保留）", existing))
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if hasModel {
                        HStack(spacing: 8) {
                            Text(L("使用模型"))
                                .font(.system(size: 13))
                                .foregroundStyle(Color.textSecondary)
                            ModelChoiceButton(settings: app.settings, selection: $modelID)
                        }
                        .padding(.top, 2)
                    } else {
                        HStack(spacing: 10) {
                            Text(L("还没有设置模型。"))
                                .font(.system(size: 13))
                                .foregroundStyle(Color.warningText)
                            OpenSettingsButton()
                        }
                    }
                }
                .padding(.top, 18)
                .padding(.leading, 54)

                HStack(spacing: 12) {
                    Spacer()
                    Button(L("取消")) { closing = true }
                        .buttonStyle(DialogCancelButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    Button(eligible == 1 ? L("开始生成") : L("生成 {0} 个", eligible)) {
                        confirmed = true
                        closing = true
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(eligible == 0 || !modelUsable)
                }
                .padding(.top, 26)
            }
            .padding(EdgeInsets(top: 26, leading: 26, bottom: 22, trailing: 26))
        }
        .onAppear {
            // Without a default endpoint, start from the first starred model.
            if !app.settings.isLLMReady { modelID = app.settings.favorites.first?.id }
        }
    }

    private func note(icon: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Color.textTertiary)
            Text(text).font(.system(size: 13)).foregroundStyle(Color.textSecondary)
        }
    }

    private func finish() {
        app.batchSummaryTarget = nil
        guard confirmed else { return }
        let n = app.queueSummaries(ids, favorite: favorite, includeExisting: includeExisting)
        app.selection = []
        if n > 0 { app.showToast(L("已开始为 {0} 个妙记生成纪要", n)) }
    }
}
