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
            id: nil,
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

extension ConfigChoice {
    init(label: String?, value: String) {
        self.init(description: nil, group: nil, groupLabel: nil, label: label, value: value)
    }
}

extension SlashCommand {
    init(description: String?, hasInput: Bool?, name: String) {
        self.init(description: description, hasInput: hasInput, inputHint: nil, name: name)
    }

    init(description: String?, hasInput: Bool?, inputHint: String?, name: String) {
        self.init(completes: nil, description: description, hasInput: hasInput, inputHint: inputHint, name: name)
    }
}

/// A command is exactly one of its fields: each initializer sets one.
extension CommandParams {
    private init() {
        self.init(
            addParticipant: nil,
            cancelDelivery: nil,
            commandParamsContinue: nil,
            createThread: nil,
            deleteThread: nil,
            deliver: nil,
            forkThread: nil,
            interrupt: nil,
            key: nil,
            moveDelivery: nil,
            respond: nil,
            retryDelivery: nil,
            spawn: nil,
            steerDelivery: nil,
            stop: nil,
            stopItem: nil,
            updateParticipant: nil,
            updateThread: nil
        )
    }

    init(addParticipant: AddParticipant) {
        self.init()
        self.addParticipant = addParticipant
    }

    init(cancelDelivery: CancelDelivery) {
        self.init()
        self.cancelDelivery = cancelDelivery
    }

    init(commandParamsContinue: Continue) {
        self.init()
        self.commandParamsContinue = commandParamsContinue
    }

    init(createThread: CreateThread) {
        self.init()
        self.createThread = createThread
    }

    init(deleteThread: DeleteThread) {
        self.init()
        self.deleteThread = deleteThread
    }

    init(deliver: Deliver) {
        self.init()
        self.deliver = deliver
    }

    init(forkThread: ForkThread) {
        self.init()
        self.forkThread = forkThread
    }

    init(interrupt: Interrupt) {
        self.init()
        self.interrupt = interrupt
    }

    init(moveDelivery: MoveDelivery) {
        self.init()
        self.moveDelivery = moveDelivery
    }

    init(respond: Respond) {
        self.init()
        self.respond = respond
    }

    init(retryDelivery: RetryDelivery) {
        self.init()
        self.retryDelivery = retryDelivery
    }

    init(spawn: Spawn) {
        self.init()
        self.spawn = spawn
    }

    init(steerDelivery: SteerDelivery) {
        self.init()
        self.steerDelivery = steerDelivery
    }

    init(stop: Stop) {
        self.init()
        self.stop = stop
    }

    init(stopItem: StopItem) {
        self.init()
        self.stopItem = stopItem
    }

    init(updateParticipant: UpdateParticipant) {
        self.init()
        self.updateParticipant = updateParticipant
    }

    init(updateThread: UpdateThread) {
        self.init()
        self.updateThread = updateThread
    }
}
