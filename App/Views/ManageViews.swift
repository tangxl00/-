//
//  ManageViews.swift
//  TingDu
//
//  书源管理（P0-1 导入入口）、应用设置、本地 TXT 导入（P0-7）。
//  iOS 专属层，未编译（沙箱无 Xcode）。
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import ReaderCore

// MARK: - 书源管理

struct SourceManageView: View {
    @EnvironmentObject private var services: AppServices
    @Query(sort: \SourceRecord.sortOrder) private var records: [SourceRecord]
    @State private var importText = ""
    @State private var importURL = ""
    @State private var importing = false
    @State private var report: ImportReport?
    @State private var showImportSheet = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showImportSheet = true
                    } label: {
                        Label("导入书源（粘贴 JSON 或填 URL）", systemImage: "square.and.arrow.down")
                    }
                } footer: {
                    Text("本应用不内置任何书源。书源格式兼容 legado（BookSource JSON）。使用 JavaScript 规则的源会明确标注为「本版本不支持」，不会静默降级。")
                }

                Section("已导入（\(records.count)）") {
                    if records.isEmpty {
                        Text("暂无书源").foregroundStyle(.secondary)
                    }
                    ForEach(records) { record in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.name).font(.subheadline)
                                Text(record.url).font(.caption2).foregroundStyle(.tertiary)
                                    .lineLimit(1).truncationMode(.middle)
                                if let source = record.bookSource {
                                    let scan = JSStaticScanner.scan(source)
                                    if scan.usesWebJS {
                                        Label("依赖 WebView 注入，本版不支持", systemImage: "exclamationmark.triangle")
                                            .font(.caption2).foregroundStyle(.orange)
                                    } else if scan.usesJS {
                                        Label(scan.missingMethods.isEmpty
                                              ? "含 JS 规则（本版可执行）"
                                              : "含 JS 规则，缺 java.\(scan.missingMethods.joined(separator: "、java."))",
                                              systemImage: "exclamationmark.triangle")
                                            .font(.caption2).foregroundStyle(.orange)
                                    }
                                }
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { record.enabled },
                                set: { services.setSourceEnabled(url: record.url, enabled: $0) }
                            ))
                            .labelsHidden()
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                services.deleteSource(url: record.url)
                            } label: { Label("删除", systemImage: "trash") }
                        }
                    }
                }

                if let report {
                    Section("导入结果") {
                        Text(report.headline).font(.subheadline)
                        ForEach(report.problemItems.prefix(12)) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.sourceName ?? "未命名源").font(.footnote)
                                Text(item.reason ?? "").font(.caption2).foregroundStyle(.orange)
                            }
                        }
                        if report.problemItems.count > 12 {
                            Text("…另有 \(report.problemItems.count - 12) 条详见报告").font(.caption2)
                        }
                    }
                }
            }
            .navigationTitle("书源")
            .sheet(isPresented: $showImportSheet) { importSheet }
        }
    }

    private var importSheet: some View {
        NavigationStack {
            Form {
                Section("粘贴书源 JSON") {
                    TextEditor(text: $importText)
                        .frame(minHeight: 160)
                        .font(.system(.caption, design: .monospaced))
                }
                Section("或从 URL 导入") {
                    TextField("https://…", text: $importURL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    Button("拉取并导入") {
                        Task { await importFromURL() }
                    }
                    .disabled(importURL.trimmingCharacters(in: .whitespaces).isEmpty || importing)
                }
            }
            .navigationTitle("导入书源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showImportSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") { importPasted() }
                        .disabled(importText.trimmingCharacters(in: .whitespaces).isEmpty || importing)
                }
            }
        }
    }

    private func importPasted() {
        importing = true
        report = services.importSources(text: importText)
        importing = false
        if report?.usableCount ?? 0 > 0 {
            importText = ""
        }
    }

    private func importFromURL() async {
        importing = true
        defer { importing = false }
        do {
            report = try await services.importSourcesFromURL(importURL.trimmingCharacters(in: .whitespaces))
            if report?.usableCount ?? 0 > 0 { importURL = "" }
        } catch {
            report = ImportReport(items: [], successCount: 0, failureCount: 1,
                                  duplicateCount: 0, jsDegradedCount: 0, unsupportedTypeCount: 0)
        }
    }
}

