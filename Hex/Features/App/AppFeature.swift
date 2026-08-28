import AppKit
import ComposableArchitecture
import Dependencies
import HexCore
import SwiftUI

@Reducer
struct AppFeature {
  enum ActiveTab: Equatable, Hashable {
    case home
    case insights
    case dictionary
    case snippets
    case style
    case settings
    case help
  }

	@ObservableState
	struct State {
		var transcription: TranscriptionFeature.State = .init()
		var settings: SettingsFeature.State = .init()
		var history: HistoryFeature.State = .init()
		var activeTab: ActiveTab = .home
		@Shared(.hexSettings) var hexSettings: HexSettings
		@Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState

    // Permission state
    var microphonePermission: PermissionStatus = .notDetermined
    var accessibilityPermission: PermissionStatus = .notDetermined
    var inputMonitoringPermission: PermissionStatus = .notDetermined
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case transcription(TranscriptionFeature.Action)
    case settings(SettingsFeature.Action)
    case history(HistoryFeature.Action)
    case setActiveTab(ActiveTab)
    case task
    case pasteLastTranscript

    // Permission actions
    case checkPermissions
    case permissionsUpdated(mic: PermissionStatus, acc: PermissionStatus, input: PermissionStatus)
    case appActivated
    case requestMicrophone
    case requestAccessibility
    case requestInputMonitoring
    case modelStatusEvaluated(Bool)
  }

  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.transcription) var transcription
  @Dependency(\.permissions) var permissions

  var body: some ReducerOf<Self> {
    BindingReducer()

    Scope(state: \.transcription, action: \.transcription) {
      TranscriptionFeature()
    }

    Scope(state: \.settings, action: \.settings) {
      SettingsFeature()
    }

    Scope(state: \.history, action: \.history) {
      HistoryFeature()
    }

    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .task:
        return .merge(
          startPasteLastTranscriptMonitoring(),
          ensureSelectedModelReadiness(),
          startPermissionMonitoring()
        )

      case .pasteLastTranscript:
        @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
        guard let lastTranscript = transcriptionHistory.history.first?.text else {
          return .none
        }
        return .run { send in
          // Surface failures the same way dictation results do, so the floating
          // bottom-center Copy pill shows up instead of the paste vanishing
          // silently when no input was focused.
          let result = await pasteboard.paste(lastTranscript)
          HexLog.app.debug("Paste Last Transcript outcome=\(String(describing: result), privacy: .public)")
          switch result {
          case .pasted:
            break
          case .noFocusedInput:
            await send(.transcription(.pasteUnavailable(lastTranscript, reason: .noFocusedInput)))
          case .failed:
            await send(.transcription(.pasteUnavailable(lastTranscript, reason: .insertionRejected)))
          }
        }

      case .transcription(.modelMissing):
        HexLog.app.notice("Model missing - activating app and switching to settings")
        state.activeTab = .settings
        state.settings.shouldFlashModelSection = true
        return .run { send in
          await MainActor.run {
            HexLog.app.notice("Activating app for model missing")
            NSApplication.shared.activate(ignoringOtherApps: true)
          }
          try? await Task.sleep(for: .seconds(2))
          await send(.settings(.set(\.shouldFlashModelSection, false)))
        }

      case .transcription:
        return .none

      case .settings:
        return .none

      case .settings(.delegate(.permissionChanged(let mic))):
        state.microphonePermission = mic
        // Also re-check all permissions to keep the full state fresh
        return .send(.checkPermissions)

      case .history(.navigateToSettings):
        state.activeTab = .settings
        return .none
      case .history:
        return .none
		case let .setActiveTab(tab):
			state.activeTab = tab
			return .none

      // Permission handling
      case .checkPermissions:
        return .run { send in
          async let mic = permissions.microphoneStatus()
          async let acc = permissions.accessibilityStatus()
          async let input = permissions.inputMonitoringStatus()
          await send(.permissionsUpdated(mic: mic, acc: acc, input: input))
        }

      case let .permissionsUpdated(mic, acc, input):
        state.microphonePermission = mic
        state.accessibilityPermission = acc
        state.inputMonitoringPermission = input
        return .none

      case .appActivated:
        return .send(.checkPermissions)

      case .requestMicrophone:
        return .run { send in
          _ = await permissions.requestMicrophone()
          await send(.checkPermissions)
        }

      case .requestAccessibility:
        return .run { send in
          await permissions.requestAccessibility()
          for _ in 0..<10 {
            try? await Task.sleep(for: .seconds(1))
            await send(.checkPermissions)
          }
        }

      case .requestInputMonitoring:
        return .run { send in
          _ = await permissions.requestInputMonitoring()
          for _ in 0..<10 {
            try? await Task.sleep(for: .seconds(1))
            await send(.checkPermissions)
          }
        }

      case .modelStatusEvaluated:
        return .none
      }
    }
  }

  private func startPasteLastTranscriptMonitoring() -> Effect<Action> {
    .run { send in
      @Shared(.isSettingPasteLastTranscriptHotkey) var isSettingPasteLastTranscriptHotkey: Bool
      @Shared(.hexSettings) var hexSettings: HexSettings

      let token = keyEventMonitor.handleKeyEvent { keyEvent in
        if isSettingPasteLastTranscriptHotkey {
          return false
        }

        guard let pasteHotkey = hexSettings.pasteLastTranscriptHotkey,
              let key = keyEvent.key,
              key == pasteHotkey.key,
              keyEvent.modifiers.matchesExactly(pasteHotkey.modifiers) else {
          return false
        }

        MainActor.assumeIsolated {
          send(.pasteLastTranscript)
        }
        return true
      }

      defer { token.cancel() }

      await withTaskCancellationHandler {
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(60))
        }
      } onCancel: {
        token.cancel()
      }
    }
  }

  private func ensureSelectedModelReadiness() -> Effect<Action> {
    .run { send in
      @Shared(.hexSettings) var hexSettings: HexSettings
      @Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState
      let selectedModel = hexSettings.selectedModel
      guard !selectedModel.isEmpty else {
        await send(.modelStatusEvaluated(false))
        return
      }
      let isReady = await transcription.isModelDownloaded(selectedModel)
      $modelBootstrapState.withLock { state in
        state.modelIdentifier = selectedModel
        if state.modelDisplayName?.isEmpty ?? true {
          state.modelDisplayName = selectedModel
        }
        state.isModelReady = isReady
        if isReady {
          state.lastError = nil
          state.progress = 1
        } else {
          state.progress = 0
        }
      }
      await send(.modelStatusEvaluated(isReady))
    }
  }

  private func startPermissionMonitoring() -> Effect<Action> {
    .run { send in
      await send(.checkPermissions)
      for await activation in permissions.observeAppActivation() {
        if case .didBecomeActive = activation {
          await send(.appActivated)
        }
      }
    }
  }
}

// MARK: - App View

struct AppView: View {
  @Bindable var store: StoreOf<AppFeature>
  @State private var isSidebarVisible = true
  @State private var isPersonalisationWizardPresented = false
  @Namespace private var transcriptHoverNamespace
  @State private var hoveredTranscriptID: UUID? = nil

  // Cached stats to prevent expensive main-thread sorting and reductions on every body evaluation
  @State private var cachedWordCount: Int = 0
  @State private var cachedDailyStreak: Int = 0
  @State private var cachedAverageWPM: Int = 0
  @State private var cachedUniqueAppsCount: Int = 1
  @State private var cachedDisplayTranscripts: [Transcript] = []

  @State private var lastProcessedHistoryCount: Int = -1
  @State private var lastProcessedHistoryFirstId: UUID? = nil
  @State private var lastProcessedHistoryLastId: UUID? = nil

  private var userName: String {
    let name = NSFullUserName()
    if name.isEmpty {
      let loginName = NSUserName()
      return loginName.isEmpty ? "Yuxuan" : loginName
    }
    return name.components(separatedBy: " ").first ?? "Yuxuan"
  }

  private var wordCount: Int { cachedWordCount }
  private var dailyStreak: Int { cachedDailyStreak }
  private var averageWPM: Int { cachedAverageWPM }
  private var uniqueAppsCount: Int { cachedUniqueAppsCount }
  private var displayTranscripts: [Transcript] { cachedDisplayTranscripts }

