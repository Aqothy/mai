import Foundation

// Optional wire fields are added as provider capabilities evolve. These
// convenience initializers keep existing feature code concise while the
// generated canonical initializers continue to expose every field explicitly.
extension Attachment {
    init(data: String?, kind: String, mimeType: String?, name: String?, uri: String?) {
        self.init(
            meta: nil,
            annotations: nil,
            data: data,
            description: nil,
            kind: kind,
            mimeType: mimeType,
            name: name,
            resourceMeta: nil,
            size: nil,
            title: nil,
            uri: uri
        )
    }
}

extension Capabilities {
    init(
        auth: Bool?,
        configOptions: Bool?,
        loadReplay: Bool?,
        logout: Bool?,
        mcp: MCPCapabilities?,
        modelSwitch: String?,
        promptContent: PromptContentCapabilities?,
        resume: Bool?,
        sessionList: Bool?
    ) {
        self.init(
            additionalDirectories: nil,
            auth: auth,
            configOptions: configOptions,
            loadReplay: loadReplay,
            logout: logout,
            mcp: mcp,
            modelSwitch: modelSwitch,
            promptContent: promptContent,
            resume: resume,
            sessionClose: nil,
            sessionDelete: nil,
            sessionList: sessionList
        )
    }
}

extension Command {
    init(
        commandID: String?,
        configSelections: [ConfigOptionSelection]?,
        createdAt: Date?,
        cwd: String?,
        decision: String?,
        message: CommandMessage?,
        modelSelection: ModelSelection?,
        optionID: String?,
        providerInstanceID: String?,
        requestID: String?,
        threadID: String?,
        title: String?,
        turnID: String?,
        type: String,
        value: JSONAny?
    ) {
        self.init(
            additionalDirectories: nil,
            commandID: commandID,
            configSelections: configSelections,
            createdAt: createdAt,
            cwd: cwd,
            decision: decision,
            message: message,
            modelSelection: modelSelection,
            optionID: optionID,
            providerInstanceID: providerInstanceID,
            requestID: requestID,
            threadID: threadID,
            title: title,
            turnID: turnID,
            type: type,
            value: value
        )
    }
}

extension ConfigChoice {
    init(label: String?, value: String) {
        self.init(description: nil, group: nil, groupLabel: nil, label: label, value: value)
    }
}

extension EventPayload {
    init(
        approval: ApprovalEvent?,
        attachments: [Attachment]?,
        configOptions: [ConfigOption]?,
        createdAt: Date?,
        cwd: String?,
        decision: String?,
        item: Item?,
        messageID: String?,
        modelSelection: ModelSelection?,
        optionID: String?,
        plan: Plan?,
        providerInstanceID: String?,
        requestID: String?,
        role: String?,
        session: SessionBinding?,
        sessionCleared: Bool?,
        slashCommands: [SlashCommand]?,
        stopReason: String?,
        text: String?,
        threadID: String?,
        title: String?,
        tokenUsage: TokenUsage?,
        turnID: String?,
        updatedAt: Date?,
        value: JSONAny?
    ) {
        self.init(
            additionalDirectories: nil,
            approval: approval,
            attachments: attachments,
            configOptions: configOptions,
            createdAt: createdAt,
            cwd: cwd,
            decision: decision,
            item: item,
            messageID: messageID,
            modelSelection: modelSelection,
            optionID: optionID,
            plan: plan,
            providerInstanceID: providerInstanceID,
            requestID: requestID,
            role: role,
            session: session,
            sessionCleared: sessionCleared,
            slashCommands: slashCommands,
            stopReason: stopReason,
            text: text,
            threadID: threadID,
            title: title,
            tokenUsage: tokenUsage,
            turnID: turnID,
            updatedAt: updatedAt,
            value: value
        )
    }
}

extension SessionBinding {
    init(
        activeTurnID: String?,
        configOptions: [ConfigOption]?,
        cwd: String?,
        driver: String?,
        lastError: String?,
        providerInstanceID: String,
        providerName: String?,
        slashCommands: [SlashCommand]?,
        status: String,
        stopRequested: Bool?,
        threadID: String,
        tokenUsage: TokenUsage?,
        updatedAt: Date
    ) {
        self.init(
            activeTurnID: activeTurnID,
            additionalDirectories: nil,
            configOptions: configOptions,
            cwd: cwd,
            driver: driver,
            lastError: lastError,
            providerInstanceID: providerInstanceID,
            providerName: providerName,
            slashCommands: slashCommands,
            status: status,
            stopRequested: stopRequested,
            threadID: threadID,
            tokenUsage: tokenUsage,
            updatedAt: updatedAt
        )
    }
}

extension SessionSummary {
    init(cwd: String?, sessionID: String, title: String?, updatedAt: String?) {
        self.init(
            additionalDirectories: nil,
            cwd: cwd,
            sessionID: sessionID,
            title: title,
            updatedAt: updatedAt
        )
    }
}

extension SlashCommand {
    init(description: String?, hasInput: Bool?, name: String) {
        self.init(description: description, hasInput: hasInput, inputHint: nil, name: name)
    }
}

extension Thread {
    init(
        createdAt: Date,
        cwd: String?,
        id: String,
        latestTurn: Turn?,
        modelSelection: ModelSelection?,
        plan: Plan?,
        providerInstanceID: String?,
        session: SessionBinding?,
        timeline: [TimelineEntry],
        title: String,
        updatedAt: Date
    ) {
        self.init(
            additionalDirectories: nil,
            createdAt: createdAt,
            cwd: cwd,
            id: id,
            latestTurn: latestTurn,
            modelSelection: modelSelection,
            plan: plan,
            providerInstanceID: providerInstanceID,
            session: session,
            timeline: timeline,
            title: title,
            updatedAt: updatedAt
        )
    }
}

extension ThreadListEntry {
    init(
        createdAt: Date,
        cwd: String?,
        hasPendingApprovals: Bool,
        id: String,
        latestTurn: Turn?,
        modelSelection: ModelSelection?,
        providerInstanceID: String?,
        session: SessionBinding?,
        title: String,
        updatedAt: Date
    ) {
        self.init(
            additionalDirectories: nil,
            createdAt: createdAt,
            cwd: cwd,
            hasPendingApprovals: hasPendingApprovals,
            id: id,
            latestTurn: latestTurn,
            modelSelection: modelSelection,
            providerInstanceID: providerInstanceID,
            session: session,
            title: title,
            updatedAt: updatedAt
        )
    }
}
