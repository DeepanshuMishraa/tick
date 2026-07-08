//
//  AIPostProcessingClient.swift
//  Hex
//

import ComposableArchitecture
import Dependencies
import DependenciesMacros
import Foundation
import HexCore

private let aiLogger = HexLog.transcription

@DependencyClient
struct AIPostProcessingClient {
	var postProcess: @Sendable (String, AIPostProcessingMode, AppContext?) async throws -> String
	var validateAPIKey: @Sendable (String, AIProvider, String) async throws -> Bool
}

extension AIPostProcessingClient: DependencyKey {
	static var liveValue: Self {
		let live = AIPostProcessingClientLive()
		return .init(
			postProcess: { text, mode, appContext in
				try await live.postProcess(text: text, mode: mode, appContext: appContext)
			},
			validateAPIKey: { apiKey, provider, model in
				try await live.validateAPIKey(apiKey, provider: provider, model: model)
			}
		)
	}
}

extension DependencyValues {
	var aiPostProcessing: AIPostProcessingClient {
		get { self[AIPostProcessingClient.self] }
		set { self[AIPostProcessingClient.self] = newValue }
	}
}

struct AIPostProcessingClientLive {
	@Shared(.hexSettings) var hexSettings: HexSettings

	func postProcess(text: String, mode: AIPostProcessingMode, appContext: AppContext?) async throws -> String {
		guard mode != .off else {
			return text
		}

		let provider = hexSettings.aiProvider
		let apiKey: String
		let selectedModel: String
		let baseURL: String

		switch provider {
		case .groq:
			guard let key = hexSettings.groqAPIKey, !key.isEmpty else {
				aiLogger.warning("Groq API key not configured, skipping AI post-processing")
				return text
			}
			apiKey = key
			selectedModel = hexSettings.aiPostProcessingModel
			baseURL = "https://api.groq.com/openai/v1/chat/completions"
		case .google:
			guard let key = hexSettings.googleAPIKey, !key.isEmpty else {
				aiLogger.warning("Google API key not configured, skipping AI post-processing")
				return text
			}
			apiKey = key
			selectedModel = hexSettings.googleModel
			baseURL = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
		}

		let systemPrompt = mode.systemPrompt(appContext: appContext, selectedStyleIndex: hexSettings.selectedStyleIndex)

		guard !systemPrompt.isEmpty else {
			return text
		}

		let request = GroqRequest(
			model: selectedModel,
			messages: [
				["role": "system", "content": systemPrompt],
				["role": "user", "content": "Transcription: \(text)"]
			],
			temperature: 0.3,
			maxTokens: 2048
		)

		guard let url = URL(string: baseURL) else {
			throw AIPostProcessingError.invalidURL
		}

		var request2 = URLRequest(url: url)
		request2.httpMethod = "POST"
		request2.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request2.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

		let encoder = JSONEncoder()
		encoder.keyEncodingStrategy = .useDefaultKeys
		request2.httpBody = try encoder.encode(request)
		
		// Log the request for debugging
		if let jsonString = String(data: request2.httpBody!, encoding: .utf8) {
			aiLogger.debug("\(provider.displayName) API request body: \(jsonString, privacy: .public)")
		}

		aiLogger.info("Sending text to \(provider.displayName) for post-processing with model \(selectedModel), mode: \(mode.displayName), app: \(appContext?.appName ?? "unknown")")

		let startTime = Date()

		let (data, response) = try await URLSession.shared.data(for: request2)

		let elapsed = Date().timeIntervalSince(startTime)
		aiLogger.info("\(provider.displayName) API response received in \(String(format: "%.2f", elapsed))s")

		guard let httpResponse = response as? HTTPURLResponse else {
			throw AIPostProcessingError.invalidResponse
		}

		guard httpResponse.statusCode == 200 else {
			let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
			aiLogger.error("\(provider.displayName) API error: \(httpResponse.statusCode) - \(errorMessage)")
			throw AIPostProcessingError.apiError(statusCode: httpResponse.statusCode, message: errorMessage)
		}

		let decoder = JSONDecoder()
		let groqResponse = try decoder.decode(GroqResponse.self, from: data)

		guard var content = groqResponse.choices.first?.message.content else {
			aiLogger.warning("\(provider.displayName) response had no content")
			return text
		}

		// Strip Qwen/DeepSeek thinking blocks: <think>...</think>
		while let thinkRangeStart = content.range(of: "<think>"),
		      let thinkRangeEnd = content.range(of: "</think>", range: thinkRangeStart.upperBound..<content.endIndex) {
			content.removeSubrange(thinkRangeStart.lowerBound..<thinkRangeEnd.upperBound)
		}
		content = content.trimmingCharacters(in: .whitespacesAndNewlines)

		aiLogger.info("AI post-processing completed successfully")
		return content
	}

	func validateAPIKey(_ apiKey: String, provider: AIProvider, model: String) async throws -> Bool {
		guard !apiKey.isEmpty else {
			throw AIPostProcessingError.invalidAPIKey
		}

		let baseURL: String
		switch provider {
		case .groq:
			baseURL = "https://api.groq.com/openai/v1/chat/completions"
		case .google:
			baseURL = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
		}

		let request = GroqRequest(
			model: model,
			messages: [
				["role": "system", "content": "You are a helpful assistant."],
				["role": "user", "content": "Test"]
			],
			temperature: 0.3,
			maxTokens: 10
		)

		guard let url = URL(string: baseURL) else {
			throw AIPostProcessingError.invalidURL
		}

		var urlRequest = URLRequest(url: url)
		urlRequest.httpMethod = "POST"
		urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
		urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

		let encoder = JSONEncoder()
		encoder.keyEncodingStrategy = .useDefaultKeys
		urlRequest.httpBody = try encoder.encode(request)
		
		// Log the request for debugging
		if let jsonString = String(data: urlRequest.httpBody!, encoding: .utf8) {
			aiLogger.debug("\(provider.displayName) API validation request body: \(jsonString, privacy: .public)")
		}

		aiLogger.info("Validating \(provider.displayName) API key with model \(model)")

		let (data, response) = try await URLSession.shared.data(for: urlRequest)

		guard let httpResponse = response as? HTTPURLResponse else {
			throw AIPostProcessingError.invalidResponse
		}

		if httpResponse.statusCode == 200 {
			aiLogger.info("\(provider.displayName) API key validation successful")
			return true
		} else {
			let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
			aiLogger.error("\(provider.displayName) API key validation failed: \(httpResponse.statusCode) - \(errorMessage)")
			throw AIPostProcessingError.apiError(statusCode: httpResponse.statusCode, message: errorMessage)
		}
	}
}

enum AIPostProcessingError: Error, LocalizedError {
	case invalidURL
	case invalidResponse
	case invalidAPIKey
	case apiError(statusCode: Int, message: String)

	var errorDescription: String? {
		switch self {
		case .invalidURL:
			return "Invalid API URL"
		case .invalidResponse:
			return "Invalid response from API"
		case .invalidAPIKey:
			return "Invalid or unauthorized API key"
		case .apiError(let statusCode, let message):
			return "API error (\(statusCode)): \(message)"
		}
	}
}

private struct GroqRequest: Encodable {
	let model: String
	let messages: [[String: String]]
	let temperature: Double
	let maxTokens: Int
	
	enum CodingKeys: String, CodingKey {
		case model
		case messages
		case temperature
		case maxTokens = "max_tokens"
	}
}

private struct GroqResponse: Decodable {
	let choices: [GroqChoice]
}

private struct GroqChoice: Decodable {
	let message: GroqMessage
}

private struct GroqMessage: Decodable {
	let content: String
}
