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
                case .table(let headers, let alignments, let rows):
                    MarkdownTableView(headers: headers, alignments: alignments, rows: rows)
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
        case table(headers: [String], alignments: [TableAlignment], rows: [[String]])
        case divider
    }

    enum TableAlignment: Equatable {
        case leading
        case center
        case trailing
    }

    static func parse(_ markdown: String) -> [ProseBlock] {
        var blocks: [ProseBlock] = []
        var paragraph: [String] = []
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph))
                paragraph.removeAll(keepingCapacity: true)
            }
        }

        var lineIndex = 0
        while lineIndex < lines.count {
            let line = lines[lineIndex]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                flushParagraph()
                lineIndex += 1
                continue
            }

            if lineIndex + 1 < lines.count,
               let headers = tableCells(in: line),
               let alignments = tableAlignments(in: lines[lineIndex + 1], columnCount: headers.count) {
                flushParagraph()
                var rows: [[String]] = []
                lineIndex += 2
                while lineIndex < lines.count, let cells = tableCells(in: lines[lineIndex]) {
                    rows.append(cells)
                    lineIndex += 1
                }
                blocks.append(.table(headers: headers, alignments: alignments, rows: rows))
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
                    lineIndex += 1
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
            lineIndex += 1
        }
        flushParagraph()
        return blocks
    }

    /// Splits a GFM-style table row while preserving escaped pipe characters.
    private static func tableCells(in line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }

        var cells: [String] = []
        var cell = ""
        var escaped = false
        for character in trimmed {
            if escaped {
                cell.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
                cell.append(character)
            } else if character == "|" {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(character)
            }
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))

        if trimmed.hasPrefix("|") { cells.removeFirst() }
        if trimmed.hasSuffix("|") { cells.removeLast() }
        return cells.isEmpty ? nil : cells
    }

    private static func tableAlignments(in line: String, columnCount: Int) -> [TableAlignment]? {
        guard let cells = tableCells(in: line), cells.count == columnCount else { return nil }
        var alignments: [TableAlignment] = []
        for cell in cells {
            let marker = cell.trimmingCharacters(in: .whitespaces)
            let dashes = marker.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard dashes.count >= 3, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            if marker.hasPrefix(":"), marker.hasSuffix(":") {
                alignments.append(.center)
            } else if marker.hasSuffix(":") {
                alignments.append(.trailing)
            } else {
                alignments.append(.leading)
            }
        }
        return alignments
    }

    private static func numberedItem(_ line: String) -> (number: Int, text: String)? {
        guard let dot = line.firstIndex(of: "."),
              line.index(after: dot) < line.endIndex,
              line[line.index(after: dot)] == " ",
              let number = Int(line[..<dot]) else { return nil }
        return (number, String(line[line.index(dot, offsetBy: 2)...]))
    }

    fileprivate static func inline(_ markdown: String) -> AttributedString {
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

private struct MarkdownTableView: View {
    let headers: [String]
    let alignments: [MarkdownProseView.TableAlignment]
    let rows: [[String]]

    private var columnCount: Int {
        max(headers.count, rows.map(\.count).max() ?? 0)
    }

    var body: some View {
        ScrollView(.horizontal) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                tableRow(headers, isHeader: true)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    tableRow(row, isHeader: false)
                        .background(index.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.045))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private func tableRow(_ cells: [String], isHeader: Bool) -> some View {
        GridRow {
            ForEach(0..<columnCount, id: \.self) { index in
                Text(MarkdownProseView.inline(index < cells.count ? cells[index] : ""))
                    .fontWeight(isHeader ? .semibold : .regular)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(
                        minWidth: 96,
                        idealWidth: 180,
                        maxWidth: 320,
                        alignment: alignment(at: index)
                    )
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(isHeader ? Color.secondary.opacity(0.1) : Color.clear)
                    .overlay(alignment: .trailing) { Divider() }
            }
        }
    }

    private func alignment(at index: Int) -> Alignment {
        guard index < alignments.count else { return .leading }
        switch alignments[index] {
        case .leading: return Alignment.leading
        case .center: return Alignment.center
        case .trailing: return Alignment.trailing
        }
    }
}
