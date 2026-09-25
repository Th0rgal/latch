import SwiftUI
import UIKit

// thomas.md Quiet Ink. Paper and hairlines. Color only when a value is actually good or bad.

enum Ink {
    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { trait in
            let hex = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255,
                alpha: 1
            )
        })
    }

    static let paper = adaptive(light: 0xfbfaf6, dark: 0x131110)
    static let ink = adaptive(light: 0x26231e, dark: 0xefebe2)
    static let ink2 = adaptive(light: 0x57534b, dark: 0xcfc9bf)
    static let muted = adaptive(light: 0x6e695f, dark: 0xa8a195)
    static let rule = adaptive(light: 0xe7e3da, dark: 0x2c2925)
    static let good = adaptive(light: 0x1baf7a, dark: 0x2ec48c)
    static let bad = adaptive(light: 0xeb6834, dark: 0xe07a4a)

    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func prose(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

struct Tag: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(Ink.mono(11, .medium))
            .tracking(1.6)
            .foregroundStyle(Ink.muted)
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Ink.rule)
            .frame(height: 1)
            .padding(.vertical, 4)
    }
}

struct Stat: View {
    let label: String
    let value: String
    var tone: Color = Ink.ink

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(Ink.mono(13))
                .foregroundStyle(Ink.ink2)
            Spacer(minLength: 12)
            Text(value)
                .font(Ink.mono(15, .medium))
                .monospacedDigit()
                .foregroundStyle(tone)
        }
    }
}

struct QuietButton: View {
    let title: String
    var filled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Ink.serif(17, .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(filled ? Ink.paper : Ink.ink)
                .background(filled ? Ink.ink : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Ink.ink, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
