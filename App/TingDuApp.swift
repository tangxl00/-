//
//  TingDuApp.swift
//  听读（TingDu）iOS v1 P0
//
//  入口：SwiftData 容器 + 服务注入 + 免责声明门。
//  iOS 专属层，未编译（沙箱无 Xcode）。
//

import SwiftUI
import SwiftData
import ReaderCore

@main
struct TingDuApp: App {
    let container: ModelContainer
    @StateObject private var services: AppServices
    @StateObject private var settingsStore = SettingsStore()

    init() {
        do {
            container = try ModelContainer(
                for: SourceRecord.self, BookRecord.self, ProgressRecord.self, ReplaceRuleRecord.self
            )
        } catch {
            // 容器创建失败（存储损坏等）：使用内存容器兜底，避免直接崩溃
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            container = try! ModelContainer(
                for: SourceRecord.self, BookRecord.self, ProgressRecord.self, ReplaceRuleRecord.self,
                configurations: config
            )
        }
        // StateObject(wrappedValue:) 是逃逸 autoclosure，直接引用存储属性会捕获
        // mutating self（struct init 内不合法）——先拷贝到局部变量再传入。
        let modelContainer = container
        _services = StateObject(wrappedValue: AppServices(container: modelContainer))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(services)
                .environmentObject(settingsStore)
                .modelContainer(container)
        }
    }
}
