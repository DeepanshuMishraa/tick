import SwiftUI

// MARK: - Design System: "Tick"
//
// Editorial, handcrafted macOS voice app.
// - Light, warm, single theme (no dark mode churn)
// - Custom controls that don't look like stock macOS
// - Editorial serif headlines, geometric sans body
// - Cream hero cards, off-white canvas, light grey stat surfaces

// MARK: - Color Tokens

enum TickColor {
    // Brand
    static let brand = Color(red: 0.486, green: 0.227, blue: 0.929) // #7c3aed violet
    static let brandSoft = Color(red: 0.929, green: 0.902, blue: 0.996) // #ede6fe
    static let brandMid = Color(red: 0.706, green: 0.557, blue: 0.969) // #b48ef7

    // Canvas
    static let canvas = Color(red: 0.969, green: 0.957, blue: 0.925) // #f7f4ec off-white
    static let hero = Color(red: 0.992, green: 0.972, blue: 0.886) // #fdf8e2 cream hero
    static let stat = Color(red: 0.953, green: 0.953, blue: 0.957) // #f3f3f5 light grey
    static let surface = Color.white
    static let row = Color(red: 0.984, green: 0.980, blue: 0.969) // #fbfaf7 row

    // Text
    static let textPrimary = Color(red: 0.039, green: 0.039, blue: 0.047) // #0a0a0c
    static let textSecondary = Color(red: 0.361, green: 0.361, blue: 0.388) // #5c5c63
    static let textTertiary = Color(red: 0.580, green: 0.576, blue: 0.608) // #94939b
    static let textOnDark = Color.white
    static let textOnBrand = Color.white

    // Borders / lines
    static let line = Color(red: 0.0, green: 0.0, blue: 0.0).opacity(0.08)
    static let lineStrong = Color(red: 0.0, green: 0.0, blue: 0.0).opacity(0.14)
    static let chipBorder = Color(red: 0.0, green: 0.0, blue: 0.0).opacity(0.06)
    static let cardBorder = Color(red: 0.0, green: 0.0, blue: 0.0).opacity(0.04)

    // Recording states (semantic)
    static let recording = Color(red: 0.910, green: 0.310, blue: 0.310)
    static let transcribing = Color(red: 0.180, green: 0.620, blue: 0.620)
    static let success = Color(red: 0.122, green: 0.557, blue: 0.275)
    static let warning = Color(red: 0.918, green: 0.580, blue: 0.149)
    static let error = Color(red: 0.831, green: 0.235, blue: 0.235)
}

// MARK: - Typography
//
// Spline Sans Mono is used consistently across display text, labels, controls,
// captions, and metadata. It is registered via `TickFonts.registerIfNeeded()`
// in `HexApp.init()`.
// `INFOPLIST_KEY_UIAppFonts` is set as a belt-and-braces fallback.

// Regular and italic variable faces are bundled so the app does not depend on
// a font being installed on the user's Mac.
//
// Following user preferences, the entire app uses Spline Sans Mono.

enum TickFontName {
    static let regular = "SplineSansMono-Regular"
    static let italic = "SplineSansMono-Italic"
}

// MARK: - Helper

private func tickFont(_ size: CGFloat, weight: Font.Weight = .regular, italic: Bool = false) -> Font {
    // 2003265652 is the 'wght' variation axis identifier in Spline Sans Mono.
    let weightAxisIdentifier = 2003265652
    let weightValue: Double
    switch weight {
    case .ultraLight: weightValue = 200
    case .thin: weightValue = 300
    case .light: weightValue = 350
    case .regular: weightValue = 400
    case .medium: weightValue = 450
    case .semibold: weightValue = 500
    case .bold: weightValue = 600
    case .heavy: weightValue = 700
    case .black: weightValue = 800
    default: weightValue = 400
    }

    let descriptor = CTFontDescriptorCreateWithAttributes([
        kCTFontNameAttribute: (italic ? TickFontName.italic : TickFontName.regular) as CFString,
        kCTFontVariationAttribute: [
            weightAxisIdentifier: weightValue
        ]
    ] as CFDictionary)

    let ctFont = CTFontCreateWithFontDescriptor(descriptor, size, nil)
    return Font(ctFont as NSFont)
}

