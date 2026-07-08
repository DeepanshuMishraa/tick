//
//  AIOrchestratorClient.swift
//  Hex
//
//  The orchestrator runs alongside the existing AIPostProcessingClient.
//  When autonomous mode is enabled, it uses the Swift AI SDK to detect
//  tool invocations from transcribed speech. If a tool call is detected,
//  it fires TTS confirmation immediately and executes the tool in the
//  background. If no tool call is detected, it returns cleaned text.
//

import ComposableArchitecture
import Dependencies
import DependenciesMacros
import Foundation
import HexCore

private let orchestratorLogger = HexLog.transcription

/// The result of a tool execution.
public struct ToolExecutionResult: Sendable, Equatable {
	public let toolName: String
	public let success: Bool
	public let message: String
}

/// The result of orchestrator processing.
public enum AIOrchestratorOutput: Sendable, Equatable {
	/// Normal dictation — cleaned text to be pasted
	case text(String)
	/// Tool call(s) were detected and executed
	case toolCallsExecuted([ToolExecutionResult])
}

@DependencyClient
struct AIOrchestratorClient {
	/// Process transcribed text through the AI with tool calling.
	/// - If autonomous mode is off, returns nil (caller should use AIPostProcessingClient).
	/// - If autonomous mode is on, returns either cleaned text or tool execution result.
	/// - onToolDetected: Called BEFORE tool execution, so the caller can show UI like the notch.
	var process: @Sendable (String, AppContext?, _ onToolDetected: @Sendable (_ toolName: String) async -> Void) async throws -> AIOrchestratorOutput?
}

extension AIOrchestratorClient: DependencyKey {
	static var liveValue: Self {
		let live = AIOrchestratorClientLive()
		return .init(
			process: { text, appContext, onToolDetected in
				try await live.process(text: text, appContext: appContext, onToolDetected: onToolDetected)
			}
		)
	}
}

extension DependencyValues {
	var aiOrchestrator: AIOrchestratorClient {
		get { self[AIOrchestratorClient.self] }
		set { self[AIOrchestratorClient.self] = newValue }
	}
}

