//
//  CoreTextPageView.swift
//  TingDu
//
//  阅读页渲染：UIViewRepresentable 包一个 CoreText 绘制视图。
//  输入是 CoreTextMeasurer.renderLines 产出的行（与分页共用），
//  因此渲染文本与分页文本严格一致。
//  iOS 专属层，未编译（沙箱无 Xcode）。
//

import SwiftUI
import UIKit
import CoreText
import ReaderCore

struct CoreTextPageView: UIViewRepresentable {
    let lines: [RenderLine]
    let settings: ReadingSettings
    let theme: ReaderTheme

    func makeUIView(context: Context) -> CoreTextPageUIView {
        CoreTextPageUIView()
    }

    func updateUIView(_ view: CoreTextPageUIView, context: Context) {
        view.render(lines: lines, settings: settings, theme: theme)
    }
}

final class CoreTextPageUIView: UIView {
    private var lines: [RenderLine] = []
    private var font: UIFont = .systemFont(ofSize: 17)
    private var textColor: UIColor = .black
    private var indent: CGFloat = 0

    func render(lines: [RenderLine], settings: ReadingSettings, theme: ReaderTheme) {
        self.lines = lines
        self.font = CoreTextMeasurer.font(for: settings)
        self.textColor = UIColor(hex: theme.textHex)
        self.indent = CGFloat(settings.firstLineIndent) * font.pointSize
        backgroundColor = UIColor(hex: theme.backgroundHex)
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: 0)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]

        for line in lines {
            let x = line.isParagraphStart ? indent : 0
            let y = CGFloat(line.top)
            let lineText = line.isParagraphStart
                ? line.text
                : line.text
            let attr = NSAttributedString(string: lineText, attributes: attrs)
            // v1.2.1：CTLineCreateWithAttributedString 返回非 Optional，去掉 guard let。
            let ctLine = CTLineCreateWithAttributedString(attr)
            let baseline = y + CGFloat(line.height) * 0.8   // 近似基线（行高 × 0.8）
            ctx.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(ctLine, ctx)
        }
    }
}

extension UIColor {
    convenience init(hex: String) {
        var value: UInt64 = 0
        let cleaned = hex.replacingOccurrences(of: "#", with: "")
        Scanner(string: cleaned).scanHexInt64(&value)
        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}
