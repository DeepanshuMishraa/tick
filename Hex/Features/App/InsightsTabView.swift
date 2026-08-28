import Foundation
import HexCore
import SwiftUI

struct InsightsTabView: View {
  let transcripts: [Transcript]
  let wordCount: Int
  let averageWPM: Int
  let uniqueAppsCount: Int

  @State private var heatmapPage = 0
  @State private var cachedWordsByDay: [Date: Int] = [:]
  @State private var cachedTranscriptsByDay: [Date: Int] = [:]
  @State private var cachedTopApps: [(name: String, words: Int)] = []
  private let monthsPerPage = 3

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

  private var topApps: [(name: String, words: Int)] {
    cachedTopApps
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      pageIntro
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

        return (wordsByDay, transcriptsByDay, Array(topApps.prefix(4)))
      }.value

      guard !Task.isCancelled else { return }
      cachedWordsByDay = snapshot.0
      cachedTranscriptsByDay = snapshot.1
      cachedTopApps = snapshot.2
    }
  }

  private var pageIntro: some View {
    VStack(alignment: .leading, spacing: 6) {
      TickEyebrow(text: "Insights")
      HStack(spacing: 6) {
        Text("Your words, in")
          .font(TickFont.display(30, weight: .medium))
        Text("motion.")
          .font(TickFont.displayItalic(30))
          .foregroundStyle(TickColor.brand)
      }
      .foregroundStyle(TickColor.textPrimary)

      Text("A quiet view of how your voice becomes momentum.")
        .font(TickFont.bodyFunc(14))
        .foregroundStyle(TickColor.textSecondary)
    }
  }

  private var metricGrid: some View {
    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
      InsightMetricCard(
        label: "WORDS DICTATED",
        value: wordCount.formatted(),
        detail: wordCount == 0 ? "Your first words are waiting." : "Across all your transcripts.",
        icon: "text.quote"
      )
      InsightMetricCard(
        label: "ACTIVE DAYS",
        value: activeDays.formatted(),
        detail: activeDays == 0 ? "Start a rhythm today." : "Days with at least one transcript.",
        icon: "calendar"
      )
      InsightMetricCard(
        label: "AVERAGE / DAY",
        value: averageWordsPerDay.formatted(),
        detail: activeDays == 0 ? "No daily average yet." : "Words on an active day.",
        icon: "chart.bar"
      )
      InsightMetricCard(
        label: "BEST DAY",
        value: bestDay?.words.formatted() ?? "—",
        detail: bestDay.map { "Words on \(shortDate($0.date))." } ?? "Your biggest day will appear here.",
        icon: "sparkles"
      )
    }
  }

  private var activityCard: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 5) {
          Text("Dictation rhythm")
            .font(TickFont.headingFunc(18, weight: .semibold))
            .foregroundStyle(TickColor.textPrimary)
          Text("Three months at a time, day by day")
            .font(TickFont.caption)
            .foregroundStyle(TickColor.textSecondary)
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 3) {
          HStack(spacing: 6) {
            heatmapNavigationButton(icon: "chevron.left", isDisabled: heatmapPage == 0) {
              withAnimation(.easeInOut(duration: 0.2)) { heatmapPage -= 1 }
            }
            Text(visibleRangeLabel)
              .font(TickFont.labelFunc(12, weight: .medium))
              .foregroundStyle(TickColor.textPrimary)
              .frame(minWidth: 112)
            heatmapNavigationButton(icon: "chevron.right", isDisabled: heatmapPage >= maxHeatmapPage) {
              withAnimation(.easeInOut(duration: 0.2)) { heatmapPage += 1 }
            }
          }
          .accessibilityElement(children: .contain)
          .accessibilityLabel("Heat map period")
          .accessibilityValue(visibleRangeLabel)
          Text("\(streaks.current) day streak · \(averageWPM) WPM")
            .font(TickFont.caption)
            .foregroundStyle(TickColor.brand)
          Text("Longest \(streaks.longest) days")
            .font(TickFont.caption)
            .foregroundStyle(TickColor.textTertiary)
        }
      }

        .padding(.vertical, 18)

      HStack(alignment: .top, spacing: 10) {
        VStack(alignment: .leading, spacing: 5) {
          ForEach(calendar.shortWeekdaySymbols, id: \.self) { weekday in
            Text(weekday)
              .font(TickFont.captionFunc(10))
              .foregroundStyle(TickColor.textTertiary)
              .frame(width: 26, height: 18, alignment: .leading)
          }
        }
        .padding(.top, 22)

        VStack(alignment: .leading, spacing: 5) {
          HStack(spacing: 5) {
            ForEach(Array(heatmapWeeks.enumerated()), id: \.offset) { _, week in
              Text(monthLabel(for: week))
                .font(TickFont.captionFunc(10))
                .foregroundStyle(TickColor.textTertiary)
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

      HStack(spacing: 7) {
        Text("Less")
          .font(TickFont.caption)
          .foregroundStyle(TickColor.textTertiary)
        ForEach([0, 1, 2, 3, 4], id: \.self) { level in
          RoundedRectangle(cornerRadius: 4)
            .fill(InsightHeatmapCell.color(for: level))
            .frame(width: 15, height: 15)
        }
        Text("More")
          .font(TickFont.caption)
          .foregroundStyle(TickColor.textTertiary)
        Spacer()
        Text("Hover a day for details")
          .font(TickFont.caption)
          .foregroundStyle(TickColor.textTertiary)
      }
      .padding(.top, 18)
    }
    .padding(20)
    .hexGlass(cornerRadius: TickRadius.card, style: .regular)
  }

  private var supportingDetails: some View {
    HStack(alignment: .top, spacing: 12) {
      weekdayCard
      appsCard
    }
  }

  private var weekdayCard: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 5) {
        Text("When you flow")
          .font(TickFont.headingFunc(17, weight: .semibold))
          .foregroundStyle(TickColor.textPrimary)
        Text("Your strongest days of the week")
          .font(TickFont.caption)
          .foregroundStyle(TickColor.textSecondary)
      }

      VStack(spacing: 11) {
        ForEach(Array(weekdayTotals.enumerated()), id: \.offset) { _, weekday in
          HStack(spacing: 10) {
            Text(weekday.name)
              .font(TickFont.captionFunc(11))
              .foregroundStyle(TickColor.textSecondary)
              .frame(width: 30, alignment: .leading)
            GeometryReader { geometry in
              RoundedRectangle(cornerRadius: 4)
                .fill(TickColor.brand.opacity(0.78))
                .frame(width: weekdayBarWidth(for: weekday.words, in: geometry.size.width), height: 8)
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 12)
            Text(weekday.words.formatted())
              .font(TickFont.mono(10))
              .foregroundStyle(TickColor.textTertiary)
              .frame(width: 42, alignment: .trailing)
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
      VStack(alignment: .leading, spacing: 5) {
        Text("Where you flow")
          .font(TickFont.headingFunc(17, weight: .semibold))
          .foregroundStyle(TickColor.textPrimary)
        Text("Words by app · \(uniqueAppsCount) \(uniqueAppsCount == 1 ? "app" : "apps")")
          .font(TickFont.caption)
          .foregroundStyle(TickColor.textSecondary)
      }

      if topApps.isEmpty {
        VStack(alignment: .leading, spacing: 5) {
          Image(systemName: "rectangle.stack.badge.plus")
            .foregroundStyle(TickColor.textTertiary)
          Text("Your app patterns will appear after you dictate.")
            .font(TickFont.caption)
            .foregroundStyle(TickColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        let maxAppWords = max(1, topApps.map { $0.words }.max() ?? 1)
        VStack(spacing: 14) {
          ForEach(Array(topApps.enumerated()), id: \.offset) { _, app in
            HStack(spacing: 10) {
              Image(systemName: "rectangle.inset.filled")
                .font(TickFont.captionFunc(11))
                .foregroundStyle(TickColor.brand)
                .frame(width: 18)
              Text(app.name)
                .font(TickFont.labelFunc(12))
                .foregroundStyle(TickColor.textPrimary)
                .lineLimit(1)
              Spacer(minLength: 4)
              Text(app.words.formatted())
                .font(TickFont.mono(10))
                .foregroundStyle(TickColor.textTertiary)
            }
            .overlay(alignment: .bottomLeading) {
              GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 2)
                  .fill(TickColor.brandSoft)
                  .frame(height: 3)
                  .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                      .fill(TickColor.brand)
                      .frame(width: geometry.size.width * CGFloat(app.words) / CGFloat(maxAppWords), height: 3)
                  }
              }
              .frame(height: 3)
              .offset(y: 7)
            }
          }
        }
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .hexGlass(cornerRadius: TickRadius.card, style: .regular)
  }

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
        .font(TickFont.captionFunc(11, weight: .semibold))
        .foregroundStyle(isDisabled ? TickColor.textTertiary.opacity(0.35) : TickColor.textSecondary)
        .frame(width: 24, height: 24)
        .hexGlass(cornerRadius: 6, interactive: true)
    }
    .buttonStyle(.plain)
    .disabled(isDisabled)
    .help(isDisabled ? "No more data in this direction" : icon == "chevron.left" ? "Show earlier months" : "Show later months")
  }

  private func shortDate(_ date: Date) -> String {
    date.formatted(.dateTime.month(.abbreviated).day())
  }

  private func weekdayBarWidth(for words: Int, in width: CGFloat) -> CGFloat {
    let maximum = max(1, weekdayTotals.map { $0.words }.max() ?? 1)
    guard words > 0 else { return 0 }
    return max(5, width * CGFloat(words) / CGFloat(maximum))
  }
}

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

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(label)
          .font(TickFont.eyebrow)
          .tracking(0.7)
          .foregroundStyle(TickColor.textTertiary)
        Spacer()
        Image(systemName: icon)
          .font(TickFont.captionFunc(12))
          .foregroundStyle(TickColor.brand)
      }
      Text(value)
        .font(TickFont.display(25))
        .foregroundStyle(TickColor.textPrimary)
      Text(detail)
        .font(TickFont.caption)
        .foregroundStyle(TickColor.textSecondary)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(16)
    .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
    .hexGlass(cornerRadius: TickRadius.card, style: .regular)
  }
}

