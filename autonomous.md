# Autonomous Hex — AI Tool Calling & Personal Assistant Architecture

> **Vision:** Transform Hex from a dictation app into an autonomous personal assistant.  
> Speak naturally → Hex transcribes + pastes as usual.  
> Speak with intent → AI detects tool call, speaks confirmation via Edge TTS, executes tool in background.

---

## 1. Context & Current State

### What Hex Does Today

Hex is a macOS menu-bar dictation app (SwiftUI + TCA + WhisperKit/Parakeet).  
Flow: **Hotkey → Record → Transcribe → Word Remap/Snippet Expand → AI Post-Process → Paste**

### Architecture Quick Reference

| Layer | Files | Role |
|-------|-------|------|
| **TCA Reducers** | `AppFeature.swift`, `TranscriptionFeature.swift`, `SettingsFeature.swift` | State management & effects |
| **Clients** | `AIPostProcessingClient.swift`, `RecordingClient.swift`, `TranscriptionClient.swift` | Dependency-injected services |
| **Settings** | `HexSettings.swift`, `SettingsFeature.swift` | Persisted config (`@Shared(.hexSettings)`) |
| **Models** | `AppContext.swift`, `TranscriptionHistory.swift` | Domain types |

### Current AI Post-Processing Pipeline (unchanged — runs alongside orchestrator)

```
Transcribed Text
    → [WordRemovalApplier / WordRemappingApplier / SnippetApplier]
    → AIPostProcessingClient.postProcess(text, mode, appContext)
        → Raw URLSession call to Groq API
        → Returns cleaned text
    → PasteBoard.paste(result)
```

### Swift AI SDK (New Dependency)

**Repo:** `https://github.com/teunlao/swift-ai-sdk`  
**Docs:** https://swift-ai-sdk-docs.vercel.app

Provides `generateText`, `streamText`, tool calling with typed `Codable` schemas, `generateObject`, `generateSpeech`, and multiple provider support. Groq works via the OpenAI-compatible provider with a custom `baseURL`.

### Edge TTS (New Dependency)

**Package:** `https://github.com/herrkaefer/SwiftEdgeTTS` (macOS 12+, pure Swift, 400+ neural voices)  
Alternative: `https://github.com/brewusinc/Edge-TTS`

Provides high-quality neural TTS via Microsoft Edge's service — no Python deps, async/await API, streams MP3 audio.

---

## 2. Proposed Architecture — Autonomous Mode

### High-Level Flow

```
User speaks
  → Audio recorded
  → Transcribed (WhisperKit / Parakeet)
  → Word Remapping / Snippet Expansion (existing — unchanged)
  → TWO PARALLEL PATHS:

    PATH A (Normal Dictation — existing):
      → AIPostProcessingClient (Groq, app-aware formatting)
      → Paste into active app
      → (unchanged from today)

    PATH B (Autonomous Mode — NEW):
      → AIOrchestratorClient (Swift AI SDK with tools)
          ├── Detects TOOL CALL
          │     → Speak confirmation via Edge TTS IMMEDIATELY
          │     → Execute tool (EventKit / AppleScript / etc.)
          │     → Done
          │
          └── Detects NORMAL TEXT
                → Post-process (clean up, app-aware formatting)
                → Paste into active app
```

### The "Instant TTS" UX

1. AI response streams from Groq via Swift AI SDK
2. As soon as a tool call token arrives in the stream → **immediately** fire Edge TTS with the AI-generated confirmation phrase
3. Tool execution begins in the **background** while TTS plays
4. User hears confirmation within ~200ms of the AI deciding it's a tool call

---

## 3. New & Modified Files

### New Package Dependencies

| Package | URL | Product |
|---------|-----|---------|
| **SwiftAISDK** | `https://github.com/teunlao/swift-ai-sdk` | `SwiftAISDK`, `OpenAIProvider` |
| **SwiftEdgeTTS** | `https://github.com/herrkaefer/SwiftEdgeTTS` | `SwiftEdgeTTS` |

### New Files

