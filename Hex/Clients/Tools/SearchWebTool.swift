//
//  SearchWebTool.swift
//  Hex
//

import AppKit
import Foundation

/// Searches the web by opening Safari (or default browser) with the query.
enum SearchWebTool {
	struct Input: Codable, Sendable {
		let query: String
	}

	static let definition = ToolDefinition<Input>(
		id: "search_web",
		displayName: "Search Web",
		description: "Search the web for information. Use this when the user wants to look something up online.",
		parameterSchema: [
			"type": "object",
			"properties": [
				"query": ["type": "string", "description": "The search query"],
			],
			"required": ["query"],
		],
		execute: { input in
			guard let encoded = input.query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
				  let url = URL(string: "https://www.google.com/search?q=\(encoded)") else {
				return .failure(error: "Could not create search URL")
			}

			let opened = NSWorkspace.shared.open(url)
			if opened {
				return .success(confirmation: "Searching the web for \"\(input.query)\".", data: nil)
			} else {
				return .failure(error: "Could not open browser")
			}
		}
	)
}
