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
