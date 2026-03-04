import Foundation

struct NoteAttachment: Codable {
    let name: String?
    let uti: String?
    let mimeType: String?
    let base64Data: String?
}

struct ExportNote: Codable {
    let id: String
    let sourceIndex: Int?
    let title: String
    let plaintext: String
    let bodyHTML: String
    let attachments: [NoteAttachment]?
    let account: String
    let folderPath: [String]
    let createdAt: String?
    let updatedAt: String?
}

enum ExportMode: String, Codable {
    case folderTree = "folder-tree"
    case zip = "zip"
}

enum ExistingItemPolicy: String, Codable {
    case overwrite
    case skip
    case uniquify

    var summary: String {
        switch self {
        case .overwrite:
            return "overwrite existing files/folders"
        case .skip:
            return "skip when target already exists"
        case .uniquify:
            return "create suffixed names (-1, -2, ...)"
        }
    }
}

enum FilenameMode: String, Codable {
    case unicodeSafe = "unicode"
    case asciiTranslit = "ascii"

    var summary: String {
        switch self {
        case .unicodeSafe:
            return "keep Unicode names, sanitize for cross-platform safety"
        case .asciiTranslit:
            return "transliterate to ASCII for maximum portability"
        }
    }
}