| File | Purpose |
|------|---------|
| `Hex/Clients/AIOrchestratorClient.swift` | **New orchestrator** — uses Swift AI SDK, manages tool detection, dispatches tools, triggers TTS chain |
| `Hex/Clients/SpeechSynthesisClient.swift` | Edge TTS wrapper — `@DependencyClient` with a `speak(_ text:)` method, plays MP3 via AVAudioPlayer |
| `Hex/Clients/ToolRegistryClient.swift` | Central registry of all available tools + type-erased `AnyTool` wrapper |
| `Hex/Clients/Tools/AddToDoTool.swift` | Adds item to macOS Reminders via EventKit (`EKReminder`) |
| `Hex/Clients/Tools/SetReminderTool.swift` | Creates time-based reminder via EventKit (`EKAlarm`) |
| `Hex/Clients/Tools/SearchWebTool.swift` | Opens Safari with search query or returns URL |
| `Hex/Clients/Tools/OpenAppTool.swift` | Opens an application via `NSWorkspace.shared.open` |
| `Hex/Clients/Tools/CreateNoteTool.swift` | Creates a note in Apple Notes via AppleScript |

### Modified Files

| File | Changes |
|------|---------|
| `HexCore/Sources/HexCore/Settings/HexSettings.swift` | Add settings: `autonomousModeEnabled`, `ttsEnabled`, `ttsVoice`, `enabledToolIDs` |
| `Hex/Features/Settings/AIPostProcessingSectionView.swift` | Add autonomous mode controls (toggle, tool enable/disable, TTS voice selector) |
| `Hex/Features/Settings/SettingsFeature.swift` | Add actions for autonomous mode, tool management, TTS |
| `Hex/Features/Transcription/TranscriptionFeature.swift` | Add new `aiOrchestrator` dependency; route to orchestrator in autonomous mode |
| `Hex.xcodeproj/project.pbxproj` | Add Swift AI SDK + SwiftEdgeTTS package dependencies, add new source files |

### What Stays the Same

- `AIPostProcessingClient` — unchanged, still handles app-aware formatting for normal dictation
- `AppFeature.swift` — no structural changes, just the new orchestrator integrated
- All existing recording/transcription/pasteboard logic — unchanged

---

## 4. Reuse — Existing Code to Leverage

| What Exists | Where | How to Reuse |
|-------------|-------|--------------|
| `HexSettings.groqAPIKey` | `HexSettings.swift` | Pass to OpenAI-compatible provider's `apiKey` |
| `HexSettings.aiPostProcessingModel` | `HexSettings.swift` | Reuse as the LLM model for orchestrator |
| `AppContextDetector` + `AppCategory` | `AppContextDetector.swift`, `AppContext.swift` | Enrich AI prompt with app context for formatting |
| `AIPostProcessingMode` | `HexSettings.swift:9` | Add `.autonomous` case alongside `.off`, `.on`, `.appAware` |
| `SoundEffect` / `SoundEffectsClient` | `SoundEffect.swift` | Play subtle "processing" indicator sound before TTS |
| `SuperFastCaptureController` | `SuperFastCaptureController.swift` | Fast recording keeps the whole pipeline snappy |
| `PasteboardClient` | Existing | Used for normal dictation fallback |
| `@DependencyClient` pattern | All clients | Follow same pattern for `AIOrchestratorClient`, `SpeechSynthesisClient`, `ToolRegistryClient` |
| TCA `.run` effect pattern | `TranscriptionFeature.swift` | New orchestrator call fits into existing effect chain |

---

## 5. Tool System Design

### Tool Protocol

```swift
/// A tool that the AI can invoke.
/// Each tool has a typed input schema (Codable), description for the LLM,
/// and an async execute function.
struct ToolDefinition<Input: Codable & Sendable, Output: Codable & Sendable> {
    let id: String
    let displayName: String
    let description: String          // Used in AI system prompt
    let inputSchema: Input.Type
    let execute: @Sendable (Input) async throws -> ToolResult
}

/// Type-erased wrapper for tool storage + dispatch
struct AnyTool: Sendable {
    let id: String
    let displayName: String
    let description: String
    let execute: @Sendable (Data) async throws -> ToolResult
    // ... converts to Swift AI SDK's tool format
}

enum ToolResult: Codable, Sendable {
    case success(confirmation: String, data: Data? = nil)
    case failure(error: String)
}
```

### Built-in Tools (v1)

