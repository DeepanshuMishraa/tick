import AppKit
import ComposableArchitecture
import Foundation
import HexCore
import SwiftUI

public struct InsightsTabView: View {
  let transcripts: [Transcript]
  let wordCount: Int
  let averageWPM: Int
  let uniqueAppsCount: Int

  @Shared(.hexSettings) private var hexSettings: HexSettings
  @State private var heatmapPage = 0
  @State private var cachedWordsByDay: [Date: Int] = [:]
  @State private var cachedTranscriptsByDay: [Date: Int] = [:]
  @State private var cachedTopApps: [(name: String, words: Int)] = []
  private let monthsPerPage = 3

  public init(
    transcripts: [Transcript],
    wordCount: Int,
    averageWPM: Int,
    uniqueAppsCount: Int
  ) {
    self.transcripts = transcripts
    self.wordCount = wordCount
    self.averageWPM = averageWPM
    self.uniqueAppsCount = uniqueAppsCount
  }

  private var calendar: Calendar {
    var calendar = Calendar.autoupdatingCurrent
    calendar.firstWeekday = 1
    return calendar
  }

  private var userStartDate: Date {
    let firstTranscriptDate = transcripts.map(\.timestamp).min() ?? Date()
    return calendar.startOfDay(for: firstTranscriptDate)
  }

  private var firstActivityMonth: Date {
    calendar.date(from: calendar.dateComponents([.year, .month], from: userStartDate)) ?? userStartDate
  }

  private var currentMonth: Date {
    let today = Date()
    return calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today
  }

  private var maxHeatmapPage: Int {
    let monthsSinceStart = calendar.dateComponents([.month], from: firstActivityMonth, to: currentMonth).month ?? 0
    return max(0, monthsSinceStart / monthsPerPage)
  }

  private var visibleStartMonth: Date {
    calendar.date(byAdding: .month, value: heatmapPage * monthsPerPage, to: firstActivityMonth)
      ?? firstActivityMonth
  }

  private var visibleEndMonth: Date {
    let proposedEnd = calendar.date(byAdding: .month, value: monthsPerPage - 1, to: visibleStartMonth)
      ?? visibleStartMonth
    return min(proposedEnd, currentMonth)
  }

  private var visibleEndDate: Date {
    let nextMonth = calendar.date(byAdding: .month, value: 1, to: visibleEndMonth) ?? visibleEndMonth
    let endOfMonth = calendar.date(byAdding: .day, value: -1, to: nextMonth) ?? visibleEndMonth
    return min(endOfMonth, calendar.startOfDay(for: Date()))
  }

