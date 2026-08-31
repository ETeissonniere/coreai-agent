import FoundationModels

public struct LocalAgentProfile<Model: LanguageModel>: LanguageModelSession.DynamicProfile {
    private let model: Model
    private let instructions: String
    private let tools: [any Tool]
    private let journal: AgentEventJournal
    private let broker: ToolExecutionBroker?
    private let toolCallingMode: GenerationOptions.ToolCallingMode

    public init(
        model: Model,
        instructions: String,
        tools: [any Tool],
        journal: AgentEventJournal,
        broker: ToolExecutionBroker? = nil,
        toolCallingMode: GenerationOptions.ToolCallingMode = .allowed
    ) {
        self.model = model
        self.instructions = instructions
        self.tools = tools
        self.journal = journal
        self.broker = broker
        self.toolCallingMode = toolCallingMode
    }

    public var body: some LanguageModelSession.DynamicProfile {
        let eventJournal = journal
        let executionBroker = broker
        return LanguageModelSession.Profile {
            Instructions(instructions)
            tools
        }
        .model(model)
        .toolCallingMode(tools.isEmpty ? .disallowed : toolCallingMode)
        .transcriptErrorHandlingPolicy(.revertTranscript)
        .onReasoning { reasoning in
            let events = TranscriptEventMapper.events(from: [.reasoning(reasoning)])
            for event in events { await eventJournal.record(event) }
        }
        .onToolCall { call in
            await executionBroker?.registerInvocation(toolName: call.toolName, toolCallID: call.id)
            await eventJournal.record(.toolCall(
                id: call.id,
                name: call.toolName,
                argumentsJSON: call.arguments.jsonString
            ))
        }
        .onToolOutput { _, output in
            let events = TranscriptEventMapper.events(from: [.toolOutput(output)])
            for event in events { await eventJournal.record(event) }
        }
        .onResponse { response in
            let events = TranscriptEventMapper.events(from: [.response(response)])
            for event in events { await eventJournal.record(event) }
        }
    }
}

public enum LocalAgentSession {
    public static func make<Model: LanguageModel>(
        model: Model,
        instructions: String,
        tools: [any Tool],
        journal: AgentEventJournal,
        broker: ToolExecutionBroker? = nil,
        toolCallingMode: GenerationOptions.ToolCallingMode = .allowed,
        history: [Transcript.Entry] = []
    ) -> LanguageModelSession {
        LanguageModelSession(
            profile: LocalAgentProfile(
                model: model,
                instructions: instructions,
                tools: tools,
                journal: journal,
                broker: broker,
                toolCallingMode: toolCallingMode
            ),
            history: history
        )
    }
}
