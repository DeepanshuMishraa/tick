//
//  SetAlarmTool.swift
//  Hex
//

import Foundation
import UserNotifications

/// Creates a local notification alarm.
enum SetAlarmTool {
	struct Input: Codable, Sendable {
		let label: String?
		let time: String
	}

	static let definition = ToolDefinition<Input>(
		id: "set_alarm",
		displayName: "Set Alarm",
		description: "Set a headless alarm or timer that will alert the user at a specific time (e.g., 'in 15 minutes', 'at 8:30 AM'). Use this when the user asks to set an alarm or timer.",
		parameterSchema: [
			"type": "object",
			"properties": [
				"label": ["type": "string", "description": "Optional label/reason for the alarm"],
				"time": ["type": "string", "description": "The time or duration, e.g., '8am', 'in 10 minutes', '7:30 PM'"],
			],
			"required": ["time"],
		],
		execute: { input in
			let center = UNUserNotificationCenter.current()
			
			do {
				let granted = try await center.requestAuthorization(options: [.alert, .sound])
				guard granted else {
					return .failure(error: "Notification permissions denied. Please enable them in System Settings > Privacy & Security > Notifications > Hex.")
				}
			} catch {
				return .failure(error: "Failed to request notification permission: \(error.localizedDescription)")
			}
			
			let alarmDate = parseDate(time: input.time)
			let label = input.label ?? "Alarm"
			
			let content = UNMutableNotificationContent()
			content.title = "⏰ " + label
			content.body = "Time is up!"
			content.sound = UNNotificationSound.defaultCriticalSound(withAudioVolume: 1.0)
			
			let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: alarmDate)
			let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
			
			let request = UNNotificationRequest(
				identifier: UUID().uuidString,
				content: content,
				trigger: trigger
			)
			
			do {
				try await center.add(request)
			} catch {
				return .failure(error: "Could not schedule alarm: \(error.localizedDescription)")
			}
			
			let formatter = DateFormatter()
			formatter.dateStyle = .none
			formatter.timeStyle = .short
			let timeStr = formatter.string(from: alarmDate)
			
			return .success(confirmation: "Alarm set for \(timeStr): \"\(label)\"", data: nil)
		}
	)

	private static func parseDate(time: String) -> Date {
		let now = Date()
		let calendar = Calendar.current

		if time.lowercased().hasPrefix("in ") {
			let remaining = String(time.dropFirst(3)).trimmingCharacters(in: .whitespaces)
			if let seconds = parseDuration(remaining) {
				return now.addingTimeInterval(seconds)
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
					if result < now {
						// If the time has already passed today, assume it's for tomorrow
						return calendar.date(byAdding: .day, value: 1, to: result) ?? result
					}
					return result
				}
			}
		}

		return now.addingTimeInterval(3600) // Default to 1 hour
	}

	private static func parseDuration(_ string: String) -> TimeInterval? {
		let parts = string.split(separator: " ")
		guard parts.count >= 2 else { return nil }
		guard let value = Double(parts[0]) else { return nil }
		let unit = parts[1].lowercased()
		if unit.hasPrefix("sec") { return value }
		if unit.hasPrefix("min") { return value * 60 }
		if unit.hasPrefix("hour") { return value * 3600 }
		return nil
	}
}
