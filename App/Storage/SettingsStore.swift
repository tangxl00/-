//
//  SettingsStore.swift
//  TingDu
//
//  阅读设置持久化（UserDefaults + JSON），以及一次性免责声明标记。
//  iOS 专属层，未编译（沙箱无 Xcode）。
//

import Foundation
import SwiftUI
import ReaderCore

/// 阅读设置存储：ReadingSettings 是纯值类型 Codable，直接 JSON 化存 UserDefaults。
@MainActor
final class SettingsStore: ObservableObject {
    static let settingsKey = "td.readingSettings.v1"
    static let disclaimerKey = "td.disclaimerAccepted.v1"

    @Published var settings: ReadingSettings {
        didSet { persist() }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.settingsKey),
           let loaded = try? JSONDecoder().decode(ReadingSettings.self, from: data) {
            self.settings = loaded
        } else {
            self.settings = .default
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings.clamped()) {
            defaults.set(data, forKey: Self.settingsKey)
        }
    }

    // MARK: - 免责声明（一次性）

    static var disclaimerAccepted: Bool {
        UserDefaults.standard.bool(forKey: disclaimerKey)
    }

    static func acceptDisclaimer() {
        UserDefaults.standard.set(true, forKey: disclaimerKey)
    }
}
