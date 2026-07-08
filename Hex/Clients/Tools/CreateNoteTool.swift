//
//  CreateNoteTool.swift
//  Hex
//

import Foundation

/// Creates a note in Apple Notes via AppleScript.
enum CreateNoteTool {
	struct Input: Codable, Sendable {
		let title: String
		let body: String
	}

	static let definition = ToolDefinition<Input>(
		id: "create_note",
		displayName: "Create Note",
		description: "Create a new note in Apple Notes. Use this when the user wants to save some text as a note.",
		parameterSchema: [
			"type": "object",
			"properties": [
				"title": ["type": "string", "description": "The title of the note"],
				"body": ["type": "string", "description": "The body content of the note"],
			],
			"required": ["title", "body"],
		],
		execute: { input in
			let escapedTitle = input.title
				.replacingOccurrences(of: "\\", with: "\\\\")
				.replacingOccurrences(of: "\"", with: "\\\"")
			let escapedBody = input.body
				.replacingOccurrences(of: "\\", with: "\\\\")
				.replacingOccurrences(of: "\"", with: "\\\"")

			let script = """
			tell application "Notes"
				make new note with properties {name: "\(escapedTitle)", body: "\(escapedBody)"}
			end tell
			"""

			var error: NSDictionary?
			let result = NSAppleScript(source: script)?.executeAndReturnError(&error)

			if let error {
				return .failure(error: "Failed to create note: \(error)")
			}

			return .success(confirmation: "Note \"\(input.title)\" created.", data: nil)
		}
	)
}
