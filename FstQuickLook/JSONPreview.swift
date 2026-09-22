import Foundation

/// Whitespace-only formatting: key order, duplicate keys, escapes and number spelling survive.
/// A bounded prefix is also useful when a file is too large to read in full.
enum JSONPreview {
    static let byteLimit = 8 * 1_048_576

    struct Result {
        let text: String
        let formatted: Bool
        let truncated: Bool
    }

    static func format(_ source: String, truncated: Bool, limit: Int = byteLimit) -> Result {
        let bytes = Array(source.utf8)
        func original() -> Result { Result(text: source, formatted: false, truncated: truncated) }
        guard let first = bytes.first(where: { !isWhitespace($0) }), first == 91 || first == 123 else {
            return original()
        }
        // Validate complete input without reserializing its values (large integers must not round).
        if !truncated, (try? JSONSerialization.jsonObject(with: Data(bytes), options: [.fragmentsAllowed])) == nil {
            return original()
        }
        var output = [UInt8]()
        output.reserveCapacity(min(limit, bytes.count + bytes.count / 4))
        var stack: [UInt8] = []
        var inString = false
        var escaped = false
        var previous: UInt8 = 0
        var outputTruncated = truncated
        func newline() {
            output.append(10)
            output.append(contentsOf: repeatElement(32, count: stack.count * 2))
        }
        for byte in bytes {
            if output.count + stack.count * 2 + 4 >= limit {
                outputTruncated = true
                break
            }
            if inString {
                output.append(byte)
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inString = false }
                continue
            }
            if isWhitespace(byte) { continue }
            if previous == 91 || previous == 123 {
                if byte != 93 && byte != 125 { newline() }
            }
            switch byte {
            case 34:
                inString = true
                output.append(byte)
            case 91, 123:
                guard stack.count < 128 else { return original() }
                stack.append(byte)
                output.append(byte)
            case 93, 125:
                guard let opening = stack.popLast(), (opening == 91 && byte == 93) || (opening == 123 && byte == 125) else {
                    return original()
                }
                if previous != opening { newline() }
                output.append(byte)
            case 44:
                output.append(byte)
                newline()
            case 58:
                output.append(contentsOf: [58, 32])
            default:
                output.append(byte)
            }
            previous = byte
        }
        // The output budget can bisect a UTF-8 scalar. Never display replacement characters.
        for trim in 0...min(3, output.count) {
            if let text = String(bytes: output.dropLast(trim), encoding: .utf8) {
                return Result(text: text, formatted: true, truncated: outputTruncated)
            }
        }
        return original()
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 32 || byte == 9 || byte == 10 || byte == 13
    }
}