// MARK: - TickFont
//
// One clear voice:
//   Spline Sans Mono → display, headlines, body, UI, labels, buttons, captions

enum TickFont {
    // Touch the font registration to force it to run before any Font.custom lookup.
    static let _ensureRegistered: Void = { TickFonts.registerIfNeeded() }()
    // MARK: Display
    // Big editorial headlines, hero text, page titles

    /// Page/section titles
    static let title: Font = tickFont(22)

    /// Section heading
    static let heading: Font = tickFont(15)

    /// Subheading / large label
    static let subhead: Font = tickFont(17)

    /// Editorial display — used in hero cards and stat numbers
    static func display(_ size: CGFloat = 32, weight: Font.Weight = .regular) -> Font {
        tickFont(max(10, size * 0.92), weight: weight)
    }

    /// Editorial accent (displayed in brand color for emphasis, e.g. "you")
    static func displayAccent(_ size: CGFloat = 32, weight: Font.Weight = .semibold) -> Font {
        tickFont(max(10, size * 0.92), weight: weight)
    }

    /// Editorial italic accent — falls back to display (custom fonts are not italic by default).
    /// Use with brand color to call out a word in a headline.
    static func displayItalic(_ size: CGFloat = 32) -> Font {
        tickFont(max(10, size * 0.92), italic: true)
    }

    /// Custom-size section heading
    static func headingFunc(_ size: CGFloat = 24, weight: Font.Weight = .semibold) -> Font {
        tickFont(max(10, size * 0.94), weight: weight)
    }

    // MARK: Body
    // All body text, UI labels, buttons, and captions use Spline Sans Mono.

    /// Body text — Spline Sans Mono Regular 14pt
    static let body: Font = tickFont(14)

    /// UI label / button — Spline Sans Mono Regular 13pt
    static let label: Font = tickFont(13)

    /// Caption / metadata — Spline Sans Mono Regular 12pt
    static let caption: Font = tickFont(12)

    /// Eyebrow — uppercase tracked label
    static let eyebrow: Font = tickFont(11)

    /// Body text (function form for custom size).
    static func bodyFunc(_ size: CGFloat = 14, weight: Font.Weight = .regular) -> Font {
        tickFont(size, weight: weight)
    }

    /// UI label / button (function form for custom size).
    static func labelFunc(_ size: CGFloat = 13, weight: Font.Weight = .medium) -> Font {
        tickFont(size, weight: weight)
    }

    /// Caption (function form for custom size).
    static func captionFunc(_ size: CGFloat = 12, weight: Font.Weight = .regular) -> Font {
        tickFont(size, weight: weight)
    }

    /// Monospace (for values, codes, shortcuts) — Spline Sans Mono
    static func mono(_ size: CGFloat = 12, weight: Font.Weight = .medium) -> Font {
        tickFont(size, weight: weight)
    }

    /// Italic body — Spline Sans Mono Italic
    static func bodyItalic(_ size: CGFloat = 14, weight: Font.Weight = .regular) -> Font {
        tickFont(size, weight: weight, italic: true)
    }
}

// MARK: - Spacing

enum TickSpacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 6
    static let s: CGFloat = 10
    static let m: CGFloat = 14
    static let l: CGFloat = 20
    static let xl: CGFloat = 28
    static let xxl: CGFloat = 40
    static let section: CGFloat = 48

    // Legacy aliases used by older views
    static let micro: CGFloat = xxs
    static let small: CGFloat = s
    static let medium: CGFloat = m
    static let large: CGFloat = l
    static let xlarge: CGFloat = xl
    static let xxlarge: CGFloat = xxl
}

// MARK: - Radius

enum TickRadius {
    static let chip: CGFloat = 8
    static let card: CGFloat = 14
    static let hero: CGFloat = 18
    static let pill: CGFloat = 999

    // Legacy aliases
    static let small: CGFloat = 6
    static let medium: CGFloat = 10
    static let large: CGFloat = 14
    static let xlarge: CGFloat = 18
}

// MARK: - Hero / Card Surfaces

/// A cream hero card — the "Make Flow sound like you" surface
struct TickHero<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(TickSpacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: TickRadius.hero)
                    .fill(TickColor.hero)
            )
    }
}

