//
//  GetTodosTool.swift
//  Hex
//

import EventKit
import Foundation

/// Retrieves all pending to-do items from macOS Reminders.
enum GetTodosTool {
	struct Input: Codable, Sendable {
		let list: String?
	}

	static let definition = ToolDefinition<Input>(
		id: "get_todos",
		displayName: "Get Reminders",
		description: "Retrieve pending items from the user's reminders list. Use when the user asks 'what's on my to-do list' or 'show my reminders'.",
		parameterSchema: [
			"type": "object",
			"properties": [
				"list": ["type": "string", "description": "Optional list name to filter by"],
			],
		],
		execute: { input in
			let store = try await RemindersHelper.createAuthorizedStore()
			let reminders = await RemindersHelper.fetchIncompleteReminders(from: store, start: nil, end: nil)

			let filtered = input.list.flatMap { list in
				let f = reminders.filter { $0.calendar.title == list }
				return f.isEmpty ? reminders : f
			} ?? reminders

			if filtered.isEmpty {
				return .success(confirmation: "Your reminders list is empty.", data: nil)
			}

			let items = filtered.prefix(20).enumerated().map { i, r in
				"\(i + 1). \(r.title ?? "")"
			}.joined(separator: "\n")

			return .success(confirmation: "You have \(filtered.count) item\(filtered.count == 1 ? "" : "s"). \(items)", data: nil)
		}
	)
}
