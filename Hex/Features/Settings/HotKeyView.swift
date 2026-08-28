import HexCore
import Inject
import Sauce
import SwiftUI

struct HotKeyView: View {
  @ObserveInjection var inject
  var modifiers: Modifiers
  var key: Key?
  var isActive: Bool

  var body: some View {
    HStack(spacing: 8) {
      if modifiers.isHyperkey {
        KeyView(text: "✦")
          .transition(.blurReplace)
      } else {
        ForEach(modifiers.sorted) { modifier in
          KeyView(text: modifier.stringValue)
            .transition(.blurReplace)
        }
      }

      if let key {
        KeyView(text: key.toString)
      }

      if modifiers.isEmpty && key == nil {
        Text("")
          .font(TickFont.mono())
          .frame(width: 48, height: 48)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity)
    .background {
      if isActive && key == nil && modifiers.isEmpty {
        Text("Enter a key combination")
          .font(TickFont.caption)
          .foregroundStyle(TickColor.textTertiary)
          .transition(.blurReplace)
      }
    }
    .hexGlass(cornerRadius: 14, tint: isActive ? TickColor.brandSoft : nil, interactive: true, style: .regular)
    .animation(TickAnimation.spring, value: key)
    .animation(TickAnimation.spring, value: modifiers)
    .animation(TickAnimation.spring, value: isActive)
    .enableInjection()
  }
}

struct KeyView: View {
  @ObserveInjection var inject
  var text: String

  var body: some View {
    Text(text)
      .font(TickFont.headingFunc(17, weight: .bold))
      .foregroundStyle(TickColor.textPrimary)
      .frame(width: 44, height: 44)
      .hexGlass(cornerRadius: 8, interactive: true, style: .regular)
      .enableInjection()
  }
}
