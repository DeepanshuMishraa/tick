//! AI post-processing text logic: prompts, deterministic normalization,
//! chunking, edit-script application, and output validation.
//!
//! A bad completion must never replace a good raw transcription, so every
//! model output passes through `validate_output` or `apply_edit_script`.

use fancy_regex::Regex;
use serde::Deserialize;
use unicode_segmentation::UnicodeSegmentation;

use crate::app_context::{AppCategory, AppContext};
use crate::settings::WritingStyle;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OutputContract {
    FinalText,
    EditScript,
}

impl OutputContract {
    fn instructions(self) -> &'static str {
        match self {
            Self::FinalText => "Output only the final text. No reasoning, explanations, markdown code fences, or labels. The source input is always non-empty, so the output must also be non-empty.",
            Self::EditScript => concat!(
                "Return only compact JSON in this exact shape: {\"edits\":[{\"old\":\"exact unique source text\",\"new\":\"replacement text\"}]}\n",
                "- `old` must be a non-empty, exact, uniquely occurring substring copied from the source.\n",
                "- Use the fewest edits needed. Preserve every source passage that does not need a change.\n",
                "- Use {\"edits\":[]} when the source already needs no changes.\n",
                "- Encode line breaks inside JSON strings as \\n.\n",
                "- Never return the rewritten transcript, reasoning, markdown fences, labels, or keys other than `edits`, `old`, and `new`."
            ),
        }
    }
}

const BASE_PROMPT: &str = concat!(
    "You are Tick's fast, intelligent on-device dictation formatter. Determine the final text intended for typing.\n",
    "\n",
    "This is a text-transformation task, not a question-answering task:\n",
    "- Never answer, solve, explain, or comment on what the user dictated.\n",
    "- Never begin with conversational filler such as \"Sure\", \"Certainly\", \"Of course\", or \"Here is\".\n",
    "- Preserve the user's intended meaning and wording; clean and format it for insertion into the active field.\n",
    "- If the dictation contains a request (for example, \"write an email to ...\"), produce the requested text to type, but do not discuss the request or add an assistant reply.\n",
    "- When uncertain about intent, make only conservative transcription corrections and return the cleaned dictation.\n",
    "\n",
    "Core Formatting Rules:\n",
    "- Remove spoken hesitation and waiting fillers before returning text: standalone \"um\", \"umm\", \"ummm\", \"uh\", \"uhh\", \"uhhh\", \"ah\", \"ahh\", \"er\", \"err\", \"erm\", \"hmm\", and \"hm\". Remove standalone \"like\" or \"you know\" only when clearly used as filler, never when they carry meaning or appear in a name, quote, code, URL, or identifier. Never leave filler runs, commas, or extra spaces behind. Then fix spelling, grammar, punctuation, and capitalization.\n",
    "- Resolve real-time speech corrections before formatting: in \"meet me at 3pm, no sorry 4pm\", output \"meet me at 4pm\" only. Treat \"no wait\", \"actually\", and \"I mean\" similarly.\n",
    "- Convert spoken structural commands (\"new line\", \"next line\", \"new paragraph\", \"comma\", \"period\", \"question mark\", \"colon\") into real formatting.\n",
    "- Handle lists naturally: treat \"first thing is ...\", \"second thing is ...\", \"third thing is ...\" and similar markers as hard boundaries between ordered list items. Number items consecutively in ordered lists (1., 2., 3.). A spoken request for an unordered list produces bulleted items (`- `).\n",
    "\n",
    "Intelligent Content & App Adaptation:\n",
    "- Email / Letter Intent: If the dictation explicitly asks for an email/letter, includes email structure, or the active app/site is Mail, Gmail, or Outlook, format it as an email: greeting, spaced body paragraphs, and a professional closing when appropriate. Preserve all dictated facts. Do not invent recipients, subject lines, claims, dates, or signatures; use a neutral greeting/closing only when the format requires one.\n",
    "- Chat / Messaging Intent: If the content is a direct conversational message (or the active app/site is Slack, Discord, Messages, Teams, WhatsApp), format as a concise, natural, fluid chat message without formal email headers or sign-offs.\n",
    "- Notes / Documents / Code: If the content is structured notes, bullet points, or code/technical commands, preserve exact technical identifiers, syntax, numbers, URLs, and email addresses.\n"
);

