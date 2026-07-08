//
//  AddToDoTool.swift
//  Hex
//

import EventKit
import Foundation

/// Adds an item to macOS Reminders.
enum AddToDoTool {
	struct Input: Codable, Sendable {
		let text: String
		let list: String?
	}

	static let definition = ToolDefinition<Input>(
		id: "add_todo",
		displayName: "Add to Reminders",
		description: "Add an item to the user's reminders list. Use this when the user says things like 'add milk to my shopping list' or 'remind me to buy groceries'.",
		parameterSchema: [
			"type": "object",
			"properties": [
				"text": ["type": "string", "description": "The text of the item to add"],
				"list": ["type": "string", "description": "Optional list name"],
			],
			"required": ["text"],
		],
		execute: { input in
			let store = try await RemindersHelper.createAuthorizedStore()

			guard let calendar = RemindersHelper.findCalendar(in: store, named: input.list) else {
				return .failure(error: "No Reminders list found. Please open the Reminders app and create a list first.")
			}

			let reminder = EKReminder(eventStore: store)
			reminder.title = input.text
			reminder.calendar = calendar

			do {
				try store.save(reminder, commit: true)
			} catch {
				return .failure(error: "Could not save reminder: \(error.localizedDescription)")
			}

			let listSuffix = input.list.map { " in \"\($0)\"" } ?? ""
			return .success(confirmation: "Added \"\(input.text)\"\(listSuffix) to your reminders.", data: nil)
		}
	)
}
