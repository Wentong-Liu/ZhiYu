import Foundation

/// AX 裸字符串（role / attribute / action 名）的单一真相源。
/// 原先散落在 WeChatAXProbe / InserterProbe / StickerSender / VoiceTranscriber 里的字面量
/// （`"AXValue"` `"AXRole"` `"AXPress"` 等）统一收敛到此处，四个文件复用。
/// 值与抽取前**逐字不变**——纯字面量→具名常量；拼写错会在编译期暴露（不会像裸串那样静默失配）。
/// 与 `AXWalkLimit` 一样属于 app 目标内的跨文件共享常量。
enum AXAttr {
    static let role = "AXRole"
    static let value = "AXValue"
    static let title = "AXTitle"
    static let description = "AXDescription"
    static let children = "AXChildren"
    static let focused = "AXFocused"
    static let enabled = "AXEnabled"
    static let position = "AXPosition"
    static let size = "AXSize"
    static let focusedWindow = "AXFocusedWindow"
    static let mainWindow = "AXMainWindow"
    static let placeholderValue = "AXPlaceholderValue"
    static let manualAccessibility = "AXManualAccessibility"
    static let enhancedUserInterface = "AXEnhancedUserInterface"
}

enum AXRole {
    static let staticText = "AXStaticText"
    static let textArea = "AXTextArea"
    static let textField = "AXTextField"
    static let scrollArea = "AXScrollArea"
    static let splitGroup = "AXSplitGroup"
    static let table = "AXTable"
    static let row = "AXRow"
    static let tableRow = "AXTableRow"
    static let image = "AXImage"
    static let column = "AXColumn"
    static let scrollBar = "AXScrollBar"
    static let button = "AXButton"
    static let group = "AXGroup"
    static let popover = "AXPopover"
    static let menu = "AXMenu"
    static let menuItem = "AXMenuItem"
}

enum AXAction {
    static let press = "AXPress"
    static let confirm = "AXConfirm"
    static let cancel = "AXCancel"
    static let showMenu = "AXShowMenu"
}