  private func updateStatsIfNeeded() {
    let currentHistory = store.state.history.transcriptionHistory.history
    
    // Check if we need to recalculate
    if currentHistory.count == lastProcessedHistoryCount,
       currentHistory.first?.id == lastProcessedHistoryFirstId,
       currentHistory.last?.id == lastProcessedHistoryLastId {
      return
    }
    
    // Recalculate word count
    let count = currentHistory.reduce(0) { c, t in c + t.text.split(separator: " ").count }
    
    // Recalculate streak
    let streak: Int
    if currentHistory.isEmpty {
      streak = 0
    } else {
      let calendar = Calendar.current
      let dates = Set(currentHistory.map { calendar.startOfDay(for: $0.timestamp) })
      let today = calendar.startOfDay(for: Date())
      var currentCheckDate = today
      var currentStreak = 0
      if !dates.contains(today) {
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), dates.contains(yesterday) {
          currentCheckDate = yesterday
        } else {
          currentCheckDate = today
        }
      }
      while dates.contains(currentCheckDate) {
        currentStreak += 1
        guard let prevDate = calendar.date(byAdding: .day, value: -1, to: currentCheckDate) else { break }
        currentCheckDate = prevDate
      }
      streak = currentStreak
    }
    
    // Recalculate WPM
    let wpm: Int
    if currentHistory.isEmpty {
      wpm = 0
    } else {
      var totalWords = 0
      var totalSeconds: Double = 0.0
      for transcript in currentHistory {
        let words = transcript.text.split(separator: " ").count
        if transcript.duration > 0.5 && words > 0 {
          totalWords += words
          totalSeconds += transcript.duration
        }
      }
      if totalSeconds > 1.0 {
        let rawWpm = Double(totalWords) / (totalSeconds / 60.0)
        wpm = min(250, max(0, Int(round(rawWpm))))
      } else {
        wpm = 0
      }
    }
    
    // Recalculate unique apps
    let appNames = Set(currentHistory.compactMap { $0.sourceAppName })
    let appsCount = max(1, appNames.count)
    
    // Sort and cache display transcripts
    let sortedTranscripts: [Transcript]
    if currentHistory.isEmpty {
      let calendar = Calendar.current
      let today = Date()
      
      let t1 = Transcript(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        timestamp: calendar.date(bySettingHour: 12, minute: 38, second: 0, of: today) ?? today,
        text: "I want to draft a email for holiday seasons",
        audioPath: URL(fileURLWithPath: ""),
        duration: 5.0
      )
      let t2 = Transcript(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        timestamp: calendar.date(bySettingHour: 12, minute: 38, second: 10, of: today) ?? today,
        text: "Email is ready. Could you help me to check if this sentence is right?",
        audioPath: URL(fileURLWithPath: ""),
        duration: 8.0
      )
      let t3 = Transcript(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
        timestamp: calendar.date(bySettingHour: 12, minute: 38, second: 20, of: today) ?? today,
        text: "Audio is silence",
        audioPath: URL(fileURLWithPath: ""),
        duration: 2.0
      )
      let t4 = Transcript(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
        timestamp: calendar.date(bySettingHour: 12, minute: 39, second: 0, of: today) ?? today,
        text: "Could you please review this attachment and provide your feedback?",
        audioPath: URL(fileURLWithPath: ""),
        duration: 6.0
      )
      let t5 = Transcript(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
        timestamp: calendar.date(bySettingHour: 12, minute: 40, second: 0, of: today) ?? today,
        text: "I need assistance in finalizing the presentation for tomorrow's meeting.",
        audioPath: URL(fileURLWithPath: ""),
        duration: 9.0
      )
      let t6 = Transcript(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!,
        timestamp: calendar.date(bySettingHour: 12, minute: 41, second: 0, of: today) ?? today,
        text: "Let's schedule a call to discuss the project updates.",
        audioPath: URL(fileURLWithPath: ""),
        duration: 4.0
      )
      sortedTranscripts = [t6, t5, t4, t3, t2, t1]
    } else {
      sortedTranscripts = currentHistory.sorted(by: { $0.timestamp > $1.timestamp })
    }
    
    // Update state
    cachedWordCount = count
    cachedDailyStreak = streak
    cachedAverageWPM = wpm
    cachedUniqueAppsCount = appsCount
    cachedDisplayTranscripts = sortedTranscripts
    
