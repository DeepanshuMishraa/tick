import SwiftUI

// MARK: - Design System: "Tick"
//
// Native macOS visual language for a focused voice utility.
// The bundled Spline Sans Mono type system stays intentionally intact; the
// surfaces around it are adaptive materials rather than fixed color blocks.

// MARK: - Color Tokens

enum TickColor {
    // Neutral Apple Monochrome / Liquid Glass Brand
    static let brand = Color.primary
    static let brandSoft = Color.primary.opacity(0.08)
    static let brandMid = Color.primary.opacity(0.60)
    static let brandGlow = Color.white.opacity(0.20)

    // Semantic materials with layered optical depth and text contrast protection
    static let canvas = Color.primary.opacity(0.015)
    static let hero = Color.clear
    static let stat = Color.clear
    static let surface = Color.clear
    static let row = Color.clear

    // Text (crisp, high-contrast, razor-sharp on liquid glass)
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let textTertiary = Color.primary.opacity(0.55)
    static let textOnDark = Color.white
    static let textOnBrand = Color.primary

    // Borders / Specular lines
    static let line = Color.primary.opacity(0.08)
    static let lineStrong = Color.primary.opacity(0.18)
    static let chipBorder = Color.primary.opacity(0.10)
    static let cardBorder = Color.primary.opacity(0.12)

    // Recording states (semantic)
    static let recording = Color(red: 0.930, green: 0.280, blue: 0.280)
    static let transcribing = Color(red: 0.180, green: 0.620, blue: 0.620)
    static let success = Color(red: 0.140, green: 0.680, blue: 0.360)
    static let warning = Color(red: 0.940, green: 0.600, blue: 0.160)
    static let error = Color(red: 0.880, green: 0.240, blue: 0.240)
}