| Tool ID | Description | Input Schema | macOS Backend |
|---------|-------------|-------------|---------------|
| `add_todo` | Add an item to the user's to-do list | `{ text: String, list: String? }` | EventKit `EKReminder` |
| `set_reminder` | Set a time-based reminder | `{ text: String, time: String }` | EventKit `EKReminder` + `EKAlarm` |
| `search_web` | Search the web for information | `{ query: String }` | `NSWorkspace.shared.open(URL)` |
| `open_app` | Open a specified application | `{ appName: String }` | `NSWorkspace.shared.openApplication` |
| `create_note` | Create a note | `{ title: String, body: String }` | AppleScript → Notes.app |

### Tool Registry Client

```swift
@DependencyClient
struct ToolRegistryClient {
    /// All registered tools (enabled + disabled)
    var allTools: @Sendable () -> [AnyTool]

    /// Only enabled tools (filtered by HexSettings.enabledToolIDs)
    var enabledTools: @Sendable () -> [AnyTool]

    /// Execute a specific tool by ID with the given JSON data
    var executeTool: @Sendable (String, Data) async throws -> ToolResult
}
```

### Tool → Swift AI SDK Bridge

Each `AnyTool` adapts to the Swift AI SDK's `tool()` format:

```swift
extension AnyTool {
    /// Convert to Swift AI SDK tool for use in generateText/streamText
    func toSDKTool() -> Tool<...> {
        tool(
            description: self.description,
            inputSchema: self.inputSchemaType,
            execute: { input, _ in
                try await self.execute(input)
            }
        )
    }
}
```

The system prompt for autonomous mode tells the AI:

```
You are an autonomous assistant. Decide if the user's speech is a tool invocation or normal dictation.

Available tools (with descriptions):
- add_todo: Add items to the user's to-do/reminders list
- set_reminder: Create a time-based reminder
- search_web: Search the web
- open_app: Open an application
- create_note: Create a note

If it's a tool call:
  → Call the appropriate tool with the extracted parameters.
  → The tool's response will be spoken to the user.

If it's normal dictation:
  → Clean up filler words, fix grammar, adapt to the active app context.
  → Return only the cleaned text.
```

---

## 6. Swift AI SDK Integration

### Provider Configuration

```swift
import SwiftAISDK
import OpenAIProvider

// Configure OpenAI-compatible provider to point at Groq
let provider = createOpenAI(settings: OpenAIProviderSettings(
    apiKey: groqAPIKey,
    baseURL: "https://api.groq.com/openai/v1"
))

// Select model (uses the user's chosen model from settings)
let model = try provider.chat(selectedModel)
```

### Orchestrator Call (streaming)

```swift
let toolDefs = toolRegistry.enabledTools().map { $0.toSDKTool() }
let toolDict = Dictionary(uniqueKeysWithValues: toolDefs.map { ($0.id, $0) })

let stream = try streamText(
    model: model,
    tools: toolDict,
    prompt: "Transcription: \(text)\n\nContext: \(appContextDescription)",
    toolChoice: .auto
)

for try await part in stream.fullStream {
    switch part {
    case .textDelta(let delta):
        // Accumulate text for post-processing — only used if no tool call
        accumulatedText += delta

    case .toolCall(let toolCall):
        // 🔥 TOOL CALL DETECTED — speak confirmation immediately!
        Task {
            let spokenResponse = extractConfirmation(from: toolCall)
            await speechSynthesis.speak(spokenResponse)

            // Execute tool in background
            let result = try await toolRegistry.executeTool(
                toolCall.toolName,
                toolCall.args
            )

            // Optional: speak result if needed
            if case .success(let confirm) = result {
                await speechSynthesis.speak(confirm.confirmation)
            }
        }

    case .toolResult(let result):
        // Tool execution completed — handle result
        break

    case .error(let error):
        // Handle error
        break
    }
}
```

---

## 7. Edge TTS Design

### SpeechSynthesisClient

```swift
@DependencyClient
struct SpeechSynthesisClient {
    /// Speak a confirmation phrase. Plays audio and returns when done (or interrupted).
    var speak: @Sendable (String) async throws -> Void

    /// Immediately stop any ongoing speech
    var stopSpeaking: @Sendable () async -> Void

    /// Check if currently speaking
    var isSpeaking: @Sendable () async -> Bool
}
```

### Implementation

