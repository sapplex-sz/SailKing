import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

enum OceanStyle {
    static let blue = Color(red: 0.07, green: 0.37, blue: 0.72)
    static let ink = Color(red: 0.09, green: 0.17, blue: 0.25)
    static let secondary = Color(red: 0.34, green: 0.40, blue: 0.47)
    static let canvas = Color(red: 0.96, green: 0.975, blue: 0.985)
    static let line = Color(red: 0.86, green: 0.9, blue: 0.93)
    static let paleBlue = Color(red: 0.9, green: 0.95, blue: 0.99)
    static let warning = Color(red: 0.65, green: 0.28, blue: 0.10)
    static let green = Color(red: 0.17, green: 0.48, blue: 0.38)
}

struct OceanButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 12)
            #if os(macOS)
            .padding(.vertical, 8)
            #else
            .padding(.vertical, 12)
            #endif
            .foregroundStyle(primary ? Color.white : OceanStyle.ink)
            .background(primary ? OceanStyle.blue : Color.white, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(primary ? Color.clear : OceanStyle.line, lineWidth: 1))
            .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.42)
    }
}

struct OceanSettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(OceanStyle.line, lineWidth: 1))
    }
}

struct OceanDisclosure<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) { content }
                .font(.system(size: 12)).foregroundStyle(OceanStyle.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .medium)).foregroundStyle(OceanStyle.ink)
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
        }
        .padding(12)
        .background(.white, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(OceanStyle.line, lineWidth: 1))
    }
}

struct OceanBrand: View {
    var compact = false
    private var brandImage: Image? {
        guard let url = Bundle.main.url(forResource: "HaiwangBrand", withExtension: "png") else { return nil }
        #if os(macOS)
        guard let image = NSImage(contentsOf: url) else { return nil }
        return Image(nsImage: image)
        #elseif os(iOS)
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        return Image(uiImage: image)
        #else
        return nil
        #endif
    }
    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let image = brandImage { image.resizable().scaledToFit() }
                else { Color.clear }
            }.frame(width: compact ? 36 : 43, height: compact ? 36 : 43)
            VStack(alignment: .leading, spacing: 3) {
                Text(hw("出海王输入法", "SailKing")).font(.system(size: compact ? 16 : 18, weight: .bold))
                if !compact {
                    Text("SAILKING").font(.system(size: 9, weight: .semibold, design: .rounded)).tracking(2.8).foregroundStyle(OceanStyle.secondary)
                }
            }
        }
        .foregroundStyle(OceanStyle.ink)
        .accessibilityElement(children: .combine)
    }
}

struct SectionHeading: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 28, weight: .bold)).tracking(-0.5).foregroundStyle(OceanStyle.ink)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(OceanStyle.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
