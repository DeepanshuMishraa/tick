//! The application a dictation is aimed at, used to adapt AI formatting.

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AppCategory {
    Terminal,
    Email,
    CodeEditor,
    Chat,
    Browser,
    Notes,
    Document,
    Spreadsheet,
    Other,
}

impl AppCategory {
    pub fn display_name(self) -> &'static str {
        match self {
            Self::Terminal => "Terminal",
            Self::Email => "Email",
            Self::CodeEditor => "Code Editor",
            Self::Chat => "Chat",
            Self::Browser => "Browser",
            Self::Notes => "Notes",
            Self::Document => "Document",
            Self::Spreadsheet => "Spreadsheet",
            Self::Other => "Other",
        }
    }

    pub fn from_bundle_id(bundle_id: &str) -> Self {
        use AppCategory::*;
        match bundle_id {
            "com.apple.Terminal" | "com.googlecode.iterm2" | "dev.warp.Warp-Stable" | "org.alacritty"
            | "io.alacritty" | "com.googlecode.macvim" | "org.vim.MacVim" | "com.github.wez.wezterm"
            | "net.kovidgoyal.kitty" => Terminal,
            "com.apple.mail" | "com.microsoft.Outlook" | "com.freron.MailMate" | "com.apple.mobileme.mail" => Email,
            "com.apple.dt.Xcode" | "com.microsoft.VSCode" | "com.microsoft.VSCodeInsiders" | "com.sublimetext.4"
            | "com.sublimetext.3" | "com.jetbrains.intellij" | "com.jetbrains.intellij.ce"
            | "com.jetbrains.pycharm" | "com.jetbrains.webstorm" | "com.google.AndroidStudio" | "dev.zed.Zed"
            | "com.macromates.TextMate" | "com.panic.Nova" | "org.gnu.Emacs" | "org.vim" => CodeEditor,
            "com.apple.MobileSMS" | "com.slack.mac" | "com.hnc.Discord" | "com.microsoft.teams"
            | "com.telegram.telegram" | "com.whatsapp.WhatsApp" | "org.signal.Signal" | "co.monal.Monal"
            | "com.skype.skype" | "com.facebook.Messenger" => Chat,
            "com.apple.Safari" | "com.google.Chrome" | "org.mozilla.firefox" | "com.microsoft.edgemac"
            | "com.brave.Browser" | "company.thebrowser.Browser" | "com.vivaldi.Vivaldi"
            | "com.operasoftware.Opera" | "com.google.Chrome.canary" => Browser,
            "com.apple.Notes" | "md.notion" | "com.culturedcode.ThingsMac" | "com.agiletortoise.Drafts-OSX"
            | "com.brettterpstra.nvalt" | "notion.id" | "com.bear.bear-macos" | "com.apple.iWork.Keynote" => Notes,
            "com.apple.iWork.Pages" | "com.microsoft.Word" | "com.microsoft.Powerpoint" | "org.libreoffice.script" => {
                Document
            }
            "com.apple.iWork.Numbers" | "com.microsoft.Excel" => Spreadsheet,
            _ => Other,
        }
    }

    pub fn system_prompt_context(self) -> &'static str {
        match self {
            Self::Terminal => concat!(
                "The user is dictating into a terminal/command-line application. Format the output strictly as a raw shell command or sequence of commands:\n",
                "- Return ONLY the executable command line. Do NOT wrap the command in markdown code fences or blocks (e.g., do NOT use ```bash or ```).\n",
                "- Convert spoken punctuation or names into code syntax: e.g. \"dash dash\" to \"--\", \"hyphen\" to \"-\", \"slash\" to \"/\", \"dot\" to \".\", \"space\" to \" \", \"star\" to \"*\".\n",
                "- Use lowercase for command names, parameters, and flags unless specifically stated or required (e.g., \"git add dot\" → \"git add .\").\n",
                "- Transform colloquial dictation of a command message (like \"git commit this is a good landing page\", \"git commit this UI is so good\" or \"git commit message this is great\") into the correct flag syntax with quotation marks: e.g., `git commit -m \"this is a good landing page\"`, `git commit -m \"this UI is so good\"`, `git commit -m \"this is great\"`.\n",
                "- Never output syntactically invalid commands like `git commit this is a good landing page`. It MUST be formatted as a valid git command with the message flag, i.e., `git commit -m \"this is a good landing page\"`.\n",
                "- Convert colloquial commands into their actual executable forms (e.g., \"create directory src\" → \"mkdir src\", \"list files\" → \"ls\", \"push branch\" → \"git push\").\n",
                "- Remove all filler words, self-corrections, and conversational explanations completely.\n",
                "- Do not add periods, punctuation, or other sentence-ending characters at the end of the command line.\n",
                "- If dictating multiple commands, separate them onto their own lines or join them with \"&&\" depending on context."
            ),
            Self::Email => concat!(
                "The user is dictating into an email application. Format the output strictly as a well-structured email message:\n",
                "- If the user's dictation is short or outlines an instruction (e.g., \"email John about the launch tomorrow\"), expand it into a short but complete email structure. You are explicitly authorized to add standard structural text (like \"Dear John,\", \"Hope you are well.\", \"Best regards,\") to make it a valid, professional email layout.\n",
                "- Format the greeting (e.g., \"Dear Name,\", \"Hi Name,\") on its own line at the start, followed by a blank line. If the recipient name is unknown or not specified, use a friendly generic greeting like \"Hi,\" or \"Dear Team,\".\n",
                "- Separate body paragraphs with clean blank lines for readability.\n",
                "- Use a professional yet natural tone.\n",
                "- Add a sign-off (e.g., \"Best regards,\", \"Thanks,\", \"Sincerely,\") on its own line at the end.\n",
                "- Remove all spoken formatting cues (like \"new line\", \"comma\", \"period\", \"bullet point\") and replace them with actual formatting.\n",
                "- Clean up filler words and self-corrections."
            ),
            Self::CodeEditor => concat!(
                "The user is dictating into a code editor. Format the output appropriately for a programming context:\n",
                "- If the user dictates a shell or terminal command (e.g. starting with \"git commit\", \"npm install\", \"docker run\", etc.), format it strictly as a raw shell command without markdown code fences. Specifically, transform colloquial dictation of a command message (like \"git commit this is a good landing page\") into the correct flag syntax: e.g., `git commit -m \"this is a good landing page\"`.\n",
                "- If the content sounds like code, format it as code with appropriate syntax.\n",
                "- If the content sounds like a comment, format it as a code comment.\n",
                "- Use proper indentation and formatting conventions.\n",
                "- Preserve technical terms, variable names, and function names as spoken.\n",
                "- Clean up filler words but keep technical precision.\n",
                "- If dictating variable names or identifiers, use camelCase or snake_case as appropriate for the likely language."
            ),
            Self::Chat => concat!(
                "The user is dictating into a chat/messaging application. Format the output as a natural message:\n",
                "- Keep it conversational and concise\n",
                "- Clean up filler words (um, uh, like, you know) but preserve the casual tone\n",
                "- Add punctuation for readability\n",
                "- Do not add emoji unless the user said them explicitly\n",
                "- Handle self-corrections: use the corrected version"
            ),
            Self::Browser => concat!(
                "The user is dictating into a web browser. Format the output based on the website's context:\n",
                "- If on an email site (Gmail, Outlook, Yahoo Mail), strictly format the output as a well-structured email: put the greeting at the top, separate the body paragraphs with blank lines, and put the sign-off at the bottom.\n",
                "- If on a messaging or chat site (Slack web, WhatsApp web, Discord web), format as a concise, conversational message.\n",
                "- If on a document editor (Google Docs, Notion), format as organized text with proper formatting and structure.\n",
                "- Default: clean up filler words, add punctuation, and format nicely without conversational filler."
            ),
            Self::Notes => concat!(
                "The user is dictating into a note-taking application. Format the output as organized notes:\n",
                "- Use bullet points for lists of items\n",
                "- Add headers for topic changes (e.g., \"## \" prefix)\n",
                "- Preserve the user's structure and organization intent\n",
                "- Clean up filler words but keep the content complete\n",
                "- Proper punctuation and capitalization"
            ),
            Self::Document => concat!(
                "The user is dictating into a document editor. Format the output as well-structured prose:\n",
                "- Use proper paragraphs with clear topic sentences\n",
                "- Correct grammar and punctuation\n",
                "- Maintain professional tone appropriate for a document\n",
                "- Clean up filler words and self-corrections\n",
                "- Preserve the user's intended meaning precisely"
            ),
            Self::Spreadsheet => concat!(
                "The user is dictating into a spreadsheet application. Format the output appropriately:\n",
                "- If dictating data, format as tab-separated values or clear entries\n",
                "- If dictating formulas, use appropriate function syntax\n",
                "- Clean up filler words\n",
                "- Preserve numbers and mathematical expressions accurately"
            ),
            Self::Other => "",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppContext {
    pub bundle_id: String,
    pub app_name: String,
    pub url: Option<String>,
}

impl AppContext {
    pub fn category(&self) -> AppCategory {
        AppCategory::from_bundle_id(&self.bundle_id)
    }

    pub fn browser_url_host(&self) -> Option<String> {
        let url = self.url.as_deref()?;
        let rest = url.split_once("://")?.1;
        let authority = rest.split(['/', '?', '#']).next()?;
        let host_port = authority.rsplit_once('@').map_or(authority, |(_, host)| host);
        let host = host_port.split(':').next()?;
        (!host.is_empty()).then(|| host.to_string())
    }
}

/// AppleScript that returns the active tab URL for supported browsers.
pub fn browser_url_script(bundle_id: &str) -> Option<&'static str> {
    Some(match bundle_id {
        "com.apple.Safari" => r#"tell application "Safari" to get URL of current tab of front window"#,
        "com.google.Chrome" | "com.google.Chrome.canary" => {
            r#"tell application "Google Chrome" to get URL of active tab of front window"#
        }
        "company.thebrowser.Browser" => r#"tell application "Arc" to get URL of active tab of front window"#,
        "com.microsoft.edgemac" => r#"tell application "Microsoft Edge" to get URL of active tab of front window"#,
        "com.brave.Browser" => r#"tell application "Brave Browser" to get URL of active tab of front window"#,
        _ => return None,
    })
}