    // Update checkpoint values
    lastProcessedHistoryCount = currentHistory.count
    lastProcessedHistoryFirstId = currentHistory.first?.id
    lastProcessedHistoryLastId = currentHistory.last?.id
  }

  var body: some View {
    ZStack {
      HStack(spacing: 0) {
        if isSidebarVisible {
          sidebar
            .frame(width: 220)
            .background(AppTheme.sidebarBackground)
            .transition(.move(edge: .leading))

          Rectangle()
            .fill(TickColor.line)
            .frame(width: 1)
        }

        detailContent
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(AppTheme.detailBackground)
      }
      .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isSidebarVisible)

      if isPersonalisationWizardPresented {
        PersonalisationWizardModal(onDismiss: { isPersonalisationWizardPresented = false })
      }
    }
    .toolbar {
      ToolbarItem(placement: .navigation) {
        Button(action: {
          withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            isSidebarVisible.toggle()
          }
        }) {
          Image(systemName: "sidebar.left")
        }
        .help(isSidebarVisible ? "Hide Sidebar" : "Show Sidebar")
      }
    }
    .task {
      await store.send(.task).finish()
    }
    .onAppear {
      updateStatsIfNeeded()
    }
    .onChange(of: store.state.history.transcriptionHistory.history) { _, _ in
      updateStatsIfNeeded()
    }
  }

  @ViewBuilder
  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Clean top breathing room below titlebar / traffic lights
      Spacer()
        .frame(height: 52)
      
      VStack(alignment: .leading, spacing: 4) {
        SidebarItem(icon: "house.fill", title: "Home", iconColor: Color(red: 0.20, green: 0.48, blue: 0.96), isActive: store.activeTab == .home) {
          store.send(.setActiveTab(.home))
        }
        SidebarItem(icon: "chart.xyaxis.line", title: "Insights", iconColor: Color(red: 0.58, green: 0.28, blue: 0.94), isActive: store.activeTab == .insights) {
          store.send(.setActiveTab(.insights))
        }
        SidebarItem(icon: "book.closed.fill", title: "Dictionary", iconColor: Color(red: 0.12, green: 0.68, blue: 0.62), isActive: store.activeTab == .dictionary) {
          store.send(.setActiveTab(.dictionary))
        }
        SidebarItem(icon: "scissors", title: "Snippets", iconColor: Color(red: 0.96, green: 0.52, blue: 0.18), isActive: store.activeTab == .snippets) {
          store.send(.setActiveTab(.snippets))
        }
        SidebarItem(icon: "slider.horizontal.3", title: "Style", iconColor: Color(red: 0.92, green: 0.24, blue: 0.56), isActive: store.activeTab == .style) {
          store.send(.setActiveTab(.style))
        }
      }
      .padding(.horizontal, 12)
      
      Spacer()
      
      VStack(alignment: .leading, spacing: 4) {
        SidebarItem(icon: "gearshape.fill", title: "Settings", iconColor: Color(red: 0.45, green: 0.48, blue: 0.54), isActive: store.activeTab == .settings) {
          store.send(.setActiveTab(.settings))
        }
        SidebarItem(icon: "questionmark.circle.fill", title: "Help", iconColor: Color(red: 0.35, green: 0.38, blue: 0.88), isActive: store.activeTab == .help) {
          store.send(.setActiveTab(.help))
        }
      }
      .padding(.horizontal, 12)
      .padding(.bottom, 20)
    }
  }

  @ViewBuilder
  private var detailContent: some View {
    VStack(spacing: 0) {
      if store.activeTab == .home {
        homeHeader
      } else {
        standardHeader
      }
      
      ScrollView {
        VStack(spacing: 0) {
          switch store.activeTab {
          case .home:
            homeTabContent
          case .insights:
            InsightsTabView(
              transcripts: store.history.transcriptionHistory.history,
              wordCount: wordCount,
              averageWPM: averageWPM,
              uniqueAppsCount: uniqueAppsCount
            )
            .padding(24)
          case .dictionary:
            DictionaryTabView()
              .padding(24)
          case .snippets:
            SnippetsTabView()
              .padding(24)
          case .style:
            StyleTabView(isWizardPresented: $isPersonalisationWizardPresented)
              .padding(24)
          case .settings:
            SettingsView(
              store: store.scope(state: \.settings, action: \.settings),
              microphonePermission: store.microphonePermission,
              accessibilityPermission: store.accessibilityPermission,
              inputMonitoringPermission: store.inputMonitoringPermission
            )
            .padding(24)
          case .help:
            HelpTabView()
              .padding(24)
          }
        }
        .frame(maxWidth: .infinity, alignment: .top)
      }
    }
  }

  private var homeHeader: some View {
    HStack {
      Text(homeGreeting)
        .font(TickFont.headingFunc(19, weight: .medium))
        .foregroundStyle(TickColor.textPrimary)
      
      HStack(spacing: 8) {
        Button(action: { store.send(.setActiveTab(.insights)) }) {
          StatPill(emoji: "🔥", text: "\(dailyStreak) \(dailyStreak == 1 ? "day" : "days")")
        }
        .buttonStyle(.plain)
        
        Button(action: { store.send(.setActiveTab(.insights)) }) {
          StatPill(emoji: "🚀", text: "\(wordCount) \(wordCount == 1 ? "word" : "words")")
        }
        .buttonStyle(.plain)
        
        Button(action: { store.send(.setActiveTab(.insights)) }) {
          StatPill(emoji: "👋", text: "\(averageWPM) WPM")
        }
        .buttonStyle(.plain)
      }
      .padding(.leading, 12)
      
      Spacer()
      
      HStack(spacing: 16) {
        // Notifications and user avatar removed per request
      }
    }
    .padding(.leading, 24)
    .padding(.trailing, 24)
    .padding(.vertical, 16)
    .frame(height: 56)
    .background(Color.clear)
  }

  private var homeGreeting: String {
    switch wordCount {
    case 0:
      return "Ready when you are, \(userName)"
    case 1...200:
      return "You're finding your flow, \(userName)"
    case 201...500:
      return "You're in a good rhythm, \(userName)"
    case 501...2_000:
      return "You're on a roll, \(userName)"
    default:
      return "You're in full flow, \(userName)"
    }
  }

  private var standardHeader: some View {
    HStack {
      Text(tabTitle(store.activeTab))
        .font(TickFont.headingFunc(18, weight: .medium))
        .foregroundStyle(TickColor.textPrimary)

      Spacer()
    }
    .padding(.leading, 24)
    .padding(.trailing, 24)
    .padding(.vertical, 16)
    .frame(height: 56)
    .background(Color.clear)
  }
  
  private func tabTitle(_ tab: AppFeature.ActiveTab) -> String {
    switch tab {
    case .home: return "Home"
    case .insights: return "Insights"
    case .dictionary: return "Dictionary"
    case .snippets: return "Snippets"
    case .style: return "Style"
    case .settings: return "Settings"
    case .help: return "Help"
    }
  }

  @ViewBuilder
  private var homeTabContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("TODAY")
          .font(TickFont.headingFunc(11, weight: .bold))
          .foregroundStyle(TickColor.textSecondary)
        Spacer()
      }
      .padding(.horizontal, 24)
      .padding(.top, 24)
      .padding(.bottom, 10)
      
      LazyVStack(alignment: .leading, spacing: 2) {
        ForEach(displayTranscripts) { transcript in
          TranscriptRow(
            transcript: transcript,
            isPlaying: store.state.history.playingTranscriptID == transcript.id,
            isHovered: hoveredTranscriptID == transcript.id,
            hoverNamespace: transcriptHoverNamespace,
            onHover: { isHovered in
              withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                if isHovered {
                  hoveredTranscriptID = transcript.id
                } else if hoveredTranscriptID == transcript.id {
                  hoveredTranscriptID = nil
                }
              }
            },
            onPlay: { store.send(.history(.playTranscript(transcript.id))) },
            onCopy: { store.send(.history(.copyToClipboard(transcript.text))) },
            onDelete: { store.send(.history(.deleteTranscript(transcript.id))) }
          )
        }
      }
      .padding(.horizontal, 24)
      .padding(.bottom, 24)
    }
  }
}

// MARK: - Support Views

struct SidebarItem: View {
  let icon: String
  let title: String
  var iconColor: Color? = nil
  let isActive: Bool
  let action: () -> Void
  
  @State private var isHovered = false
  @Environment(\.colorScheme) private var colorScheme
  
  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        if let iconColor {
          ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .fill(iconColor.gradient)
              .frame(width: 22, height: 22)
            Image(systemName: icon)
              .font(.system(size: 11, weight: .semibold))
              .foregroundColor(.white)
          }
        } else {
          Image(systemName: icon)
            .font(TickFont.labelFunc(13, weight: isActive ? .semibold : .medium))
            .foregroundColor(isActive ? TickColor.brand : .secondary)
            .frame(width: 16, height: 16)
        }
        
        Text(title)
          .font(TickFont.labelFunc(13, weight: isActive ? Font.Weight.semibold : Font.Weight.regular))
          .foregroundColor(isActive ? TickColor.textPrimary : TickColor.textSecondary)
        
        Spacer()
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background {
        if isActive || isHovered {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isActive ? (colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06)) : Color.clear)
            .hexGlass(
              in: RoundedRectangle(cornerRadius: 8, style: .continuous),
              tint: isActive ? TickColor.brandSoft : nil,
              interactive: true,
              style: isActive ? .regular : .clear
            )
        }
      }
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
  }
}

struct StatPill: View {
  let emoji: String
  let text: String

  var body: some View {
    HStack(spacing: 4) {
      Text(emoji)
        .font(TickFont.captionFunc(13))
      Text(text)
        .font(TickFont.labelFunc(12, weight: .semibold))
        .foregroundStyle(TickColor.textPrimary)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .hexGlass(in: Capsule(), interactive: true, style: .regular)
  }
}

struct TranscriptRow: View {
  let transcript: Transcript
  let isPlaying: Bool
  var isHovered: Bool = false
  var hoverNamespace: Namespace.ID? = nil
  var onHover: ((Bool) -> Void)? = nil
  let onPlay: () -> Void
  let onCopy: () -> Void
  let onDelete: () -> Void
  
  let isSilence: Bool
  
  @Environment(\.colorScheme) private var colorScheme
  @State private var showCopied = false
  @State private var copyTask: Task<Void, Error>?
  
  init(
    transcript: Transcript,
    isPlaying: Bool,
    isHovered: Bool = false,
    hoverNamespace: Namespace.ID? = nil,
    onHover: ((Bool) -> Void)? = nil,
    onPlay: @escaping () -> Void,
    onCopy: @escaping () -> Void,
    onDelete: @escaping () -> Void
  ) {
    self.transcript = transcript
    self.isPlaying = isPlaying
    self.isHovered = isHovered
    self.hoverNamespace = hoverNamespace
    self.onHover = onHover
    self.onPlay = onPlay
    self.onCopy = onCopy
    self.onDelete = onDelete
    
    let textLower = transcript.text.lowercased()
    self.isSilence = textLower.contains("silence") || textLower.contains("slince")
  }
  
  private enum TimeFormatter {
    static let shared: DateFormatter = {
      let formatter = DateFormatter()
      formatter.dateStyle = .none
      formatter.timeStyle = .short
      return formatter
    }()
  }
  