/// A labeled section group (legacy API: title + icon + content)
struct TickSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: TickSpacing.m) {
            Label(title, systemImage: icon)
                .font(TickFont.labelFunc(12, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(TickColor.textTertiary)
                .textCase(.uppercase)
            content
        }
    }
}

/// A stat card — light grey rounded surface
struct TickStat<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(TickSpacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: TickRadius.card)
                    .fill(TickColor.stat)
            )
    }
}

/// A bordered white card (e.g. for entry rows, model list)
struct TickCard<Content: View>: View {
    @ViewBuilder let content: Content
    var isSelected: Bool = false
    var body: some View {
        content
            .padding(TickSpacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: TickRadius.card)
                    .fill(TickColor.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: TickRadius.card)
                            .stroke(isSelected ? TickColor.brand : TickColor.cardBorder, lineWidth: isSelected ? 1.5 : 1)
                    )
            )
    }
}

// MARK: - Pill / Chip

/// A small pill tag (for dictionary entries, shortcuts)
struct TickChip<Content: View>: View {
    @ViewBuilder let content: Content
    var isSelected: Bool = false
    var body: some View {
        content
            .font(TickFont.labelFunc(12))
            .padding(.horizontal, TickSpacing.s)
            .padding(.vertical, TickSpacing.xs)
            .background(
                RoundedRectangle(cornerRadius: TickRadius.chip)
                    .fill(TickColor.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: TickRadius.chip)
                            .stroke(isSelected ? TickColor.brand : TickColor.chipBorder, lineWidth: 1)
                    )
            )
            .foregroundStyle(isSelected ? TickColor.brand : TickColor.textPrimary)
    }
}

// MARK: - Eyebrow (uppercase tracked label)

struct TickEyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(TickFont.eyebrow)
            .tracking(0.8)
            .foregroundStyle(TickColor.textTertiary)
    }
}

// MARK: - Primary Button (black filled, white text)

struct TickPrimaryButton: View {
    let title: String
    var icon: String? = nil
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: TickSpacing.s) {
                if let icon {
                    Image(systemName: icon)
                        .font(TickFont.labelFunc(12))
                }
                Text(title)
                    .font(TickFont.labelFunc(13, weight: .medium))
            }
            .padding(.horizontal, TickSpacing.l)
            .padding(.vertical, TickSpacing.s + 2)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(TickColor.textPrimary)
            )
            .foregroundStyle(TickColor.textOnDark)
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Secondary Button (subtle dark)

struct TickSecondaryButton: View {
    let title: String
    var icon: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: TickSpacing.s) {
                if let icon {
                    Image(systemName: icon)
                        .font(TickFont.labelFunc(12))
                }
                Text(title)
                    .font(TickFont.labelFunc(13, weight: .medium))
            }
            .padding(.horizontal, TickSpacing.l)
            .padding(.vertical, TickSpacing.s + 2)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(TickColor.textPrimary.opacity(0.15), lineWidth: 1)
            )
            .foregroundStyle(TickColor.textPrimary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Custom Toggle (smooth pill, brand fill when on)

struct TickToggle: View {
    @Binding var isOn: Bool
    @State private var isHovered = false

    var body: some View {
        ZStack {
            Capsule()
                .fill(isOn ? TickColor.brand : Color(red: 0.886, green: 0.886, blue: 0.898))
                .frame(width: 38, height: 22)
                .overlay(
                    Capsule()
                        .stroke(isOn ? Color.clear : Color.black.opacity(0.08), lineWidth: 1)
                )
            Circle()
                .fill(Color.white)
                .frame(width: 18, height: 18)
                .shadow(color: Color.black.opacity(0.18), radius: 2, x: 0, y: 1)
                .offset(x: isOn ? 8 : -8)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                isOn.toggle()
            }
        }
        .scaleEffect(isHovered ? 1.04 : 1.0)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

// MARK: - Custom Slider (thin track, round brand thumb)

struct TickSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.01

    var body: some View {
        GeometryReader { geo in
            let normalized = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let width = geo.size.width
            let thumbX = CGFloat(normalized) * width

            ZStack(alignment: .leading) {
                // Track background
                Capsule()
                    .fill(Color(red: 0.886, green: 0.886, blue: 0.898))
                    .frame(height: 4)
                // Active track
                Capsule()
                    .fill(TickColor.brand)
                    .frame(width: thumbX, height: 4)
                // Thumb
                Circle()
                    .fill(TickColor.brand)
                    .frame(width: 16, height: 16)
                    .shadow(color: TickColor.brand.opacity(0.35), radius: 4, x: 0, y: 2)
                    .offset(x: thumbX - 8)
            }
            .frame(height: 20)
            .contentShape(Rectangle().inset(by: -8))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let clamped = max(0, min(width, drag.location.x))
                        let raw = range.lowerBound + Double(clamped / width) * (range.upperBound - range.lowerBound)
                        let stepped = (raw / step).rounded() * step
                        value = max(range.lowerBound, min(range.upperBound, stepped))
                    }
            )
        }
        .frame(height: 20)
    }
}

