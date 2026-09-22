import libcmark

public struct DownOptions: OptionSet {
    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    public static let `default` = DownOptions(rawValue: CMARK_OPT_DEFAULT)
    public static let safe = DownOptions(rawValue: CMARK_OPT_SAFE)
}
