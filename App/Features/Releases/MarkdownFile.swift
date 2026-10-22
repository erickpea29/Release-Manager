import SwiftUI
import UniformTypeIdentifiers

/// Release notes as a Markdown file, for the system save panel.
nonisolated struct MarkdownFile: FileDocument {
    static let markdown = UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText
    static let readableContentTypes: [UTType] = [markdown]

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
