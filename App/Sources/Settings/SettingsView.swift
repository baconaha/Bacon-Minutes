import SwiftUI
import UniformTypeIdentifiers

/// ⌘, window (§7.1).
struct SettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        TabView {
            ScrollView {
                APISettingsForm(settings: settings, embedded: false)
                    .padding(20)
            }
            .tabItem { Label(L("智能纪要"), systemImage: "sparkles") }

            GeneralSettingsView(settings: settings)
                .tabItem { Label(L("通用"), systemImage: "gearshape") }
        }
        .frame(width: 600, height: 620)
    }
}

private struct GeneralSettingsView: View {
    @Bindable var settings: AppSettings
    @State private var suffixText = ""
    @State private var iconError: String?
    @State private var languageChoice = LanguagePreference.choice

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(L("界面语言"))
                    Spacer()
                    DropdownButton(alignment: .trailing, minWidth: 220, openOnHover: false, items: { languageItems }) { open in
                        SelectField(text: languageLabel, open: open)
                            .frame(width: 220)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text(L("语言"))
            } footer: {
                Text(L("菜单栏和系统对话框中的文字会在重新打开应用后切换。"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section(L("文字记录")) {
                Toggle(L("逐字高亮（按 cue 时长估算当前字）"), isOn: $settings.general.perCharHighlight)
                Toggle(L("拼接中文字幕时在无标点处补「，」"), isOn: $settings.general.insertComma)
            }
            Section(L("播放@@settings")) {
                Toggle(L("跳过空白片段"), isOn: $settings.general.skipBlankEnabled)
                HStack {
                    Text(L("空白片段阈值"))
                    Spacer()
                    TextField("", value: $settings.general.skipBlankThreshold, format: .number.precision(.fractionLength(0...1)))
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                    Text(L("秒"))
                    Stepper("", value: $settings.general.skipBlankThreshold, in: 0.5...30, step: 0.5)
                        .labelsHidden()
                }
            }
            Section {
                TextField(L("文件名后缀"), text: $suffixText, prompt: Text("_FeishuMinutes, _Recording"))
                    .onSubmit { saveSuffixes() }
                HStack {
                    Spacer()
                    Button(L("恢复默认")) {
                        settings.general.filenameSuffixes = FilePairing.defaultSuffixes
                        suffixText = FilePairing.defaultSuffixes.joined(separator: ", ")
                    }
                    Button(L("保存")) { saveSuffixes() }
                }
            } header: {
                Text(L("自动配对"))
            } footer: {
                Text(L("导入时从文件名中去掉开头的 13 位时间戳和这些后缀（逗号分隔），用于默认标题和音视频与 SRT 的自动配对。"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack(spacing: 16) {
                    AppLogo(size: 56)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Button(L("上传图片…")) { chooseIcon() }
                            Button(L("恢复默认")) { AppIconStore.shared.resetToDefault() }
                                .disabled(AppIconStore.shared.customArtwork == nil)
                        }
                        if let iconError {
                            Text(iconError).font(.system(size: 11)).foregroundStyle(Color.errorText)
                        }
                    }
                }
            } header: {
                Text(L("应用图标"))
            } footer: {
                Text(L("同时用于 Dock 和应用内各处的图标。建议上传 1024×1024 的正方形图片，四周透明的部分会被自动裁掉。Dock 图标在应用运行时生效。"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section(L("存储")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("回收站中的妙记会一直保留，直到你手动彻底删除。导入时不会复制媒体文件。"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(L("删除妙记不会删除原始媒体文件。"))
                        .font(.system(size: 12, weight: .bold))
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { suffixText = settings.general.filenameSuffixes.joined(separator: ", ") }
    }

    private var languageLabel: String {
        languageChoice?.nativeName ?? L("跟随系统（{0}）", LanguagePreference.systemLanguage.nativeName)
    }

    private var languageItems: [DropdownItem] {
        var items: [DropdownItem] = [
            .button(L("跟随系统（{0}）", LanguagePreference.systemLanguage.nativeName), selected: languageChoice == nil) {
                setLanguage(nil)
            },
            .divider,
        ]
        for lang in AppLanguage.allCases {
            items.append(.button(lang.nativeName, selected: languageChoice == lang) { setLanguage(lang) })
        }
        return items
    }

    private func setLanguage(_ lang: AppLanguage?) {
        languageChoice = lang
        LanguagePreference.set(lang)
    }

    private func chooseIcon() {
        let panel = NSOpenPanel()
        panel.message = L("选择一张图片作为应用图标")
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .icns]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try AppIconStore.shared.setCustom(from: url)
            iconError = nil
        } catch {
            iconError = error.localizedDescription
        }
    }

    private func saveSuffixes() {
        let list = suffixText.split(whereSeparator: { $0 == "," || $0 == "，" })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        settings.general.filenameSuffixes = list
    }
}

/// Provider / protocol / key / model form, shared by Settings and the summary empty state (§7.1).
struct APISettingsForm: View {
    @Bindable var settings: AppSettings
    var embedded: Bool
    @State private var showKey = false
    @State private var models: [String] = []
    @State private var fetchingModels = false
    @State private var modelMessage: String?
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?
    @State private var showAdvanced = false

    private var presetBinding: Binding<String> {
        Binding(get: { settings.llm.presetID }, set: { id in
            guard let p = ProviderPreset.preset(id: id) else { return }
            var c = settings.llm
            c.apply(preset: p)
            settings.llm = c
            models = []
            modelMessage = nil
            testResult = nil
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !embedded {
                Text(L("智能纪要使用你自己的模型服务生成。API Key 保存在系统钥匙串中。"))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textTertiary)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    label(L("服务商预设"))
                    DropdownButton(minWidth: 260, openOnHover: false, items: {
                        ProviderPreset.all.map { p in
                            DropdownItem.button(p.name, selected: p.id == settings.llm.presetID) { presetBinding.wrappedValue = p.id }
                        }
                    }) { open in
                        SelectField(text: settings.currentPreset?.name ?? L("自定义"), open: open)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 260, alignment: .leading)
                }
                GridRow {
                    label(L("协议"))
                    Picker("", selection: $settings.llm.protocolKind) {
                        ForEach(LLMProtocol.allCases) { p in Text(p.displayName).tag(p) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)
                }
                GridRow {
                    label("Base URL")
                    TextField("https://…", text: $settings.llm.baseURL)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    label("API Key")
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Group {
                                if showKey {
                                    TextField(keyPlaceholder, text: $settings.apiKey)
                                } else {
                                    SecureField(keyPlaceholder, text: $settings.apiKey)
                                }
                            }
                            .textFieldStyle(.roundedBorder)
                            Button { showKey.toggle() } label: {
                                Image(systemName: showKey ? "eye.slash" : "eye")
                            }
                            .buttonStyle(IconButtonStyle(size: 24))
                            .help(showKey ? L("隐藏") : L("显示"))
                        }
                        Text(keyCaption)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.textTertiary)
                    }
                }
                GridRow {
                    label(settings.llm.protocolKind == .azure ? L("部署名") : L("模型"))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            TextField(settings.llm.protocolKind == .azure ? L("Azure 部署名称") : L("模型名称"),
                                      text: $settings.llm.model)
                                .textFieldStyle(.roundedBorder)
                            if !models.isEmpty {
                                DropdownButton(alignment: .trailing, minWidth: 220, openOnHover: false, items: {
                                    models.map { m in
                                        DropdownItem.button(m, selected: m == settings.llm.model) { settings.llm.model = m }
                                    }
                                }) { open in
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(Color.textSecondary)
                                        .frame(width: 26, height: 24)
                                        .background(RoundedRectangle(cornerRadius: 5).fill(open ? Color.searchFill : Color.clear))
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(L("从列表中选择"))
                            }
                            Button(fetchingModels ? L("获取中…") : L("获取模型列表")) { fetchModels() }
                                .disabled(fetchingModels || settings.llm.protocolKind == .azure)
                        }
                        if let modelMessage {
                            Text(modelMessage)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.textTertiary)
                                .textSelection(.enabled)
                        }
                    }
                }
                GridRow {
                    label(L("输出语言"))
                    DropdownButton(minWidth: 220, openOnHover: false, items: {
                        OutputLanguage.allCases.map { l in
                            DropdownItem.button(l.displayName, selected: l == settings.llm.outputLanguage) {
                                settings.llm.outputLanguage = l
                            }
                        }
                    }) { open in
                        SelectField(text: settings.llm.outputLanguage.displayName, open: open)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 220, alignment: .leading)
                }
            }

            DisclosureGroup(L("高级"), isExpanded: $showAdvanced) {
                advanced.padding(.top, 8)
            }
            .font(.system(size: 13))

            HStack(spacing: 10) {
                Button(testing ? L("测试中…") : L("测试连接")) { test() }
                    .disabled(testing || !settings.llm.isConfigured)
                if let r = testResult {
                    Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(r.ok ? Color.green : Color.errorText)
                    Text(r.text)
                        .font(.system(size: 12))
                        .foregroundStyle(r.ok ? Color.textSecondary : Color.errorText)
                        .textSelection(.enabled)
                        .lineLimit(4)
                }
            }
        }
        .font(.system(size: 13))
        .padding(embedded ? 16 : 0)
        .background(embedded ? AnyView(RoundedRectangle(cornerRadius: 8).fill(Color.card).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.divider))) : AnyView(Color.clear))
    }

    private var advanced: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                label("temperature")
                HStack(spacing: 8) {
                    Toggle(L("发送"), isOn: $settings.llm.temperatureEnabled)
                        .toggleStyle(.checkbox)
                    TextField("", value: $settings.llm.temperature, format: .number.precision(.fractionLength(0...2)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .disabled(!settings.llm.temperatureEnabled)
                    if settings.llm.protocolKind == .anthropic {
                        Text(L("当前 Claude 模型不接受 temperature，建议不发送"))
                            .font(.system(size: 11))
                            .foregroundStyle(Color.textTertiary)
                    }
                }
            }
            GridRow {
                label(L("最大输出 tokens"))
                TextField("", value: $settings.llm.maxOutputTokens, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
            }
            GridRow {
                label(L("超时（秒）"))
                TextField("", value: $settings.llm.timeout, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
            }
            GridRow {
                label(L("单次最大输入字数"))
                TextField("", value: $settings.llm.maxInputChars, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
            }
            if settings.llm.protocolKind == .azure {
                GridRow {
                    label("api-version")
                    TextField("2024-10-21", text: $settings.llm.azureAPIVersion)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }
            }
            if settings.llm.protocolKind == .anthropic {
                GridRow {
                    label("anthropic-version")
                    TextField("2023-06-01", text: $settings.llm.anthropicVersion)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }
            }
            GridRow(alignment: .top) {
                label(L("自定义 Header"))
                VStack(alignment: .leading, spacing: 6) {
                    ForEach($settings.llm.customHeaders) { $h in
                        HStack(spacing: 6) {
                            TextField(L("名称"), text: $h.key).textFieldStyle(.roundedBorder).frame(width: 150)
                            TextField(L("值"), text: $h.value).textFieldStyle(.roundedBorder)
                            Button {
                                settings.llm.customHeaders.removeAll { $0.id == h.id }
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                        }
                    }
                    Button {
                        settings.llm.customHeaders.append(HeaderPair(key: "", value: ""))
                    } label: {
                        Label(L("添加 Header"), systemImage: "plus")
                    }
                    .buttonStyle(TextLinkButtonStyle(size: 12))
                    HStack {
                        Button(L("重置参数兼容记录")) {
                            settings.compatStore.reset()
                            testResult = (true, L("已清除，下次请求将重新尝试全部参数"))
                        }
                        .buttonStyle(TextLinkButtonStyle(size: 12))
                        .help(L("遇到 HTTP 400 时自动去掉的参数会按服务记住，这里可以清除"))
                    }
                }
            }
        }
    }

    private func label(_ s: String) -> some View {
        Text(s)
            .foregroundStyle(Color.textSecondary)
            .gridColumnAlignment(.trailing)
    }

    private var keyPlaceholder: String {
        (settings.currentPreset?.isLocal ?? false) ? L("本地服务可留空") : "sk-…"
    }

    private var keyCaption: String {
        let k = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.isEmpty {
            return (settings.currentPreset?.isLocal ?? false) ? L("本地服务通常不需要 Key") : L("尚未填写")
        }
        return L("已保存到钥匙串 · 末 4 位 {0}", String(k.suffix(4)))
    }

    private func fetchModels() {
        fetchingModels = true
        modelMessage = nil
        let config = settings.llm
        let key = settings.apiKey
        let client = LLMClient(compat: settings.compatStore)
        Task {
            defer { fetchingModels = false }
            do {
                let list = try await client.listModels(config: config, apiKey: key)
                models = list
                modelMessage = list.isEmpty ? L("服务端没有返回模型，请手动填写") : L("获取到 {0} 个模型，点击 ⌄ 选择", list.count)
            } catch {
                models = []
                modelMessage = L("获取失败（可手动填写）：{0}", error.localizedDescription)
            }
        }
    }

    private func test() {
        testing = true
        testResult = nil
        let config = settings.llm
        let key = settings.apiKey
        let client = LLMClient(compat: settings.compatStore)
        Task {
            defer { testing = false }
            do {
                let seconds = try await client.testConnection(config: config, apiKey: key)
                testResult = (true, L("连接成功 · {0} ms", Int(seconds * 1000)))
            } catch {
                testResult = (false, error.localizedDescription)
            }
        }
    }
}

/// Text-field-looking trigger for a dropdown (provider preset).
struct SelectField: View {
    let text: String
    let open: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.textTertiary)
                .rotationEffect(.degrees(open ? 180 : 0))
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.card))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(open ? Color.brand : Color.divider))
        .contentShape(Rectangle())
    }
}