fn style_instructions(style: WritingStyle) -> &'static str {
    match style {
        WritingStyle::Formal => concat!(
            "\nSELECTED WRITING STYLE: FORMAL\n",
            "- Use standard capitalization, grammar, and punctuation.\n",
            "- Use a polished, professional tone without changing the speaker's meaning.\n",
            "- End complete prose sentences with appropriate punctuation.\n",
            "- For an unordered list, use one bullet per line. For an explicitly ordered list, use `1.`, `2.`, `3.`."
        ),
        WritingStyle::Casual => concat!(
            "\nSELECTED WRITING STYLE: CASUAL\n",
            "- Keep sentence-initial capitalization and proper nouns capitalized.\n",
            "- Use a relaxed, natural, friendly tone.\n",
            "- Do not force a final period on a short chat/message unless it improves clarity.\n",
            "- Preserve intentional emphasis and contractions; do not add slang or emoji."
        ),
        WritingStyle::VeryCasual => concat!(
            "\nSELECTED WRITING STYLE: VERY CASUAL\n",
            "- Use lowercase for prose, including sentence starts, while preserving required spelling of code, commands, URLs, email addresses, and identifiers.\n",
            "- Keep punctuation light and the tone very informal.\n",
            "- Do not add slang, emoji, or content that was not spoken."
        ),
    }
}

fn url_hint(host: &str) -> &'static str {
    let lower = host.to_lowercase();
    if lower.contains("mail.google.com") || lower.contains("gmail.com") {
        "- The user is in Gmail: strictly format as a professional email. Even if the transcription is a short instruction or brief note (e.g., \"tell John I am on my way\"), you MUST expand and structure it into a complete email format: greeting (e.g., \"Hi John,\"), body (e.g., \"I wanted to let you know that I am on my way.\"), and sign-off (e.g., \"Best regards,\"). You are explicitly authorized to add standard structural email layouts."
    } else if lower.contains("outlook.") || lower.contains("mail.yahoo.com") {
        "- The user is in an email client (Outlook/Yahoo): format as a professional email. If the dictation is a short message or instruction, expand and structure it with a greeting, spaced body paragraphs, and an appropriate closing sign-off."
    } else if lower.contains("slack.com") || lower.contains("discord.com") {
        "- The user is in a messaging app (Slack/Discord): format as a concise, natural, conversational chat message. Keep paragraphs brief and do not use formal email greetings/closings."
    } else if lower.contains("notion.so") || lower.contains("notion.site") {
        "- The user is in Notion: format as clean, structured markdown notes with bullet points or headers (\"## \") where appropriate."
    } else if lower.contains("docs.google.com") {
        "- The user is in Google Docs: format as document prose with proper paragraphs, grammar, and formal punctuation."
    } else if lower.contains("github.com") {
        "- The user is on GitHub: format as markdown code comments, issue descriptions, pull requests, or commit messages depending on the dictated content."
    } else if lower.contains("jira.") || lower.contains("atlassian.net") {
        "- The user is in Jira: format as structured bug reports or task descriptions with bullet points."
    } else {
        ""
    }
}

/// System prompt for the formatter.
pub fn system_prompt(context: Option<&AppContext>, style: WritingStyle, contract: OutputContract) -> String {
    if contract == OutputContract::EditScript {
        return edit_script_prompt(context, style);
    }
    let mut details = String::new();
    if let Some(context) = context.filter(|c| c.category() != AppCategory::Other || c.app_name != "Unknown") {
        let category = context.category();
        details.push_str(&format!(
            "\n\nApplication Context:\n- Active Application: {}\n- Category: {}",
            context.app_name,
            category.display_name()
        ));
        if !category.system_prompt_context().is_empty() {
            details.push_str(&format!("\n- Category hints: {}", category.system_prompt_context()));
        }
        if let Some(host) = context.browser_url_host() {
            details.push_str(&format!("\n- Browser Site: {host}"));
            let hint = url_hint(&host);
            if !hint.is_empty() {
                details.push('\n');
                details.push_str(hint);
            }
        }
    }
    format!("{BASE_PROMPT}{details}{}\n\n{}", style_instructions(style), contract.instructions())
}