  var body: some View {
    HStack(alignment: .center, spacing: 20) {
      Text(TimeFormatter.shared.string(from: transcript.timestamp))
        .font(TickFont.captionFunc(13))
        .foregroundStyle(TickColor.textSecondary)
        .frame(width: 75, alignment: .leading)
      
      HStack(spacing: 6) {
        if isSilence {
          Text(transcript.text)
            .font(TickFont.captionFunc(13))
            .italic()
            .foregroundColor(.secondary.opacity(0.8))
          
          Image(systemName: "info.circle")
            .font(TickFont.captionFunc(12))
            .foregroundColor(.secondary.opacity(0.8))
        } else {
          Text(transcript.text)
            .font(TickFont.captionFunc(13))
            .foregroundStyle(TickColor.textPrimary)
        }
      }
      
      Spacer()
      
      HStack(spacing: 12) {
        Button(action: {
          onCopy()
          showCopyAnimation()
        }) {
          Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
            .font(TickFont.captionFunc(12))
            .foregroundColor(showCopied ? .green : .secondary)
        }
        .buttonStyle(.plain)
        
        Menu {
          Button(isPlaying ? "Stop Audio" : "Play Audio", action: onPlay)
          Button("Delete", role: .destructive, action: onDelete)
        } label: {
          Image(systemName: "ellipsis")
            .font(TickFont.captionFunc(12))
            .foregroundStyle(TickColor.textSecondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
      }
      .frame(width: 80, alignment: .trailing)
      .opacity(isHovered ? 1.0 : 0.0)
      .disabled(!isHovered)
      .animation(.easeOut(duration: 0.15), value: isHovered)
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 12)
    .background {
      if isHovered {
        if let hoverNamespace {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.40))
            .hexGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous), interactive: true, style: .regular)
            .matchedGeometryEffect(id: "homeTranscriptHover", in: hoverNamespace)
        } else {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.40))
            .hexGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous), interactive: true, style: .regular)
        }
      }
    }
    .contentShape(Rectangle())
    .onHover { hovered in
      onHover?(hovered)
    }
    .onDisappear {
      copyTask?.cancel()
    }
  }
  
  private func showCopyAnimation() {
    copyTask?.cancel()
    copyTask = Task {
      withAnimation { showCopied = true }
      try await Task.sleep(for: .seconds(1.5))
      withAnimation { showCopied = false }
    }
  }
}

// MARK: - Custom Controls

struct CustomSegmentedControl: View {
  let items: [String]
  @Binding var selectedIndex: Int
  
  var body: some View {
    HStack(spacing: 16) {
      ForEach(Array(items.enumerated()), id: \.element) { index, item in
        Button(action: { selectedIndex = index }) {
          VStack(spacing: 6) {
            Text(item)
              .font(TickFont.labelFunc(13, weight: selectedIndex == index ? Font.Weight.semibold : Font.Weight.medium))
              .foregroundColor(selectedIndex == index ? .primary : .secondary)
            
            Rectangle()
              .fill(selectedIndex == index ? Color.primary : Color.clear)
              .frame(height: 2)
          }
        }
        .buttonStyle(.plain)
      }
    }
  }
}

// MARK: - Modals

struct StatisticsModal: View {
  let wordCount: Int
  let dailyStreak: Int
  let averageWPM: Int
  let uniqueAppsCount: Int
  let onDismiss: () -> Void
  
  private var dailyStreakDescription: String {
    if dailyStreak == 0 {
      return "Start recording to build your daily streak!"
    } else if dailyStreak < 3 {
      return "You are off to a great start!"
    } else if dailyStreak < 7 {
      return "Keep it up, you're on a roll!"
    } else {
      return "Incredible dedication, you're unstoppable!"
    }
  }

  private var wpmDescription: String {
    if averageWPM == 0 {
      return "Speak to calculate your words per minute."
    } else if averageWPM < 80 {
      return "Use Tick more to see your WPM improve."
    } else if averageWPM < 130 {
      return "Nice job, you speak at a good, natural pace!"
    } else {
      return "Wow, you dictate fast! Professional level speed."
    }
  }

  private var appsDescription: String {
    if uniqueAppsCount <= 1 {
      return "Flowing in your primary app. Try using Tick in other apps!"
    } else if uniqueAppsCount < 5 {
      return "You're starting to flow across different apps."
    } else {
      return "You've been flowing nearly everywhere!"
    }
  }

  private var coverLettersCount: Int {
    max(1, wordCount / 120)
  }

  var body: some View {
    ZStack {
      Color.black.opacity(0.4)
        .edgesIgnoringSafeArea(.all)
        .onTapGesture {
          onDismiss()
        }
      
      VStack(spacing: 0) {
        HStack {
          Spacer()
          Button(action: onDismiss) {
            Image(systemName: "xmark")
              .font(TickFont.labelFunc(12))
              .foregroundStyle(TickColor.textSecondary)
              .frame(width: 28, height: 28)
              .hexGlass(in: Circle(), interactive: true)
          }
          .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)

        HStack(spacing: 6) {
          Text("You've been ")
            .font(TickFont.display(22, weight: .regular))
            .foregroundStyle(TickColor.textPrimary)
          Text("Ticking. Hard.")
            .font(TickFont.displayItalic(22))
            .foregroundStyle(TickColor.brand)
        }
        .padding(.bottom, 6)

        Text("Here's a personal snapshot of your productivity with Tick.")
          .font(TickFont.body)
          .foregroundStyle(TickColor.textSecondary)
          .padding(.bottom, 24)

        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
          StatCard(title: "DAILY STREAK", mainText: "\(dailyStreak) \(dailyStreak == 1 ? "day" : "days") 🔥", description: dailyStreakDescription)
          StatCard(title: "AVERAGE SPEED", mainText: "\(averageWPM) WPM 👋", description: wpmDescription)
          StatCard(title: "TOTAL WORDS DICTATED", mainText: "\(wordCount) 🚀", description: "You've written \(coverLettersCount) \(coverLettersCount == 1 ? "cover letter" : "cover letters")!")
          StatCard(title: "TOTAL APPS USED", mainText: "\(uniqueAppsCount) \(uniqueAppsCount == 1 ? "app" : "apps") 🏆", description: appsDescription)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 32)
      }
      .frame(width: 540)
      .hexGlass(cornerRadius: 20, interactive: true)
      .shadow(color: Color.black.opacity(0.25), radius: 40, x: 0, y: 20)
    }
  }
}

struct StatCard: View {
  let title: String
  let mainText: String
  let description: String
  
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(TickFont.eyebrow)
        .tracking(0.8)
        .foregroundStyle(TickColor.textTertiary)

      Text(mainText)
        .font(TickFont.headingFunc(18, weight: .semibold))
        .foregroundStyle(TickColor.textPrimary)

      Text(description)
        .font(TickFont.caption)
        .foregroundStyle(TickColor.textSecondary)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .hexGlass(cornerRadius: 12)
  }
}

struct PersonalisationWizardModal: View {
  let onDismiss: () -> Void
  @Shared(.hexSettings) var hexSettings: HexSettings
  @State private var currentStep = 0

