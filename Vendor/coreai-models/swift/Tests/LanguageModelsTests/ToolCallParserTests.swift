// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause

import Foundation
import Testing

@testable import CoreAILanguageModels

#if (arch(arm64) || arch(arm64e)) && canImport(CoreAI)

@Suite("ToolCallParser")
struct ToolCallParserTests {
    @Test("Qwen XML function syntax becomes a tool call")
    func qwenXMLToolCall() throws {
        var parser = ToolCallParser()
        let input = """


            <tool_call>
            <function=countCharacters>
            <parameter=text>
            CoreAI
            </parameter>
            </function>
            </tool_call>
            """
        let call = try #require(singleCall(parser.consume(input) + parser.flush()))
        #expect(call.name == "countCharacters")
        #expect(call.rawText == input)
        #expect(try JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: String]
            == ["text": "CoreAI"])
    }

    @Test("Qwen XML syntax survives streaming boundaries")
    func qwenXMLStreamingBoundaries() throws {
        var parser = ToolCallParser()
        let chunks = [
            "<tool_", "call>\n<function=count", "Characters>\n<parameter=text>\nCore",
            "AI\n</parameter>\n</function>\n</tool_call>",
        ]
        let call = try #require(singleCall(chunks.flatMap { parser.consume($0) } + parser.flush()))
        #expect(call.name == "countCharacters")
    }

    @Test("Protocol whitespace remains part of a streamed tool call")
    func qwenWhitespaceBeforeMarker() throws {
        var parser = ToolCallParser()
        let whitespaceEvents = parser.consume("\n\n")
        let callText = "<tool_call>{\"name\":\"search\",\"arguments\":{}}</tool_call>"
        let call = try #require(singleCall(
            whitespaceEvents + parser.consume(callText) + parser.flush()))
        #expect(call.rawText == "\n\n" + callText)
    }

    @Test("Duplicate Qwen parameters are rejected")
    func duplicateParametersAreRejected() {
        var parser = ToolCallParser()
        let input = "<tool_call><function=f><parameter=x>one</parameter><parameter=x>two</parameter></function></tool_call>"
        #expect(singleCall(parser.consume(input) + parser.flush()) == nil)
    }

    @Test("Qwen JSON scalar parameters preserve their types")
    func typedParameters() throws {
        var parser = ToolCallParser()
        let input = "<tool_call><function=searchWeb><parameter=query>Core AI</parameter><parameter=maximumResults>5</parameter></function></tool_call>"
        let call = try #require(singleCall(parser.consume(input) + parser.flush()))
        let arguments = try #require(
            JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any])
        #expect(arguments["query"] as? String == "Core AI")
        #expect(arguments["maximumResults"] as? Int == 5)
    }

    @Test("Qwen parameter content retains meaningful whitespace")
    func preservesWhitespace() throws {
        var parser = ToolCallParser()
        let input = "<tool_call><function=countCharacters><parameter=text>\n  CoreAI  \n</parameter></function></tool_call>"
        let call = try #require(singleCall(parser.consume(input) + parser.flush()))
        let arguments = try #require(
            JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: String])
        #expect(arguments["text"] == "  CoreAI  ")
    }

    private func singleCall(
        _ events: [ToolCallParser.Event]
    ) -> (name: String, arguments: String, rawText: String)? {
        let calls = events.compactMap { event -> (String, String, String)? in
            if case .toolCall(_, let name, let arguments, let rawText, _, _) = event {
                return (name, arguments, rawText)
            }
            return nil
        }
        return calls.count == 1 ? calls[0] : nil
    }
}

#endif
