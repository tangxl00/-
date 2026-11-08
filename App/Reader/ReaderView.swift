//
//  ReaderView.swift
//  TingDu
//
//  阅读页 UI：点击翻页（左 1/3 上一页 / 右 1/3 下一页 / 中间唤出工具栏），
//  设置面板（字号/行距/边距/字体/主题），进度自动保存。
//  iOS 专属层，未编译（沙箱无 Xcode）。
//

import SwiftUI
import SwiftData
import ReaderCore

struct ReaderView: View {
    @StateObject private var model: ReaderViewModel
    @EnvironmentObject private var settingsStore: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var toolbarVisible = false
    @State private var settingsVisible = false

    init(book: BookRecord, services: AppServices, settingsStore: SettingsStore) {
        _model = StateObject(wrappedValue: ReaderViewModel(book: book, services: services, settingsStore: settingsStore))
    }

    var body: some View {
        GeometryReader { geo in
            let theme = settingsStore.settings.theme
            ZStack {
                Color(hex: theme.backgroundHex).ignoresSafeArea()

                switch model.loadState {
                case .idle, .loading:
                    ProgressView("正在加载…")
                case .failed(let message):
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle").font(.title)
                        Text(message)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Color(hex: theme.secondaryTextHex))
                        Button("返回") { dismiss() }
                    }
                    .padding()
                case .loaded:
                    pageContent(theme: theme, geo: geo)
                }

                if toolbarVisible { toolbarOverlay(theme: theme) }
                if settingsVisible { settingsPanel(theme: theme) }
            }
            .onAppear {
                model.viewportWidth = geo.size.width
                model.viewportHeight = geo.size.height
                Task { await model.open() }
            }
            .onChange(of: geo.size) { _, new in
                model.viewportWidth = new.width
                model.viewportHeight = new.height
                model.settingsDidChange()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { model.flush() }
            }
            .onDisappear { model.flush() }
        }
        .navigationBarHidden(true)
    }

    // MARK: - 正文页

    private func pageContent(theme: ReaderTheme, geo: GeometryProxy) -> some View {
        let margin = settingsStore.settings.horizontalMargin
        return ZStack {
            CoreTextPageView(lines: model.renderLines, settings: settingsStore.settings, theme: theme)
                .padding(.horizontal, margin)
                .padding(.vertical, settingsStore.settings.fontSize * settingsStore.settings.lineSpacing * ReadingSettings.verticalMarginRatio)
                .allowsHitTesting(false)

            // 翻页热区
            HStack(spacing: 0) {
                tapZone(width: geo.size.width / 3) { model.previousPage() }
                tapZone(width: geo.size.width / 3) {
                    withAnimation { toolbarVisible.toggle(); settingsVisible = false }
                }
                tapZone(width: geo.size.width / 3) { model.nextPage() }
            }
        }
    }

    private func tapZone(width: CGFloat, action: @escaping () -> Void) -> some View {
        Color.clear
            .frame(width: width)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }

    // MARK: - 工具栏

    private func toolbarOverlay(theme: ReaderTheme) -> some View {
        VStack {
            HStack {
                Button { dismiss() } label: { Image(systemName: "chevron.left") }
                Spacer()
                Text(model.chapterTitle).font(.subheadline).lineLimit(1)
                Spacer()
                Text("\(model.currentChapterIndex + 1)/\(model.chapters.count)")
                    .font(.caption).foregroundStyle(Color(hex: theme.secondaryTextHex))
            }
            .padding()
            .background(.ultraThinMaterial)

            Spacer()

            HStack(spacing: 28) {
                Button("上一章") { model.previousChapter() }
                Button("目录") { toolbarVisible = false; settingsVisible = false }
                Button("设置") { withAnimation { settingsVisible.toggle() } }
                Button("下一章") { model.nextChapter() }
            }
            .padding()
            .background(.ultraThinMaterial)
        }
        .foregroundStyle(Color(hex: theme.textHex))
    }

    // MARK: - 设置面板

    private func settingsPanel(theme: ReaderTheme) -> some View {
        VStack(spacing: 18) {
            sliderRow("字号 \(Int(settingsStore.settings.fontSize))pt)",
                      value: Binding(
                        get: { settingsStore.settings.fontSize },
                        set: { settingsStore.settings.fontSize = $0; model.settingsDidChange() }),
                      range: ReadingSettings.fontSizeRange)
            sliderRow("行距 \(String(format: "%.1f", settingsStore.settings.lineSpacing))",
                      value: Binding(
                        get: { settingsStore.settings.lineSpacing },
                        set: { settingsStore.settings.lineSpacing = $0; model.settingsDidChange() }),
                      range: ReadingSettings.lineSpacingRange)
            sliderRow("段距 \(Int(settingsStore.settings.paragraphSpacing))",
                      value: Binding(
                        get: { settingsStore.settings.paragraphSpacing },
                        set: { settingsStore.settings.paragraphSpacing = $0; model.settingsDidChange() }),
                      range: ReadingSettings.paragraphSpacingRange)
            sliderRow("边距 \(Int(settingsStore.settings.horizontalMargin))",
                      value: Binding(
                        get: { settingsStore.settings.horizontalMargin },
                        set: { settingsStore.settings.horizontalMargin = $0; model.settingsDidChange() }),
                      range: ReadingSettings.horizontalMarginRange)

            HStack {
                ForEach(ReaderTheme.allCases, id: \.self) { t in
                    Button(t.displayName) {
                        settingsStore.settings.theme = t
                        model.settingsDidChange()
                    }
                    .buttonStyle(.bordered)
                    .tint(t == settingsStore.settings.theme ? .accentColor : Color(hex: theme.secondaryTextHex))
                }
            }

            HStack {
                ForEach(ReaderFont.allCases, id: \.self) { f in
                    Button(f.displayName) {
                        settingsStore.settings.font = f
                        model.settingsDidChange()
                    }
                    .buttonStyle(.bordered)
                    .tint(f == settingsStore.settings.font ? .accentColor : Color(hex: theme.secondaryTextHex))
                }
            }

            Text("第 \(model.currentPageIndex + 1) / \(model.pageCount) 页 · 已读 \(Int(model.overallFraction * 100))%")
                .font(.caption)
                .foregroundStyle(Color(hex: theme.secondaryTextHex))
        }
        .padding()
        .background(.ultraThinMaterial)
        .foregroundStyle(Color(hex: theme.textHex))
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.footnote)
            Slider(value: value, in: range)
        }
    }
}

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        let cleaned = hex.replacingOccurrences(of: "#", with: "")
        Scanner(string: cleaned).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }
}
