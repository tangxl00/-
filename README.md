# 听读（TingDu）iOS v1 · P0 MVP

iOS 17+ / SwiftUI / SwiftData 的本地阅读器。**不内置任何书源、不提供任何内容**；
内容完全来自用户自行导入的 legado 兼容书源（BookSource JSON）与本地 TXT 文件。

## 目录结构

```
TingDu/
├── App/                     # iOS App 层（SwiftUI 视图 + SwiftData 存储 + CoreText 渲染）
│   ├── TingDuApp.swift      # 入口：ModelContainer + 服务注入 + 免责声明门
│   ├── Storage/             # SwiftData 模型（SourceRecord/BookRecord/ProgressRecord）+ 服务容器 + 设置存储
│   ├── Views/               # 书架 / 搜索 / 详情目录 / 书源管理 / 设置 / TXT 导入 / 免责声明
│   └── Reader/              # 阅读器：ReaderViewModel + CoreText 度量与渲染
├── Packages/
│   └── ReaderCore/          # 跨平台核心包（Linux 可测）：规则引擎 / 搜索 / 合并 / 进度 / 分页 / TXT / HTTP
│       ├── Sources/ReaderCore/
│       │   ├── Engine/      # RuleEvaluator / URLTemplate / JSONPath / EvalContext / JSStaticScanner
│       │   ├── Domain/      # 搜索服务 / 详情服务 / 书源导入 / 四桶合并 / 进度 / 分页 / 设置
│       │   ├── Model/       # BookSource（legado 兼容解码）/ JsonValue / 规则模型
│       │   ├── Platform/    # HTTPClient（限速+重试）/ 文本解码（GBK 表）/ TXTImporter
│       │   ├── Selectors/   # CSS / XPath 风格选择器（非 JS）
│       │   ├── Core/        # 工具
│       │   └── Resources/   # gbk-table.bin（GBK→Unicode 二进制映射表）
│       └── Tests/           # 235 个 XCTest 用例（Linux swift test 全绿）
├── project.yml              # XcodeGen 工程定义
└── .github/workflows/ios.yml  # CI：Linux 单测 + macOS iOS 编译
```

## 本地构建

```bash
brew install xcodegen
xcodegen generate
open TingDu.xcodeproj      # 选 TingDu scheme，iOS Simulator 运行
```

## 核心层自测（Linux，无需 macOS）

```bash
cd Packages/ReaderCore
swift test                 # 235 tests, 0 failures
```

覆盖：规则引擎语义（@css/@@/@XPath/@Json/##正则##/{{}}/@put/@get/$1 反填/0 基索引/
`-` 倒序/Jsoup text() 语义）、URL 模板与选项 JSON 解析（js 字段→jsUnsupported 显式报错）、
JSONPath、四桶合并排序、TXT 分章（标准/宽松/兜底 8000 字）、GBK 解码与乱码探测、
字符偏移进度（切章即存/1s 节流/越界钳制/百分比）、分页（连续性/覆盖/换字号重排）。

## P0 边界（有意不做）

- **不执行 JavaScript**：书源规则中出现 `@js:`、`<js>`、选项 `js`/`webJs`/`webView` 等字段
  → 静态扫描标记 + 运行时抛 `jsUnsupported`，**绝不静默返回空串**。
- 无发现页、无换源、无缓存章节、无 WebDAV、无正文净化规则、无朗读（TTS）——均为 P1+。
- 详情页点章节进入阅读器时按已存进度恢复（P0 不做定向跳章）。

## 合规

- 不内置书源；一次性免责声明（不同意则退出）。
- 不提供任何付费内容解锁 / 去广告 / 版权规避能力。
- 核心层规则语义自行实现，未复制 legado（GPLv3）代码；GBK 映射表由 Unicode 映射数据生成。

## 已知限制

- App 层（SwiftUI/SwiftData/CoreText）在无 Xcode 的环境交付，**未编译验证**——以 CI
  （`.github/workflows/ios.yml` 的 ios-build job）作为编译门禁。
- 大 TXT（>20MB）整文存 SwiftData 可能性能不佳，P1 改文件存储。
- 阅读器目录跳转、阅读时长统计等未包含在 P0。
