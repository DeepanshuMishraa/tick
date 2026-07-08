//
//  OpenAppTool.swift
//  Hex
//

import AppKit
import Foundation

/// Opens a specified application on the Mac.
enum OpenAppTool {
	struct Input: Codable, Sendable {
		let appName: String
	}

	static let definition = ToolDefinition<Input>(
		id: "open_app",
		displayName: "Open Application",
		description: "Open a specified application on the Mac. Use this when the user asks to open an app like Safari, Mail, Calendar, etc.",
		parameterSchema: [
			"type": "object",
			"properties": [
				"appName": ["type": "string", "description": "The name of the application to open, e.g. \"Safari\", \"Mail\", \"Calendar\""],
			],
			"required": ["appName"],
		],
		execute: { input in
			let workspace = NSWorkspace.shared

			// First try to launch by bundle identifier
			let bundleIDMappings: [String: String] = [
				"safari": "com.apple.Safari",
				"mail": "com.apple.mail",
				"calendar": "com.apple.Calendar",
				"notes": "com.apple.Notes",
				"reminders": "com.apple.Reminders",
				"messages": "com.apple.MobileSMS",
				"music": "com.apple.Music",
				"photos": "com.apple.Photos",
				"system settings": "com.apple.systempreferences",
				"settings": "com.apple.systempreferences",
				"finder": "com.apple.Finder",
				"terminal": "com.apple.Terminal",
				"xcode": "com.apple.dt.Xcode",
			]

			let appNameLower = input.appName.lowercased().trimmingCharacters(in: .whitespaces)

			let appURL: URL? = {
				if let bundleID = bundleIDMappings[appNameLower] {
					return workspace.urlForApplication(withBundleIdentifier: bundleID)
				}
				// Fall back to searching by app name
				if let path = workspace.fullPath(forApplication: input.appName) {
					return URL(fileURLWithPath: path)
				}
				return nil
			}()

			if let appURL {
				let config = NSWorkspace.OpenConfiguration()
				config.activates = true
				try await workspace.openApplication(at: appURL, configuration: config)
				return .success(confirmation: "Opening \(input.appName).", data: nil)
			}

			return .failure(error: "Could not find application named \"\(input.appName)\"")
		}
	)
}