fn edit_script_prompt(context: Option<&AppContext>, style: WritingStyle) -> String {
    let style_text = match style {
        WritingStyle::Formal => "Formal: standard capitalization, polished grammar, complete punctuation. End complete prose sentences with appropriate punctuation.",
        WritingStyle::Casual => "Casual: sentence-initial and proper-noun capitalization, relaxed friendly tone, light punctuation. Do not force a final period on a short chat/message unless it improves clarity.",
        WritingStyle::VeryCasual => "Very casual: lowercase ordinary prose and keep punctuation light; preserve identifiers and proper technical spelling.",
    };
    let mut context_text = String::new();
    if let Some(context) = context {
        context_text = format!(
            " Active app: {}, category: {}.",
            context.app_name,
            context.category().display_name()
        );
        if let Some(host) = context.browser_url_host() {
            context_text.push_str(&format!(" Site: {host}."));
        }
    }
    format!(
        concat!(
            "You are Tick's dictation formatter. Transform the non-empty source dictation into clean text ready to type, expressed ONLY as minimal exact replacement operations. This is a text-transformation task, not question-answering: never answer, solve, explain, or comment on the dictation, and never begin with filler such as \"Sure\" or \"Here is\". If the dictation contains a request (for example, \"write an email to ...\"), produce the requested text to type without discussing it.\n",
            "\n",
            "Apply these formatting rules through exact replacements, using the fewest edits needed:\n",
            "- Fillers: remove standalone hesitation fillers (\"um\", \"uh\", \"ah\", \"er\", \"erm\", \"hmm\", \"hm\" and repeats). Remove standalone \"like\" or \"you know\" only when clearly filler, never inside names, quotes, code, URLs, or identifiers. Never leave filler runs, stray commas, or double spaces behind.\n",
            "- Self-corrections: resolve real-time corrections before formatting. In \"meet me at 3pm, no sorry 4pm\", keep only \"meet me at 4pm\". Treat \"no wait\", \"actually\", and \"I mean\" the same way.\n",
            "- Spoken punctuation and layout: convert spoken cues (\"comma\", \"period\", \"question mark\", \"exclamation mark\", \"colon\", \"new line\", \"next line\", \"new paragraph\") into real punctuation and line breaks.\n",
            "- Lists: treat \"first ...\", \"second ...\", \"third ...\" and similar markers as boundaries between ordered items numbered consecutively (1., 2., 3.). A spoken request for an unordered list produces bulleted items (\"- \").\n",
            "- Intent: an explicit email/letter request (or email structure) becomes greeting, spaced body paragraphs, and a professional closing; never invent recipients, subjects, dates, or signatures. A direct conversational message stays a concise chat message with no email headers or sign-offs. Notes, code, and technical content keep exact identifiers, syntax, numbers, URLs, and email addresses.\n",
            "- Style: {style}{context}\n",
            "{contract}"
        ),
        style = style_text,
        context = context_text,
        contract = OutputContract::EditScript.instructions()
    )
}

/// Appended to the prompt when a long dictation is processed in segments.
pub const CHUNK_PROMPT_SUFFIX: &str = "\nYou are processing one internal segment of a longer dictation. Edit only this segment. Do not add greetings, closings, headings, list markers, or facts that are not present in this segment. Return only the required compact JSON edit script.";

/// Terminal context only helps for command-like dictation; ordinary prose
/// typed into a terminal would otherwise be mangled into shell syntax.
pub fn effective_app_context<'a>(context: Option<&'a AppContext>, text: &str) -> Option<&'a AppContext> {
    let context = context?;
    if context.category() != AppCategory::Terminal {
        return Some(context);
    }
    let lower = text.trim().to_lowercase();
    const PREFIXES: [&str; 26] = [
        "git ", "cd ", "ls", "pwd", "mkdir ", "rm ", "cp ", "mv ", "cat ", "grep ", "rg ", "find ", "curl ",
        "ssh ", "docker ", "brew ", "bun ", "npm ", "pnpm ", "yarn ", "swift ", "xcodebuild ",
        "create directory ", "list files", "run command ", "execute ",
    ];
    (PREFIXES.iter().any(|prefix| lower.starts_with(prefix)) || text.contains('\n')).then_some(context)
}

