import AppKit

/// 触发候选面板的「双击修饰键」。默认双击右 ⌘。
/// 只收 ⌘ / ⌥ / ⌃ 的左右键——不收 Shift（打字时极易误触双击）。
/// keyCode 为各修饰键的硬件码；flag 为对应的修饰标志，用于在 flagsChanged 里确认是「按下」边沿。
enum TriggerKey: String, CaseIterable, Identifiable {
    case rightCommand
    case leftCommand
    case rightOption
    case leftOption
    case rightControl
    case leftControl

    var id: String { rawValue }

    /// 修饰键的硬件 keyCode。
    var keyCode: UInt16 {
        switch self {
        case .rightCommand: return 54
        case .leftCommand:  return 55
        case .rightOption:  return 61
        case .leftOption:   return 58
        case .rightControl: return 62
        case .leftControl:  return 59
        }
    }

    /// 对应的修饰标志，按下时该标志被 set。
    var flag: NSEvent.ModifierFlags {
        switch self {
        case .rightCommand, .leftCommand:  return .command
        case .rightOption, .leftOption:    return .option
        case .rightControl, .leftControl:  return .control
        }
    }

    /// 设置界面与说明文案用的标签，如「双击右⌘」。
    var label: String {
        switch self {
        case .rightCommand: return "双击右⌘"
        case .leftCommand:  return "双击左⌘"
        case .rightOption:  return "双击右⌥"
        case .leftOption:   return "双击左⌥"
        case .rightControl: return "双击右⌃"
        case .leftControl:  return "双击左⌃"
        }
    }
}