private struct InsightHeatmapCell: View {
  let day: InsightDay
  let maximumWords: Int
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
    guard !day.isUnavailable else { return "No data available" }
    let transcriptLabel = day.transcriptCount == 1 ? "transcript" : "transcripts"
    let date = day.date.formatted(.dateTime.month(.abbreviated).day().year())
    return "\(day.wordCount.formatted()) words · \(day.transcriptCount) \(transcriptLabel) · \(date)"
  }

  var body: some View {
    RoundedRectangle(cornerRadius: 4)
      .fill(day.isUnavailable ? TickColor.canvas.opacity(0.35) : Self.color(for: level))
      .frame(width: 18, height: 18)
      .overlay(
        RoundedRectangle(cornerRadius: 4)
          .stroke(Color.clear, lineWidth: 0)
      )
      .contentShape(Rectangle())
      .onHover { isHovered = $0 }
      .help(tooltipText)
      .accessibilityLabel(Text(day.isUnavailable ? "No data available" : "\(day.wordCount) words on \(day.date.formatted(date: .abbreviated, time: .omitted))"))
  }

  static func color(for level: Int) -> Color {
    switch level {
    case 4: return TickColor.brand
    case 3: return TickColor.brand.opacity(0.78)
    case 2: return TickColor.brandMid.opacity(0.75)
    case 1: return TickColor.brandSoft
    default: return TickColor.canvas
    }
  }
}