  var body: some View {
    ZStack {
      Color.black.opacity(0.4)
        .edgesIgnoringSafeArea(.all)
        .onTapGesture {
          onDismiss()
        }

      VStack(spacing: 0) {
        HStack {
          Spacer()
          Button(action: onDismiss) {
            Image(systemName: "xmark")
              .font(TickFont.labelFunc(12))
              .foregroundStyle(TickColor.textSecondary)
              .frame(width: 28, height: 28)
              .hexGlass(in: Circle(), interactive: true)
          }
          .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)

        // Step indicator (4 dashes)
        HStack(spacing: 6) {
          ForEach(0..<4) { index in
            RoundedRectangle(cornerRadius: 2)
              .fill(index == currentStep ? TickColor.textPrimary : TickColor.lineStrong)
              .frame(width: 36, height: 3)
          }
        }
        .padding(.bottom, 24)

        // Editorial headline with violet italic
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          (
            Text("How do you write in ")
              .font(TickFont.display(24, weight: .regular))
              .foregroundStyle(TickColor.textPrimary)
            + Text("other apps?")
              .font(TickFont.displayItalic(24))
              .foregroundStyle(TickColor.brand)
          )

          HStack(spacing: 6) {
            ChatGptIcon()
            NotionIcon()
            MediumIcon()
          }
          .padding(.leading, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.bottom, 28)

        // Three style cards
        HStack(spacing: 16) {
          WizardStyleCard(
            title: "Formal.",
            label: "Caps + Punctuation",
            lines: [
              "So far, I am enjoying the new workout routine.",
              "I am excited for tomorrow's workout, especially after a full night of rest."
            ],
            isSelected: hexSettings.selectedStyleIndex == 0,
            action: { $hexSettings.withLock { $0.selectedStyleIndex = 0; $0.hasSelectedStyle = true } }
          )

          WizardStyleCard(
            title: "Casual",
            label: "Caps + Less punctuation",
            lines: [
              "So far I am enjoying the new workout routine.",
              "I am excited for tomorrow's workout especially after a full night of rest."
            ],
            isSelected: hexSettings.selectedStyleIndex == 1,
            action: { $hexSettings.withLock { $0.selectedStyleIndex = 1; $0.hasSelectedStyle = true } }
          )

          WizardStyleCard(
            title: "very casual",
            label: "No caps + Less punctuation",
            lines: [
              "so far i am enjoying the new workout routine",
              "i am excited for tomorrow's workout especially after a call or full night of rest"
            ],
            isSelected: hexSettings.selectedStyleIndex == 2,
            action: { $hexSettings.withLock { $0.selectedStyleIndex = 2; $0.hasSelectedStyle = true } }
          )
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 32)

        // Action row
        HStack {
          Spacer()

          TickSecondaryButton(title: "Back") {
            onDismiss()
          }
          .padding(.trailing, 8)

          TickPrimaryButton(title: currentStep < 3 ? "Next" : "Done") {
            if currentStep < 3 {
              currentStep += 1
            } else {
              onDismiss()
            }
          }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
      }
      .frame(width: 700)
      .hexGlass(cornerRadius: 20, interactive: true)
      .shadow(color: Color.black.opacity(0.3), radius: 40, x: 0, y: 20)
    }
  }
}

struct WizardStyleCard: View {
  let title: String
  let label: String
  let lines: [String]
  let isSelected: Bool
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 14) {
        // Title in serif
        Text(title)
          .font(TickFont.display(22, weight: .regular))
          .foregroundStyle(TickColor.textPrimary)

        // Eyebrow label
        Text(label.uppercased())
          .font(TickFont.eyebrow)
          .tracking(0.6)
          .foregroundStyle(TickColor.textSecondary)

        // Divider
        Rectangle()
          .fill(TickColor.line)
          .frame(height: 1)
          .padding(.vertical, 2)

        // Example text
        VStack(alignment: .leading, spacing: 8) {
          ForEach(lines, id: \.self) { line in
            Text(line)
              .font(TickFont.bodyFunc(12))
              .foregroundStyle(TickColor.textPrimary)
              .lineSpacing(2)
          }
        }

        Spacer()
      }
      .padding(18)
      .frame(width: 200, height: 250, alignment: .leading)
      .hexGlass(cornerRadius: 16, interactive: true)
      .overlay(
        RoundedRectangle(cornerRadius: 16)
              .stroke(Color.clear, lineWidth: 0)
      )
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
  }
}

// MARK: - Dictionary Tab

struct DictionaryTabView: View {
  @Shared(.hexSettings) var hexSettings: HexSettings
  @State private var isBannerVisible = true
  @State private var isAddingWord = false
  @State private var searchText = ""
  
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Dictionary")
          .font(TickFont.headingFunc(24, weight: .semibold))
          .foregroundStyle(TickColor.textPrimary)
        Spacer()
        TickPrimaryButton(title: "Add new", icon: "plus") {
          isAddingWord = true
        }
      }
      .padding(.bottom, 16)

      // Search bar
      HStack {
        HStack {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(TickColor.textSecondary)
          TextField("Search words...", text: $searchText)
            .textFieldStyle(.plain)
            .font(TickFont.bodyFunc(13))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .hexGlass(cornerRadius: 8)
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .stroke(Color.clear, lineWidth: 0)
        )

        Spacer()

        HStack(spacing: 12) {
          Image(systemName: "arrow.up.arrow.down")
            .foregroundStyle(TickColor.textSecondary)
          Image(systemName: "arrow.clockwise")
            .foregroundStyle(TickColor.textSecondary)
        }
        .font(TickFont.bodyFunc(14))
      }
      .padding(.bottom, 20)
      
      
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          if isBannerVisible {
            VStack(alignment: .leading, spacing: 12) {
              HStack {
                Text("Tick speaks the way you speak.")
                  .font(TickFont.display(24, weight: .semibold))
                Spacer()
                Button(action: { isBannerVisible = false }) {
                  Image(systemName: "xmark")
                    .foregroundStyle(TickColor.textSecondary)
                }
                .buttonStyle(.plain)
              }
              
              Text("Tick learns your unique words and names - automatically or manually. **Add personal terms, company jargon, client names, or industry-specific lingo.** Share them with your team so everyone stays on the same page.")
                .font(TickFont.captionFunc(13))
                .foregroundStyle(TickColor.textSecondary)
                .lineSpacing(4)
                .padding(.trailing, 24)
              
              HStack(spacing: 8) {
                DictionaryPill(text: "Q3 Roadmap")
                DictionaryPill(text: "Whispr → Wisper")
                DictionaryPill(text: "SF MOMA")
                DictionaryPill(text: "Figma Jam")
                DictionaryPill(text: "Company name")
              }
              .padding(.vertical, 8)
              
              TickPrimaryButton(title: "Add new word", icon: "plus") {
                isAddingWord = true
              }
            }
            .padding(24)
            .hexGlass(cornerRadius: 16, interactive: true)
            .overlay(
              RoundedRectangle(cornerRadius: 16)
                .stroke(Color.clear, lineWidth: 0)
            )
            .padding(.bottom, 20)
          }
          
          VStack(alignment: .leading, spacing: 0) {
            let filteredRemappings = hexSettings.wordRemappings.filter { remapping in
              searchText.isEmpty ? true : (
                remapping.match.lowercased().contains(searchText.lowercased()) ||
                remapping.replacement.lowercased().contains(searchText.lowercased())
              )
            }

            if filteredRemappings.isEmpty {
              HStack {
                Spacer()
                Text("No dictionary terms found")
                  .font(TickFont.captionFunc(13))
                  .foregroundStyle(TickColor.textSecondary)
                  .padding(.vertical, 24)
                Spacer()
              }
            } else {
              ForEach(filteredRemappings) { item in
                HStack {
                  VStack(alignment: .leading, spacing: 4) {
                    Text(item.match)
                      .font(TickFont.labelFunc(13, weight: .medium))
                      .foregroundStyle(TickColor.textPrimary)
                    Text("Match term")
                      .font(TickFont.captionFunc(9))
                      .foregroundStyle(TickColor.textSecondary)
                  }

                  Spacer()
                  
                  Image(systemName: "arrow.right")
                    .font(TickFont.captionFunc(12))
                    .foregroundStyle(TickColor.textSecondary)

                  Spacer()

                  VStack(alignment: .leading, spacing: 4) {
                    Text(item.replacement)
                      .font(TickFont.labelFunc(13, weight: .medium))
                      .foregroundStyle(TickColor.textPrimary)
                    Text("Replacement")
                      .font(TickFont.captionFunc(9))
                      .foregroundStyle(TickColor.textSecondary)
                  }

                  Spacer()

                  Button(action: {
                    $hexSettings.withLock {
                      $0.wordRemappings.removeAll { $0.id == item.id }
                    }
                  }) {
                    Image(systemName: "trash")
                      .font(TickFont.captionFunc(11))
                      .foregroundStyle(TickColor.textSecondary)
                  }
                  .buttonStyle(.plain)
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
                
              }
            }
          }
          .hexGlass(cornerRadius: 12)
          .overlay(
            RoundedRectangle(cornerRadius: 12)
              .stroke(Color.clear, lineWidth: 0)
          )
        }
      }
    }
    .sheet(isPresented: $isAddingWord) {
      AddWordSheet()
    }
  }
}

struct AddWordSheet: View {
  @Environment(\.dismiss) var dismiss
  @Shared(.hexSettings) var hexSettings: HexSettings
  
  @State private var originalWord = ""
  @State private var replacementWord = ""
  @FocusState private var focusedField: Field?
  