actor AIOrchestratorClientLive {
	@Shared(.hexSettings) var hexSettings: HexSettings
	@Dependency(\.toolRegistry) var toolRegistry
	@Dependency(\.speechSynthesis) var speechSynthesis

	func process(text: String, appContext: AppContext?, onToolDetected: @Sendable (String) async -> Void) async throws -> AIOrchestratorOutput? {
		orchestratorLogger.info("Orchestrator process called with text: \"\(text)\"")

		let enabledTools = await toolRegistry.enabledTools()
		orchestratorLogger.info("Enabled tools: \(enabledTools.map(\.id))")

		// If no tools are enabled, fall back to normal dictation
		guard !enabledTools.isEmpty else {
			orchestratorLogger.info("No tools enabled, falling through to normal dictation")
			return nil
		}
	
		let selectedModel: String
		let apiKey: String

		switch hexSettings.aiProvider {
		case .groq:
			guard let key = hexSettings.groqAPIKey, !key.isEmpty else {
				orchestratorLogger.warning("Groq API key not configured")
				return nil
			}
			apiKey = key
			selectedModel = hexSettings.aiPostProcessingModel
		case .google:
			guard let key = hexSettings.googleAPIKey, !key.isEmpty else {
				orchestratorLogger.warning("Google API key not configured")
				return nil
			}
			apiKey = key
			selectedModel = hexSettings.googleModel
		}

		// Build the system prompt
		let toolDescriptions = enabledTools.map { tool in
			"- \(tool.id): \(tool.description)"
		}.joined(separator: "\n")

		let appContextStr: String
		if let appContext {
			appContextStr = "Active application: \(appContext.appName) (category: \(appContext.category.displayName))"
		} else {
			appContextStr = "No specific application context detected."
		}

		let systemPrompt = """
		You are an intelligent dictation assistant. Your job is to clean up the user's speech and return polished text.

		However, if the user is asking you to DO something using one of the available tools, call that tool instead.
		You should be HELPFUL and call tools whenever the user's intent matches a tool's purpose.

		Important:
		- If the user asks to set an alarm or a timer (e.g., "set an alarm for 7 AM", "timer for 10 minutes"), use the `set_alarm` tool.
		- If the user asks to remember something or add to a to-do list (e.g., "remind me to buy milk", "add a task to my list"), use the `set_reminder` or `add_todo` tools.

		Available tools:
		\(toolDescriptions)

		\(appContextStr)

		If the user's speech is a tool-worthy request, call the tool. Otherwise, clean up the text and return it.
		"""

		return try await callAI(
			provider: hexSettings.aiProvider,
			systemPrompt: systemPrompt,
			userText: text,
			model: selectedModel,
			apiKey: apiKey,
			tools: enabledTools,
			onToolDetected: onToolDetected
		)
	}

	private func callAI(
		provider: AIProvider,
		systemPrompt: String,
		userText: String,
		model: String,
		apiKey: String,
		tools: [AnyTool],
		onToolDetected: @Sendable (String) async -> Void
	) async throws -> AIOrchestratorOutput {
		return try await performAICall(
			provider: provider,
			systemPrompt: systemPrompt,
			userText: userText,
			model: model,
			apiKey: apiKey,
			tools: tools,
			onToolDetected: onToolDetected
		)
	}

	private func performAICall(
		provider: AIProvider,
		systemPrompt: String,
		userText: String,
		model: String,
		apiKey: String,
		tools: [AnyTool],
		onToolDetected: @Sendable (String) async -> Void
	) async throws -> AIOrchestratorOutput {
		// Build the request — use the provider's OpenAI-compatible endpoint
		let baseURL: String = {
			switch provider {
			case .groq:
				return "https://api.groq.com/openai/v1/chat/completions"
			case .google:
				return "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
			}
		}()

		guard let url = URL(string: baseURL) else {
			throw AIOrchestratorError.invalidURL
		}

		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

		// Build tools array for the OpenAI API format using each tool's explicit parameter schema
		let toolsJSON: [[String: Any]] = tools.map { tool in
			[
				"type": "function",
				"function": [
					"name": tool.id,
					"description": tool.description,
					"parameters": tool.parameterSchema,
				],
			] as [String: Any]
		}

		let body: [String: Any] = [
			"model": model,
			"messages": [
				["role": "system", "content": systemPrompt],
				["role": "user", "content": "Transcription: \(userText)"],
			],
			"tools": toolsJSON,
			"tool_choice": "auto",
			"temperature": 0.3,
			"max_tokens": 2048,
		]

		request.httpBody = try JSONSerialization.data(withJSONObject: body)

		// Log the full request for debugging
		if let bodyData = request.httpBody, let bodyStr = String(data: bodyData, encoding: .utf8) {
			orchestratorLogger.info("Sending to \(provider.displayName) for tool-aware processing with model \(model)")
			orchestratorLogger.debug("Request body: \(bodyStr)")
		}

		let (data, response) = try await URLSession.shared.data(for: request)

		guard let httpResponse = response as? HTTPURLResponse,
			  httpResponse.statusCode == 200 else {
			let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
			let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown error"
			orchestratorLogger.error("API error (\(provider.displayName)): \(statusCode) - \(errorMsg)")
			throw AIOrchestratorError.apiError(statusCode: statusCode, message: errorMsg)
		}

		// Parse the response
		guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
			  let choices = json["choices"] as? [[String: Any]],
			  let firstChoice = choices.first,
			  let message = firstChoice["message"] as? [String: Any] else {
			throw AIOrchestratorError.invalidResponse
		}

		// Log the response for debugging
		if let responseStr = String(data: data, encoding: .utf8) {
			orchestratorLogger.debug("API response: \(responseStr)")
		}

		// Check for tool calls
		if let toolCalls = message["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
			orchestratorLogger.info("Tool calls detected in response: \(toolCalls.count)")
			// Fire the callback BEFORE executing tools, so caller can show notch
			for call in toolCalls {
				if let function = call["function"] as? [String: Any],
				   let name = function["name"] as? String {
					await onToolDetected(name)
				}
			}
			return try await handleToolCalls(toolCalls, tools: tools)
		}

		// No tool call — return cleaned text
		if let content = message["content"] as? String, !content.isEmpty {
			return .text(content)
		}

		return .text(userText)
	}

	private func handleToolCalls(
		_ toolCalls: [[String: Any]],
		tools: [AnyTool]
	) async throws -> AIOrchestratorOutput {
		var results: [ToolExecutionResult] = []

		for call in toolCalls {
			guard let function = call["function"] as? [String: Any],
				  let name = function["name"] as? String,
				  let argumentsStr = function["arguments"] as? String,
				  let argumentsData = argumentsStr.data(using: .utf8) else {
				continue
			}

			orchestratorLogger.info("Tool call detected: \(name)")
			orchestratorLogger.debug("Arguments: \(argumentsStr)")

			// Execute the tool
			do {
				let result = try await toolRegistry.executeTool(name, argumentsData)
				let executionResult: ToolExecutionResult
				switch result {
				case .success(let confirmation, _):
					executionResult = ToolExecutionResult(toolName: name, success: true, message: confirmation)
					try? await speechSynthesis.speak(confirmation)
				case .failure(let error):
					executionResult = ToolExecutionResult(toolName: name, success: false, message: error)
					try? await speechSynthesis.speak("Failed: \(error)")
				}
				results.append(executionResult)
			} catch {
				orchestratorLogger.error("Tool execution threw: \(error.localizedDescription)")
				results.append(ToolExecutionResult(toolName: name, success: false, message: error.localizedDescription))
				try? await speechSynthesis.speak("Failed: \(error.localizedDescription)")
			}
		}

		return .toolCallsExecuted(results)
	}
}

enum AIOrchestratorError: Error, LocalizedError {
	case apiError(statusCode: Int, message: String)
	case invalidResponse
	case invalidURL
	case noAPIKey

	var errorDescription: String? {
		switch self {
		case .apiError(let code, let msg):
			return "AI API error (\(code)): \(msg)"
		case .invalidResponse:
			return "Invalid response from AI API"
		case .invalidURL:
			return "Invalid API URL"
		case .noAPIKey:
			return "API key not configured"
		}
	}
}