```swift
actor SpeechSynthesisClientLive {
    private let ttsService = EdgeTTSService()

    func speak(_ text: String) async throws {
        // Generate MP3 to temp file
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tts-\(UUID().uuidString).mp3")

        let audioURL = try await ttsService.synthesize(
            text: text,
            voice: selectedVoice,  // e.g., "en-US-JennyNeural"
            outputURL: outputURL,
            rate: "+0%",
            volume: "+0%",
            pitch: "+0Hz"
        )

        // Play the audio
        let player = try AVAudioPlayer(contentsOf: audioURL)
        player.play()
        // Wait for completion or interruption
    }

    func stopSpeaking() {
        // Interrupt current playback
    }

    func isSpeaking() -> Bool {
        // Check if audio is currently playing
    }
}
```

**Interruption behavior:** When a new hotkey press starts recording, `stopSpeaking()` is called immediately so TTS doesn't conflict with the new recording.

---

## 8. macOS Native Storage Integration

### Reminders (EventKit)

```swift
import EventKit

struct AddToDoTool {
    let eventStore = EKEventStore()

    func execute(input: AddToDoInput) async throws -> ToolResult {
        let status = try await eventStore.requestAccess(to: .reminder)

        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = input.text
        reminder.calendar = eventStore.defaultCalendarForNewReminders()

        if let listName = input.list {
            // Find or create the list
            let calendars = eventStore.calendars(for: .reminder)
            if let calendar = calendars.first(where: { $0.title == listName }) {
                reminder.calendar = calendar
            }
        }

        try eventStore.save(reminder, commit: true)
        return .success(confirmation: "Added \(input.text) to your reminders.")
    }
}
```

### Notes (AppleScript)

```swift
struct CreateNoteTool {
    func execute(input: CreateNoteInput) async throws -> ToolResult {
        let script = """
        tell application "Notes"
            activate
            make new note with properties {name: "\(input.title)", body: "\(input.body)"}
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if error != nil { throw NoteError.failed }
        return .success(confirmation: "Note created: \(input.title)")
    }
}
```

---

## 9. Settings Design

### HexSettings Additions

```swift
public var autonomousModeEnabled: Bool = false
public var ttsEnabled: Bool = true
public var ttsVoice: String = "en-US-JennyNeural"  // Default Edge TTS voice
public var enabledToolIDs: [String] = ToolRegistry.defaultToolIDs
```

### Settings UI (inside AI Post-Processing Section)

```
─────────────────────────────────────────────
 AI Post-Processing
─────────────────────────────────────────────

Mode: [Off] [App-Aware] [Autonomous]

── When Autonomous is ON ──

  Available tools:
  ☑ Add to Reminders     — Add items to your reminders list
  ☑ Set Reminder         — Create time-based reminders
  ☐ Search Web           — Search the web
  ☐ Open Application     — Open an app
  ☐ Create Note          — Create a note in Notes.app

  TTS Confirmation: [On]
  TTS Voice: [en-US-JennyNeural ▼]
─────────────────────────────────────────────
```

The mode picker extends the existing `AIPostProcessingMode` enum:
- **Off** — No AI processing at all (current)
- **App-Aware** — AI post-processing with app context (current)
- **Autonomous** — AI + tool calling + TTS (new)

---

## 10. Implementation Steps

### Phase 1 — Foundation

- [ ] **Step 1.1:** Add SPM packages
  - `SwiftAISDK` + `OpenAIProvider` from `https://github.com/teunlao/swift-ai-sdk`
  - `SwiftEdgeTTS` from `https://github.com/herrkaefer/SwiftEdgeTTS`
  - Add to `Hex` target's Frameworks, Libraries, and Embedded Content

- [ ] **Step 1.2:** Extend `HexSettings`
  - Add `autonomousModeEnabled`, `ttsEnabled`, `ttsVoice`, `enabledToolIDs` fields
  - Add `.autonomous` case to `AIPostProcessingMode`
  - Register in `HexSettingsSchema`

- [ ] **Step 1.3:** Create `SpeechSynthesisClient`
  - `@DependencyClient` with `speak`, `stopSpeaking`, `isSpeaking`
  - Live implementation using `SwiftEdgeTTS` + `AVAudioPlayer`
  - Handle interruption (stop on new recording)

### Phase 2 — Tool System