// MARK: - Underline Tab (used in Dictionary, Snippets, Styles)

struct TickTabBar<Item: Hashable, Label: View>: View {
    @Binding var selection: Item
    let items: [Item]
    @ViewBuilder let label: (Item) -> Label

    var body: some View {
        HStack(spacing: TickSpacing.l) {
            ForEach(items, id: \.self) { item in
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        selection = item
                    }
                } label: {
                    label(item)
                        .font(TickFont.labelFunc(14, weight: selection == item ? .semibold : .regular))
                        .foregroundStyle(selection == item ? TickColor.textPrimary : TickColor.textTertiary)
                        .padding(.bottom, TickSpacing.s)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(selection == item ? TickColor.textPrimary : Color.clear)
                                .frame(height: 1.5)
                        }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}

// MARK: - Sidebar Item (custom, not native)

struct TickSidebarItem: View {
    let icon: String
    let title: String
    let badge: String?
    let isActive: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: TickSpacing.s) {
                Image(systemName: icon)
                    .font(TickFont.labelFunc(14, weight: isActive ? Font.Weight.semibold : Font.Weight.regular))
                    .foregroundStyle(isActive ? TickColor.textPrimary : TickColor.textSecondary)
                    .frame(width: 18)
                Text(title)
                    .font(TickFont.labelFunc(14, weight: isActive ? .medium : .regular))
                    .foregroundStyle(isActive ? TickColor.textPrimary : TickColor.textSecondary)
                Spacer()
                if let badge {
                    Text(badge)
                        .font(TickFont.headingFunc(10, weight: .bold))
                        .foregroundStyle(TickColor.textOnBrand)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(TickColor.brand)
                        )
                }
            }
            .padding(.horizontal, TickSpacing.m)
            .padding(.vertical, TickSpacing.s)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? TickColor.textPrimary.opacity(0.05) : (isHovered ? TickColor.textPrimary.opacity(0.025) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Icon Button (for transcript rows: copy, play, delete)

struct TickIconButton: View {
    let systemName: String
    var color: Color = TickColor.textSecondary
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(TickFont.labelFunc(13, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(isHovered ? TickColor.textPrimary.opacity(0.05) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Sidebar Footer Item (Invite, Help etc.)

struct TickSidebarFooterItem: View {
    let icon: String
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: TickSpacing.s) {
                Image(systemName: icon)
                    .font(TickFont.captionFunc(13))
                    .foregroundStyle(TickColor.textSecondary)
                    .frame(width: 18)
                Text(title)
                    .font(TickFont.labelFunc(13))
                    .foregroundStyle(TickColor.textPrimary)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Brand Badge (with optional "Pro" pill)

struct TickBrand: View {
    var withProBadge: Bool = false

    var body: some View {
        HStack(spacing: TickSpacing.s) {
            // Brand mark: a small wave/soundform glyph in violet rounded square
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(TickColor.brand)
                    .frame(width: 26, height: 26)
                // Custom waveform glyph (3 vertical bars)
                HStack(spacing: 2) {
                    Capsule().fill(Color.white).frame(width: 2.5, height: 6)
                    Capsule().fill(Color.white).frame(width: 2.5, height: 12)
                    Capsule().fill(Color.white).frame(width: 2.5, height: 8)
                }
            }
            Text("Tick")
                .font(TickFont.headingFunc(20, weight: .semibold))
                .foregroundStyle(TickColor.textPrimary)
            if withProBadge {
                Text("Pro")
                    .font(TickFont.headingFunc(10, weight: .bold))
                    .foregroundStyle(TickColor.textOnBrand)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(TickColor.brand)
                    )
            }
        }
    }
}

// MARK: - Section Header (Hero with eyebrow + big serif title + optional body)

struct TickSectionHeader: View {
    let title: String
    var bodyText: String? = nil
    var trailing: AnyView? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: TickSpacing.xs) {
                Text(title)
                    .font(TickFont.headingFunc(28, weight: .semibold))
                    .foregroundStyle(TickColor.textPrimary)
                if let bodyText {
                    Text(bodyText)
                        .font(TickFont.bodyFunc())
                        .foregroundStyle(TickColor.textSecondary)
                }
            }
            Spacer()
            if let trailing { trailing }
        }
    }
}

// MARK: - Animations

enum TickAnimation {
    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.78)
    static let ease = Animation.easeInOut(duration: 0.2)
}

