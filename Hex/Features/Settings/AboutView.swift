import ComposableArchitecture
import Inject
import SwiftUI

struct AboutView: View {
    @ObserveInjection var inject
    @Bindable var store: StoreOf<SettingsFeature>
    @State var viewModel = CheckForUpdatesViewModel.shared
    @State private var showingChangelog = false

    var body: some View {
        VStack(alignment: .leading, spacing: TickSpacing.xl) {
            // Editorial hero
            TickHero {
                VStack(alignment: .leading, spacing: TickSpacing.m) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Tick is a voice-to-text app that ")
                            .font(TickFont.display(32, weight: .regular))
                            .foregroundStyle(TickColor.textPrimary)
                        + Text("sounds like you")
                            .font(TickFont.displayItalic(32))
                            .foregroundStyle(TickColor.brand)
                    }
                    Text("On-device, private, and free. No audio leaves your Mac.")
                        .font(TickFont.body)
                        .foregroundStyle(TickColor.textPrimary)
                        .opacity(0.7)
                }
            }

            VStack(alignment: .leading, spacing: TickSpacing.m) {
                TickEyebrow(text: "About")
                    .padding(.leading, TickSpacing.xs)

                VStack(spacing: 0) {
                    aboutRow(eyebrow: "Version", title: "Installed version") {
                        HStack(spacing: TickSpacing.m) {
                            Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown")
                                .font(TickFont.mono())
                                .foregroundStyle(TickColor.textPrimary)
                            TickSecondaryButton(title: "Check for Updates", icon: "arrow.clockwise") {
                                viewModel.checkForUpdates()
                            }
                        }
                    }

                    Rectangle().fill(TickColor.line).frame(height: 1)

                    aboutRow(eyebrow: "Release notes", title: "Changelog") {
                        TickSecondaryButton(title: "Show", icon: "doc.text") {
                            showingChangelog.toggle()
                        }
                        .sheet(isPresented: $showingChangelog) {
                            ChangelogView()
                        }
                    }

                    Rectangle().fill(TickColor.line).frame(height: 1)

                    aboutRow(eyebrow: "Source", title: "Open source on GitHub") {
                        Link(destination: URL(string: "https://github.com/dipxsy/Tick/")!) {
                            HStack(spacing: 4) {
                                Text("dipxsy/Tick")
                                Image(systemName: "arrow.up.right")
                                    .font(TickFont.captionFunc(10))
                            }
                            .font(TickFont.body)
                            .foregroundStyle(TickColor.brand)
                        }
                    }

                    Rectangle().fill(TickColor.line).frame(height: 1)

                    aboutRow(eyebrow: "Support", title: "Become a sponsor") {
                        Link(destination: URL(string: "https://github.com/sponsors/dipxsy")!) {
                            HStack(spacing: 4) {
                                Text("github.com/sponsors/dipxsy")
                                Image(systemName: "arrow.up.right")
                                    .font(TickFont.captionFunc(10))
                            }
                            .font(TickFont.body)
                            .foregroundStyle(TickColor.brand)
                        }
                    }
                }
                .padding(.horizontal, TickSpacing.l)
                .padding(.vertical, TickSpacing.m)
                .hexGlass(cornerRadius: TickRadius.card)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .enableInjection()
    }

    private func aboutRow<Content: View>(eyebrow: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: TickSpacing.l) {
            VStack(alignment: .leading, spacing: 4) {
                Text(eyebrow.uppercased())
                    .font(TickFont.eyebrow)
                    .tracking(0.8)
                    .foregroundStyle(TickColor.textTertiary)
                Text(title)
                    .font(TickFont.body)
                    .foregroundStyle(TickColor.textPrimary)
            }
            Spacer()
            content()
        }
        .padding(.vertical, TickSpacing.s)
    }
}