  private var visibleRangeLabel: String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM yyyy"
    return "\(formatter.string(from: visibleStartMonth)) – \(formatter.string(from: visibleEndMonth))"
  }

  private var wordsByDay: [Date: Int] {
    cachedWordsByDay
  }

  private var transcriptsByDay: [Date: Int] {
    cachedTranscriptsByDay
  }

  private var activeDays: Int { wordsByDay.count }

  private var averageWordsPerDay: Int {
    guard activeDays > 0 else { return 0 }
    return wordCount / activeDays
  }

  private var effectiveWPM: Int {
    averageWPM > 0 ? averageWPM : 130
  }

  private var hoursSaved: Double {
    guard wordCount > 0 else { return 0.0 }
    let typingMinutes = Double(wordCount) / 40.0
    let voiceMinutes = Double(wordCount) / Double(max(40, effectiveWPM))
    return max(0.1, (typingMinutes - voiceMinutes) / 60.0)
  }

  private var speedMultiplier: String {
    let mult = Double(max(40, effectiveWPM)) / 40.0
    return String(format: "%.1fx", mult)
  }

  private var pagesEquivalent: Int {
    max(1, wordCount / 250)
  }

  private var bestDay: (date: Date, words: Int)? {
    wordsByDay.max { lhs, rhs in
      if lhs.value == rhs.value { return lhs.key < rhs.key }
      return lhs.value < rhs.value
    }.map { (date: $0.key, words: $0.value) }
  }

  private var streaks: (current: Int, longest: Int) {
    let activeDates = Set(wordsByDay.keys)
    guard !activeDates.isEmpty else { return (0, 0) }

    let today = calendar.startOfDay(for: Date())
    var currentDate = today
    if !activeDates.contains(currentDate),
       let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
       activeDates.contains(yesterday) {
      currentDate = yesterday
    }

    var current = 0
    while activeDates.contains(currentDate) {
      current += 1
      guard let previousDate = calendar.date(byAdding: .day, value: -1, to: currentDate) else { break }
      currentDate = previousDate
    }

    let sortedDates = activeDates.sorted()
    var longest = 1
    var run = 1
    for index in 1..<sortedDates.count {
      let previousDate = sortedDates[index - 1]
      let date = sortedDates[index]
      if calendar.dateComponents([.day], from: previousDate, to: date).day == 1 {
        run += 1
        longest = max(longest, run)
      } else {
        run = 1
      }
    }

    return (current, longest)
  }

  private var heatmapWeeks: [[InsightDay]] {
    let firstWeek = calendar.dateInterval(of: .weekOfYear, for: visibleStartMonth)?.start
      ?? visibleStartMonth
    let today = calendar.startOfDay(for: Date())
    let daySpan = calendar.dateComponents([.day], from: firstWeek, to: visibleEndDate).day ?? 0
    let visibleWeekCount = max(1, daySpan / 7 + 1)

    return (0..<visibleWeekCount).map { weekIndex in
      (0..<7).compactMap { dayIndex in
        guard let date = calendar.date(byAdding: .day, value: weekIndex * 7 + dayIndex, to: firstWeek) else {
          return nil
        }
        return InsightDay(
          date: date,
          wordCount: wordsByDay[date, default: 0],
          transcriptCount: transcriptsByDay[date, default: 0],
          isUnavailable: date < userStartDate || date < visibleStartMonth || date > visibleEndDate || date > today
        )
      }
    }
  }

  private var heatmapMaxWords: Int {
    max(1, heatmapWeeks.flatMap { $0 }.map(\.wordCount).max() ?? 0)
  }

  private var weekdayTotals: [(name: String, words: Int)] {
    let names = calendar.shortWeekdaySymbols
    let totals = wordsByDay.reduce(into: Array(repeating: 0, count: 7)) { result, entry in
      let weekday = calendar.component(.weekday, from: entry.key)
      result[weekday - 1] += entry.value
    }
    return (0..<7).map { (names[$0], totals[$0]) }
  }

  private var peakWeekday: String? {
    weekdayTotals.max { $0.words < $1.words }?.name
  }

  private var topApps: [(name: String, words: Int)] {
    cachedTopApps
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      metricGrid
      efficiencyCard
      activityCard
      supportingDetails
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .onChange(of: transcripts) { _, _ in
      heatmapPage = min(heatmapPage, maxHeatmapPage)
    }
    .task(id: transcripts) {
      let snapshot = await Task.detached(priority: .userInitiated) {
        var calendar = Calendar.autoupdatingCurrent
        calendar.firstWeekday = 1
        var wordsByDay: [Date: Int] = [:]
        var transcriptsByDay: [Date: Int] = [:]
        var apps: [String: Int] = [:]

        for transcript in transcripts {
          let day = calendar.startOfDay(for: transcript.timestamp)
          let words = transcript.text.split { $0.isWhitespace }.count
          wordsByDay[day, default: 0] += words
          transcriptsByDay[day, default: 0] += 1
          let appName = transcript.sourceAppName?.isEmpty == false ? transcript.sourceAppName! : "Other apps"
          apps[appName, default: 0] += words
        }

        let sortedApps: [(name: String, words: Int)] = apps.map { entry in
          (name: entry.key, words: entry.value)
        }
        let topApps = sortedApps.sorted { lhs, rhs in
          lhs.words == rhs.words ? lhs.name < rhs.name : lhs.words > rhs.words
        }

        return (wordsByDay, transcriptsByDay, Array(topApps.prefix(5)))
      }.value

      guard !Task.isCancelled else { return }
      cachedWordsByDay = snapshot.0
      cachedTranscriptsByDay = snapshot.1
      cachedTopApps = snapshot.2
    }
  }

  // MARK: - Key Metrics Grid

  private var metricGrid: some View {
    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
      InsightMetricCard(
        label: "WORDS SPOKEN",
        value: wordCount.formatted(),
        detail: wordCount == 0 ? "No dictations yet" : "\(transcripts.count.formatted()) recordings total",
        icon: "text.word.spacing",
        badge: wordCount > 0 ? "~\(pagesEquivalent) pages" : nil
      )
      InsightMetricCard(
        label: "ACTIVE STREAK",
        value: "\(streaks.current) \(streaks.current == 1 ? "day" : "days")",
        detail: streaks.longest > 1 ? "Longest: \(streaks.longest) days" : "Daily activity",
        icon: "flame.fill",
        badge: streaks.current > 0 ? "Active" : nil
      )
      InsightMetricCard(
        label: "SPEAKING SPEED",
        value: "\(effectiveWPM) WPM",
        detail: "\(speedMultiplier) faster than typing",
        icon: "gauge.with.needle.fill",
        badge: "~40 WPM avg typing"
      )
      InsightMetricCard(
        label: "PEAK DAY",
        value: bestDay != nil ? "\(bestDay!.words.formatted())" : "—",
        detail: bestDay != nil ? shortDate(bestDay!.date) : "No daily record yet",
        icon: "trophy.fill",
        badge: bestDay != nil ? "Record" : nil
      )
    }
  }

  // MARK: - Efficiency & Velocity Comparison

  private var efficiencyCard: some View {
    HStack(alignment: .center, spacing: 24) {
      VStack(alignment: .leading, spacing: 5) {
        Text("Typing vs. Dictation Speed")
          .font(.system(size: 15, weight: .semibold, design: .default))
          .foregroundStyle(TickColor.textPrimary)

        Text(wordCount > 0 ? "Estimated \(String(format: "%.1f", hoursSaved)) hours saved compared to 40 WPM manual keyboard typing." : "Start dictating to see how much time you save over manual keyboard typing.")
          .font(.system(size: 12, weight: .regular, design: .default))
          .foregroundStyle(TickColor.textSecondary)
      }

      Spacer()

      VStack(alignment: .trailing, spacing: 8) {
        HStack(spacing: 12) {
          Text("Keyboard Typing")
            .font(.system(size: 11, weight: .regular, design: .default))
            .foregroundStyle(TickColor.textTertiary)

          Text("40 WPM")
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(TickColor.textSecondary)
            .frame(width: 58, alignment: .trailing)
        }

        HStack(spacing: 12) {
          Text("Voice Dictation")
            .font(.system(size: 11, weight: .semibold, design: .default))
            .foregroundStyle(TickColor.brand)

          Text("\(effectiveWPM) WPM")
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(TickColor.brand)
            .frame(width: 58, alignment: .trailing)
        }

        GeometryReader { proxy in
          ZStack(alignment: .leading) {
            Capsule()
              .fill(Color.primary.opacity(0.06))

            Capsule()
              .fill(
                LinearGradient(
                  colors: [TickColor.brand.opacity(0.85), TickColor.brand],
                  startPoint: .leading,
                  endPoint: .trailing
                )
              )
              .frame(width: min(proxy.size.width, proxy.size.width * CGFloat(min(1.0, Double(effectiveWPM) / 180.0))))
          }
        }
        .frame(width: 170, height: 5)
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 16)
    .hexGlass(cornerRadius: TickRadius.card, style: .regular)
  }

  // MARK: - Daily Activity Heatmap Card

  private var activityCard: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center) {
        VStack(alignment: .leading, spacing: 3) {
          Text("Daily Activity")
            .font(.system(size: 15, weight: .semibold, design: .default))
            .foregroundStyle(TickColor.textPrimary)

          Text("Overview across 3-month windows")
            .font(.system(size: 12, weight: .regular, design: .default))
            .foregroundStyle(TickColor.textSecondary)
        }

        Spacer()

        HStack(spacing: 8) {
          heatmapNavigationButton(icon: "chevron.left", isDisabled: heatmapPage == 0) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) { heatmapPage -= 1 }
          }
          Text(visibleRangeLabel)
            .font(.system(size: 12, weight: .medium, design: .default))
            .foregroundStyle(TickColor.textPrimary)
            .frame(minWidth: 120, alignment: .center)
          heatmapNavigationButton(icon: "chevron.right", isDisabled: heatmapPage >= maxHeatmapPage) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) { heatmapPage += 1 }
          }
        }
      }
      .padding(.bottom, 18)

      // Heatmap Grid
      HStack(alignment: .top, spacing: 10) {
        VStack(alignment: .leading, spacing: 5) {
          ForEach(calendar.shortWeekdaySymbols, id: \.self) { weekday in
            Text(weekday.prefix(2))
              .font(.system(size: 9, weight: .medium, design: .monospaced))
              .foregroundStyle(TickColor.textTertiary)
              .frame(width: 20, height: 18, alignment: .leading)
          }
        }
        .padding(.top, 22)

        VStack(alignment: .leading, spacing: 5) {
          HStack(spacing: 5) {
            ForEach(Array(heatmapWeeks.enumerated()), id: \.offset) { _, week in
              Text(monthLabel(for: week))
                .font(.system(size: 10, weight: .medium, design: .default))
                .foregroundStyle(TickColor.textSecondary)
                .frame(width: 18, height: 18, alignment: .leading)
            }
          }

          HStack(alignment: .top, spacing: 5) {
            ForEach(Array(heatmapWeeks.enumerated()), id: \.offset) { _, week in
              VStack(spacing: 5) {
                ForEach(week) { day in
                  InsightHeatmapCell(day: day, maximumWords: heatmapMaxWords)
                }
              }
            }
          }
        }
      }

      // Legend
      HStack(spacing: 12) {
        HStack(spacing: 5) {
          Text("Less")
            .font(.system(size: 11, weight: .regular, design: .default))
            .foregroundStyle(TickColor.textTertiary)
          ForEach([0, 1, 2, 3, 4], id: \.self) { level in
            RoundedRectangle(cornerRadius: 3)
              .fill(InsightHeatmapCell.color(for: level, theme: hexSettings.themeColor))
              .frame(width: 12, height: 12)
          }
          Text("More")
            .font(.system(size: 11, weight: .regular, design: .default))
            .foregroundStyle(TickColor.textTertiary)
        }

        Spacer()

        HStack(spacing: 14) {
          Text("🔥 \(streaks.current)d streak")
            .font(.system(size: 11, weight: .medium, design: .default))
            .foregroundStyle(TickColor.brand)
          Text("\(wordCount.formatted()) words total")
            .font(.system(size: 11, weight: .regular, design: .default))
            .foregroundStyle(TickColor.textSecondary)
        }
      }
      .padding(.top, 18)
    }
    .padding(20)
    .hexGlass(cornerRadius: TickRadius.card, style: .regular)
  }

  // MARK: - Supporting Details (Two-Column Analytics Grid)

  private var supportingDetails: some View {
    HStack(alignment: .top, spacing: 14) {
      weekdayCard
      appsCard
    }
  }

  private var weekdayCard: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("Activity by Weekday")
            .font(.system(size: 15, weight: .semibold, design: .default))
            .foregroundStyle(TickColor.textPrimary)
          Text("Word volume across days")
            .font(.system(size: 12, weight: .regular, design: .default))
            .foregroundStyle(TickColor.textSecondary)
        }
        Spacer()
        if let peak = peakWeekday {
          Text("Peak: \(peak)")
            .font(.system(size: 10, weight: .semibold, design: .default))
            .foregroundStyle(TickColor.brand)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .hexGlass(cornerRadius: 6)
        }
      }

      let maxWords = max(1, weekdayTotals.map(\.words).max() ?? 1)
      VStack(spacing: 11) {
        ForEach(Array(weekdayTotals.enumerated()), id: \.offset) { _, weekday in
          let isPeak = weekday.words == maxWords && weekday.words > 0
          HStack(spacing: 10) {
            Text(weekday.name)
              .font(.system(size: 11, weight: isPeak ? .semibold : .regular, design: .default))
              .foregroundStyle(isPeak ? TickColor.textPrimary : TickColor.textSecondary)
              .frame(width: 32, alignment: .leading)

            GeometryReader { geometry in
              ZStack(alignment: .leading) {
                Capsule()
                  .fill(Color.primary.opacity(0.04))

                Capsule()
                  .fill(
                    LinearGradient(
                      colors: isPeak
                        ? [TickColor.brand, TickColor.brand.opacity(0.70)]
                        : [TickColor.brand.opacity(0.50), TickColor.brand.opacity(0.25)],
                      startPoint: .leading,
                      endPoint: .trailing
                    )
                  )
                  .frame(width: max(4, geometry.size.width * CGFloat(weekday.words) / CGFloat(maxWords)))
              }
            }
            .frame(height: 6)

            Text(weekday.words.formatted())
              .font(.system(size: 10, weight: .regular, design: .monospaced))
              .foregroundStyle(isPeak ? TickColor.brand : TickColor.textTertiary)
              .frame(width: 44, alignment: .trailing)
          }
        }
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .hexGlass(cornerRadius: TickRadius.card, style: .regular)
  }

  private var appsCard: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("Top Applications")
            .font(.system(size: 15, weight: .semibold, design: .default))
            .foregroundStyle(TickColor.textPrimary)
          Text("Voice activity distribution")
            .font(.system(size: 12, weight: .regular, design: .default))
            .foregroundStyle(TickColor.textSecondary)
        }
        Spacer()
        Text("\(uniqueAppsCount) \(uniqueAppsCount == 1 ? "app" : "apps")")
          .font(.system(size: 10, weight: .semibold, design: .default))
          .foregroundStyle(TickColor.textTertiary)
          .padding(.horizontal, 7)
          .padding(.vertical, 2.5)
          .hexGlass(cornerRadius: 6)
      }

      if topApps.isEmpty {
        VStack(spacing: 10) {
          Spacer()
          Image(systemName: "app.connected.to.app.below.fill")
            .font(.system(size: 24))
            .foregroundStyle(TickColor.textTertiary.opacity(0.5))
          Text("Application breakdown will appear as you dictate across macOS apps.")
            .font(.system(size: 12, weight: .regular, design: .default))
            .foregroundStyle(TickColor.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
          Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 150)
      } else {
        let maxAppWords = max(1, topApps.map(\.words).max() ?? 1)
        let totalAppWords = max(1, topApps.reduce(0) { $0 + $1.words })

        VStack(spacing: 13) {
          ForEach(Array(topApps.enumerated()), id: \.offset) { index, app in
            let percentage = Int(round(Double(app.words) / Double(totalAppWords) * 100.0))
            VStack(spacing: 4) {
              HStack(spacing: 8) {
                AppIconBadge(appName: app.name)

                Text(app.name)
                  .font(.system(size: 12, weight: .medium, design: .default))
                  .foregroundStyle(TickColor.textPrimary)
                  .lineLimit(1)

                Spacer(minLength: 4)

                Text("\(percentage)%")
                  .font(.system(size: 10, weight: .semibold, design: .monospaced))
                  .foregroundStyle(TickColor.brand)
                  .padding(.horizontal, 5)
                  .padding(.vertical, 1.5)
                  .background(TickColor.brand.opacity(0.10))
                  .cornerRadius(4)

                Text("\(app.words.formatted()) words")
                  .font(.system(size: 10, weight: .regular, design: .monospaced))
                  .foregroundStyle(TickColor.textTertiary)
                  .frame(minWidth: 65, alignment: .trailing)
              }

              GeometryReader { proxy in
                ZStack(alignment: .leading) {
                  Capsule()
                    .fill(Color.primary.opacity(0.04))

                  Capsule()
                    .fill(
                      LinearGradient(
                        colors: index == 0
                          ? [TickColor.brand, TickColor.brand.opacity(0.70)]
                          : [TickColor.brand.opacity(0.50), TickColor.brand.opacity(0.25)],
                        startPoint: .leading,
                        endPoint: .trailing
                      )
                    )
                    .frame(width: max(4, proxy.size.width * CGFloat(app.words) / CGFloat(maxAppWords)))
                }
              }
              .frame(height: 4)
            }
          }
        }
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .hexGlass(cornerRadius: TickRadius.card, style: .regular)
  }

  // MARK: - Helpers

  private func monthLabel(for date: Date?) -> String {
    guard let date else { return "" }
    let month = calendar.component(.month, from: date)
    return calendar.shortMonthSymbols[month - 1]
  }

  private func monthLabel(for week: [InsightDay]) -> String {
    guard let monthStart = week.first(where: { day in
      calendar.component(.day, from: day.date) == 1 &&
      day.date >= visibleStartMonth && day.date <= visibleEndMonth
    })?.date else {
      return ""
    }
    return monthLabel(for: monthStart)
  }

  private func heatmapNavigationButton(
    icon: String,
    isDisabled: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(isDisabled ? TickColor.textTertiary.opacity(0.30) : TickColor.textPrimary)
        .frame(width: 24, height: 24)
        .hexGlass(cornerRadius: 6, interactive: !isDisabled)
    }
    .buttonStyle(.plain)
    .disabled(isDisabled)
  }

  private func shortDate(_ date: Date) -> String {
    date.formatted(.dateTime.month(.abbreviated).day())
  }
}