  enum Field: Hashable {
    case original
    case replacement
  }
  
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      // Header
      HStack(spacing: 12) {
        ZStack {
          RoundedRectangle(cornerRadius: 10)
            .fill(TickColor.brand.opacity(0.1))
            .frame(width: 40, height: 40)
          Image(systemName: "book.closed.fill")
            .font(.system(size: 18))
            .foregroundStyle(TickColor.brand)
        }
        
        VStack(alignment: .leading, spacing: 2) {
          Text("Add Dictionary Term")
            .font(TickFont.headingFunc(16, weight: .bold))
            .foregroundStyle(TickColor.textPrimary)
          Text("Tick will auto-replace the spoken word in your transcription.")
            .font(TickFont.captionFunc(11))
            .foregroundStyle(TickColor.textSecondary)
        }
        Spacer()
      }
      .padding(.bottom, 4)
      
      // Original Word
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text("Original Word (Spoken)")
            .font(TickFont.captionFunc(12, weight: .medium))
            .foregroundStyle(TickColor.textPrimary)
          Spacer()
          Text("Case-insensitive")
            .font(TickFont.captionFunc(10))
            .foregroundStyle(TickColor.textTertiary)
        }
        
        TextField("e.g. Whispr or Flow", text: $originalWord)
          .textFieldStyle(.plain)
          .focused($focusedField, equals: .original)
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .hexGlass(cornerRadius: 10)
          .overlay(
            RoundedRectangle(cornerRadius: 10)
              .stroke(Color.clear, lineWidth: 0)
              .animation(.easeOut(duration: 0.15), value: focusedField)
          )
      }
      
      // Replacement Word
      VStack(alignment: .leading, spacing: 6) {
        Text("Replacement Word (Written)")
          .font(TickFont.captionFunc(12, weight: .medium))
          .foregroundStyle(TickColor.textPrimary)
        
        TextField("e.g. Whisper or Hex", text: $replacementWord)
          .textFieldStyle(.plain)
          .focused($focusedField, equals: .replacement)
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .hexGlass(cornerRadius: 10)
          .overlay(
            RoundedRectangle(cornerRadius: 10)
              .stroke(Color.clear, lineWidth: 0)
              .animation(.easeOut(duration: 0.15), value: focusedField)
          )
      }
      
      // Action Buttons
      HStack(spacing: 12) {
        Spacer()
        
        TickSecondaryButton(title: "Cancel") {
          dismiss()
        }
        
        TickPrimaryButton(title: "Save") {
          let trimmedOrig = originalWord.trimmingCharacters(in: .whitespacesAndNewlines)
          let trimmedRepl = replacementWord.trimmingCharacters(in: .whitespacesAndNewlines)
          if !trimmedOrig.isEmpty && !trimmedRepl.isEmpty {
            $hexSettings.withLock {
              $0.wordRemappings.insert(
                WordRemapping(match: trimmedOrig, replacement: trimmedRepl),
                at: 0
              )
            }
            dismiss()
          }
        }
        .disabled(originalWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || replacementWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      .padding(.top, 8)
    }
    .padding(28)
    .frame(width: 440)
    .hexGlass(cornerRadius: 16)
    .onAppear {
      focusedField = .original
    }
  }
}

struct DictionaryPill: View {
  let text: String
  var body: some View {
    Text(text)
      .font(TickFont.labelFunc(12, weight: .medium))
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .hexGlass(cornerRadius: 8)
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(Color.clear, lineWidth: 0)
      )
  }
}

// MARK: - Snippets Tab

struct SnippetsTabView: View {
  @Shared(.hexSettings) var hexSettings: HexSettings
  @State private var isBannerVisible = true
  @State private var isAddingSnippet = false
  @State private var searchText = ""
  
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Snippets")
          .font(TickFont.headingFunc(24, weight: .semibold))
          .foregroundStyle(TickColor.textPrimary)
        Spacer()
        TickPrimaryButton(title: "Add new", icon: "plus") {
          isAddingSnippet = true
        }
      }
      .padding(.bottom, 16)

      // Search bar
      HStack {
        HStack {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(TickColor.textSecondary)
          TextField("Search snippets...", text: $searchText)
            .textFieldStyle(.plain)
            .font(TickFont.bodyFunc(13))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
      .hexGlass(cornerRadius: 8)
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .stroke(Color.clear, lineWidth: 0)
        )

        Spacer()

        HStack(spacing: 12) {
          Image(systemName: "arrow.up.arrow.down")
            .foregroundStyle(TickColor.textSecondary)
          Image(systemName: "arrow.clockwise")
            .foregroundStyle(TickColor.textSecondary)
        }
        .font(TickFont.bodyFunc(14))
      }
      .padding(.bottom, 20)
      
      
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          if isBannerVisible {
            VStack(alignment: .leading, spacing: 12) {
              HStack {
                Text("The stuff you shouldn't have to re-type.")
                  .font(TickFont.display(24, weight: .semibold))
                Spacer()
                Button(action: { isBannerVisible = false }) {
                  Image(systemName: "xmark")
                    .foregroundStyle(TickColor.textSecondary)
                }
                .buttonStyle(.plain)
              }
              
              Text("Save shortcuts to speak the things you type all the time - emails, links, addresses, bios - anything. **Just speak and Tick expands them instantly,** without retyping or hunting through old messages.")
                .font(TickFont.captionFunc(13))
                .foregroundStyle(TickColor.textSecondary)
                .lineSpacing(4)
                .padding(.trailing, 24)
              
              VStack(alignment: .leading, spacing: 8) {
                SnippetDiagramRow(shortcut: "LinkedIn", content: "https://www.linkedin.com/in/john-doe-9b0139134/")
                SnippetDiagramRow(shortcut: "intro email", content: "Hey, would love to find some time to chat later...")
                SnippetDiagramRow(shortcut: "my calendly link", content: "calendly.com/you/invite-name")
              }
              .padding(.vertical, 8)
              
              TickPrimaryButton(title: "Add new snippet", icon: "plus") {
                isAddingSnippet = true
              }
            }
            .padding(24)
            .hexGlass(cornerRadius: 16, interactive: true)
            .overlay(
              RoundedRectangle(cornerRadius: 16)
                .stroke(Color.clear, lineWidth: 0)
            )
            .padding(.bottom, 20)
          }
          
          VStack(alignment: .leading, spacing: 0) {
            let filteredSnippets = hexSettings.snippets.filter { snippet in
              searchText.isEmpty ? true : (
                snippet.shortcut.lowercased().contains(searchText.lowercased()) ||
                snippet.content.lowercased().contains(searchText.lowercased())
              )
            }

            if filteredSnippets.isEmpty {
              HStack {
                Spacer()
                Text("No snippets found")
                  .font(TickFont.captionFunc(13))
                  .foregroundStyle(TickColor.textSecondary)
                  .padding(.vertical, 24)
                Spacer()
              }
            } else {
              ForEach(filteredSnippets) { snippet in
                HStack {
                  VStack(alignment: .leading, spacing: 4) {
                    Text(snippet.shortcut)
                      .font(TickFont.labelFunc(13, weight: .medium))
                      .foregroundStyle(TickColor.textPrimary)
                    Text("Shortcut")
                      .font(TickFont.captionFunc(9))
                      .foregroundStyle(TickColor.textSecondary)
                  }

                  Spacer()
                  
                  Image(systemName: "arrow.right")
                    .font(TickFont.captionFunc(12))
                    .foregroundStyle(TickColor.textSecondary)

                  Spacer()

                  VStack(alignment: .leading, spacing: 4) {
                    Text(snippet.content)
                      .font(TickFont.labelFunc(13))
                      .foregroundStyle(TickColor.textSecondary)
                      .lineLimit(1)
                    Text("Expansion")
                      .font(TickFont.captionFunc(9))
                      .foregroundStyle(TickColor.textSecondary)
                  }

                  Spacer()

                  HStack(spacing: 12) {
                    Button(action: {
                      NSPasteboard.general.clearContents()
                      NSPasteboard.general.setString(snippet.content, forType: .string)
                    }) {
                      Image(systemName: "doc.on.doc")
                        .font(TickFont.captionFunc(11))
                        .foregroundStyle(TickColor.textSecondary)
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: {
                      $hexSettings.withLock {
                        $0.snippets.removeAll { $0.id == snippet.id }
                      }
                    }) {
                      Image(systemName: "trash")
                        .font(TickFont.captionFunc(11))
                        .foregroundStyle(TickColor.textSecondary)
                    }
                    .buttonStyle(.plain)
                  }
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
                
              }
            }
          }
          .hexGlass(cornerRadius: 12)
          .overlay(
            RoundedRectangle(cornerRadius: 12)
              .stroke(Color.clear, lineWidth: 0)
          )
        }
      }
    }
    .sheet(isPresented: $isAddingSnippet) {
      AddSnippetSheet()
    }
  }
}