/// Token budget for an edit script; scripts describe only changes, so the
/// budget stays bounded regardless of transcript length.
pub fn max_output_tokens(source: &str) -> i32 {
    let estimate = i32::try_from(source.len() / 10).unwrap_or(i32::MAX).saturating_add(24);
    estimate.clamp(32, 96)
}

/// Compiles a built-in, case-insensitive pattern. The inline flag is used
/// because the builder flag is not honored for every construct.
fn ci(pattern: &str) -> Regex {
    Regex::new(&format!("(?i){pattern}"))
        .unwrap_or_else(|error| panic!("invalid built-in pattern {pattern}: {error}"))
}

fn grapheme_count(text: &str) -> usize {
    text.graphemes(true).count()
}

// MARK: - Chunking

const TARGET_CHUNK: usize = 240;
const FORCED_SPLIT: usize = 800;

/// Splits independent prose into segments so long dictations stay within the
/// local model's budget. Structured content stays whole.
pub fn chunks(text: &str) -> Vec<String> {
    let length = grapheme_count(text);
    let semantic = length >= 160 && is_independent_prose(text);
    if !semantic && length < FORCED_SPLIT {
        return vec![text.to_string()];
    }
    let sentences: Vec<String> = text
        .split_sentence_bounds()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .flat_map(split_oversized)
        .collect();
    if sentences.len() <= 1 {
        let pieces = split_oversized(text);
        return if pieces.len() > 1 { pieces } else { vec![text.to_string()] };
    }
    let mut result = Vec::new();
    let mut current = String::new();
    for sentence in sentences {
        let combined = if current.is_empty() {
            grapheme_count(&sentence)
        } else {
            grapheme_count(&current) + 1 + grapheme_count(&sentence)
        };
        if !current.is_empty() && combined > TARGET_CHUNK {
            result.push(std::mem::replace(&mut current, sentence));
        } else {
            if !current.is_empty() {
                current.push(' ');
            }
            current.push_str(&sentence);
        }
    }
    if !current.is_empty() {
        result.push(current);
    }
    if result.len() > 1 { result } else { vec![text.to_string()] }
}

fn split_oversized(text: &str) -> Vec<String> {
    if grapheme_count(text) <= TARGET_CHUNK {
        return vec![text.to_string()];
    }
    let mut pieces = Vec::new();
    let mut current = String::new();
    for word in text.split_whitespace() {
        if !current.is_empty() && grapheme_count(&current) + 1 + grapheme_count(word) > TARGET_CHUNK {
            pieces.push(std::mem::take(&mut current));
        }
        if !current.is_empty() {
            current.push(' ');
        }
        current.push_str(word);
    }
    if !current.is_empty() {
        pieces.push(current);
    }
    pieces
}

fn is_independent_prose(text: &str) -> bool {
    let lower = text.to_lowercase();
    const CUES: [&str; 6] = ["new line", "new paragraph", "bullet point", "first thing", "second thing", "subject line"];
    !text.contains('\n') && !CUES.iter().any(|cue| lower.contains(cue))
}

// MARK: - Deterministic normalizer

const CORRECTION_CUES: [&str; 5] = ["no, sorry", "no sorry", "no, wait", "no wait", "i mean"];

/// Removes fillers and applies high-confidence spoken corrections and list
/// markers. Also the fallback when the model is unavailable or fails.
pub fn normalize(text: &str) -> String {
    let mut value = remove_spoken_fillers(text);
    for _ in 0..3 {
        let Some((start, end)) = earliest_cue(&value) else { break };
        let replacement = value[end..]
            .trim_matches(|c: char| c.is_whitespace() || matches!(c, ',' | ';' | ':'))
            .to_string();
        if replacement.is_empty() {
            break;
        }
        let Some(prefix) = replacing_abandoned_phrase(&value[..start]) else { break };
        value = format!("{prefix} {replacement}");
    }
    value = spoken_ordered_list(&value);
    ci(r"[^\S\r\n]+").replace_all(&value, " ").trim().to_string()
}