// MARK: - Components

private struct InsightDay: Identifiable {
  let date: Date
  let wordCount: Int
  let transcriptCount: Int
  let isUnavailable: Bool

  var id: Date { date }
}

private struct InsightMetricCard: View {
  let label: String
  let value: String
  let detail: String
  let icon: String
  var badge: String? = nil

  @State private var isHovered = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(label)
          .font(.system(size: 10, weight: .semibold, design: .default))
          .tracking(0.6)
          .foregroundStyle(TickColor.textTertiary)

        Spacer()

        ZStack {
          Circle()
            .fill(TickColor.brand.opacity(0.10))
            .frame(width: 22, height: 22)
          Image(systemName: icon)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(TickColor.brand)
        }
      }

      Text(value)
        .font(.system(size: 24, weight: .bold, design: .default))
        .foregroundStyle(TickColor.textPrimary)
        .lineLimit(1)
        .minimumScaleFactor(0.85)

      Text(detail)
        .font(.system(size: 11, weight: .regular, design: .default))
        .foregroundStyle(TickColor.textSecondary)
        .lineLimit(1)

      if let badge {
        Text(badge)
          .font(.system(size: 9, weight: .medium, design: .monospaced))
          .foregroundStyle(TickColor.brand)
          .padding(.horizontal, 5)
          .padding(.vertical, 2)
          .background(TickColor.brand.opacity(0.08))
          .cornerRadius(4)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, minHeight: 116, alignment: .leading)
    .hexGlass(cornerRadius: TickRadius.card, style: .regular)
    .scaleEffect(isHovered ? 1.015 : 1.0)
    .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isHovered)
    .onHover { isHovered = $0 }
  }
}