enum HexGlassStyle {
    case clear
    case regular
    case prominent
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

/// A hero card — elevated Liquid Glass surface with specular rim
struct TickHero<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(TickSpacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hexGlass(cornerRadius: TickRadius.hero, style: .regular)
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

/// A stat card — light rounded liquid glass surface
struct TickStat<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(TickSpacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hexGlass(cornerRadius: TickRadius.card, style: .regular)
    }
}

/// A bordered card (e.g. for entry rows, model list)
struct TickCard<Content: View>: View {
    @ViewBuilder let content: Content
    var isSelected: Bool = false
    var body: some View {
        content
            .padding(TickSpacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hexGlass(cornerRadius: TickRadius.card, tint: isSelected ? TickColor.brandSoft : nil, interactive: true, style: .regular)
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
            .hexGlass(cornerRadius: TickRadius.chip, tint: isSelected ? TickColor.brandSoft : nil, interactive: true, style: .regular)
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

// MARK: - Primary Button (Luminous brand liquid glass)

struct TickPrimaryButton: View {
    let title: String
    var icon: String? = nil
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: TickSpacing.s) {
                if let icon {
                    Image(systemName: icon)
                        .font(TickFont.labelFunc(12, weight: .semibold))
                }
                Text(title)
                    .font(TickFont.labelFunc(13, weight: .semibold))
            }
            .padding(.horizontal, TickSpacing.l)
            .padding(.vertical, TickSpacing.s + 2)
            .foregroundStyle(TickColor.textPrimary)
            .hexGlass(cornerRadius: 10, interactive: true, style: .prominent)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        LinearGradient(
                            stops: [
                                .init(color: colorScheme == .dark ? Color.white.opacity(isHovered ? 0.65 : 0.40) : Color.white.opacity(isHovered ? 0.85 : 0.60), location: 0.0),
                                .init(color: colorScheme == .dark ? Color.white.opacity(isHovered ? 0.25 : 0.12) : Color.white.opacity(isHovered ? 0.40 : 0.20), location: 0.5),
                                .init(color: colorScheme == .dark ? Color.white.opacity(isHovered ? 0.45 : 0.22) : Color.white.opacity(isHovered ? 0.60 : 0.35), location: 1.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
            )
            .shadow(color: Color.black.opacity(colorScheme == .dark ? (isHovered ? 0.25 : 0.10) : (isHovered ? 0.12 : 0.04)), radius: isHovered ? 6 : 2, x: 0, y: isHovered ? 3 : 1)
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Secondary Button (Refined crystal liquid glass)

struct TickSecondaryButton: View {
    let title: String
    var icon: String? = nil
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: TickSpacing.s) {
                if let icon {
                    Image(systemName: icon)
                        .font(TickFont.labelFunc(12, weight: .medium))
                }
                Text(title)
                    .font(TickFont.labelFunc(13, weight: .medium))
            }
            .padding(.horizontal, TickSpacing.l)
            .padding(.vertical, TickSpacing.s + 2)
            .foregroundStyle(TickColor.textPrimary)
            .hexGlass(cornerRadius: 10, interactive: true, style: .regular)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        LinearGradient(
                            stops: [
                                .init(color: colorScheme == .dark ? Color.white.opacity(isHovered ? 0.50 : 0.25) : Color.white.opacity(isHovered ? 0.75 : 0.45), location: 0.0),
                                .init(color: colorScheme == .dark ? Color.white.opacity(isHovered ? 0.15 : 0.06) : Color.white.opacity(isHovered ? 0.25 : 0.12), location: 0.5),
                                .init(color: colorScheme == .dark ? Color.white.opacity(isHovered ? 0.30 : 0.14) : Color.white.opacity(isHovered ? 0.45 : 0.22), location: 1.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
            )
            .shadow(color: Color.black.opacity(colorScheme == .dark ? (isHovered ? 0.20 : 0.08) : (isHovered ? 0.10 : 0.03)), radius: isHovered ? 5 : 2, x: 0, y: isHovered ? 2 : 1)
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Custom Toggle (smooth pill, brand fill when on)

struct TickToggle: View {
    @Binding var isOn: Bool
    @State private var isHovered = false

    var body: some View {
        ZStack {
            Capsule()
                .fill(.clear)
                .frame(width: 38, height: 22)
                .hexGlass(in: Capsule(), tint: isOn ? TickColor.brand.opacity(0.35) : nil, interactive: true, style: .regular)
            Circle()
                .fill(Color.white)
                .frame(width: 17, height: 17)
                .shadow(color: Color.black.opacity(0.22), radius: 2.5, x: 0, y: 1.5)
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
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: 5)
                // Active track
                Capsule()
                    .fill(TickColor.brand)
                    .frame(width: max(5, thumbX), height: 5)
                // Thumb
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().fill(TickColor.brand.opacity(0.1)))
                    .frame(width: 16, height: 16)
                    .shadow(color: TickColor.brand.opacity(0.45), radius: 4, x: 0, y: 1.5)
                    .offset(x: max(0, min(width - 16, thumbX - 8)))
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
                    .foregroundStyle(isActive ? TickColor.brand : TickColor.textSecondary)
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
                        .hexGlass(cornerRadius: 4, tint: TickColor.brand, interactive: true, style: .prominent)
                }
            }
            .padding(.horizontal, TickSpacing.m)
            .padding(.vertical, TickSpacing.s)
            .hexGlass(
                cornerRadius: 8,
                tint: isActive ? TickColor.brandSoft : nil,
                interactive: true,
                style: isActive ? .regular : .clear
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
                .hexGlass(in: Circle(), interactive: true, style: .regular)
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
                    .shadow(color: TickColor.brandGlow, radius: 4, x: 0, y: 1.5)
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
                    .hexGlass(cornerRadius: 4, tint: TickColor.brand, interactive: true, style: .prominent)
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
    /// Adaptive app chrome: true Liquid Glass on macOS 26+, system vibrancy
    /// below it, and an opaque high-contrast fallback when transparency is off.
    @ViewBuilder
    func hexGlass(cornerRadius: CGFloat = TickRadius.card, tint: Color? = nil, interactive: Bool = false, style: HexGlassStyle = .clear) -> some View {
        hexGlass(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), tint: tint, interactive: interactive, style: style)
    }

    @ViewBuilder
    func hexGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false, style: HexGlassStyle = .clear) -> some View {
        modifier(HexGlassModifier(shape: shape, tint: tint, interactive: interactive, style: style))
    }

    func hexCard() -> some View {
        self
            .padding(TickSpacing.l)
            .hexGlass(cornerRadius: TickRadius.card, style: .regular)
    }

    func hexRow(isFirst: Bool = false, isLast: Bool = false) -> some View {
        self
            .padding(.horizontal, TickSpacing.l)
            .padding(.vertical, TickSpacing.m)
            .background(Color.clear)
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
    static let sidebarBackground = Color.primary.opacity(0.015)
    static let detailBackground = Color.clear
    static let bannerBackground = TickColor.hero
    static let cardBackground = TickColor.surface
    static let statBackground = TickColor.stat
    static let primaryText = TickColor.textPrimary
    static let secondaryText = TickColor.textSecondary
    static let tertiaryText = TickColor.textTertiary
    static let brandColor = TickColor.brand
    static let border = TickColor.line
}

private struct HexGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool
    let style: HexGlassStyle
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content
                .clipShape(shape)
                .background(shape.fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(shape.stroke(Color.primary.opacity(0.15), lineWidth: 1))
        } else if #available(macOS 26.0, *) {
            let glass: Glass = switch style {
            case .clear: .clear
            case .regular: .regular
            case .prominent: .regular
            }

            // Glossy optical substrate: delicate light gradient giving glossy liquid sheen
            let substrateGradient = LinearGradient(
                stops: [
                    .init(color: colorScheme == .dark ? Color.white.opacity(style == .prominent ? 0.12 : (style == .regular ? 0.06 : 0.025)) : Color.white.opacity(style == .prominent ? 0.50 : (style == .regular ? 0.30 : 0.15)), location: 0.0),
                    .init(color: colorScheme == .dark ? Color.white.opacity(style == .prominent ? 0.04 : (style == .regular ? 0.015 : 0.005)) : Color.white.opacity(style == .prominent ? 0.20 : (style == .regular ? 0.10 : 0.03)), location: 0.45),
                    .init(color: colorScheme == .dark ? Color.black.opacity(style == .prominent ? 0.10 : (style == .regular ? 0.04 : 0.01)) : Color.black.opacity(0.02), location: 1.0)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Specular rim stroke gradient: luminous top-leading light source
            let rimGradient = LinearGradient(
                stops: [
                    .init(color: colorScheme == .dark ? Color.white.opacity(0.35) : Color.white.opacity(0.65), location: 0.0),
                    .init(color: colorScheme == .dark ? Color.white.opacity(0.12) : Color.white.opacity(0.25), location: 0.35),
                    .init(color: colorScheme == .dark ? Color.white.opacity(0.04) : Color.white.opacity(0.08), location: 0.75),
                    .init(color: colorScheme == .dark ? Color.white.opacity(0.18) : Color.white.opacity(0.35), location: 1.0)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            content
                .background(shape.fill(substrateGradient))
                .clipShape(shape)
                .glassEffect(glass.tint(tint ?? .clear).interactive(interactive), in: shape)
                .overlay(
                    shape.stroke(rimGradient, lineWidth: 0.75)
                )
                .shadow(
                    color: Color.black.opacity(colorScheme == .dark ? 0.15 : 0.04),
                    radius: interactive ? 4 : 2,
                    x: 0,
                    y: 1
                )
        } else {
            content
                .clipShape(shape)
                .background(shape.fill(.ultraThinMaterial))
                .overlay(shape.fill(tint ?? .clear).clipShape(shape))
                .overlay(
                    shape.stroke(
                        LinearGradient(
                            stops: [
                                .init(color: Color.white.opacity(0.25), location: 0.0),
                                .init(color: Color.white.opacity(0.06), location: 0.4),
                                .init(color: Color.clear, location: 1.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
                )
        }
    }
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
