//
//  MainViews.swift
//  TingDu
//
//  根视图（免责声明门 + TabView）与书架页。
//  iOS 专属层，未编译（沙箱无 Xcode）。
//

import SwiftUI
import SwiftData
import ReaderCore

// MARK: - 根视图

struct RootView: View {
    @EnvironmentObject private var services: AppServices
    @State private var disclaimerAccepted = SettingsStore.disclaimerAccepted

    var body: some View {
        if disclaimerAccepted {
            mainTabs
        } else {
            DisclaimerView(onAccept: {
                SettingsStore.acceptDisclaimer()
                disclaimerAccepted = true
            })
        }
    }

    private var mainTabs: some View {
        TabView {
            BookshelfView()
                .tabItem { Label("书架", systemImage: "books.vertical") }
            SearchView()
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
            SourceManageView()
                .tabItem { Label("书源", systemImage: "shippingbox") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
    }
}

// MARK: - 一次性免责声明（合规要求）

struct DisclaimerView: View {
    var onAccept: () -> Void
    @State private var scrolled = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "book").font(.system(size: 44))
            Text("欢迎使用 听读").font(.title2.bold())

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("使用前请阅读并同意以下条款：").bold()
                    bullet("本应用不内置任何书源、不提供任何内容；全部内容来自你自行导入的书源与本地文件。")
                    bullet("请仅导入你有权访问的内容源；通过书源获取的内容的版权责任由书源提供方与使用者承担。")
                    bullet("本应用不提供任何付费内容解锁、去广告或版权规避功能。")
                    bullet("部分书源使用了 JavaScript 规则（本版本不支持），导入时会明确标注，不会静默降级。")
                    bullet("阅读进度、书源与设置仅保存在本机；清除应用数据会全部丢失。")
                }
                .font(.subheadline)
            }
            .frame(maxHeight: 320)

            Button("同意并继续") { onAccept() }
                .buttonStyle(.borderedProminent)
                .disabled(!scrolled)

            Button("不同意，退出") { exit(0) }
                .font(.footnote)
        }
        .padding()
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("·"); Text(text)
        }
    }
}

// MARK: - 书架（P0-6）

struct BookshelfView: View {
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var settingsStore: SettingsStore
    @Query(sort: \BookRecord.lastReadAt, order: .reverse) private var books: [BookRecord]
    @State private var importTXTPresented = false

    var body: some View {
        NavigationStack {
            Group {
                if books.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(books) { book in
                            NavigationLink(value: book) {
                                BookshelfRow(book: book)
                            }
                        }
                        .onDelete(perform: deleteBooks)
                    }
                }
            }
            .navigationTitle("书架")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        importTXTPresented = true
                    } label: { Label("导入 TXT", systemImage: "plus") }
                }
            }
            .navigationDestination(for: BookRecord.self) { book in
                if book.isLocal {
                    ReaderContainerView(book: book)
                } else {
                    BookDetailView(book: book)
                }
            }
            .sheet(isPresented: $importTXTPresented) {
                LocalImportView()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "books.vertical").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("书架还是空的").font(.headline)
            Text("去「搜索」找书加入书架，或点右上角导入本地 TXT")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func deleteBooks(at offsets: IndexSet) {
        let context = services.container.mainContext
        for index in offsets {
            let book = books[index]
            SwiftDataProgressStore(container: services.container).remove(bookKey: book.bookKey)
            context.delete(book)
        }
        try? context.save()
    }
}

struct BookshelfRow: View {
    let book: BookRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(book.name).font(.headline)
                if book.isLocal {
                    Text("本地").font(.caption2).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.quaternary, in: .capsule)
                } else {
                    Text(book.originName).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(book.author.isEmpty ? "佚名" : book.author).font(.subheadline).foregroundStyle(.secondary)
            if !book.lastChapterTitle.isEmpty {
                Text("读到：\(book.lastChapterTitle)").font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

/// 本地书直接进阅读器；在线书先进详情页
struct ReaderContainerView: View {
    let book: BookRecord
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var settingsStore: SettingsStore

    var body: some View {
        ReaderView(book: book, services: services, settingsStore: settingsStore)
    }
}