struct AddSnippetSheet: View {
  @Environment(\.dismiss) var dismiss
  @Shared(.hexSettings) var hexSettings: HexSettings
  
  @State private var shortcut = ""
  @State private var expansion = ""
  @FocusState private var focusedField: Field?
  
  enum Field: Hashable {
    case shortcut
    case expansion
  }
  
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      // Header
      HStack(spacing: 12) {
        ZStack {
          RoundedRectangle(cornerRadius: 10)
            .fill(TickColor.brand.opacity(0.1))
            .frame(width: 40, height: 40)
          Image(systemName: "scissors")
            .font(.system(size: 18))
            .foregroundStyle(TickColor.brand)
        }
        
        VStack(alignment: .leading, spacing: 2) {
          Text("Add Snippet Shortcut")
            .font(TickFont.headingFunc(16, weight: .bold))
            .foregroundStyle(TickColor.textPrimary)
          Text("Speak the shortcut phrase, and Tick expands it into the full text.")
            .font(TickFont.captionFunc(11))
            .foregroundStyle(TickColor.textSecondary)
        }
        Spacer()
      }
      .padding(.bottom, 4)
      
      // Shortcut Phrase
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text("Shortcut Phrase (Spoken)")
            .font(TickFont.captionFunc(12, weight: .medium))
            .foregroundStyle(TickColor.textPrimary)
          Spacer()
          Text("Case-insensitive")
            .font(TickFont.captionFunc(10))
            .foregroundStyle(TickColor.textTertiary)
        }
        
        TextField("e.g. My Calendly or Intro email", text: $shortcut)
          .textFieldStyle(.plain)
          .focused($focusedField, equals: .shortcut)
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .hexGlass(cornerRadius: 10)
          .overlay(
            RoundedRectangle(cornerRadius: 10)
              .stroke(Color.clear, lineWidth: 0)
              .animation(.easeOut(duration: 0.15), value: focusedField)
          )
      }
      
      // Expansion Content
      VStack(alignment: .leading, spacing: 6) {
        Text("Expansion Content (Pasted)")
          .font(TickFont.captionFunc(12, weight: .medium))
          .foregroundStyle(TickColor.textPrimary)
        
        TextEditor(text: $expansion)
          .font(TickFont.bodyFunc(13))
          .scrollContentBackground(.hidden)
          .focused($focusedField, equals: .expansion)
          .padding(8)
          .frame(height: 100)
          .hexGlass(cornerRadius: 10)
          .overlay(
            RoundedRectangle(cornerRadius: 10)
              .stroke(Color.clear, lineWidth: 0)
              .animation(.easeOut(duration: 0.15), value: focusedField)
          )
      }
      
      // Action Buttons
      HStack(spacing: 12) {
        Spacer()
        
        TickSecondaryButton(title: "Cancel") {
          dismiss()
        }
        
        TickPrimaryButton(title: "Save") {
          let trimmedShort = shortcut.trimmingCharacters(in: .whitespacesAndNewlines)
          let trimmedExp = expansion.trimmingCharacters(in: .whitespacesAndNewlines)
          if !trimmedShort.isEmpty && !trimmedExp.isEmpty {
            $hexSettings.withLock {
              $0.snippets.insert(
                SnippetSetting(shortcut: trimmedShort, content: trimmedExp),
                at: 0
              )
            }
            dismiss()
          }
        }
        .disabled(shortcut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      .padding(.top, 8)
    }
    .padding(28)
    .frame(width: 440)
    .hexGlass(cornerRadius: 16)
    .onAppear {
      focusedField = .shortcut
    }
  }
}

struct SnippetDiagramRow: View {
  let shortcut: String
  let content: String

  var body: some View {
    HStack(spacing: 8) {
      Text(shortcut)
        .font(TickFont.labelFunc(12, weight: .medium))
        .foregroundStyle(TickColor.textPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .hexGlass(cornerRadius: 8)
        .overlay(
          RoundedRectangle(cornerRadius: 8)
          .stroke(Color.clear, lineWidth: 0)
        )

      Image(systemName: "arrow.right")
        .font(TickFont.labelFunc(11, weight: .medium))
        .foregroundStyle(TickColor.textSecondary)

      Text(content)
        .font(TickFont.bodyFunc(12))
        .foregroundStyle(TickColor.textPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .hexGlass(cornerRadius: 8)
        .overlay(
          RoundedRectangle(cornerRadius: 8)
          .stroke(Color.clear, lineWidth: 0)
        )
    }
  }
}

// MARK: - Style Tab

struct StyleTabView: View {
  @Shared(.hexSettings) var hexSettings: HexSettings
  @Binding var isWizardPresented: Bool
  @AppStorage("hasSeenPersonalisationWizard") private var hasSeenWizard: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Styles")
          .font(TickFont.headingFunc(24, weight: .semibold))
          .foregroundStyle(TickColor.textPrimary)
        Spacer()
      }
      .padding(.bottom, 12)
      
      Text("Configure how your transcriptions are formatted. Choose the style that best matches where you speak, and Tick will automatically format spelling, capitalization, and punctuation.")
        .font(TickFont.bodyFunc(14))
        .foregroundStyle(TickColor.textSecondary)
        .lineSpacing(4)
        .padding(.bottom, 24)
      
      
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          HStack(spacing: 16) {
            StylePreviewCard(
              style: .formal,
              isSelected: hexSettings.selectedStyleIndex == 0,
              action: { $hexSettings.withLock { $0.selectedStyleIndex = 0; $0.hasSelectedStyle = true } }
            )
            
            StylePreviewCard(
              style: .casual,
              isSelected: hexSettings.selectedStyleIndex == 1,
              action: { $hexSettings.withLock { $0.selectedStyleIndex = 1; $0.hasSelectedStyle = true } }
            )
            
            StylePreviewCard(
              style: .veryCasual,
              isSelected: hexSettings.selectedStyleIndex == 2,
              action: { $hexSettings.withLock { $0.selectedStyleIndex = 2; $0.hasSelectedStyle = true } }
            )
          }
          .padding(.top, 10)
        }
      }
    }
    .onAppear {
      if !hasSeenWizard {
        isWizardPresented = true
        hasSeenWizard = true
      }
    }
  }
}

enum StyleType {
  case formal
  case casual
  case veryCasual
}

struct StylePreviewCard: View {
  let style: StyleType
  let isSelected: Bool
  let action: () -> Void
  
