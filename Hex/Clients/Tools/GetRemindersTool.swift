//
//  GetRemindersTool.swift
//  Hex
//

import EventKit
import Foundation

/// Retrieves upcoming time-based reminders from macOS Reminders.
enum GetRemindersTool {
	struct Input: Codable, Sendable {
		let list: String?
	}

	static let definition = ToolDefinition<Input>(
		id: "get_reminders",
		displayName: "Get Upcoming Reminders",
		description: "Retrieve upcoming time-based reminders. Use when the user asks 'what reminders do I have' or 'show my upcoming reminders'.",
		parameterSchema: [
			"type": "object",
			"properties": [
				"list": ["type": "string", "description": "Optional list name to filter by"],
			],
		],
		execute: { input in
			let store = try await RemindersHelper.createAuthorizedStore()
			let reminders = await RemindersHelper.fetchIncompleteReminders(from: store, start: Date(), end: nil)

			let filtered = input.list.flatMap { list in
				let f = reminders.filter { $0.calendar.title == list }
				return f.isEmpty ? reminders : f
			} ?? reminders

			if filtered.isEmpty {
				return .success(confirmation: "No upcoming reminders.", data: nil)
			}

			let formatter = DateFormatter()
			formatter.dateStyle = .none
			formatter.timeStyle = .short

			let items = filtered.prefix(20).compactMap { r -> String? in
				guard let title = r.title else { return nil }
				let dueStr = r.dueDateComponents.flatMap { Calendar.current.date(from: $0) }.map { formatter.string(from: $0) } ?? ""
				return dueStr.isEmpty ? title : "\(dueStr) - \(title)"
			}.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n")

			return .success(confirmation: "You have \(filtered.count) upcoming reminder\(filtered.count == 1 ? "" : "s"). \(items)", data: nil)
		}
	)
}
