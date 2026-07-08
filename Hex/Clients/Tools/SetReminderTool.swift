//
//  SetReminderTool.swift
//  Hex
//

import EventKit
import Foundation

/// Creates a time-based reminder in macOS Reminders.
enum SetReminderTool {
	struct Input: Codable, Sendable {
		let text: String
		let time: String
		let date: String?
	}

	static let definition = ToolDefinition<Input>(
		id: "set_reminder",
		displayName: "Set Reminder",
		description: "Create a time-based reminder with an alarm. Use when the user says 'remind me to... at [time]' or 'set a reminder for [time]'.",
		parameterSchema: [
			"type": "object",
			"properties": [
				"text": ["type": "string", "description": "The reminder text"],
				"time": ["type": "string", "description": "When, e.g. '5pm', 'in 30 minutes', 'tomorrow at 9am'"],
				"date": ["type": "string", "description": "Optional date"],
			],
			"required": ["text", "time"],
		],
		execute: { input in
			let store = try await RemindersHelper.createAuthorizedStore()

			guard let calendar = RemindersHelper.findCalendar(in: store) else {
				return .failure(error: "No Reminders list found. Please open the Reminders app and create a list first.")
			}

			let reminder = EKReminder(eventStore: store)
			reminder.title = input.text
			reminder.calendar = calendar

			let alarmDate = parseDate(time: input.time, date: input.date)
			reminder.addAlarm(EKAlarm(absoluteDate: alarmDate))

			let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: alarmDate)
			reminder.dueDateComponents = components

			do {
				try store.save(reminder, commit: true)
			} catch {
				return .failure(error: "Could not save reminder: \(error.localizedDescription)")
			}

			let formatter = DateFormatter()
			formatter.dateStyle = .none
			formatter.timeStyle = .short
			let timeStr = formatter.string(from: alarmDate)

			return .success(confirmation: "Reminder set for \(timeStr): \"\(input.text)\"", data: nil)
		}
	)

	// MARK: - Date Parsing

	private static func parseDate(time: String, date: String?) -> Date {
		let now = Date()
		let calendar = Calendar.current

		if time.lowercased().hasPrefix("in ") {
			let remaining = String(time.dropFirst(3)).trimmingCharacters(in: .whitespaces)
			if let minutes = parseDuration(remaining) {
				return now.addingTimeInterval(minutes * 60)
			}
		}

		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")

		let timeFormats = ["h:mm a", "hh:mm a", "h a", "HH:mm", "HHmm", "h:mm"]
		for format in timeFormats {
			formatter.dateFormat = format
			if let parsed = formatter.date(from: time) {
				let components = calendar.dateComponents([.hour, .minute], from: parsed)
				var dateComponents = calendar.dateComponents([.year, .month, .day], from: now)
				dateComponents.hour = components.hour
				dateComponents.minute = components.minute
				if let result = calendar.date(from: dateComponents) {
					return result
				}
			}
		}

		return now.addingTimeInterval(3600)
	}

	private static func parseDuration(_ string: String) -> TimeInterval? {
		let parts = string.split(separator: " ")
		guard parts.count >= 2 else { return nil }
		guard let value = Double(parts[0]) else { return nil }
		let unit = parts[1].lowercased()
		if unit.hasPrefix("min") { return value * 60 }
		if unit.hasPrefix("hour") { return value * 3600 }
		return nil
	}
}