fn remove_spoken_fillers(text: &str) -> String {
    let parenthetical = ci(r",\s*(?:um+|uh+|ah+|hm+|hmm+|er+|erm)(?![\p{L}\p{N}]),\s*");
    let filler = ci(r"(?<![\p{L}\p{N}])(?:um+|uh+|ah+|hm+|hmm+|er+|erm)(?![\p{L}\p{N}])[,;:!?]*\s*");
    let without_parenthetical = parenthetical.replace_all(text, " ").into_owned();
    filler.replace_all(&without_parenthetical, "").into_owned()
}

fn earliest_cue(text: &str) -> Option<(usize, usize)> {
    let lower = text.to_lowercase();
    // Lowercasing can change byte lengths for non-ASCII text; only trust the
    // offsets when it did not.
    if lower.len() != text.len() {
        return None;
    }
    CORRECTION_CUES
        .iter()
        .filter_map(|cue| lower.find(cue).map(|start| (start, start + cue.len())))
        .min_by_key(|(start, _)| *start)
}

fn replacing_abandoned_phrase(prefix: &str) -> Option<String> {
    let mut phrase = prefix.trim().to_string();
    while phrase.ends_with([',', ';', ':']) {
        phrase.pop();
        phrase = phrase.trim().to_string();
    }
    // A complete abandoned sentence: keep earlier sentences, drop this one.
    if phrase.ends_with(['.', '!', '?']) {
        phrase.pop();
        phrase = phrase.trim().to_string();
    }
    if let Some(boundary) = phrase.rfind(['.', '!', '?', '\n']) {
        let preserved = phrase[..=boundary].trim();
        if !preserved.is_empty() {
            return Some(preserved.to_string());
        }
    }
    let mut words: Vec<&str> = phrase.split_whitespace().collect();
    if words.is_empty() {
        return None;
    }
    const ANCHORS: [&str; 8] = ["at", "on", "to", "for", "from", "in", "with", "as"];
    let anchor = words.iter().rposition(|word| {
        let cleaned = word.to_lowercase();
        let cleaned = cleaned.trim_matches(|c: char| c.is_ascii_punctuation());
        ANCHORS.contains(&cleaned)
    });
    match anchor {
        Some(index) => words.truncate(index + 1),
        None => {
            words.pop();
        }
    }
    Some(words.join(" "))
}

fn spoken_ordered_list(text: &str) -> String {
    let marker = ci(
        r"\b(?:the\s+)?(?:first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)\s+(?:thing|item|point|step)\s+(?:is|:)\s*",
    );
    let matches: Vec<(usize, usize)> = marker
        .find_iter(text)
        .filter_map(Result::ok)
        .map(|m| (m.start(), m.end()))
        .collect();
    if matches.len() < 2 {
        return text.to_string();
    }
    let prefix = ci(r"\bthe\s*$").replace_all(&text[..matches[0].0], "").trim().to_string();
    let trailing_joiner = ci(r"\s+(?:and|then)\s*$");
    let items: Vec<String> = matches
        .iter()
        .enumerate()
        .filter_map(|(index, (_, end))| {
            let content_end = matches.get(index + 1).map_or(text.len(), |next| next.0);
            let content = text[*end..content_end].trim();
            let content = trailing_joiner.replace_all(content, "").trim().to_string();
            (!content.is_empty()).then_some(content)
        })
        .collect();
    if items.len() < 2 {
        return text.to_string();
    }
    let numbered: Vec<String> = items.iter().enumerate().map(|(i, item)| format!("{}. {item}", i + 1)).collect();
    if prefix.is_empty() {
        numbered.join("\n")
    } else {
        format!("{prefix}\n{}", numbered.join("\n"))
    }
}

// MARK: - Edit scripts

#[derive(Deserialize)]
struct EditPayload {
    edits: Vec<Edit>,
}

#[derive(Deserialize)]
struct Edit {
    old: String,
    new: String,
}

