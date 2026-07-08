//
//  ToolDefinition.swift
//  Hex
//

import Foundation

/// The result of executing a tool.
public enum ToolResult: Codable, Sendable {
	case success(confirmation: String, data: Data?)
	case failure(error: String)

	public var confirmation: String {
		switch self {
		case .success(let c, _): return c
		case .failure(let e): return "Failed: \(e)"
		}
	}
}

/// A typed tool definition with a Codable input schema.
/// The AI uses the description + input schema to know when and how to call this tool.
public struct ToolDefinition<Input: Codable & Sendable> {
	public let id: String
	public let displayName: String
	public let description: String
	public let parameterSchema: [String: Any]
	public let execute: @Sendable (Input) async throws -> ToolResult

	public init(
		id: String,
		displayName: String,
		description: String,
		parameterSchema: [String: Any],
		execute: @escaping @Sendable (Input) async throws -> ToolResult
	) {
		self.id = id
		self.displayName = displayName
		self.description = description
		self.parameterSchema = parameterSchema
		self.execute = execute
	}
}

/// A type-erased tool that can be stored in a registry and dispatched at runtime.
public struct AnyTool: Sendable {
	public let id: String
	public let displayName: String
	public let description: String
	public let inputSchemaType: Any.Type
	public let parameterSchema: [String: Any]
	public let executeJSON: @Sendable (Data) async throws -> ToolResult

	public init<I: Codable & Sendable>(_ definition: ToolDefinition<I>) {
		self.id = definition.id
		self.displayName = definition.displayName
		self.description = definition.description
		self.inputSchemaType = I.self
		self.parameterSchema = definition.parameterSchema
		self.executeJSON = { jsonData in
			let input = try JSONDecoder().decode(I.self, from: jsonData)
			return try await definition.execute(input)
		}
	}

	/// Convert to the Swift AI SDK's tool format for use in streamText/generateText.
	/// Returns a dictionary representation compatible with SwiftAISDK.
	public func toSDKDictionary() -> [String: Any] {
		[
			"id": id,
			"description": description,
		]
	}
}