- [ ] **Step 2.1:** Define `ToolDefinition<Input, Output>` + `AnyTool` + `ToolResult`
  - Generics + type erasure pattern
  - JSON encoding/decoding for arbitrary tool inputs/outputs
  - Bridge to Swift AI SDK's `tool()` format

- [ ] **Step 2.2:** Create `ToolRegistryClient`
  - Registry with all built-in tools
  - Filtering by `enabledToolIDs`
  - `executeTool(id:data:)` dispatch method

- [ ] **Step 2.3:** Implement built-in tools
  - `AddToDoTool` — EventKit (`EKReminder`)
  - `SetReminderTool` — EventKit (`EKReminder` + `EKAlarm`)
  - `SearchWebTool` — `NSWorkspace.shared.open`
  - `OpenAppTool` — `NSWorkspace.shared.openApplication`
  - `CreateNoteTool` — AppleScript → Notes.app

### Phase 3 — AI Orchestrator

- [ ] **Step 3.1:** Create `AIOrchestratorClient`
  - `@DependencyClient` with `process(text:context:)` method
  - Returns discriminated union: `enum AIOutput { case text(String), case toolCalls([ToolCallResult]) }`
  - Configures Groq provider via OpenAI-compatible provider
  - Uses `streamText` with tool definitions from registry

- [ ] **Step 3.2:** Implement tool detection + instant TTS wiring
  - In the stream, when a `toolCall` part arrives → immediately fire TTS
  - Execute tool in task group, optionally speak result

- [ ] **Step 3.3:** Wire into `TranscriptionFeature`
  - Add `@Dependency(\.aiOrchestrator)` and `@Dependency(\.speechSynthesis)`
  - In `handleTranscriptionResult`, check `hexSettings.autonomousModeEnabled`
  - If autonomous → route through orchestrator
  - If not → existing `aiPostProcessing` path (unchanged)

### Phase 4 — Settings UI

- [ ] **Step 4.1:** Extend `AIPostProcessingSectionView`
  - Add `.autonomous` option to the mode picker
  - Conditionally show tool enable/disable toggles
  - TTS voice selector (populated from Edge TTS available voices)
  - TTS enable/disable toggle

- [ ] **Step 4.2:** Add actions to `SettingsFeature`
  - `setAutonomousMode(Bool)`, `setTTSEnabled(Bool)`, `setTTSVoice(String)`
  - `toggleTool(String)`, `resetToolDefaults`

### Phase 5 — Polish

- [ ] **Step 5.1:** TTS interruption on new recording
  - When `.hotKeyPressed` fires while TTS is playing → stop TTS immediately
  - Add to `TranscriptionFeature`'s hotkey handler

- [ ] **Step 5.2:** Error handling
  - Tool execution failure → speak error via TTS
  - Network failure → fall back to normal dictation
  - Timeout → fall back to raw transcription

- [ ] **Step 5.3:** Multiple sequential tool calls
  - Support chaining: "Add milk to shopping list and remind me at 5pm"
  - Swift AI SDK supports this natively with parallel tool calls

---

## 11. Verification

| Scenario | Test |
|----------|------|
| Normal dictation works as before | Speak a sentence → verify it's cleaned + pasted (existing flow untouched) |
| Tool invocation triggers TTS + tool | Speak "Add buy milk to my reminders" → hear "Added buy milk to your reminders" → verify in Reminders.app |
| Multiple tool calls | Speak "Add eggs to shopping and remind me at 5pm" → both tools execute |
| TTS interruption on new recording | While TTS is playing, press hotkey → TTS stops, new recording starts |
| Autonomous mode off → no change | Toggle mode to Off/App-Aware → normal dictation behaves exactly as before |
| No API key → graceful fallback | Autonomous mode shows warning, falls back to normal dictation if no key |
| Settings persistence | Toggle tools on/off, change voice → restart app → settings preserved |

**Build & Test:**
```bash
xcodebuild -scheme Hex -configuration Debug
cd HexCore && swift test
xcodebuild test -scheme Hex
```

---

