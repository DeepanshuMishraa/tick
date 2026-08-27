//
//  KeyEvent.swift
//  HexCore
//
//  Created by Kit Langton on 1/28/25.
//

import Sauce

public enum InputEvent {
    case keyboard(KeyEvent)
    case mouseClick
}

public struct KeyEvent: Sendable {
    public let key: Key?
    public let modifiers: Modifiers
    public let text: String?
    public let isKeyDown: Bool
    
    public init(
        key: Key?,
        modifiers: Modifiers,
        text: String? = nil,
        isKeyDown: Bool = true
    ) {
        self.key = key
        self.modifiers = modifiers
        self.text = text
        self.isKeyDown = isKeyDown
    }
}
