import AppKit
import Foundation
import SwiftUI

struct MarkdownContentView: View {
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .markdown(let markdown):
                    MarkdownProseView(source: markdown)
                case .code(let language, let code):
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(language.isEmpty ? "Code" : language)
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Copy Code", systemImage: "doc.on.doc") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(code, forType: .string)
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                            .help("Copy Code")
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        Divider()
                        ScrollView(.horizontal) {
                            Text(code).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                                .padding(12)
                        }
                    }
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9))
                }
            }
        }
    }

    private enum Block { case markdown(String), code(String, String) }

    private var blocks: [Block] {
        let parts = source.components(separatedBy: "```")
        return parts.enumerated().compactMap { index, part in
            guard !part.isEmpty else { return nil }
            if index.isMultiple(of: 2) { return .markdown(part) }
            let lines = part.split(separator: "\n", omittingEmptySubsequences: false)
            let language = lines.first.map(String.init) ?? ""
            return .code(language, lines.dropFirst().joined(separator: "\n"))
        }
    }

}

struct MarkdownProseView: View {
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.parse(source).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    Text(Self.inline(text))
                        .font(headingFont(level))
                        .padding(.top, level <= 2 ? 4 : 1)
                case .paragraph(let lines):
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(Self.inline(line))
                        }
                    }
                case .bullet(let depth, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").frame(width: 10, alignment: .trailing)
                        Text(Self.inline(text)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, CGFloat(depth * 18))
                case .numbered(let depth, let number, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(number).").frame(minWidth: 18, alignment: .trailing)
                        Text(Self.inline(text)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, CGFloat(depth * 18))
                case .quote(let text):
                    HStack(spacing: 10) {
                        Capsule().fill(.tertiary).frame(width: 3)
                        Text(Self.inline(text)).foregroundStyle(.secondary)
                    }
                case .divider:
                    Divider()
                }
            }
        }
        .lineSpacing(3)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    enum ProseBlock: Equatable {
        case heading(Int, String)
        case paragraph([String])
        case bullet(Int, String)
        case numbered(Int, Int, String)
        case quote(String)
        case divider
    }

    static func parse(_ markdown: String) -> [ProseBlock] {
        var blocks: [ProseBlock] = []
        var paragraph: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph))
                paragraph.removeAll(keepingCapacity: true)
            }
        }

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                flushParagraph()
                continue
            }

            let leadingSpaces = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) {
                $0 + ($1 == "\t" ? 4 : 1)
            }
            let depth = leadingSpaces / 2

            if trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }), trimmed.count >= 3 {
                flushParagraph()
                blocks.append(.divider)
            } else if trimmed.first == "#" {
                let level = min(trimmed.prefix(while: { $0 == "#" }).count, 6)
                let index = trimmed.index(trimmed.startIndex, offsetBy: level)
                guard index == trimmed.endIndex || trimmed[index] == " " else {
                    paragraph.append(trimmed)
                    continue
                }
                flushParagraph()
                blocks.append(.heading(level, trimmed[index...].trimmingCharacters(in: .whitespaces)))
            } else if ["- ", "* ", "+ "].contains(where: trimmed.hasPrefix) {
                flushParagraph()
                blocks.append(.bullet(depth, String(trimmed.dropFirst(2))))
            } else if let numbered = numberedItem(trimmed) {
                flushParagraph()
                blocks.append(.numbered(depth, numbered.number, numbered.text))
            } else if trimmed.hasPrefix("> ") {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst(2))))
            } else {
                paragraph.append(trimmed)
            }
        }
        flushParagraph()
        return blocks
    }

    private static func numberedItem(_ line: String) -> (number: Int, text: String)? {
        guard let dot = line.firstIndex(of: "."),
              line.index(after: dot) < line.endIndex,
              line[line.index(after: dot)] == " ",
              let number = Int(line[..<dot]) else { return nil }
        return (number, String(line[line.index(dot, offsetBy: 2)...]))
    }

    private static func inline(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.weight(.semibold)
        case 2: .title3.weight(.semibold)
        default: .headline
        }
    }
}
