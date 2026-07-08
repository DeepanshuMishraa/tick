//
//  ToolRegistryClient.swift
//  Hex
//

import ComposableArchitecture
import Dependencies
import DependenciesMacros
import Foundation
import HexCore

private let toolLogger = HexLog.transcription

@DependencyClient
struct ToolRegistryClient {
	var allTools: @Sendable () async -> [AnyTool] = { [] }
	var enabledTools: @Sendable () async -> [AnyTool] = { [] }
	var executeTool: @Sendable (String, Data) async throws -> ToolResult
}

extension ToolRegistryClient: DependencyKey {
	static var liveValue: Self {
		let live = ToolRegistryClientLive()
		return .init(
			allTools: { await live.allTools() },
			enabledTools: { await live.enabledTools() },
			executeTool: { id, data in try await live.executeTool(id: id, data: data) }
		)
	}
}

extension DependencyValues {
	var toolRegistry: ToolRegistryClient {
		get { self[ToolRegistryClient.self] }
		set { self[ToolRegistryClient.self] = newValue }
	}
}

actor ToolRegistryClientLive {
	@Shared(.hexSettings) var hexSettings: HexSettings

	private var registry: [String: AnyTool] = [:]

	init() {
		registerBuiltInTools()
	}

	// MARK: - Registration

	private func registerBuiltInTools() {
		let tools: [AnyTool] = [
			AnyTool(AddToDoTool.definition),
			AnyTool(GetTodosTool.definition),
			AnyTool(SetReminderTool.definition),
			AnyTool(GetRemindersTool.definition),
			AnyTool(SearchWebTool.definition),
			AnyTool(OpenAppTool.definition),
			AnyTool(CreateNoteTool.definition),
			AnyTool(SetAlarmTool.definition),
		]
		for tool in tools {
			registry[tool.id] = tool
		}
	}

	// MARK: - Queries

	func allTools() -> [AnyTool] {
		Array(registry.values).sorted { $0.displayName < $1.displayName }
	}

	func enabledTools() -> [AnyTool] {
		let enabledIDs = Set(hexSettings.enabledToolIDs)
		return registry.values.filter { enabledIDs.contains($0.id) }
			.sorted { $0.displayName < $1.displayName }
	}

	// MARK: - Execution

	func executeTool(id: String, data: Data) async throws -> ToolResult {
		guard let tool = registry[id] else {
			return .failure(error: "Unknown tool: \(id)")
		}
		toolLogger.info("Executing tool: \(id)")
		return try await tool.executeJSON(data)
	}
}