// MARK: - 应用设置

struct SettingsView: View {
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var settingsStore: SettingsStore
    @Query private var books: [BookRecord]

    var body: some View {
        NavigationStack {
            List {
                Section("阅读设置") {
                    Stepper("字号 \(Int(settingsStore.settings.fontSize)) pt",
                            value: Binding(
                                get: { settingsStore.settings.fontSize },
                                set: { settingsStore.settings.fontSize = $0 }),
                            in: ReadingSettings.fontSizeRange, step: 1)
                    Picker("字体", selection: Binding(
                        get: { settingsStore.settings.font },
                        set: { settingsStore.settings.font = $0 })) {
                        ForEach(ReaderFont.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Picker("主题", selection: Binding(
                        get: { settingsStore.settings.theme },
                        set: { settingsStore.settings.theme = $0 })) {
                        ForEach(ReaderTheme.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                }
                Section("净化与替换") {
                    NavigationLink("替换规则") { ReplaceRulesView() }
                }
                Section("数据") {
                    LabeledContent("书源", value: "\(services.sourceCount) 个（启用 \(services.enabledSourceCount)）")
                    LabeledContent("书架", value: "\(books.count) 本")
                }
                Section {
                    Text("本应用不内置任何书源、不提供任何内容；内容获取行为完全由你导入的书源决定。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
        }
    }
}

// MARK: - 本地 TXT 导入（P0-7）

struct LocalImportView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var fileURL: URL?
    @State private var result: TXTImportResult?
    @State private var errorText: String?
    @State private var importing = false

    var body: some View {
        NavigationStack {
            Form {
                Section("选择 TXT 文件") {
                    Button {
                        pickFile()
                    } label: {
                        Label(fileURL?.lastPathComponent ?? "点击选择文件", systemImage: "doc.text")
                    }
                }
                if let result {
                    Section("识别结果") {
                        LabeledContent("书名", value: result.bookName)
                        LabeledContent("编码", value: result.encoding.displayName)
                        LabeledContent("分章规则", value: TXTChapterRules.rule(id: result.ruleID)?.displayName ?? result.ruleID)
                        LabeledContent("章节数", value: "\(result.chapterCount)")
                        ForEach(result.notes, id: \.self) { note in
                            Text(note).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Section {
                        Button("导入到书架") { addToShelf() }
                            .disabled(importing)
                    }
                }
                if let errorText {
                    Section { Text(errorText).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle("导入 TXT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
            .fileImporter(isPresented: $presentingPicker,
                          allowedContentTypes: [.plainText, .text],
                          allowsMultipleSelection: false) { outcome in
                switch outcome {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    importFile(url)
                case .failure(let error):
                    errorText = "选择文件失败：\(error.localizedDescription)"
                }
            }
        }
    }

    @State private var presentingPicker = false
    @State private var decodedText: String?

    private func pickFile() {
        presentingPicker = true
    }

    private func importFile(_ url: URL) {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let bookName = url.deletingPathExtension().lastPathComponent
            fileURL = url
            result = try TXTImporter.import(data: data, bookName: bookName)
            // 统一转成 UTF-8 存书架（GBK/GB18030 文件已由 TextDecoder 解码）
            decodedText = (try? TextDecoder.decode(data, as: result?.encoding ?? .utf8))
                ?? String(data: data, encoding: .utf8)
            errorText = nil
        } catch {
            self.errorText = "导入失败：\(error)"
        }
    }

    private func addToShelf() {
        guard let result, let text = decodedText else { return }
        importing = true
        defer { importing = false }
        let context = services.container.mainContext
        let record = BookRecord(
            bookKey: "local:" + UUID().uuidString,
            name: result.bookName,
            author: "",
            isLocal: true,
            localText: text.data(using: .utf8),
            localRuleID: result.ruleID,
            chapterCount: result.chapterCount
        )
        context.insert(record)
        try? context.save()
        dismiss()
    }
}


// MARK: - 替换/净化规则管理（P0#2，v1.2.0：增删改 / 排序 / 启停）

/// 规则列表：点击进编辑、开关启停、左滑删除、拖动（或 EditButton）排序。
/// 首次启动由 AppServices.installDefaultReplaceRulesIfNeeded() 灌入 8 条默认水印规则。
struct ReplaceRulesView: View {
    @EnvironmentObject private var services: AppServices
    @State private var rules: [ReplaceRule] = []
    @State private var editingRule: ReplaceRule?
    @State private var showNewRule = false

    var body: some View {
        List {
            if rules.isEmpty {
                Text("暂无规则")
                    .foregroundStyle(.secondary)
            }
            ForEach(rules) { rule in
                Button {
                    editingRule = rule
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(rule.name.isEmpty ? "（未命名）" : rule.name)
                                .font(.body)
                                .foregroundStyle(.primary)
                            Text(rule.isRegex ? "正则：\(rule.pattern)" : "字面量：\(rule.pattern)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { rule.enable },
                            set: {
                                services.setReplaceRuleEnabled(id: rule.id, enabled: $0)
                                reload()
                            }))
                            .labelsHidden()
                    }
                }
            }
            .onDelete(perform: delete)
            .onMove(perform: move)
        }
        .navigationTitle("替换规则（\(rules.count)）")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) { EditButton() }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showNewRule = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(item: $editingRule) { rule in
            ReplaceRuleEditView(rule: rule) { updated in
                services.saveReplaceRule(updated)
                reload()
            }
        }
        .sheet(isPresented: $showNewRule) {
            ReplaceRuleEditView(rule: ReplaceRule()) { new in
                services.saveReplaceRule(new)
                reload()
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        rules = services.replaceRules()
    }

    private func delete(at offsets: IndexSet) {
        let ids = offsets.map { rules[$0].id }
        for id in ids { services.deleteReplaceRule(id: id) }
        reload()
    }

    private func move(from source: IndexSet, to destination: Int) {
        var arr = rules
        arr.move(fromOffsets: source, toOffset: destination)
        services.reorderReplaceRules(ids: arr.map(\.id))
        reload()
    }
}

/// 规则编辑：13 字段中的 11 个可编辑（id / sortOrder 由系统管理）。
struct ReplaceRuleEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ReplaceRule
    let onSave: (ReplaceRule) -> Void

    init(rule: ReplaceRule, onSave: @escaping (ReplaceRule) -> Void) {
        _draft = State(initialValue: rule)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("名称", text: $draft.name)
                    Toggle("正则模式（关闭 = 字面量替换）", isOn: $draft.isRegex)
                    Toggle("启用", isOn: $draft.enable)
                }
                Section("匹配与替换") {
                    TextField("匹配（pattern）", text: $draft.pattern, axis: .vertical)
                        .lineLimit(2...4)
                    TextField("替换为（留空 = 删除匹配）", text: $draft.replacement, axis: .vertical)
                        .lineLimit(2...4)
                }
                Section("作用范围") {
                    Toggle("作用于章节标题", isOn: $draft.scopeTitle)
                    Toggle("作用于正文", isOn: $draft.scopeContent)
                    TextField("限定书名（正则，逗号分隔，空 = 全部书）", text: $draft.scope)
                    TextField("排除书名（正则，逗号分隔）", text: $draft.excludeScope)
                }
                Section("高级") {
                    Stepper("超时 \(draft.timeoutMillisecond) ms", value: $draft.timeoutMillisecond, in: 500...10000, step: 500)
                }
            }
            .navigationTitle(draft.name.isEmpty ? "新建规则" : "编辑规则")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(draft)
                        dismiss()
                    }
                    .disabled(draft.pattern.isEmpty)
                }
            }
        }
    }
}