/// Applies a model-generated `{"edits":[...]}` script. Every `old` must occur
/// exactly once and edits may not overlap; anything else is rejected.
pub fn apply_edit_script(output: &str, source: &str) -> Option<String> {
    let trimmed = output.trim();
    if trimmed.contains("```") {
        return None;
    }
    let payload: EditPayload = serde_json::from_str(trimmed).ok()?;
    if payload.edits.len() > 24 {
        return None;
    }
    if payload.edits.is_empty() {
        return Some(source.to_string());
    }
    let mut located: Vec<(usize, usize, &str)> = Vec::new();
    for edit in &payload.edits {
        if edit.old.is_empty() {
            return None;
        }
        let occurrences: Vec<usize> = source.match_indices(edit.old.as_str()).map(|(i, _)| i).collect();
        let [start] = occurrences[..] else { return None };
        let end = start + edit.old.len();
        if located.iter().any(|(s, e, _)| start < *e && *s < end) {
            return None;
        }
        located.push((start, end, edit.new.as_str()));
    }
    located.sort_by_key(|(start, _, _)| std::cmp::Reverse(*start));
    let mut result = source.to_string();
    for (start, end, replacement) in located {
        result.replace_range(start..end, replacement);
    }
    validate_output(&result, Some(source))
}

// MARK: - Validation

const WRAPPER_PREFIXES: [&str; 6] = [
    "corrected transcription:",
    "corrected text:",
    "final answer:",
    "here is the corrected text:",
    "here's the corrected text:",
    "output:",
];

fn find_ci(haystack: &str, needle: &str, from: usize) -> Option<usize> {
    haystack[from..].to_ascii_lowercase().find(&needle.to_ascii_lowercase()).map(|i| i + from)
}

fn remove_model_artifacts(output: &str) -> Option<String> {
    let mut value = output.trim().to_string();
    for (open, close) in [("<think>", "</think>"), ("<reasoning>", "</reasoning>"), ("<analysis>", "</analysis>")] {
        while let Some(start) = find_ci(&value, open, 0) {
            let end = find_ci(&value, close, start + open.len())?;
            value.replace_range(start..end + close.len(), "");
        }
    }
    for marker in ["<|im_start|>", "<|im_end|>", "<|endoftext|>"] {
        while let Some(start) = find_ci(&value, marker, 0) {
            value.replace_range(start..start + marker.len(), "");
        }
    }
    Some(value.trim().to_string())
}

fn remove_wrapper_prefix(output: &str) -> String {
    let lower = output.to_lowercase();
    match WRAPPER_PREFIXES.iter().find(|prefix| lower.starts_with(*prefix)) {
        Some(prefix) if output.is_char_boundary(prefix.len()) => output[prefix.len()..].trim().to_string(),
        _ => output.to_string(),
    }
}

/// Returns cleaned model output, or `None` when it must not replace the
/// source (reasoning leaks, wrappers, answers instead of formatting,
/// severe truncation).
pub fn validate_output(output: &str, source: Option<&str>) -> Option<String> {
    let value = remove_wrapper_prefix(&remove_model_artifacts(output)?);
    if value.is_empty() || value.eq_ignore_ascii_case("EMPTY") {
        return None;
    }
    const INVALID: [&str; 10] = [
        "<think>", "</think>", "<reasoning>", "</reasoning>", "<analysis>", "</analysis>", "<|im_start|>",
        "<|im_end|>", "<|endoftext|>", "```",
    ];
    let lower = value.to_lowercase();
    if INVALID.iter().any(|marker| lower.contains(marker)) {
        return None;
    }
    let first_line = lower.lines().next().unwrap_or_default().trim().to_string();
    if WRAPPER_PREFIXES.iter().any(|prefix| first_line.starts_with(prefix)) {
        return None;
    }
    let Some(source) = source else { return Some(value) };
    let source_lower = source.trim().to_lowercase();
    const ANSWERS: [&str; 9] = [
        "sure", "certainly", "of course", "absolutely", "i'd be happy to", "the answer is", "you should",
        "you can", "as an ai",
    ];
    if ANSWERS.iter().any(|prefix| lower.starts_with(prefix) && !source_lower.starts_with(prefix)) {
        return None;
    }
    let source_words = source.split_whitespace().count();
    let output_words = value.split_whitespace().count();
    if source_words >= 12 && output_words * 100 < source_words * 45 {
        return None;
    }
    Some(normalize_list_formatting(&normalize(&value), source))
}

