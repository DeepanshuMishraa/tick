import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct HotKeySectionView: View {
    @ObserveInjection var inject
    @Bindable var store: StoreOf<SettingsFeature>

    var body: some View {
        VStack(alignment: .leading, spacing: TickSpacing.m) {
            TickEyebrow(text: "Hotkey")
                .padding(.leading, TickSpacing.xs)

            // Hero cream card with hotkey
            TickHero {
                VStack(alignment: .leading, spacing: TickSpacing.m) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Press-and-hold or ")
                            .font(TickFont.display(26, weight: .regular))
                            .foregroundStyle(TickColor.textPrimary)
                        + Text("double-tap")
                            .font(TickFont.displayItalic(26))
                            .foregroundStyle(TickColor.brand)
                        + Text(" to record")
                            .font(TickFont.display(26, weight: .regular))
                            .foregroundStyle(TickColor.textPrimary)
                    }
                    Text("Tap to set a new hotkey. Use any modifier combo, or pick a single key.")
                        .font(TickFont.body)
                        .foregroundStyle(TickColor.textPrimary)
                        .opacity(0.7)

                    HStack {
                        Spacer()
                        let hotKey = store.hexSettings.hotkey
                        let key = store.isSettingHotKey ? nil : hotKey.key
                        let modifiers = store.isSettingHotKey ? store.currentModifiers : hotKey.modifiers

                        HotKeyView(modifiers: modifiers, key: key, isActive: store.isSettingHotKey)
                            .animation(TickAnimation.spring, value: key)
                            .animation(TickAnimation.spring, value: modifiers)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        store.send(.startSettingHotKey)
                    }
                }
            }

            // Modifier side controls (for modifier-only hotkeys)
            let hotKey = store.hexSettings.hotkey
            if !store.isSettingHotKey,
               hotKey.key == nil,
               !hotKey.modifiers.isEmpty {
                ModifierSideControls(
                    modifiers: hotKey.modifiers,
                    onSelect: { kind, side in
                        store.send(.setModifierSide(kind, side))
                    }
                )
                .transition(.opacity)
            }

            // Options card
            VStack(spacing: 0) {
                ToggleRow(
                    eyebrow: "Behavior",
                    title: "Enable Double-Tap Lock",
                    subtitle: "Tap twice to lock recording mode",
                    isOn: Binding(
                        get: { store.hexSettings.doubleTapLockEnabled },
                        set: { store.send(.toggleDoubleTapLockEnabled($0)) }
                    )
                )

                if hotKey.key != nil {
                    Rectangle().fill(TickColor.line).frame(height: 1)

                    ToggleRow(
                        eyebrow: "Tapping",
                        title: "Use Double-Tap Only",
                        subtitle: "Require double-tap even for key combinations",
                        isOn: Binding(
                            get: { store.hexSettings.useDoubleTapOnly },
                            set: { store.send(.toggleUseDoubleTapOnly($0)) }
                        ),
                       	isEnabled: store.hexSettings.doubleTapLockEnabled
                    )
                }

                if store.hexSettings.hotkey.key == nil {
                    Rectangle().fill(TickColor.line).frame(height: 1)

                    VStack(alignment: .leading, spacing: TickSpacing.s) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("MINIMUM HOLD".uppercased())
                                    .font(TickFont.eyebrow)
                                    .tracking(0.8)
                                    .foregroundStyle(TickColor.textTertiary)
                                Text("Hold time before recording starts")
                                    .font(TickFont.body)
                                    .foregroundStyle(TickColor.textPrimary)
                            }
                            Spacer()
                            Text("\(store.hexSettings.minimumKeyTime, specifier: "%.1f")s")
                                .font(TickFont.mono())
                                .foregroundStyle(TickColor.textPrimary)
                        }
                        TickSlider(
                            value: Binding(
                                get: { store.hexSettings.minimumKeyTime },
                                set: { store.send(.setMinimumKeyTime($0)) }
                            ),
                            range: 0.0...2.0,
                            step: 0.1
                        )
                    }
                    .padding(.vertical, TickSpacing.s)
                }
            }
            .padding(.horizontal, TickSpacing.l)
            .padding(.vertical, TickSpacing.m)
            .hexGlass(cornerRadius: TickRadius.card)
        }
        .enableInjection()
    }
}

private struct ToggleRow: View {
    let eyebrow: String
    let title: String
    let subtitle: String?
    @Binding var isOn: Bool
    var isEnabled: Bool = true

    var body: some View {
        HStack(alignment: .center, spacing: TickSpacing.l) {
            VStack(alignment: .leading, spacing: 4) {
                Text(eyebrow.uppercased())
                    .font(TickFont.eyebrow)
                    .tracking(0.8)
                    .foregroundStyle(TickColor.textTertiary)
                Text(title)
                    .font(TickFont.body)
                    .foregroundStyle(TickColor.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(TickFont.caption)
                        .foregroundStyle(TickColor.textSecondary)
                }
            }
            Spacer()
            TickToggle(isOn: $isOn)
        }
        .padding(.vertical, TickSpacing.s)
        .opacity(isEnabled ? 1 : 0.5)
    }
}

private struct ModifierSideControls: View {
    @ObserveInjection var inject
    var modifiers: Modifiers
    var onSelect: (Modifier.Kind, Modifier.Side) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: TickSpacing.m) {
            TickEyebrow(text: "Modifier Sides")
                .padding(.leading, TickSpacing.xs)

            VStack(alignment: .leading, spacing: TickSpacing.m) {
                ForEach(modifiers.kinds, id: \.self) { kind in
                    if kind.supportsSideSelection {
                        VStack(alignment: .leading, spacing: TickSpacing.s) {
                            Text("\(kind.symbol) \(kind.displayName)")
                                .font(TickFont.labelFunc(13, weight: .semibold))
                                .foregroundStyle(TickColor.textPrimary)

                            HStack(spacing: TickSpacing.s) {
                                ForEach(Modifier.Side.allCases, id: \.self) { side in
                                    ModifierSideChip(
                                        title: side.displayName,
                                        isSelected: modifiers.side(for: kind) == side,
                                        action: { onSelect(kind, side) }
                                    )
                                    .disabled(!kind.supportsSideSelection && side != .either)
                                }
                            }
                        }
                    }
                }
            }
            .padding(TickSpacing.l)
            .hexGlass(cornerRadius: TickRadius.card)
        }
    }
}

private struct ModifierSideChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(TickColor.textPrimary)
                }
                Text(title)
                    .font(TickFont.labelFunc(12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(TickColor.textPrimary)
            }
            .padding(.horizontal, TickSpacing.m)
            .padding(.vertical, TickSpacing.xs + 3)
            .hexGlass(
                cornerRadius: 8,
                tint: isSelected ? Color.primary.opacity(0.12) : nil,
                interactive: true,
                style: isSelected ? .prominent : .regular
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.primary.opacity(0.35) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.spring(response: 0.22, dampingFraction: 0.8), value: isSelected)
    }
}