## 12. Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                        Hex App (TCA)                            │
│                                                                 │
│  ┌─────────────────────┐     ┌─────────────────────────────┐   │
│  │ TranscriptionFeature│     │      AI Orchestrator        │   │
│  │                     │     │        Client               │   │
│  │ • Record            │────▶│                             │   │
│  │ • Transcribe        │     │ ┌─────────────────────────┐ │   │
│  │ • Word Remap        │     │ │  Swift AI SDK           │ │   │
│  │ • Snippets          │     │ │  (Groq via OpenAI-comp) │ │   │
│  └──────────┬──────────┘     │ └───────────┬─────────────┘ │   │
│             │                │             │               │   │
│             ▼                │             ▼               │   │
│  ┌─────────────────────┐     │  ┌──────────────────────┐   │   │
│  │ AIPostProcessing    │     │  │  ToolRegistryClient  │   │   │
│  │ Client (unchanged)  │     │  │                      │   │   │
│  │                     │     │  │ • AddToDo (EventKit) │   │   │
│  │ • Groq (URLSession) │     │  │ • Reminder (EventKit)│   │   │
│  │ • App-aware format  │     │  │ • Search (NSWorkspace)│   │   │
│  └──────────┬──────────┘     │  │ • OpenApp (NSWorkspace)│   │   │
│             │                │  │ • CreateNote (AScript)│   │   │
│             ▼                │  └──────────────────────┘   │   │
│  ┌─────────────────────┐     │             │               │   │
│  │ PasteboardClient    │     │             ▼               │   │
│  │ (paste text)        │     │  ┌──────────────────────┐   │   │
│  └─────────────────────┘     │  │ SpeechSynthesis      │   │   │
│                              │  │ Client (Edge TTS)    │   │   │
│  ┌─────────────────────┐     │  └──────────────────────┘   │   │
│  │ SettingsFeature     │     │                             │   │
│  │                     │◀────│  Tool configs, TTS settings │   │
│  └─────────────────────┘     └─────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

**Data flow for Autonomous Mode:**

```
Transcribed Text
  → AIOrchestratorClient.process(text, context)
    → streamText(model, tools, prompt)
      → Stream inspection:
          ├── .toolCall → SpeechSynthesis.speak(confirmation) ──▶ User hears
          │                   └─▶ ToolRegistry.execute(id, args)
          │                         └─▶ EventKit / AppleScript / NSWorkspace
          │
          └── .textDelta → Accumulate cleaned text
  → If .text output (no tool call): paste via PasteboardClient (existing)
  → If .toolCalls output: all done (TTS already fired)
```

---

## 13. Future Considerations

- **Custom tool registration** — Users define their own tools via config file
- **Proactive suggestions** — AI suggests actions even without explicit tool calls
- **On-device LLM** — Use local models for tool detection (privacy-first)
- **Calendar integration** — Create events via EventKit
- **MCP server support** — Swift AI SDK already supports MCP tools
- **Voice shortcuts** — User-defined custom phrases → custom tool chains

---

## Appendix: Key SDK References

### Swift AI SDK — Tool Calling

```swift
import SwiftAISDK
import OpenAIProvider

// Groq provider setup
let provider = createOpenAI(settings: OpenAIProviderSettings(
    apiKey: groqAPIKey,
    baseURL: "https://api.groq.com/openai/v1"
))
let model = try provider.chat("llama-3.3-70b-versatile")

// Typed tool
struct TodoInput: Codable, Sendable { let text: String; let list: String? }
let todoTool = tool(
    description: "Add an item to the user's to-do list",
    inputSchema: TodoInput.self,
    execute: { input, _ in
        let result = try await addToReminders(input)
        return result
    }
)

// Streaming with tools
let stream = try streamText(
    model: model,
    tools: ["add_todo": todoTool.eraseToTool()],
    prompt: transcription
)
for try await part in stream.fullStream {
    switch part {
    case .toolCall(let call):
        // Immediately speak confirmation
        await speechSynthesis.speak("Added to your reminders!")
    case .textDelta(let delta):
        buffer += delta
    default: break
    }
}
```

### Edge TTS

```swift
import SwiftEdgeTTS

let tts = EdgeTTSService()
let audioURL = try await tts.synthesize(
    text: "Done! Added to your reminders.",
    voice: "en-US-JennyNeural",
    outputURL: tempFileURL,
    rate: "+0%",
    volume: "+0%",
    pitch: "+0Hz"
)
// Play audioURL with AVAudioPlayer
```