fn normalize_list_formatting(output: &str, source: &str) -> String {
    let source = source.to_lowercase();
    let has_list_cue = source.contains("list");
    let has_ordered_cue = ["first", "second", "third", "fourth", "step", "numbered", "in order", "number one"]
        .iter()
        .any(|cue| source.contains(cue));
    if !has_list_cue && !has_ordered_cue {
        return output.to_string();
    }
    let mut lines: Vec<String> = output.split('\n').map(str::to_string).collect();
    if lines.iter().filter(|line| numbered_content(line).is_some()).count() < 2 {
        return output.to_string();
    }
    let mut number = 0;
    for line in &mut lines {
        if let Some(content) = numbered_content(line) {
            number += 1;
            *line = if has_ordered_cue { format!("{number}. {content}") } else { format!("- {content}") };
        }
    }
    lines.join("\n")
}

fn numbered_content(line: &str) -> Option<String> {
    let trimmed = line.trim();
    let digits = trimmed.chars().take_while(char::is_ascii_digit).count();
    if digits == 0 {
        return None;
    }
    let rest = &trimmed[digits..];
    let content = rest.strip_prefix('.').or_else(|| rest.strip_prefix(')'))?.trim();
    (!content.is_empty()).then(|| content.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn prompt(style: WritingStyle) -> String {
        system_prompt(None, style, OutputContract::FinalText)
    }

    #[test]
    fn prompts_include_style_and_list_rules() {
        assert!(prompt(WritingStyle::Formal).contains("SELECTED WRITING STYLE: FORMAL"));
        assert!(prompt(WritingStyle::Casual).contains("SELECTED WRITING STYLE: CASUAL"));
        assert!(prompt(WritingStyle::VeryCasual).contains("SELECTED WRITING STYLE: VERY CASUAL"));
        assert!(prompt(WritingStyle::Formal).contains("Number items consecutively"));
        assert!(prompt(WritingStyle::Formal).contains("unordered list"));
    }

    #[test]
    fn edit_script_prompt_uses_compact_contract() {
        let p = system_prompt(None, WritingStyle::VeryCasual, OutputContract::EditScript);
        assert!(p.contains(r#"{"edits":[]}"#));
        assert!(p.contains("exact, uniquely occurring substring"));
        assert!(!p.contains("Output only the final text"));
    }

    #[test]
    fn smart_prompt_keeps_context_and_style() {
        let context = AppContext { bundle_id: "com.apple.Terminal".into(), app_name: "Terminal".into(), url: None };
        let p = system_prompt(Some(&context), WritingStyle::Casual, OutputContract::FinalText);
        assert!(p.contains("Terminal"));
        assert!(p.contains("raw shell command"));
        assert!(p.contains("SELECTED WRITING STYLE: CASUAL"));
    }

    #[test]
    fn prompt_forces_transformation() {
        let p = prompt(WritingStyle::VeryCasual);
        assert!(p.contains("text-transformation task, not a question-answering task"));
        assert!(p.contains("Never answer, solve, explain, or comment"));
        assert!(p.contains("Email / Letter Intent"));
        assert!(p.contains("Do not invent recipients"));
    }

    #[test]
    fn edit_scripts() {
        let source = "This text is already correct.";
        assert_eq!(apply_edit_script(r#"{"edits":[]}"#, source).as_deref(), Some(source));
        assert_eq!(
            apply_edit_script(
                r#"{"edits":[{"old":"Red bull","new":"Red Bull"},{"old":"Formula Win","new":"Formula One"}]}"#,
                "George drives for Red bull in Formula Win."
            )
            .as_deref(),
            Some("George drives for Red Bull in Formula One.")
        );
        assert_eq!(apply_edit_script(r#"{"edits":[{"old":"hello","new":"hi"}]}"#, "hello hello"), None);
        assert_eq!(apply_edit_script(r#"{"edits":[{"old":"missing","new":"x"}]}"#, "complete source"), None);
        assert_eq!(apply_edit_script("not json", "source"), None);
        assert_eq!(apply_edit_script("```json\\n{\"edits\":[]}\\n```", "source"), None);
    }

    #[test]
    fn validator_artifacts_and_wrappers() {
        assert_eq!(validate_output("", None), None);
        assert_eq!(validate_output("EMPTY", None), None);
        assert_eq!(validate_output("<think>private reasoning</think>answer", None).as_deref(), Some("answer"));
        assert_eq!(validate_output("Corrected text:\nhello", None).as_deref(), Some("hello"));
        assert_eq!(validate_output("<think>unfinished reasoning", None), None);
        assert_eq!(validate_output("```bash\nls\n```", None), None);
    }

    #[test]
    fn validator_rejects_answers_and_truncation() {
        assert_eq!(validate_output("Sure, the answer is 42.", Some("what is the answer to life")), None);
        let source = "This complete dictation contains many important details about the project schedule, owners, launch date, customer impact, migration plan, and required follow-up work.";
        assert_eq!(validate_output("The project schedule changed.", Some(source)), None);
        let formatted = "1. First item\n2. Second item\n\nA new paragraph.";
        assert_eq!(validate_output(formatted, None).as_deref(), Some(formatted));
    }

    #[test]
    fn chunker() {
        let input = "George Russell is a very fast driver for Mercedes. He has shown strong pace throughout the season. His qualifying performances have been especially impressive. The team expects him to keep improving over the next few races. Engineers will review the latest data before preparing the car for the next event.";
        let parts = chunks(input);
        assert!(parts.len() > 1);
        assert_eq!(parts.join(" "), input);

        let layout = "Start with an introduction about tomorrow's meeting. New paragraph. Add the report details and ask everyone to confirm the time before the end of the day.";
        assert_eq!(chunks(layout), vec![layout.to_string()]);

        let email = "Hello Sam. I'm writing this email to tell you about tomorrow's meeting and the report we need to review. Please bring the latest figures and confirm the time before the end of the day. I know the schedule is tight, but we should have enough time to finish everything.";
        assert!(chunks(email).len() > 1);

        let short = "Please send the report tomorrow.";
        assert_eq!(chunks(short), vec![short.to_string()]);

        let run_on = vec!["complete transcription content"; 100].join(" ");
        let parts = chunks(&run_on);
        assert!(parts.len() > 4);
        assert!(parts.iter().all(|p| p.chars().count() <= 240));
        assert_eq!(parts.join(" "), run_on);

        let structured = format!("new paragraph {}", vec!["important structured detail"; 40].join(" "));
        let parts = chunks(&structured);
        assert!(parts.len() > 1);
        assert_eq!(parts.join(" "), structured);
    }

    #[test]
    fn normalizer() {
        assert_eq!(normalize("meet me at 3pm, no sorry 4pm"), "meet me at 4pm");
        assert_eq!(normalize("um uh ahh I need to, erm, send this"), "I need to send this");
        assert_eq!(normalize("use the umber variable, uh oh"), "use the umber variable, oh");
        assert_eq!(
            normalize("The first thing is hello everyone. Second thing is hello, how are you? And third thing is how are you doing, mate."),
            "1. hello everyone.\n2. hello, how are you?\n3. how are you doing, mate."
        );
        assert_eq!(
            normalize("hello, George. I'm telling you some things that you should take care of. The first thing is hello everyone. Second thing is hello, how are you? And third thing is how are you doing, mate."),
            "hello, George. I'm telling you some things that you should take care of.\n1. hello everyone.\n2. hello, how are you?\n3. how are you doing, mate."
        );
        assert_eq!(
            normalize("hello, how are you? I will meet you at four PM. No sorry, I will meet you at three PM."),
            "hello, how are you? I will meet you at three PM."
        );
    }

    #[test]
    fn list_repair() {
        assert_eq!(
            validate_output("1. Nice\n2. Fair\n4. Great", Some("give me a list of three things: first nice, second fair, fourth great")).as_deref(),
            Some("1. Nice\n2. Fair\n3. Great")
        );
        let source = "The first thing is hello everyone. Second thing is hello, how are you? Third thing is how are you doing, mate.";
        let output = "1. hello everyone.\n2. hello, how are you?\n3. how are you doing, mate.";
        assert_eq!(validate_output(output, Some(source)).as_deref(), Some(output));
        assert_eq!(validate_output(source, Some(source)).as_deref(), Some(output));
        assert_eq!(
            validate_output("1. Nice\n2. Fair\n3. Great", Some("give me a list of three things: nice, fair, and great")).as_deref(),
            Some("- Nice\n- Fair\n- Great")
        );
    }
}
