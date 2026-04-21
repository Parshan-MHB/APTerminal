import Foundation

public enum TerminalSpecialKey: Sendable {
    case enter
    case tab
    case escape
    case backspace
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight
    case ctrl(Character)
    case alt(Character)
    case function(Int)
}

public enum TerminalKeyInputEncoder {
    public static func encode(_ key: TerminalSpecialKey) -> Data {
        switch key {
        case .enter:
            return Data([0x0D])
        case .tab:
            return Data([0x09])
        case .escape:
            return Data([0x1B])
        case .backspace:
            return Data([0x7F])
        case .arrowUp:
            return Data([0x1B, 0x5B, 0x41])
        case .arrowDown:
            return Data([0x1B, 0x5B, 0x42])
        case .arrowRight:
            return Data([0x1B, 0x5B, 0x43])
        case .arrowLeft:
            return Data([0x1B, 0x5B, 0x44])
        case let .ctrl(character):
            let uppercased = String(character).uppercased()
            guard let scalar = uppercased.unicodeScalars.first else {
                return Data()
            }

            let value = UInt8(scalar.value & 0x1F)
            return Data([value])
        case let .alt(character):
            return Data([0x1B]) + Data(String(character).utf8)
        case let .function(number):
            switch number {
            case 1:
                return Data([0x1B, 0x4F, 0x50])
            case 2:
                return Data([0x1B, 0x4F, 0x51])
            case 3:
                return Data([0x1B, 0x4F, 0x52])
            case 4:
                return Data([0x1B, 0x4F, 0x53])
            case 5:
                return Data([0x1B, 0x5B, 0x31, 0x35, 0x7E])
            case 6:
                return Data([0x1B, 0x5B, 0x31, 0x37, 0x7E])
            case 7:
                return Data([0x1B, 0x5B, 0x31, 0x38, 0x7E])
            case 8:
                return Data([0x1B, 0x5B, 0x31, 0x39, 0x7E])
            case 9:
                return Data([0x1B, 0x5B, 0x32, 0x30, 0x7E])
            case 10:
                return Data([0x1B, 0x5B, 0x32, 0x31, 0x7E])
            case 11:
                return Data([0x1B, 0x5B, 0x32, 0x33, 0x7E])
            case 12:
                return Data([0x1B, 0x5B, 0x32, 0x34, 0x7E])
            default:
                return Data()
            }
        }
    }
}