private struct InsightHeatmapCell: View {
  let day: InsightDay
  let maximumWords: Int
  @Shared(.hexSettings) private var hexSettings: HexSettings
  @State private var isHovered = false

  private var level: Int {
    guard day.wordCount > 0 else { return 0 }
    let ratio = Double(day.wordCount) / Double(maximumWords)
    switch ratio {
    case 0.75...: return 4
    case 0.5...: return 3
    case 0.25...: return 2
    default: return 1
    }
  }

  private var tooltipText: String {
    guard !day.isUnavailable else { return "No recordings" }
    let transcriptLabel = day.transcriptCount == 1 ? "transcript" : "transcripts"
    let date = day.date.formatted(.dateTime.month(.abbreviated).day().year())
    return "\(day.wordCount.formatted()) words · \(day.transcriptCount) \(transcriptLabel) on \(date)"
  }

  var body: some View {
    RoundedRectangle(cornerRadius: 3)
      .fill(day.isUnavailable ? TickColor.canvas.opacity(0.30) : Self.color(for: level, theme: hexSettings.themeColor))
      .frame(width: 17, height: 17)
      .overlay(
        RoundedRectangle(cornerRadius: 3)
          .stroke(isHovered ? Color.white.opacity(0.40) : Color.clear, lineWidth: 0.75)
      )
      .scaleEffect(isHovered ? 1.20 : 1.0)
      .animation(.spring(response: 0.2, dampingFraction: 0.75), value: isHovered)
      .contentShape(Rectangle())
      .onHover { isHovered = $0 }
      .help(tooltipText)
      .accessibilityLabel(Text(day.isUnavailable ? "No data available" : "\(day.wordCount) words on \(day.date.formatted(date: .abbreviated, time: .omitted))"))
  }

