//
//  Down.swift
//  Down
//
//  Created by Rob Phillips on 5/28/16.
//  Copyright © 2016-2019 Down. All rights reserved.
//

import Foundation
import libcmark

public struct Down {
    public var markdownString: String

    public init(markdownString: String) {
        self.markdownString = markdownString
    }

    public func toHTML(_ options: DownOptions = .default) throws -> String {
        let length = markdownString.lengthOfBytes(using: .utf8)
        var rendered: UnsafeMutablePointer<CChar>?
        markdownString.withCString {
            rendered = cmark_markdown_to_html($0, length, options.rawValue)
        }
        guard let rendered else { throw DownError.renderingFailed }
        defer { free(rendered) }
        return String(cString: rendered)
    }
}

public enum DownError: Error {
    case renderingFailed
}
