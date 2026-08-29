import SwiftUI
import Inject
import MarkdownUI

struct ChangelogView: View {
    @ObserveInjection var inject
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TickSpacing.l) {
                HStack {
                    Text("Changelog")
                        .font(TickFont.title)
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(TickFont.labelFunc(13, weight: .semibold))
                            .foregroundStyle(TickColor.textSecondary)
                            .frame(width: 30, height: 30)
                            .hexGlass(in: Circle(), interactive: true)
                    }
                    .buttonStyle(.plain)
                }

                if let changelogPath = Bundle.main.path(forResource: "changelog", ofType: "md"),
                    let changelogContent = try? String(
                        contentsOfFile: changelogPath, encoding: .utf8)
                {
                    Markdown(changelogContent)
                        .markdownTextStyle {
                            FontFamily(.system())
                            FontSize(14)
                            ForegroundColor(.primary)
                        }
                        .markdownBlockStyle(\.heading1) { configuration in
                            configuration.label
                                .markdownTextStyle {
                                    FontSize(22)
                                    FontWeight(.regular)
                                }
                                .padding(.bottom, 8)
                        }
                        .markdownBlockStyle(\.heading2) { configuration in
                            configuration.label
                                .markdownTextStyle {
                                    FontSize(16)
                                    FontWeight(.regular)
                                }
                                .padding(.vertical, 6)
                        }
                        .markdownBlockStyle(\.paragraph) { configuration in
                            configuration.label
                                .padding(.vertical, 4)
                        }
                } else {
                    HStack(spacing: TickSpacing.s) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(TickColor.error)
                        Text("Changelog could not be loaded.")
                            .foregroundStyle(TickColor.error)
                    }
                    .padding(TickSpacing.l)
                    .hexGlass(cornerRadius: TickRadius.card, tint: TickColor.error.opacity(0.08))
                }
            }
            .padding(TickSpacing.xl)
        }
        .thinScrollbars()
        .frame(minWidth: 500, idealWidth: 600, minHeight: 420)
        .background(Color.clear)
        .enableInjection()
    }
}