  @State private var isHovered = false
  @Environment(\.colorScheme) private var colorScheme
  
  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 0) {
        // Selection indicator and title
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text(title)
              .font(TickFont.headingFunc(20, weight: .bold))
              .foregroundStyle(TickColor.textPrimary)
            
            Text(badgeText)
              .font(TickFont.eyebrow)
              .tracking(0.6)
              .foregroundStyle(badgeColor)
          }
          
          Spacer()
          
          // Selection Indicator Ring
          ZStack {
            Circle()
              .stroke(Color.clear, lineWidth: 0)
              .frame(width: 20, height: 20)
            if isSelected {
              Circle()
                .fill(TickColor.brand)
                .frame(width: 12, height: 12)
              Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.white)
            }
          }
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 14)
        
        // Preview Container
        VStack {
          previewView
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 120, alignment: .topLeading)
        .hexGlass(cornerRadius: 12)
        .padding(.horizontal, 12)
        .padding(.bottom, 16)
      }
      .frame(width: 220, height: 210)
      .hexGlass(cornerRadius: 16, interactive: true)
      .overlay(
        RoundedRectangle(cornerRadius: 16)
          .stroke(Color.clear, lineWidth: 0)
      )
      .shadow(color: Color.black.opacity(isSelected ? 0.05 : (isHovered ? 0.04 : 0)), radius: 8, x: 0, y: 4)
      .offset(y: isHovered ? -4 : 0)
      .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
      .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isSelected)
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
  }
  
  private var title: String {
    switch style {
    case .formal: return "Formal"
    case .casual: return "Casual"
    case .veryCasual: return "very casual"
    }
  }
  
  private var badgeText: String {
    switch style {
    case .formal: return "CAPS + PUNCTUATION"
    case .casual: return "CAPS + NO END PERIOD"
    case .veryCasual: return "NO CAPS + CASUAL"
    }
  }
  
  private var badgeColor: Color {
    switch style {
    case .formal: return TickColor.brand
    case .casual: return Color(red: 34/255, green: 112/255, blue: 63/255)
    case .veryCasual: return Color(red: 200/255, green: 100/255, blue: 50/255)
    }
  }
  
  @ViewBuilder
  private var previewView: some View {
    switch style {
    case .formal:
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 4) {
          Image(systemName: "envelope.fill")
            .font(.system(size: 8))
            .foregroundStyle(TickColor.textSecondary)
          Text("Email Draft")
            .font(TickFont.captionFunc(8, weight: .bold))
            .foregroundStyle(TickColor.textSecondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
        
        Text("Hey, are you free for lunch tomorrow? Let's do 12 if that works for you.")
          .font(TickFont.bodyFunc(10))
          .foregroundStyle(TickColor.textPrimary)
          .lineSpacing(1.5)
          .padding(.horizontal, 6)
          .padding(.bottom, 4)
      }
      .background(colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.85))
      .cornerRadius(6)
      .overlay(
        RoundedRectangle(cornerRadius: 6)
          .stroke(colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.06), lineWidth: 0.5)
      )
      
    case .casual:
      HStack(alignment: .top, spacing: 6) {
        Circle()
          .fill(Color(red: 220/255, green: 240/255, blue: 225/255).opacity(colorScheme == .dark ? 0.35 : 1.0))
          .frame(width: 16, height: 16)
          .overlay(
            Text("A")
              .font(TickFont.captionFunc(9, weight: .bold))
              .foregroundStyle(colorScheme == .dark ? Color.white : Color(red: 34/255, green: 112/255, blue: 63/255))
          )
        
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 3) {
            Text("Alex")
              .font(TickFont.captionFunc(9, weight: .bold))
              .foregroundStyle(TickColor.textPrimary)
            Text("12:04 PM")
              .font(TickFont.captionFunc(7))
              .foregroundStyle(TickColor.textTertiary)
          }
          
          Text("Hey, are you free for lunch tomorrow? Let's do 12 if that works for you")
            .font(TickFont.bodyFunc(10))
            .foregroundStyle(TickColor.textPrimary)
            .lineSpacing(1.5)
        }
      }
      .padding(6)
      .background(colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.85))
      .cornerRadius(6)
      .overlay(
        RoundedRectangle(cornerRadius: 6)
          .stroke(colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.06), lineWidth: 0.5)
      )
      
    case .veryCasual:
      VStack(alignment: .leading) {
        Spacer()
        HStack {
          Spacer()
          Text("hey, are you free for lunch tomorrow? let's do 12 if that works for you")
            .font(TickFont.bodyFunc(10))
            .foregroundStyle(.white)
            .lineSpacing(1.5)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
              RoundedRectangle(cornerRadius: 8)
                .fill(Color.blue)
            )
        }
      }
    }
  }
}

// MARK: - App Icon Drawings

struct ChatGptIcon: View {
  var body: some View {
    ZStack {
      Circle()
        .fill(Color(red: 16/255, green: 163/255, blue: 127/255))
        .frame(width: 24, height: 24)
      Image(systemName: "sparkles")
        .font(TickFont.captionFunc(11))
        .foregroundColor(.white)
    }
  }
}

struct NotionIcon: View {
  var body: some View {
    ZStack {
      Circle()
        .fill(Color.black)
        .frame(width: 24, height: 24)
      Text("N")
        .font(TickFont.display(12, weight: .black))
        .foregroundColor(.white)
    }
  }
}

struct MediumIcon: View {
  var body: some View {
    ZStack {
      Circle()
        .fill(Color.primary)
        .frame(width: 24, height: 24)
      Circle()
        .fill(Color(nsColor: .windowBackgroundColor))
        .frame(width: 12, height: 12)
    }
  }
}


// MARK: - Help Tab

struct HelpTabView: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Help & Support")
          .font(TickFont.headingFunc(20, weight: .bold))
        Text("Everything you need to know about setting up and using Tick.")
          .font(TickFont.captionFunc(13))
          .foregroundStyle(TickColor.textSecondary)
      }
      
      VStack(alignment: .leading, spacing: 16) {
        Text("POPULAR FAQS")
          .font(TickFont.headingFunc(10, weight: .bold))
          .foregroundStyle(TickColor.textSecondary)
        
        FAQRow(question: "How do I change the recording hotkey?", answer: "Go to the Settings tab in the sidebar and look for the Hotkey section. Click record and tap the desired keys.")
        FAQRow(question: "Does Tick process audio offline?", answer: "Yes, Tick processes all transcriptions completely offline on your Mac using Core ML, ensuring total privacy.")
        FAQRow(question: "Where are my audio records cached?", answer: "Tick caches models inside your application support container. Legacy files may reside in your local cache directories.")
      }
      .padding(20)
      .hexGlass(cornerRadius: 16)
      .overlay(
        RoundedRectangle(cornerRadius: 16)
          .stroke(Color.clear, lineWidth: 0)
      )
      
      VStack(alignment: .leading, spacing: 8) {
        Text("ABOUT TICK")
          .font(TickFont.headingFunc(10, weight: .bold))
          .foregroundStyle(TickColor.textSecondary)
        
        Text("Tick is a fork of [hex](https://hex.kitlangton.com) and in case of any issues contact [Deepanshu](mailto:dipxsy@duck.com).")
          .font(TickFont.captionFunc(13))
          .foregroundStyle(TickColor.textPrimary)
          .accentColor(TickColor.brand)
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
      .hexGlass(cornerRadius: 16)
      .overlay(
        RoundedRectangle(cornerRadius: 16)
          .stroke(Color.clear, lineWidth: 0)
      )
    }
  }
}

struct FAQRow: View {
  let question: String
  let answer: String
  @State private var isExpanded = false
  
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button(action: { withAnimation { isExpanded.toggle() } }) {
        HStack {
          Text(question)
            .font(TickFont.labelFunc(13, weight: .medium))
            .foregroundStyle(TickColor.textPrimary)
          Spacer()
          Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(TickFont.captionFunc(10))
            .foregroundStyle(TickColor.textSecondary)
        }
      }
      .buttonStyle(.plain)
      
      if isExpanded {
        Text(answer)
          .font(TickFont.captionFunc(12))
          .foregroundStyle(TickColor.textSecondary)
          .padding(.top, 4)
          .transition(.opacity)
      }
      
    }
  }
}

// MARK: - Custom Sidebar Toggle Glyph
//
// A small, custom-drawn icon — two thin parallel lines that subtly hint
// at a side panel. Drawn with shapes instead of an SF Symbol so it doesn't
// read as a stock macOS control. Animates smoothly between the open/closed
// states by shifting the lines outward.
// MARK: - Custom Sidebar Toggle Button
//
// Sits in the title bar area, right beside the green traffic light.
// Draws a minimal custom glyph (two thin bars) and gets a subtle hover
// background. Not a native macOS control — a small Tick-flavoured mark.

struct SidebarToggleButton: View {
  let isOpen: Bool
  let action: () -> Void
  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      ZStack {
        // Subtle hover background — a soft circle that fades in
        Circle()
          .fill(Color.primary.opacity(isHovered ? 0.07 : 0))
          .frame(width: 22, height: 22)
          .animation(.easeOut(duration: 0.15), value: isHovered)

        // The glyph: two thin vertical bars
        HStack(spacing: isOpen ? 3 : 5) {
          Capsule()
            .fill(Color.primary.opacity(0.7))
            .frame(width: 1.5, height: isOpen ? 10 : 12)
          Capsule()
            .fill(Color.primary.opacity(0.7))
            .frame(width: 1.5, height: isOpen ? 14 : 12)
        }
        .offset(x: isOpen ? 0 : -1)
      }
      .frame(width: 24, height: 24)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .animation(.spring(response: 0.32, dampingFraction: 0.78), value: isOpen)
  }
}
