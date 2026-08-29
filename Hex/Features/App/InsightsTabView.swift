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
  @State private var hoveredDay: InsightDay? = nil
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
    VStack(alignment: .leading, spacing: 22) {
      pageHero
      productivityPowerBanner
      metricGrid
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

  // MARK: - Hero Header

  private var pageHero: some View {
    HStack(alignment: .bottom) {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          TickEyebrow(text: "INSIGHTS & MOMENTUM")
          Circle()
            .fill(TickColor.brand)
            .frame(width: 4, height: 4)
          Text("LIVE")
            .font(TickFont.mono(9))
            .foregroundStyle(TickColor.brand)
        }
        
        HStack(spacing: 7) {
          Text("Your voice, in")
            .font(TickFont.display(32, weight: .semibold))
          Text("momentum.")
            .font(TickFont.displayItalic(32))
            .foregroundStyle(TickColor.brand)
        }
        .foregroundStyle(TickColor.textPrimary)

        Text("A crystalline overview of your voice productivity, speech speed, and writing cadence.")
          .font(TickFont.bodyFunc(13))
          .foregroundStyle(TickColor.textSecondary)
      }

      Spacer()

      // Quick momentum badges
      HStack(spacing: 8) {
        HStack(spacing: 5) {
          Text("🔥")
            .font(.system(size: 12))
          Text("\(streaks.current)d streak")
            .font(TickFont.labelFunc(12, weight: .semibold))
            .foregroundStyle(TickColor.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .hexGlass(cornerRadius: 10, interactive: true)

        HStack(spacing: 5) {
          Image(systemName: "bolt.fill")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(TickColor.brand)
          Text("\(effectiveWPM) WPM")
            .font(TickFont.labelFunc(12, weight: .semibold))
            .foregroundStyle(TickColor.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .hexGlass(cornerRadius: 10, interactive: true)
      }
    }
  }

  // MARK: - Productivity Power Banner

  private var productivityPowerBanner: some View {
    HStack(spacing: 20) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Image(systemName: "sparkles")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(TickColor.brand)
          Text("VOICE VELOCITY GAIN")
            .font(TickFont.eyebrow)
            .foregroundStyle(TickColor.brand)
        }

        Text(wordCount > 0 ? "\(String(format: "%.1f", hoursSaved)) hours reclaimed" : "Ready for takeoff")
          .font(TickFont.headingFunc(22, weight: .bold))
          .foregroundStyle(TickColor.textPrimary)

        Text(wordCount > 0 ? "You dictate at \(speedMultiplier) the speed of typing (~40 WPM). Equivalent to writing ~\(pagesEquivalent) full pages." : "Speak anywhere with your hotkey to start tracking your time saved.")
          .font(TickFont.captionFunc(12))
          .foregroundStyle(TickColor.textSecondary)
      }

      Spacer()

      // Velocity Comparison Metric Bars
      VStack(alignment: .trailing, spacing: 8) {
        HStack(spacing: 10) {
          Text("Keyboard Typing")
            .font(TickFont.captionFunc(11))
            .foregroundStyle(TickColor.textTertiary)
          Text("40 WPM")
            .font(TickFont.mono(11))
            .foregroundStyle(TickColor.textSecondary)
            .frame(width: 55, alignment: .trailing)
        }

        HStack(spacing: 10) {
          Text("Tick Dictation")
            .font(TickFont.labelFunc(11, weight: .semibold))
            .foregroundStyle(TickColor.brand)
          Text("\(effectiveWPM) WPM")
            .font(TickFont.mono(11))
            .foregroundStyle(TickColor.brand)
            .frame(width: 55, alignment: .trailing)
        }

        // Relative speed bar
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
        .frame(width: 160, height: 5)
      }
    }
    .padding(20)
    .hexGlass(cornerRadius: TickRadius.card, style: .regular)
  }

  // MARK: - Key Metrics Grid

  private var metricGrid: some View {
    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
      InsightMetricCard(
        label: "WORDS DICTATED",
        value: wordCount.formatted(),
        detail: wordCount == 0 ? "Your first words are waiting." : "Across \(transcripts.count.formatted()) dictation sessions.",
        icon: "text.quote",
        badgeText: wordCount > 0 ? "~\(pagesEquivalent) pages" : nil
      )
      InsightMetricCard(
        label: "ACTIVE RHYTHM",
        value: "\(activeDays.formatted()) \(activeDays == 1 ? "day" : "days")",
        detail: streaks.current > 0 ? "Current streak: \(streaks.current) days." : "Start your daily flow today.",
        icon: "flame.fill",
        badgeText: streaks.longest > 1 ? "Best: \(streaks.longest)d" : nil
      )
      InsightMetricCard(
        label: "AVERAGE PACE",
        value: "\(averageWordsPerDay.formatted()) / day",
        detail: activeDays == 0 ? "No daily cadence yet." : "Average output on active days.",
        icon: "chart.bar.xaxis",
        badgeText: "\(speedMultiplier) typing"
      )
      InsightMetricCard(
        label: "ALL-TIME RECORD",
        value: bestDay?.words.formatted() ?? "—",
        detail: bestDay.map { "Words recorded on \(shortDate($0.date))." } ?? "Your biggest session awaits.",
        icon: "trophy.fill",
        badgeText: bestDay != nil ? "Personal best" : nil
      )
    }
  }

  // MARK: - Dictation Rhythm Heatmap Card

  private var activityCard: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center) {
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 8) {
            Text("Dictation Rhythm")
              .font(TickFont.headingFunc(18, weight: .semibold))
              .foregroundStyle(TickColor.textPrimary)
            
            Text("3-Month Window")
              .font(TickFont.captionFunc(10))
              .foregroundStyle(TickColor.brand)
              .padding(.horizontal, 7)
              .padding(.vertical, 2.5)
              .hexGlass(cornerRadius: 6)
          }

          Text("Your voice momentum day by day across the quarter")
            .font(TickFont.captionFunc(12))
            .foregroundStyle(TickColor.textSecondary)
        }

        Spacer()

        HStack(spacing: 8) {
          heatmapNavigationButton(icon: "chevron.left", isDisabled: heatmapPage == 0) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) { heatmapPage -= 1 }
          }
          Text(visibleRangeLabel)
            .font(TickFont.labelFunc(12, weight: .semibold))
            .foregroundStyle(TickColor.textPrimary)
            .frame(minWidth: 125, alignment: .center)
          heatmapNavigationButton(icon: "chevron.right", isDisabled: heatmapPage >= maxHeatmapPage) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) { heatmapPage += 1 }
          }
        }
      }
      .padding(.bottom, 20)

      // Heatmap Grid
      HStack(alignment: .top, spacing: 10) {
        VStack(alignment: .leading, spacing: 5) {
          ForEach(calendar.shortWeekdaySymbols, id: \.self) { weekday in
            Text(weekday.prefix(2))
              .font(TickFont.mono(9))
              .foregroundStyle(TickColor.textTertiary)
              .frame(width: 22, height: 18, alignment: .leading)
          }
        }
        .padding(.top, 22)

        VStack(alignment: .leading, spacing: 5) {
          HStack(spacing: 5) {
            ForEach(Array(heatmapWeeks.enumerated()), id: \.offset) { _, week in
              Text(monthLabel(for: week))
                .font(TickFont.captionFunc(10, weight: .medium))
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

      // Legend and Micro-Stats
      HStack(spacing: 12) {
        HStack(spacing: 6) {
          Text("Less")
            .font(TickFont.captionFunc(11))
            .foregroundStyle(TickColor.textTertiary)
          ForEach([0, 1, 2, 3, 4], id: \.self) { level in
            RoundedRectangle(cornerRadius: 3.5)
              .fill(InsightHeatmapCell.color(for: level, theme: hexSettings.themeColor))
              .frame(width: 13, height: 13)
          }
          Text("More")
            .font(TickFont.captionFunc(11))
            .foregroundStyle(TickColor.textTertiary)
        }

        Spacer()

        HStack(spacing: 14) {
          Text("🔥 \(streaks.current) day streak")
            .font(TickFont.captionFunc(11))
            .foregroundStyle(TickColor.brand)
          Text("⚡️ \(effectiveWPM) WPM average")
            .font(TickFont.captionFunc(11))
            .foregroundStyle(TickColor.textSecondary)
          Text("🏆 Longest: \(streaks.longest) days")
            .font(TickFont.captionFunc(11))
            .foregroundStyle(TickColor.textTertiary)
        }
      }
      .padding(.top, 20)
    }
    .padding(22)
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
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("When you flow")
            .font(TickFont.headingFunc(17, weight: .semibold))
            .foregroundStyle(TickColor.textPrimary)
          Text("Word volume by day of the week")
            .font(TickFont.captionFunc(12))
            .foregroundStyle(TickColor.textSecondary)
        }
        Spacer()
        if let peak = peakWeekday {
          Text("Peak: \(peak)")
            .font(TickFont.captionFunc(10, weight: .semibold))
            .foregroundStyle(TickColor.brand)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .hexGlass(cornerRadius: 6)
        }
      }

      let maxWords = max(1, weekdayTotals.map(\.words).max() ?? 1)
      VStack(spacing: 12) {
        ForEach(Array(weekdayTotals.enumerated()), id: \.offset) { _, weekday in
          let isPeak = weekday.words == maxWords && weekday.words > 0
          HStack(spacing: 10) {
            Text(weekday.name)
              .font(TickFont.labelFunc(11, weight: isPeak ? .semibold : .regular))
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
                        : [TickColor.brand.opacity(0.55), TickColor.brand.opacity(0.30)],
                      startPoint: .leading,
                      endPoint: .trailing
                    )
                  )
                  .frame(width: max(4, geometry.size.width * CGFloat(weekday.words) / CGFloat(maxWords)))
              }
            }
            .frame(height: 7)

            Text(weekday.words.formatted())
              .font(TickFont.mono(10))
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
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("Where you flow")
            .font(TickFont.headingFunc(17, weight: .semibold))
            .foregroundStyle(TickColor.textPrimary)
          Text("Distribution across applications")
            .font(TickFont.captionFunc(12))
            .foregroundStyle(TickColor.textSecondary)
        }
        Spacer()
        Text("\(uniqueAppsCount) \(uniqueAppsCount == 1 ? "app" : "apps") active")
          .font(TickFont.captionFunc(10, weight: .semibold))
          .foregroundStyle(TickColor.textTertiary)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .hexGlass(cornerRadius: 6)
      }

      if topApps.isEmpty {
        VStack(spacing: 12) {
          Spacer()
          Image(systemName: "app.connected.to.app.below.fill")
            .font(.system(size: 26))
            .foregroundStyle(TickColor.textTertiary.opacity(0.6))
          Text("Your app voice distribution will appear as you dictate across macOS apps.")
            .font(TickFont.captionFunc(12))
            .foregroundStyle(TickColor.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
          Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 160)
      } else {
        let maxAppWords = max(1, topApps.map(\.words).max() ?? 1)
        let totalAppWords = max(1, topApps.reduce(0) { $0 + $1.words })

        VStack(spacing: 14) {
          ForEach(Array(topApps.enumerated()), id: \.offset) { index, app in
            let percentage = Int(round(Double(app.words) / Double(totalAppWords) * 100.0))
            VStack(spacing: 5) {
              HStack(spacing: 8) {
                AppIconBadge(appName: app.name)

                Text(app.name)
                  .font(TickFont.labelFunc(12, weight: .medium))
                  .foregroundStyle(TickColor.textPrimary)
                  .lineLimit(1)

                Spacer(minLength: 4)

                Text("\(percentage)%")
                  .font(TickFont.mono(10))
                  .foregroundStyle(TickColor.brand)
                  .padding(.horizontal, 5)
                  .padding(.vertical, 1.5)
                  .background(TickColor.brand.opacity(0.12))
                  .cornerRadius(4)

                Text("\(app.words.formatted()) words")
                  .font(TickFont.mono(10))
                  .foregroundStyle(TickColor.textTertiary)
                  .frame(minWidth: 70, alignment: .trailing)
              }

              GeometryReader { proxy in
                ZStack(alignment: .leading) {
                  Capsule()
                    .fill(Color.primary.opacity(0.04))

                  Capsule()
                    .fill(
                      LinearGradient(
                        colors: index == 0
                          ? [TickColor.brand, TickColor.brand.opacity(0.75)]
                          : [TickColor.brand.opacity(0.60), TickColor.brand.opacity(0.35)],
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
        .font(TickFont.captionFunc(10, weight: .bold))
        .foregroundStyle(isDisabled ? TickColor.textTertiary.opacity(0.30) : TickColor.textPrimary)
        .frame(width: 26, height: 26)
        .hexGlass(cornerRadius: 8, interactive: !isDisabled)
    }
    .buttonStyle(.plain)
    .disabled(isDisabled)
    .help(isDisabled ? "No more data" : icon == "chevron.left" ? "Previous 3 months" : "Next 3 months")
  }

  private func shortDate(_ date: Date) -> String {
    date.formatted(.dateTime.month(.abbreviated).day())
  }
}

// MARK: - Insight Data Types & Component Views

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
  var badgeText: String? = nil

  @State private var isHovered = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(label)
          .font(TickFont.eyebrow)
          .tracking(0.8)
          .foregroundStyle(TickColor.textTertiary)

        Spacer()

        ZStack {
          Circle()
            .fill(TickColor.brand.opacity(0.12))
            .frame(width: 24, height: 24)
          Image(systemName: icon)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(TickColor.brand)
        }
      }

      Text(value)
        .font(TickFont.display(26, weight: .bold))
        .foregroundStyle(TickColor.textPrimary)
        .lineLimit(1)
        .minimumScaleFactor(0.85)

      Text(detail)
        .font(TickFont.captionFunc(11))
        .foregroundStyle(TickColor.textSecondary)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)

      if let badgeText {
        Text(badgeText)
          .font(TickFont.mono(9))
          .foregroundStyle(TickColor.brand)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(TickColor.brand.opacity(0.10))
          .cornerRadius(4)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, minHeight: 128, alignment: .leading)
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
    guard !day.isUnavailable else { return "No data recorded" }
    let transcriptLabel = day.transcriptCount == 1 ? "transcript" : "transcripts"
    let date = day.date.formatted(.dateTime.month(.abbreviated).day().year())
    return "\(day.wordCount.formatted()) words · \(day.transcriptCount) \(transcriptLabel) on \(date)"
  }

  var body: some View {
    RoundedRectangle(cornerRadius: 3.5)
      .fill(day.isUnavailable ? TickColor.canvas.opacity(0.30) : Self.color(for: level, theme: hexSettings.themeColor))
      .frame(width: 18, height: 18)
      .overlay(
        RoundedRectangle(cornerRadius: 3.5)
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