  static func color(for level: Int, theme: HexThemeColor) -> Color {
    switch theme {
    case .monochrome:
      switch level {
      case 4: return Color.white.opacity(0.90)
      case 3: return Color.white.opacity(0.65)
      case 2: return Color.white.opacity(0.40)
      case 1: return Color.white.opacity(0.20)
      default: return TickColor.canvas
      }
    case .multicolor:
      switch level {
      case 4: return Color.cyan
      case 3: return Color.purple.opacity(0.85)
      case 2: return Color.pink.opacity(0.70)
      case 1: return Color.orange.opacity(0.45)
      default: return TickColor.canvas
      }
    default:
      let accent = theme.swatchColor
      switch level {
      case 4: return accent
      case 3: return accent.opacity(0.78)
      case 2: return accent.opacity(0.55)
      case 1: return accent.opacity(0.28)
      default: return TickColor.canvas
      }
    }
  }
}

private struct AppIconBadge: View {
  let appName: String

  private var appIcon: NSImage? {
    if let running = NSRunningApplication.runningApplications(withBundleIdentifier: appName).first {
      return running.icon
    }
    if let workspaceApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appName) {
      return NSWorkspace.shared.icon(forFile: workspaceApp.path)
    }
    return nil
  }

  var body: some View {
    Group {
      if let icon = appIcon {
        Image(nsImage: icon)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 16, height: 16)
          .cornerRadius(3.5)
      } else {
        ZStack {
          RoundedRectangle(cornerRadius: 3.5)
            .fill(TickColor.brand.opacity(0.15))
            .frame(width: 16, height: 16)
          Image(systemName: "app.fill")
            .font(.system(size: 9))
            .foregroundStyle(TickColor.brand)
        }
      }
    }
  }
}