// MARK: - Backwards-compatible Aliases
// Old views still reference Hex* names. Keep these aliases so the build
// stays green while we migrate each view to the new Tick design system.

typealias HexFont = TickFont
typealias HexSpacing = TickSpacing
typealias HexRadius = TickRadius
typealias HexAnimation = TickAnimation
typealias HexCard = TickCard
typealias HexSection = TickSection
typealias HexRow = TickCard

extension View {
    func hexCard() -> some View {
        self
            .padding(TickSpacing.l)
            .background(
                RoundedRectangle(cornerRadius: TickRadius.card)
                    .fill(TickColor.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: TickRadius.card)
                            .stroke(TickColor.cardBorder, lineWidth: 1)
                    )
            )
    }

    func hexRow(isFirst: Bool = false, isLast: Bool = false) -> some View {
        self
            .padding(.horizontal, TickSpacing.l)
            .padding(.vertical, TickSpacing.m)
            .background(TickColor.surface)
            .overlay(alignment: .bottom) {
                if !isLast {
                    Rectangle()
                        .fill(TickColor.line)
                        .frame(height: 1)
                        .padding(.horizontal, TickSpacing.l)
                }
            }
    }
}

// MARK: - AppTheme (used by the home / dictionary / snippets views)

enum AppTheme {
    static let sidebarBackground = TickColor.canvas
    static let detailBackground = TickColor.canvas
    static let bannerBackground = TickColor.hero
    static let cardBackground = TickColor.surface
    static let statBackground = TickColor.stat
    static let primaryText = TickColor.textPrimary
    static let secondaryText = TickColor.textSecondary
    static let tertiaryText = TickColor.textTertiary
    static let brandColor = TickColor.brand
    static let border = TickColor.line
}

// MARK: - Font Registration
//
// On macOS, SwiftUI's `Font.custom` only resolves fonts that are registered
// with CoreText. Bundled fonts are NOT auto-registered (unlike on iOS where
// `UIAppFonts` in Info.plist handles it). We register them via
// `CGFont` + `CTFontManagerRegisterGraphicsFont` which reads the font data
// directly from the bundle — no file URL issues, no sandbox problems.
// The static initializer runs the first time the design system is touched,
// before any view tries to resolve `Font.custom(...)`.

import AppKit
import CoreText

/// Keep CGFont references alive — CoreText does not retain graphics fonts after registration.
private let _tickFontRegistration: Void = {
    for resource in ["SplineSansMono-Variable", "SplineSansMono-Italic-Variable"] {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "ttf"),
              let data = try? Data(contentsOf: url),
              let provider = CGDataProvider(data: data as CFData),
              let cgFont = CGFont(provider) else {
            NSLog("[TickFonts] Failed to load \(resource) from bundle")
            continue
        }
        var errorRef: Unmanaged<CFError>?
        CTFontManagerRegisterGraphicsFont(cgFont, &errorRef)
        if let err = errorRef?.takeRetainedValue() {
            let d = CFErrorCopyDescription(err) as String
            if !d.contains("already registered") && !d.contains("duplicate") {
                NSLog("[TickFonts] Failed: \(d)")
            }
        }
    }
}()

enum TickFonts {
    static func registerIfNeeded() {
        _ = _tickFontRegistration
    }
}
