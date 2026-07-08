//
//  RemindersHelper.swift
//  Hex
//

import EventKit
import Foundation
import HexCore

/// Shared helpers for Reminders-based tools.
enum RemindersHelper {
	/// Request access and return a fresh, ready-to-use event store.
	static func createAuthorizedStore() async throws -> EKEventStore {
		let store = EKEventStore()
		do {
			if #available(macOS 14.0, *) {
				try await store.requestFullAccessToReminders()
			} else {
				let granted = try await store.requestAccess(to: .reminder)
				guard granted else {
					throw RemindersError.accessDenied
				}
			}
		} catch let error as RemindersError {
			throw error
		} catch {
			throw RemindersError.accessError(error.localizedDescription)
		}
		// Force refresh so calendars are immediately visible
		store.reset()
		try? await Task.sleep(for: .milliseconds(300))
		return store
	}

	/// Find a suitable reminder calendar from the given store.
	static func findCalendar(in store: EKEventStore, named listName: String? = nil) -> EKCalendar? {
		let reminderCalendars = store.calendars(for: .reminder)
		
		if let listName {
			if let calendar = reminderCalendars.first(where: { $0.title == listName }) {
				return calendar
			}
			// Create the named calendar since it doesn't exist
			let calendar = EKCalendar(for: .reminder, eventStore: store)
			calendar.title = listName
			let sources = store.sources
			if let source = sources.first(where: { $0.sourceType == .calDAV && $0.title.lowercased().contains("icloud") }) ??
			                sources.first(where: { $0.sourceType == .local }) ??
			                sources.first(where: { $0.sourceType == .calDAV }) ??
			                sources.first {
				calendar.source = source
				do {
					try store.saveCalendar(calendar, commit: true)
					return calendar
				} catch {
					HexLog.transcription.error("Failed to automatically create EKCalendar named \(listName): \(error.localizedDescription)")
				}
			}
		}

		if !reminderCalendars.isEmpty {
			if let defaultCal = store.defaultCalendarForNewReminders(),
			   reminderCalendars.contains(defaultCal) {
				return defaultCal
			}
			return reminderCalendars[0]
		}
		
		// If entirely empty, create a default "Reminders" list
		let calendar = EKCalendar(for: .reminder, eventStore: store)
		calendar.title = "Reminders"
		let sources = store.sources
		if let source = sources.first(where: { $0.sourceType == .calDAV && $0.title.lowercased().contains("icloud") }) ??
		                sources.first(where: { $0.sourceType == .local }) ??
		                sources.first(where: { $0.sourceType == .calDAV }) ??
		                sources.first {
			calendar.source = source
			do {
				try store.saveCalendar(calendar, commit: true)
				return calendar
			} catch {
				HexLog.transcription.error("Failed to automatically create default EKCalendar: \(error.localizedDescription)")
			}
		}
		return nil
	}

	/// Fetch incomplete reminders from the store.
	static func fetchIncompleteReminders(from store: EKEventStore, start: Date?, end: Date?) async -> [EKReminder] {
		let predicate = store.predicateForIncompleteReminders(
			withDueDateStarting: start,
			ending: end,
			calendars: nil
		)
		return await withCheckedContinuation { continuation in
			store.fetchReminders(matching: predicate) { reminders in
				continuation.resume(returning: reminders ?? [])
			}
		}
	}
}

enum RemindersError: Error, LocalizedError {
	case accessDenied
	case accessError(String)

	var errorDescription: String? {
		switch self {
		case .accessDenied:
			return "Access to Reminders was denied. Please grant access in System Settings > Privacy & Security > Reminders."
		case .accessError(let msg):
			return "Reminders access error: \(msg). Please check System Settings > Privacy & Security > Reminders."
		}
	}
}
