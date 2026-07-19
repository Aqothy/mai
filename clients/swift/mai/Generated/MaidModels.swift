// This file was generated from JSON Schema using quicktype, do not modify it directly.
// To parse the JSON, add this file to your project and do:
//
//   let maidClientAPI = try MaidClientAPI(json)

import Foundation

// MARK: - ACPRegistryAgent
public struct ACPRegistryAgent: Codable {
    public let args: [String]?
    public let description, icon: String?
    public let id, instanceID, name, package: String
    public let version: String?

    public enum CodingKeys: String, CodingKey {
        case args, description, icon, id
        case instanceID = "instanceId"
        case name, package, version
    }

    public init(args: [String]?, description: String?, icon: String?, id: String, instanceID: String, name: String, package: String, version: String?) {
        self.args = args
        self.description = description
        self.icon = icon
        self.id = id
        self.instanceID = instanceID
        self.name = name
        self.package = package
        self.version = version
    }
}

// MARK: ACPRegistryAgent convenience initializers and mutators

public extension ACPRegistryAgent {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ACPRegistryAgent.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        args: [String]?? = nil,
        description: String?? = nil,
        icon: String?? = nil,
        id: String? = nil,
        instanceID: String? = nil,
        name: String? = nil,
        package: String? = nil,
        version: String?? = nil
    ) -> ACPRegistryAgent {
        return ACPRegistryAgent(
            args: args ?? self.args,
            description: description ?? self.description,
            icon: icon ?? self.icon,
            id: id ?? self.id,
            instanceID: instanceID ?? self.instanceID,
            name: name ?? self.name,
            package: package ?? self.package,
            version: version ?? self.version
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ACPRegistryStartParams
public struct ACPRegistryStartParams: Codable {
    public let registryID: String
    public let restart: Bool?

    public enum CodingKeys: String, CodingKey {
        case registryID = "registryId"
        case restart
    }

    public init(registryID: String, restart: Bool?) {
        self.registryID = registryID
        self.restart = restart
    }
}

// MARK: ACPRegistryStartParams convenience initializers and mutators

public extension ACPRegistryStartParams {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ACPRegistryStartParams.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        registryID: String? = nil,
        restart: Bool?? = nil
    ) -> ACPRegistryStartParams {
        return ACPRegistryStartParams(
            registryID: registryID ?? self.registryID,
            restart: restart ?? self.restart
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - Approval
public struct Approval: Codable {
    public let args: JSONAny?
    public let createdAt: Date
    public let decision, optionID: String?
    public let options: [ApprovalOption]?
    public let requestID, status: String
    public let turnID: String?
    public let updatedAt: Date

    public enum CodingKeys: String, CodingKey {
        case args, createdAt, decision
        case optionID = "optionId"
        case options
        case requestID = "requestId"
        case status
        case turnID = "turnId"
        case updatedAt
    }

    public init(args: JSONAny?, createdAt: Date, decision: String?, optionID: String?, options: [ApprovalOption]?, requestID: String, status: String, turnID: String?, updatedAt: Date) {
        self.args = args
        self.createdAt = createdAt
        self.decision = decision
        self.optionID = optionID
        self.options = options
        self.requestID = requestID
        self.status = status
        self.turnID = turnID
        self.updatedAt = updatedAt
    }
}

// MARK: Approval convenience initializers and mutators

public extension Approval {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Approval.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        args: JSONAny?? = nil,
        createdAt: Date? = nil,
        decision: String?? = nil,
        optionID: String?? = nil,
        options: [ApprovalOption]?? = nil,
        requestID: String? = nil,
        status: String? = nil,
        turnID: String?? = nil,
        updatedAt: Date? = nil
    ) -> Approval {
        return Approval(
            args: args ?? self.args,
            createdAt: createdAt ?? self.createdAt,
            decision: decision ?? self.decision,
            optionID: optionID ?? self.optionID,
            options: options ?? self.options,
            requestID: requestID ?? self.requestID,
            status: status ?? self.status,
            turnID: turnID ?? self.turnID,
            updatedAt: updatedAt ?? self.updatedAt
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ApprovalOption
public struct ApprovalOption: Codable {
    public let kind: String?
    public let metadata: [String: JSONAny]?
    public let name, optionID: String
    public let raw: JSONAny?

    public enum CodingKeys: String, CodingKey {
        case kind, metadata, name
        case optionID = "optionId"
        case raw
    }

    public init(kind: String?, metadata: [String: JSONAny]?, name: String, optionID: String, raw: JSONAny?) {
        self.kind = kind
        self.metadata = metadata
        self.name = name
        self.optionID = optionID
        self.raw = raw
    }
}

// MARK: ApprovalOption convenience initializers and mutators

public extension ApprovalOption {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ApprovalOption.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        kind: String?? = nil,
        metadata: [String: JSONAny]?? = nil,
        name: String? = nil,
        optionID: String? = nil,
        raw: JSONAny?? = nil
    ) -> ApprovalOption {
        return ApprovalOption(
            kind: kind ?? self.kind,
            metadata: metadata ?? self.metadata,
            name: name ?? self.name,
            optionID: optionID ?? self.optionID,
            raw: raw ?? self.raw
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ApprovalEvent
public struct ApprovalEvent: Codable {
    public let args: JSONAny?
    public let cancelled: Bool?
    public let decision, detail, optionID: String?
    public let options: [ApprovalOption]?
    public let requestID: String
    public let requestType, turnID: String?

    public enum CodingKeys: String, CodingKey {
        case args, cancelled, decision, detail
        case optionID = "optionId"
        case options
        case requestID = "requestId"
        case requestType
        case turnID = "turnId"
    }

    public init(args: JSONAny?, cancelled: Bool?, decision: String?, detail: String?, optionID: String?, options: [ApprovalOption]?, requestID: String, requestType: String?, turnID: String?) {
        self.args = args
        self.cancelled = cancelled
        self.decision = decision
        self.detail = detail
        self.optionID = optionID
        self.options = options
        self.requestID = requestID
        self.requestType = requestType
        self.turnID = turnID
    }
}

// MARK: ApprovalEvent convenience initializers and mutators

public extension ApprovalEvent {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ApprovalEvent.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        args: JSONAny?? = nil,
        cancelled: Bool?? = nil,
        decision: String?? = nil,
        detail: String?? = nil,
        optionID: String?? = nil,
        options: [ApprovalOption]?? = nil,
        requestID: String? = nil,
        requestType: String?? = nil,
        turnID: String?? = nil
    ) -> ApprovalEvent {
        return ApprovalEvent(
            args: args ?? self.args,
            cancelled: cancelled ?? self.cancelled,
            decision: decision ?? self.decision,
            detail: detail ?? self.detail,
            optionID: optionID ?? self.optionID,
            options: options ?? self.options,
            requestID: requestID ?? self.requestID,
            requestType: requestType ?? self.requestType,
            turnID: turnID ?? self.turnID
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - Attachment
public struct Attachment: Codable {
    public let data: String?
    public let kind: String
    public let metadata: [String: JSONAny]?
    public let mimeType, name: String?
    public let raw: JSONAny?
    public let uri: String?

    public init(data: String?, kind: String, metadata: [String: JSONAny]?, mimeType: String?, name: String?, raw: JSONAny?, uri: String?) {
        self.data = data
        self.kind = kind
        self.metadata = metadata
        self.mimeType = mimeType
        self.name = name
        self.raw = raw
        self.uri = uri
    }
}

// MARK: Attachment convenience initializers and mutators

public extension Attachment {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Attachment.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        data: String?? = nil,
        kind: String? = nil,
        metadata: [String: JSONAny]?? = nil,
        mimeType: String?? = nil,
        name: String?? = nil,
        raw: JSONAny?? = nil,
        uri: String?? = nil
    ) -> Attachment {
        return Attachment(
            data: data ?? self.data,
            kind: kind ?? self.kind,
            metadata: metadata ?? self.metadata,
            mimeType: mimeType ?? self.mimeType,
            name: name ?? self.name,
            raw: raw ?? self.raw,
            uri: uri ?? self.uri
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - Command
public struct Command: Codable {
    public let commandID: String?
    public let createdAt: Date?
    public let cwd, decision: String?
    public let message: CommandMessage?
    public let modelSelection: ModelSelection?
    public let optionID, providerInstanceID, requestID, threadID: String?
    public let title, turnID: String?
    public let type: String
    public let value: JSONAny?

    public enum CodingKeys: String, CodingKey {
        case commandID = "commandId"
        case createdAt, cwd, decision, message, modelSelection
        case optionID = "optionId"
        case providerInstanceID = "providerInstanceId"
        case requestID = "requestId"
        case threadID = "threadId"
        case title
        case turnID = "turnId"
        case type, value
    }

    public init(commandID: String?, createdAt: Date?, cwd: String?, decision: String?, message: CommandMessage?, modelSelection: ModelSelection?, optionID: String?, providerInstanceID: String?, requestID: String?, threadID: String?, title: String?, turnID: String?, type: String, value: JSONAny?) {
        self.commandID = commandID
        self.createdAt = createdAt
        self.cwd = cwd
        self.decision = decision
        self.message = message
        self.modelSelection = modelSelection
        self.optionID = optionID
        self.providerInstanceID = providerInstanceID
        self.requestID = requestID
        self.threadID = threadID
        self.title = title
        self.turnID = turnID
        self.type = type
        self.value = value
    }
}

// MARK: Command convenience initializers and mutators

public extension Command {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Command.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        commandID: String?? = nil,
        createdAt: Date?? = nil,
        cwd: String?? = nil,
        decision: String?? = nil,
        message: CommandMessage?? = nil,
        modelSelection: ModelSelection?? = nil,
        optionID: String?? = nil,
        providerInstanceID: String?? = nil,
        requestID: String?? = nil,
        threadID: String?? = nil,
        title: String?? = nil,
        turnID: String?? = nil,
        type: String? = nil,
        value: JSONAny?? = nil
    ) -> Command {
        return Command(
            commandID: commandID ?? self.commandID,
            createdAt: createdAt ?? self.createdAt,
            cwd: cwd ?? self.cwd,
            decision: decision ?? self.decision,
            message: message ?? self.message,
            modelSelection: modelSelection ?? self.modelSelection,
            optionID: optionID ?? self.optionID,
            providerInstanceID: providerInstanceID ?? self.providerInstanceID,
            requestID: requestID ?? self.requestID,
            threadID: threadID ?? self.threadID,
            title: title ?? self.title,
            turnID: turnID ?? self.turnID,
            type: type ?? self.type,
            value: value ?? self.value
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - CommandMessage
public struct CommandMessage: Codable {
    public let attachments: [Attachment]?
    public let messageID: String?
    public let raw: JSONAny?
    public let role: String?
    public let text: String

    public enum CodingKeys: String, CodingKey {
        case attachments
        case messageID = "messageId"
        case raw, role, text
    }

    public init(attachments: [Attachment]?, messageID: String?, raw: JSONAny?, role: String?, text: String) {
        self.attachments = attachments
        self.messageID = messageID
        self.raw = raw
        self.role = role
        self.text = text
    }
}

// MARK: CommandMessage convenience initializers and mutators

public extension CommandMessage {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(CommandMessage.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        attachments: [Attachment]?? = nil,
        messageID: String?? = nil,
        raw: JSONAny?? = nil,
        role: String?? = nil,
        text: String? = nil
    ) -> CommandMessage {
        return CommandMessage(
            attachments: attachments ?? self.attachments,
            messageID: messageID ?? self.messageID,
            raw: raw ?? self.raw,
            role: role ?? self.role,
            text: text ?? self.text
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ModelSelection
public struct ModelSelection: Codable {
    public let model: String?
    public let options: JSONAny?

    public init(model: String?, options: JSONAny?) {
        self.model = model
        self.options = options
    }
}

// MARK: ModelSelection convenience initializers and mutators

public extension ModelSelection {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ModelSelection.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        model: String?? = nil,
        options: JSONAny?? = nil
    ) -> ModelSelection {
        return ModelSelection(
            model: model ?? self.model,
            options: options ?? self.options
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ConfigChoice
public struct ConfigChoice: Codable {
    public let label: String?
    public let value: String

    public init(label: String?, value: String) {
        self.label = label
        self.value = value
    }
}

// MARK: ConfigChoice convenience initializers and mutators

public extension ConfigChoice {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ConfigChoice.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        label: String?? = nil,
        value: String? = nil
    ) -> ConfigChoice {
        return ConfigChoice(
            label: label ?? self.label,
            value: value ?? self.value
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ConfigOption
public struct ConfigOption: Codable {
    public let category: String?
    public let choices: [ConfigChoice]?
    public let currentValue: JSONAny?
    public let description: String?
    public let id: String
    public let label: String?
    public let type: String

    public init(category: String?, choices: [ConfigChoice]?, currentValue: JSONAny?, description: String?, id: String, label: String?, type: String) {
        self.category = category
        self.choices = choices
        self.currentValue = currentValue
        self.description = description
        self.id = id
        self.label = label
        self.type = type
    }
}

// MARK: ConfigOption convenience initializers and mutators

public extension ConfigOption {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ConfigOption.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        category: String?? = nil,
        choices: [ConfigChoice]?? = nil,
        currentValue: JSONAny?? = nil,
        description: String?? = nil,
        id: String? = nil,
        label: String?? = nil,
        type: String? = nil
    ) -> ConfigOption {
        return ConfigOption(
            category: category ?? self.category,
            choices: choices ?? self.choices,
            currentValue: currentValue ?? self.currentValue,
            description: description ?? self.description,
            id: id ?? self.id,
            label: label ?? self.label,
            type: type ?? self.type
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - DispatchResult
public struct DispatchResult: Codable {
    public let sequence: Int

    public init(sequence: Int) {
        self.sequence = sequence
    }
}

// MARK: DispatchResult convenience initializers and mutators

public extension DispatchResult {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(DispatchResult.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        sequence: Int? = nil
    ) -> DispatchResult {
        return DispatchResult(
            sequence: sequence ?? self.sequence
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - EmptyParams
public struct EmptyParams: Codable {

    public init() {
    }
}

// MARK: EmptyParams convenience initializers and mutators

public extension EmptyParams {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(EmptyParams.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
    ) -> EmptyParams {
        return EmptyParams(
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - Event
public struct Event: Codable {
    public let actor, commandID: String?
    public let eventID: String
    public let metadata: EventMetadata?
    public let occurredAt: Date
    public let payload: EventPayload
    public let sequence: Int
    public let type: String

    public enum CodingKeys: String, CodingKey {
        case actor
        case commandID = "commandId"
        case eventID = "eventId"
        case metadata, occurredAt, payload, sequence, type
    }

    public init(actor: String?, commandID: String?, eventID: String, metadata: EventMetadata?, occurredAt: Date, payload: EventPayload, sequence: Int, type: String) {
        self.actor = actor
        self.commandID = commandID
        self.eventID = eventID
        self.metadata = metadata
        self.occurredAt = occurredAt
        self.payload = payload
        self.sequence = sequence
        self.type = type
    }
}

// MARK: Event convenience initializers and mutators

public extension Event {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Event.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        actor: String?? = nil,
        commandID: String?? = nil,
        eventID: String? = nil,
        metadata: EventMetadata?? = nil,
        occurredAt: Date? = nil,
        payload: EventPayload? = nil,
        sequence: Int? = nil,
        type: String? = nil
    ) -> Event {
        return Event(
            actor: actor ?? self.actor,
            commandID: commandID ?? self.commandID,
            eventID: eventID ?? self.eventID,
            metadata: metadata ?? self.metadata,
            occurredAt: occurredAt ?? self.occurredAt,
            payload: payload ?? self.payload,
            sequence: sequence ?? self.sequence,
            type: type ?? self.type
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - EventMetadata
public struct EventMetadata: Codable {
    public let requestID: String?

    public enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
    }

    public init(requestID: String?) {
        self.requestID = requestID
    }
}

// MARK: EventMetadata convenience initializers and mutators

public extension EventMetadata {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(EventMetadata.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        requestID: String?? = nil
    ) -> EventMetadata {
        return EventMetadata(
            requestID: requestID ?? self.requestID
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - EventPayload
public struct EventPayload: Codable {
    public let approval: ApprovalEvent?
    public let attachments: [Attachment]?
    public let configOptions: [ConfigOption]?
    public let createdAt: Date?
    public let cwd, decision: String?
    public let item: Item?
    public let messageID: String?
    public let modelSelection: ModelSelection?
    public let optionID: String?
    public let plan: Plan?
    public let providerInstanceID, requestID, role: String?
    public let session: SessionBinding?
    public let sessionCleared: Bool?
    public let slashCommands: [SlashCommand]?
    public let stopReason, text, threadID, title: String?
    public let tokenUsage: TokenUsage?
    public let turnID: String?
    public let updatedAt: Date?
    public let value: JSONAny?

    public enum CodingKeys: String, CodingKey {
        case approval, attachments, configOptions, createdAt, cwd, decision, item
        case messageID = "messageId"
        case modelSelection
        case optionID = "optionId"
        case plan
        case providerInstanceID = "providerInstanceId"
        case requestID = "requestId"
        case role, session, sessionCleared, slashCommands, stopReason, text
        case threadID = "threadId"
        case title, tokenUsage
        case turnID = "turnId"
        case updatedAt, value
    }

    public init(approval: ApprovalEvent?, attachments: [Attachment]?, configOptions: [ConfigOption]?, createdAt: Date?, cwd: String?, decision: String?, item: Item?, messageID: String?, modelSelection: ModelSelection?, optionID: String?, plan: Plan?, providerInstanceID: String?, requestID: String?, role: String?, session: SessionBinding?, sessionCleared: Bool?, slashCommands: [SlashCommand]?, stopReason: String?, text: String?, threadID: String?, title: String?, tokenUsage: TokenUsage?, turnID: String?, updatedAt: Date?, value: JSONAny?) {
        self.approval = approval
        self.attachments = attachments
        self.configOptions = configOptions
        self.createdAt = createdAt
        self.cwd = cwd
        self.decision = decision
        self.item = item
        self.messageID = messageID
        self.modelSelection = modelSelection
        self.optionID = optionID
        self.plan = plan
        self.providerInstanceID = providerInstanceID
        self.requestID = requestID
        self.role = role
        self.session = session
        self.sessionCleared = sessionCleared
        self.slashCommands = slashCommands
        self.stopReason = stopReason
        self.text = text
        self.threadID = threadID
        self.title = title
        self.tokenUsage = tokenUsage
        self.turnID = turnID
        self.updatedAt = updatedAt
        self.value = value
    }
}

// MARK: EventPayload convenience initializers and mutators

public extension EventPayload {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(EventPayload.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        approval: ApprovalEvent?? = nil,
        attachments: [Attachment]?? = nil,
        configOptions: [ConfigOption]?? = nil,
        createdAt: Date?? = nil,
        cwd: String?? = nil,
        decision: String?? = nil,
        item: Item?? = nil,
        messageID: String?? = nil,
        modelSelection: ModelSelection?? = nil,
        optionID: String?? = nil,
        plan: Plan?? = nil,
        providerInstanceID: String?? = nil,
        requestID: String?? = nil,
        role: String?? = nil,
        session: SessionBinding?? = nil,
        sessionCleared: Bool?? = nil,
        slashCommands: [SlashCommand]?? = nil,
        stopReason: String?? = nil,
        text: String?? = nil,
        threadID: String?? = nil,
        title: String?? = nil,
        tokenUsage: TokenUsage?? = nil,
        turnID: String?? = nil,
        updatedAt: Date?? = nil,
        value: JSONAny?? = nil
    ) -> EventPayload {
        return EventPayload(
            approval: approval ?? self.approval,
            attachments: attachments ?? self.attachments,
            configOptions: configOptions ?? self.configOptions,
            createdAt: createdAt ?? self.createdAt,
            cwd: cwd ?? self.cwd,
            decision: decision ?? self.decision,
            item: item ?? self.item,
            messageID: messageID ?? self.messageID,
            modelSelection: modelSelection ?? self.modelSelection,
            optionID: optionID ?? self.optionID,
            plan: plan ?? self.plan,
            providerInstanceID: providerInstanceID ?? self.providerInstanceID,
            requestID: requestID ?? self.requestID,
            role: role ?? self.role,
            session: session ?? self.session,
            sessionCleared: sessionCleared ?? self.sessionCleared,
            slashCommands: slashCommands ?? self.slashCommands,
            stopReason: stopReason ?? self.stopReason,
            text: text ?? self.text,
            threadID: threadID ?? self.threadID,
            title: title ?? self.title,
            tokenUsage: tokenUsage ?? self.tokenUsage,
            turnID: turnID ?? self.turnID,
            updatedAt: updatedAt ?? self.updatedAt,
            value: value ?? self.value
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - Item
public struct Item: Codable {
    public let createdAt: Date
    public let id, kind: String
    public let payload: JSONAny?
    public let status: String
    public let textDelta, title, turnID: String?
    public let updatedAt: Date

    public enum CodingKeys: String, CodingKey {
        case createdAt, id, kind, payload, status, textDelta, title
        case turnID = "turnId"
        case updatedAt
    }

    public init(createdAt: Date, id: String, kind: String, payload: JSONAny?, status: String, textDelta: String?, title: String?, turnID: String?, updatedAt: Date) {
        self.createdAt = createdAt
        self.id = id
        self.kind = kind
        self.payload = payload
        self.status = status
        self.textDelta = textDelta
        self.title = title
        self.turnID = turnID
        self.updatedAt = updatedAt
    }
}

// MARK: Item convenience initializers and mutators

public extension Item {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Item.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        createdAt: Date? = nil,
        id: String? = nil,
        kind: String? = nil,
        payload: JSONAny?? = nil,
        status: String? = nil,
        textDelta: String?? = nil,
        title: String?? = nil,
        turnID: String?? = nil,
        updatedAt: Date? = nil
    ) -> Item {
        return Item(
            createdAt: createdAt ?? self.createdAt,
            id: id ?? self.id,
            kind: kind ?? self.kind,
            payload: payload ?? self.payload,
            status: status ?? self.status,
            textDelta: textDelta ?? self.textDelta,
            title: title ?? self.title,
            turnID: turnID ?? self.turnID,
            updatedAt: updatedAt ?? self.updatedAt
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - Plan
public struct Plan: Codable {
    public let entries: [PlanEntry]
    public let updatedAt: Date

    public init(entries: [PlanEntry], updatedAt: Date) {
        self.entries = entries
        self.updatedAt = updatedAt
    }
}

// MARK: Plan convenience initializers and mutators

public extension Plan {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Plan.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        entries: [PlanEntry]? = nil,
        updatedAt: Date? = nil
    ) -> Plan {
        return Plan(
            entries: entries ?? self.entries,
            updatedAt: updatedAt ?? self.updatedAt
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - PlanEntry
public struct PlanEntry: Codable {
    public let content: String
    public let priority, status: String?

    public init(content: String, priority: String?, status: String?) {
        self.content = content
        self.priority = priority
        self.status = status
    }
}

// MARK: PlanEntry convenience initializers and mutators

public extension PlanEntry {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(PlanEntry.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        content: String? = nil,
        priority: String?? = nil,
        status: String?? = nil
    ) -> PlanEntry {
        return PlanEntry(
            content: content ?? self.content,
            priority: priority ?? self.priority,
            status: status ?? self.status
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - SessionBinding
public struct SessionBinding: Codable {
    public let activeTurnID: String?
    public let configOptions: [ConfigOption]?
    public let cwd, lastError, provider: String?
    public let providerInstanceID: String
    public let providerName: String?
    public let slashCommands: [SlashCommand]?
    public let status: String
    public let stopRequested: Bool?
    public let threadID: String
    public let tokenUsage: TokenUsage?
    public let updatedAt: Date

    public enum CodingKeys: String, CodingKey {
        case activeTurnID = "activeTurnId"
        case configOptions, cwd, lastError, provider
        case providerInstanceID = "providerInstanceId"
        case providerName, slashCommands, status, stopRequested
        case threadID = "threadId"
        case tokenUsage, updatedAt
    }

    public init(activeTurnID: String?, configOptions: [ConfigOption]?, cwd: String?, lastError: String?, provider: String?, providerInstanceID: String, providerName: String?, slashCommands: [SlashCommand]?, status: String, stopRequested: Bool?, threadID: String, tokenUsage: TokenUsage?, updatedAt: Date) {
        self.activeTurnID = activeTurnID
        self.configOptions = configOptions
        self.cwd = cwd
        self.lastError = lastError
        self.provider = provider
        self.providerInstanceID = providerInstanceID
        self.providerName = providerName
        self.slashCommands = slashCommands
        self.status = status
        self.stopRequested = stopRequested
        self.threadID = threadID
        self.tokenUsage = tokenUsage
        self.updatedAt = updatedAt
    }
}

// MARK: SessionBinding convenience initializers and mutators

public extension SessionBinding {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(SessionBinding.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        activeTurnID: String?? = nil,
        configOptions: [ConfigOption]?? = nil,
        cwd: String?? = nil,
        lastError: String?? = nil,
        provider: String?? = nil,
        providerInstanceID: String? = nil,
        providerName: String?? = nil,
        slashCommands: [SlashCommand]?? = nil,
        status: String? = nil,
        stopRequested: Bool?? = nil,
        threadID: String? = nil,
        tokenUsage: TokenUsage?? = nil,
        updatedAt: Date? = nil
    ) -> SessionBinding {
        return SessionBinding(
            activeTurnID: activeTurnID ?? self.activeTurnID,
            configOptions: configOptions ?? self.configOptions,
            cwd: cwd ?? self.cwd,
            lastError: lastError ?? self.lastError,
            provider: provider ?? self.provider,
            providerInstanceID: providerInstanceID ?? self.providerInstanceID,
            providerName: providerName ?? self.providerName,
            slashCommands: slashCommands ?? self.slashCommands,
            status: status ?? self.status,
            stopRequested: stopRequested ?? self.stopRequested,
            threadID: threadID ?? self.threadID,
            tokenUsage: tokenUsage ?? self.tokenUsage,
            updatedAt: updatedAt ?? self.updatedAt
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - SlashCommand
public struct SlashCommand: Codable {
    public let description: String?
    public let hasInput: Bool?
    public let name: String

    public init(description: String?, hasInput: Bool?, name: String) {
        self.description = description
        self.hasInput = hasInput
        self.name = name
    }
}

// MARK: SlashCommand convenience initializers and mutators

public extension SlashCommand {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(SlashCommand.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        description: String?? = nil,
        hasInput: Bool?? = nil,
        name: String? = nil
    ) -> SlashCommand {
        return SlashCommand(
            description: description ?? self.description,
            hasInput: hasInput ?? self.hasInput,
            name: name ?? self.name
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - TokenUsage
public struct TokenUsage: Codable {
    public let cost: Double?
    public let currency: String?
    public let maxTokens: Int?
    public let usedTokens: Int

    public init(cost: Double?, currency: String?, maxTokens: Int?, usedTokens: Int) {
        self.cost = cost
        self.currency = currency
        self.maxTokens = maxTokens
        self.usedTokens = usedTokens
    }
}

// MARK: TokenUsage convenience initializers and mutators

public extension TokenUsage {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(TokenUsage.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        cost: Double?? = nil,
        currency: String?? = nil,
        maxTokens: Int?? = nil,
        usedTokens: Int? = nil
    ) -> TokenUsage {
        return TokenUsage(
            cost: cost ?? self.cost,
            currency: currency ?? self.currency,
            maxTokens: maxTokens ?? self.maxTokens,
            usedTokens: usedTokens ?? self.usedTokens
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - InstanceInfo
public struct InstanceInfo: Codable {
    public let auth: Auth
    public let capabilities: Capabilities
    public let driver: String
    public let initializedAt: Date
    public let instanceID: String
    public let metadata: [String: JSONAny]?
    public let name: String
    public let pid: Int?
    public let startedAt: Date
    public let status: String

    public enum CodingKeys: String, CodingKey {
        case auth, capabilities, driver, initializedAt
        case instanceID = "instanceId"
        case metadata, name, pid, startedAt, status
    }

    public init(auth: Auth, capabilities: Capabilities, driver: String, initializedAt: Date, instanceID: String, metadata: [String: JSONAny]?, name: String, pid: Int?, startedAt: Date, status: String) {
        self.auth = auth
        self.capabilities = capabilities
        self.driver = driver
        self.initializedAt = initializedAt
        self.instanceID = instanceID
        self.metadata = metadata
        self.name = name
        self.pid = pid
        self.startedAt = startedAt
        self.status = status
    }
}

// MARK: InstanceInfo convenience initializers and mutators

public extension InstanceInfo {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(InstanceInfo.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        auth: Auth? = nil,
        capabilities: Capabilities? = nil,
        driver: String? = nil,
        initializedAt: Date? = nil,
        instanceID: String? = nil,
        metadata: [String: JSONAny]?? = nil,
        name: String? = nil,
        pid: Int?? = nil,
        startedAt: Date? = nil,
        status: String? = nil
    ) -> InstanceInfo {
        return InstanceInfo(
            auth: auth ?? self.auth,
            capabilities: capabilities ?? self.capabilities,
            driver: driver ?? self.driver,
            initializedAt: initializedAt ?? self.initializedAt,
            instanceID: instanceID ?? self.instanceID,
            metadata: metadata ?? self.metadata,
            name: name ?? self.name,
            pid: pid ?? self.pid,
            startedAt: startedAt ?? self.startedAt,
            status: status ?? self.status
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - Auth
public struct Auth: Codable {
    public let methods: [AuthMethod]?
    public let status: String?

    public init(methods: [AuthMethod]?, status: String?) {
        self.methods = methods
        self.status = status
    }
}

// MARK: Auth convenience initializers and mutators

public extension Auth {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Auth.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        methods: [AuthMethod]?? = nil,
        status: String?? = nil
    ) -> Auth {
        return Auth(
            methods: methods ?? self.methods,
            status: status ?? self.status
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - AuthMethod
public struct AuthMethod: Codable {
    public let description: String?
    public let id: String
    public let name: String?

    public init(description: String?, id: String, name: String?) {
        self.description = description
        self.id = id
        self.name = name
    }
}

// MARK: AuthMethod convenience initializers and mutators

public extension AuthMethod {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(AuthMethod.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        description: String?? = nil,
        id: String? = nil,
        name: String?? = nil
    ) -> AuthMethod {
        return AuthMethod(
            description: description ?? self.description,
            id: id ?? self.id,
            name: name ?? self.name
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - Capabilities
public struct Capabilities: Codable {
    public let auth, loadReplay, logout: Bool?
    public let mcp: MCPCapabilities?
    public let modelSwitch: String?
    public let promptContent: PromptContentCapabilities?
    public let resume: Bool?

    public init(auth: Bool?, loadReplay: Bool?, logout: Bool?, mcp: MCPCapabilities?, modelSwitch: String?, promptContent: PromptContentCapabilities?, resume: Bool?) {
        self.auth = auth
        self.loadReplay = loadReplay
        self.logout = logout
        self.mcp = mcp
        self.modelSwitch = modelSwitch
        self.promptContent = promptContent
        self.resume = resume
    }
}

// MARK: Capabilities convenience initializers and mutators

public extension Capabilities {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Capabilities.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        auth: Bool?? = nil,
        loadReplay: Bool?? = nil,
        logout: Bool?? = nil,
        mcp: MCPCapabilities?? = nil,
        modelSwitch: String?? = nil,
        promptContent: PromptContentCapabilities?? = nil,
        resume: Bool?? = nil
    ) -> Capabilities {
        return Capabilities(
            auth: auth ?? self.auth,
            loadReplay: loadReplay ?? self.loadReplay,
            logout: logout ?? self.logout,
            mcp: mcp ?? self.mcp,
            modelSwitch: modelSwitch ?? self.modelSwitch,
            promptContent: promptContent ?? self.promptContent,
            resume: resume ?? self.resume
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - MCPCapabilities
public struct MCPCapabilities: Codable {
    public let http, sse: Bool?

    public init(http: Bool?, sse: Bool?) {
        self.http = http
        self.sse = sse
    }
}

// MARK: MCPCapabilities convenience initializers and mutators

public extension MCPCapabilities {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(MCPCapabilities.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        http: Bool?? = nil,
        sse: Bool?? = nil
    ) -> MCPCapabilities {
        return MCPCapabilities(
            http: http ?? self.http,
            sse: sse ?? self.sse
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - PromptContentCapabilities
public struct PromptContentCapabilities: Codable {
    public let audio, embeddedContext, image: Bool?

    public init(audio: Bool?, embeddedContext: Bool?, image: Bool?) {
        self.audio = audio
        self.embeddedContext = embeddedContext
        self.image = image
    }
}

// MARK: PromptContentCapabilities convenience initializers and mutators

public extension PromptContentCapabilities {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(PromptContentCapabilities.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        audio: Bool?? = nil,
        embeddedContext: Bool?? = nil,
        image: Bool?? = nil
    ) -> PromptContentCapabilities {
        return PromptContentCapabilities(
            audio: audio ?? self.audio,
            embeddedContext: embeddedContext ?? self.embeddedContext,
            image: image ?? self.image
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - Message
public struct Message: Codable {
    public let attachments: [Attachment]?
    public let createdAt: Date
    public let id, role, text: String
    public let turnID: String?
    public let updatedAt: Date

    public enum CodingKeys: String, CodingKey {
        case attachments, createdAt, id, role, text
        case turnID = "turnId"
        case updatedAt
    }

    public init(attachments: [Attachment]?, createdAt: Date, id: String, role: String, text: String, turnID: String?, updatedAt: Date) {
        self.attachments = attachments
        self.createdAt = createdAt
        self.id = id
        self.role = role
        self.text = text
        self.turnID = turnID
        self.updatedAt = updatedAt
    }
}

// MARK: Message convenience initializers and mutators

public extension Message {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Message.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        attachments: [Attachment]?? = nil,
        createdAt: Date? = nil,
        id: String? = nil,
        role: String? = nil,
        text: String? = nil,
        turnID: String?? = nil,
        updatedAt: Date? = nil
    ) -> Message {
        return Message(
            attachments: attachments ?? self.attachments,
            createdAt: createdAt ?? self.createdAt,
            id: id ?? self.id,
            role: role ?? self.role,
            text: text ?? self.text,
            turnID: turnID ?? self.turnID,
            updatedAt: updatedAt ?? self.updatedAt
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ProviderAuthenticateParams
public struct ProviderAuthenticateParams: Codable {
    public let instanceID, methodID: String

    public enum CodingKeys: String, CodingKey {
        case instanceID = "instanceId"
        case methodID = "methodId"
    }

    public init(instanceID: String, methodID: String) {
        self.instanceID = instanceID
        self.methodID = methodID
    }
}

// MARK: ProviderAuthenticateParams convenience initializers and mutators

public extension ProviderAuthenticateParams {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ProviderAuthenticateParams.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        instanceID: String? = nil,
        methodID: String? = nil
    ) -> ProviderAuthenticateParams {
        return ProviderAuthenticateParams(
            instanceID: instanceID ?? self.instanceID,
            methodID: methodID ?? self.methodID
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ProviderImportSessionParams
public struct ProviderImportSessionParams: Codable {
    public let instanceID: String
    public let session: SessionSummary

    public enum CodingKeys: String, CodingKey {
        case instanceID = "instanceId"
        case session
    }

    public init(instanceID: String, session: SessionSummary) {
        self.instanceID = instanceID
        self.session = session
    }
}

// MARK: ProviderImportSessionParams convenience initializers and mutators

public extension ProviderImportSessionParams {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ProviderImportSessionParams.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        instanceID: String? = nil,
        session: SessionSummary? = nil
    ) -> ProviderImportSessionParams {
        return ProviderImportSessionParams(
            instanceID: instanceID ?? self.instanceID,
            session: session ?? self.session
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - SessionSummary
public struct SessionSummary: Codable {
    public let cwd: String?
    public let sessionID: String
    public let title, updatedAt: String?

    public enum CodingKeys: String, CodingKey {
        case cwd
        case sessionID = "sessionId"
        case title, updatedAt
    }

    public init(cwd: String?, sessionID: String, title: String?, updatedAt: String?) {
        self.cwd = cwd
        self.sessionID = sessionID
        self.title = title
        self.updatedAt = updatedAt
    }
}

// MARK: SessionSummary convenience initializers and mutators

public extension SessionSummary {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(SessionSummary.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        cwd: String?? = nil,
        sessionID: String? = nil,
        title: String?? = nil,
        updatedAt: String?? = nil
    ) -> SessionSummary {
        return SessionSummary(
            cwd: cwd ?? self.cwd,
            sessionID: sessionID ?? self.sessionID,
            title: title ?? self.title,
            updatedAt: updatedAt ?? self.updatedAt
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ProviderImportSessionResult
public struct ProviderImportSessionResult: Codable {
    public let imported: Bool
    public let threadID: String

    public enum CodingKeys: String, CodingKey {
        case imported
        case threadID = "threadId"
    }

    public init(imported: Bool, threadID: String) {
        self.imported = imported
        self.threadID = threadID
    }
}

// MARK: ProviderImportSessionResult convenience initializers and mutators

public extension ProviderImportSessionResult {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ProviderImportSessionResult.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        imported: Bool? = nil,
        threadID: String? = nil
    ) -> ProviderImportSessionResult {
        return ProviderImportSessionResult(
            imported: imported ?? self.imported,
            threadID: threadID ?? self.threadID
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ProviderInstanceParams
public struct ProviderInstanceParams: Codable {
    public let instanceID: String

    public enum CodingKeys: String, CodingKey {
        case instanceID = "instanceId"
    }

    public init(instanceID: String) {
        self.instanceID = instanceID
    }
}

// MARK: ProviderInstanceParams convenience initializers and mutators

public extension ProviderInstanceParams {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ProviderInstanceParams.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        instanceID: String? = nil
    ) -> ProviderInstanceParams {
        return ProviderInstanceParams(
            instanceID: instanceID ?? self.instanceID
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ProviderListSessionsParams
public struct ProviderListSessionsParams: Codable {
    public let cwd: String?
    public let instanceID: String

    public enum CodingKeys: String, CodingKey {
        case cwd
        case instanceID = "instanceId"
    }

    public init(cwd: String?, instanceID: String) {
        self.cwd = cwd
        self.instanceID = instanceID
    }
}

// MARK: ProviderListSessionsParams convenience initializers and mutators

public extension ProviderListSessionsParams {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ProviderListSessionsParams.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        cwd: String?? = nil,
        instanceID: String? = nil
    ) -> ProviderListSessionsParams {
        return ProviderListSessionsParams(
            cwd: cwd ?? self.cwd,
            instanceID: instanceID ?? self.instanceID
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ProviderSessionParams
public struct ProviderSessionParams: Codable {
    public let instanceID, sessionID: String

    public enum CodingKeys: String, CodingKey {
        case instanceID = "instanceId"
        case sessionID = "sessionId"
    }

    public init(instanceID: String, sessionID: String) {
        self.instanceID = instanceID
        self.sessionID = sessionID
    }
}

// MARK: ProviderSessionParams convenience initializers and mutators

public extension ProviderSessionParams {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ProviderSessionParams.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        instanceID: String? = nil,
        sessionID: String? = nil
    ) -> ProviderSessionParams {
        return ProviderSessionParams(
            instanceID: instanceID ?? self.instanceID,
            sessionID: sessionID ?? self.sessionID
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ProviderStartParams
public struct ProviderStartParams: Codable {
    public let config: JSONAny?
    public let driver, instanceID, name: String?
    public let restart: Bool?

    public enum CodingKeys: String, CodingKey {
        case config, driver
        case instanceID = "instanceId"
        case name, restart
    }

    public init(config: JSONAny?, driver: String?, instanceID: String?, name: String?, restart: Bool?) {
        self.config = config
        self.driver = driver
        self.instanceID = instanceID
        self.name = name
        self.restart = restart
    }
}

// MARK: ProviderStartParams convenience initializers and mutators

public extension ProviderStartParams {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ProviderStartParams.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        config: JSONAny?? = nil,
        driver: String?? = nil,
        instanceID: String?? = nil,
        name: String?? = nil,
        restart: Bool?? = nil
    ) -> ProviderStartParams {
        return ProviderStartParams(
            config: config ?? self.config,
            driver: driver ?? self.driver,
            instanceID: instanceID ?? self.instanceID,
            name: name ?? self.name,
            restart: restart ?? self.restart
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ReplayEventsInput
public struct ReplayEventsInput: Codable {
    public let fromSequenceExclusive: Int
    public let limit: Int?
    public let threadID: String?

    public enum CodingKeys: String, CodingKey {
        case fromSequenceExclusive, limit
        case threadID = "threadId"
    }

    public init(fromSequenceExclusive: Int, limit: Int?, threadID: String?) {
        self.fromSequenceExclusive = fromSequenceExclusive
        self.limit = limit
        self.threadID = threadID
    }
}

// MARK: ReplayEventsInput convenience initializers and mutators

public extension ReplayEventsInput {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ReplayEventsInput.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        fromSequenceExclusive: Int? = nil,
        limit: Int?? = nil,
        threadID: String?? = nil
    ) -> ReplayEventsInput {
        return ReplayEventsInput(
            fromSequenceExclusive: fromSequenceExclusive ?? self.fromSequenceExclusive,
            limit: limit ?? self.limit,
            threadID: threadID ?? self.threadID
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - SubscribeThreadInput
public struct SubscribeThreadInput: Codable {
    public let threadID: String

    public enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
    }

    public init(threadID: String) {
        self.threadID = threadID
    }
}

// MARK: SubscribeThreadInput convenience initializers and mutators

public extension SubscribeThreadInput {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(SubscribeThreadInput.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        threadID: String? = nil
    ) -> SubscribeThreadInput {
        return SubscribeThreadInput(
            threadID: threadID ?? self.threadID
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - Thread
public struct Thread: Codable {
    public let createdAt: Date
    public let cwd: String?
    public let draft: Bool
    public let id: String
    public let latestTurn: Turn?
    public let modelSelection: ModelSelection?
    public let plan: Plan?
    public let providerInstanceID: String?
    public let session: SessionBinding?
    public let timeline: [TimelineEntry]
    public let title: String
    public let updatedAt: Date

    public enum CodingKeys: String, CodingKey {
        case createdAt, cwd, draft, id, latestTurn, modelSelection, plan
        case providerInstanceID = "providerInstanceId"
        case session, timeline, title, updatedAt
    }

    public init(createdAt: Date, cwd: String?, draft: Bool, id: String, latestTurn: Turn?, modelSelection: ModelSelection?, plan: Plan?, providerInstanceID: String?, session: SessionBinding?, timeline: [TimelineEntry], title: String, updatedAt: Date) {
        self.createdAt = createdAt
        self.cwd = cwd
        self.draft = draft
        self.id = id
        self.latestTurn = latestTurn
        self.modelSelection = modelSelection
        self.plan = plan
        self.providerInstanceID = providerInstanceID
        self.session = session
        self.timeline = timeline
        self.title = title
        self.updatedAt = updatedAt
    }
}

// MARK: Thread convenience initializers and mutators

public extension Thread {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Thread.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        createdAt: Date? = nil,
        cwd: String?? = nil,
        draft: Bool? = nil,
        id: String? = nil,
        latestTurn: Turn?? = nil,
        modelSelection: ModelSelection?? = nil,
        plan: Plan?? = nil,
        providerInstanceID: String?? = nil,
        session: SessionBinding?? = nil,
        timeline: [TimelineEntry]? = nil,
        title: String? = nil,
        updatedAt: Date? = nil
    ) -> Thread {
        return Thread(
            createdAt: createdAt ?? self.createdAt,
            cwd: cwd ?? self.cwd,
            draft: draft ?? self.draft,
            id: id ?? self.id,
            latestTurn: latestTurn ?? self.latestTurn,
            modelSelection: modelSelection ?? self.modelSelection,
            plan: plan ?? self.plan,
            providerInstanceID: providerInstanceID ?? self.providerInstanceID,
            session: session ?? self.session,
            timeline: timeline ?? self.timeline,
            title: title ?? self.title,
            updatedAt: updatedAt ?? self.updatedAt
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - Turn
public struct Turn: Codable {
    public let completedAt: Date?
    public let error: String?
    public let interruptRequested: Bool?
    public let requestedAt: Date
    public let startedAt: Date?
    public let state: String
    public let stopReason: String?
    public let turnID: String

    public enum CodingKeys: String, CodingKey {
        case completedAt, error, interruptRequested, requestedAt, startedAt, state, stopReason
        case turnID = "turnId"
    }

    public init(completedAt: Date?, error: String?, interruptRequested: Bool?, requestedAt: Date, startedAt: Date?, state: String, stopReason: String?, turnID: String) {
        self.completedAt = completedAt
        self.error = error
        self.interruptRequested = interruptRequested
        self.requestedAt = requestedAt
        self.startedAt = startedAt
        self.state = state
        self.stopReason = stopReason
        self.turnID = turnID
    }
}

// MARK: Turn convenience initializers and mutators

public extension Turn {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Turn.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        completedAt: Date?? = nil,
        error: String?? = nil,
        interruptRequested: Bool?? = nil,
        requestedAt: Date? = nil,
        startedAt: Date?? = nil,
        state: String? = nil,
        stopReason: String?? = nil,
        turnID: String? = nil
    ) -> Turn {
        return Turn(
            completedAt: completedAt ?? self.completedAt,
            error: error ?? self.error,
            interruptRequested: interruptRequested ?? self.interruptRequested,
            requestedAt: requestedAt ?? self.requestedAt,
            startedAt: startedAt ?? self.startedAt,
            state: state ?? self.state,
            stopReason: stopReason ?? self.stopReason,
            turnID: turnID ?? self.turnID
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - TimelineEntry
public struct TimelineEntry: Codable {
    public let approval: Approval?
    public let item: Item?
    public let kind: String
    public let message: Message?

    public init(approval: Approval?, item: Item?, kind: String, message: Message?) {
        self.approval = approval
        self.item = item
        self.kind = kind
        self.message = message
    }
}

// MARK: TimelineEntry convenience initializers and mutators

public extension TimelineEntry {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(TimelineEntry.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        approval: Approval?? = nil,
        item: Item?? = nil,
        kind: String? = nil,
        message: Message?? = nil
    ) -> TimelineEntry {
        return TimelineEntry(
            approval: approval ?? self.approval,
            item: item ?? self.item,
            kind: kind ?? self.kind,
            message: message ?? self.message
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ThreadDetailSnapshot
public struct ThreadDetailSnapshot: Codable {
    public let snapshotSequence: Int
    public let thread: Thread

    public init(snapshotSequence: Int, thread: Thread) {
        self.snapshotSequence = snapshotSequence
        self.thread = thread
    }
}

// MARK: ThreadDetailSnapshot convenience initializers and mutators

public extension ThreadDetailSnapshot {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ThreadDetailSnapshot.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        snapshotSequence: Int? = nil,
        thread: Thread? = nil
    ) -> ThreadDetailSnapshot {
        return ThreadDetailSnapshot(
            snapshotSequence: snapshotSequence ?? self.snapshotSequence,
            thread: thread ?? self.thread
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ThreadListEntry
public struct ThreadListEntry: Codable {
    public let createdAt: Date
    public let cwd: String?
    public let draft, hasPendingApprovals: Bool
    public let id: String
    public let latestTurn: Turn?
    public let modelSelection: ModelSelection?
    public let providerInstanceID: String?
    public let session: SessionBinding?
    public let title: String
    public let updatedAt: Date

    public enum CodingKeys: String, CodingKey {
        case createdAt, cwd, draft, hasPendingApprovals, id, latestTurn, modelSelection
        case providerInstanceID = "providerInstanceId"
        case session, title, updatedAt
    }

    public init(createdAt: Date, cwd: String?, draft: Bool, hasPendingApprovals: Bool, id: String, latestTurn: Turn?, modelSelection: ModelSelection?, providerInstanceID: String?, session: SessionBinding?, title: String, updatedAt: Date) {
        self.createdAt = createdAt
        self.cwd = cwd
        self.draft = draft
        self.hasPendingApprovals = hasPendingApprovals
        self.id = id
        self.latestTurn = latestTurn
        self.modelSelection = modelSelection
        self.providerInstanceID = providerInstanceID
        self.session = session
        self.title = title
        self.updatedAt = updatedAt
    }
}

// MARK: ThreadListEntry convenience initializers and mutators

public extension ThreadListEntry {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ThreadListEntry.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        createdAt: Date? = nil,
        cwd: String?? = nil,
        draft: Bool? = nil,
        hasPendingApprovals: Bool? = nil,
        id: String? = nil,
        latestTurn: Turn?? = nil,
        modelSelection: ModelSelection?? = nil,
        providerInstanceID: String?? = nil,
        session: SessionBinding?? = nil,
        title: String? = nil,
        updatedAt: Date? = nil
    ) -> ThreadListEntry {
        return ThreadListEntry(
            createdAt: createdAt ?? self.createdAt,
            cwd: cwd ?? self.cwd,
            draft: draft ?? self.draft,
            hasPendingApprovals: hasPendingApprovals ?? self.hasPendingApprovals,
            id: id ?? self.id,
            latestTurn: latestTurn ?? self.latestTurn,
            modelSelection: modelSelection ?? self.modelSelection,
            providerInstanceID: providerInstanceID ?? self.providerInstanceID,
            session: session ?? self.session,
            title: title ?? self.title,
            updatedAt: updatedAt ?? self.updatedAt
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ThreadListSnapshot
public struct ThreadListSnapshot: Codable {
    public let snapshotSequence: Int
    public let threads: [ThreadListEntry]
    public let updatedAt: Date

    public init(snapshotSequence: Int, threads: [ThreadListEntry], updatedAt: Date) {
        self.snapshotSequence = snapshotSequence
        self.threads = threads
        self.updatedAt = updatedAt
    }
}

// MARK: ThreadListSnapshot convenience initializers and mutators

public extension ThreadListSnapshot {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ThreadListSnapshot.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        snapshotSequence: Int? = nil,
        threads: [ThreadListEntry]? = nil,
        updatedAt: Date? = nil
    ) -> ThreadListSnapshot {
        return ThreadListSnapshot(
            snapshotSequence: snapshotSequence ?? self.snapshotSequence,
            threads: threads ?? self.threads,
            updatedAt: updatedAt ?? self.updatedAt
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ThreadListStreamItem
public struct ThreadListStreamItem: Codable {
    public let kind: String
    public let sequence: Int?
    public let snapshot: ThreadListSnapshot?
    public let thread: ThreadListEntry?
    public let threadID: String?

    public enum CodingKeys: String, CodingKey {
        case kind, sequence, snapshot, thread
        case threadID = "threadId"
    }

    public init(kind: String, sequence: Int?, snapshot: ThreadListSnapshot?, thread: ThreadListEntry?, threadID: String?) {
        self.kind = kind
        self.sequence = sequence
        self.snapshot = snapshot
        self.thread = thread
        self.threadID = threadID
    }
}

// MARK: ThreadListStreamItem convenience initializers and mutators

public extension ThreadListStreamItem {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ThreadListStreamItem.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        kind: String? = nil,
        sequence: Int?? = nil,
        snapshot: ThreadListSnapshot?? = nil,
        thread: ThreadListEntry?? = nil,
        threadID: String?? = nil
    ) -> ThreadListStreamItem {
        return ThreadListStreamItem(
            kind: kind ?? self.kind,
            sequence: sequence ?? self.sequence,
            snapshot: snapshot ?? self.snapshot,
            thread: thread ?? self.thread,
            threadID: threadID ?? self.threadID
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ThreadStreamItem
public struct ThreadStreamItem: Codable {
    public let event: Event?
    public let kind: String
    public let snapshot: ThreadDetailSnapshot?

    public init(event: Event?, kind: String, snapshot: ThreadDetailSnapshot?) {
        self.event = event
        self.kind = kind
        self.snapshot = snapshot
    }
}

// MARK: ThreadStreamItem convenience initializers and mutators

public extension ThreadStreamItem {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ThreadStreamItem.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        event: Event?? = nil,
        kind: String? = nil,
        snapshot: ThreadDetailSnapshot?? = nil
    ) -> ThreadStreamItem {
        return ThreadStreamItem(
            event: event ?? self.event,
            kind: kind ?? self.kind,
            snapshot: snapshot ?? self.snapshot
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - Helper functions for creating encoders and decoders

func newJSONDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    if #available(iOS 10.0, OSX 10.12, tvOS 10.0, watchOS 3.0, *) {
        decoder.dateDecodingStrategy = .iso8601
    }
    return decoder
}

func newJSONEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    if #available(iOS 10.0, OSX 10.12, tvOS 10.0, watchOS 3.0, *) {
        encoder.dateEncodingStrategy = .iso8601
    }
    return encoder
}

// MARK: - Encode/decode helpers

public class JSONNull: Codable, Hashable {

    public static func == (lhs: JSONNull, rhs: JSONNull) -> Bool {
        return true
    }

    public var hashValue: Int {
        return 0
    }

    public func hash(into hasher: inout Hasher) {
        // No-op
    }

    public init() {}

    public required init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if !container.decodeNil() {
            throw DecodingError.typeMismatch(JSONNull.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Wrong type for JSONNull"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encodeNil()
    }
}

class JSONCodingKey: CodingKey {
    let key: String

    required init?(intValue: Int) {
        return nil
    }

    required init?(stringValue: String) {
        key = stringValue
    }

    var intValue: Int? {
        return nil
    }

    var stringValue: String {
        return key
    }
}

public class JSONAny: Codable {

    public let value: Any

    static func decodingError(forCodingPath codingPath: [CodingKey]) -> DecodingError {
        let context = DecodingError.Context(codingPath: codingPath, debugDescription: "Cannot decode JSONAny")
        return DecodingError.typeMismatch(JSONAny.self, context)
    }

    static func encodingError(forValue value: Any, codingPath: [CodingKey]) -> EncodingError {
        let context = EncodingError.Context(codingPath: codingPath, debugDescription: "Cannot encode JSONAny")
        return EncodingError.invalidValue(value, context)
    }

    static func decode(from container: SingleValueDecodingContainer) throws -> Any {
        if let value = try? container.decode(Bool.self) {
            return value
        }
        if let value = try? container.decode(Int64.self) {
            return value
        }
        if let value = try? container.decode(Double.self) {
            return value
        }
        if let value = try? container.decode(String.self) {
            return value
        }
        if container.decodeNil() {
            return JSONNull()
        }
        throw decodingError(forCodingPath: container.codingPath)
    }

    static func decode(from container: inout UnkeyedDecodingContainer) throws -> Any {
        if let value = try? container.decode(Bool.self) {
            return value
        }
        if let value = try? container.decode(Int64.self) {
            return value
        }
        if let value = try? container.decode(Double.self) {
            return value
        }
        if let value = try? container.decode(String.self) {
            return value
        }
        if let value = try? container.decodeNil() {
            if value {
                return JSONNull()
            }
        }
        if var container = try? container.nestedUnkeyedContainer() {
            return try decodeArray(from: &container)
        }
        if var container = try? container.nestedContainer(keyedBy: JSONCodingKey.self) {
            return try decodeDictionary(from: &container)
        }
        throw decodingError(forCodingPath: container.codingPath)
    }

    static func decode(from container: inout KeyedDecodingContainer<JSONCodingKey>, forKey key: JSONCodingKey) throws -> Any {
        if let value = try? container.decode(Bool.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(Int64.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(Double.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(String.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeNil(forKey: key) {
            if value {
                return JSONNull()
            }
        }
        if var container = try? container.nestedUnkeyedContainer(forKey: key) {
            return try decodeArray(from: &container)
        }
        if var container = try? container.nestedContainer(keyedBy: JSONCodingKey.self, forKey: key) {
            return try decodeDictionary(from: &container)
        }
        throw decodingError(forCodingPath: container.codingPath)
    }

    static func decodeArray(from container: inout UnkeyedDecodingContainer) throws -> [Any] {
        var arr: [Any] = []
        while !container.isAtEnd {
            let value = try decode(from: &container)
            arr.append(value)
        }
        return arr
    }

    static func decodeDictionary(from container: inout KeyedDecodingContainer<JSONCodingKey>) throws -> [String: Any] {
        var dict = [String: Any]()
        for key in container.allKeys {
            let value = try decode(from: &container, forKey: key)
            dict[key.stringValue] = value
        }
        return dict
    }

    static func encode(to container: inout UnkeyedEncodingContainer, array: [Any]) throws {
        for value in array {
            if let value = value as? Bool {
                try container.encode(value)
            } else if let value = value as? Int64 {
                try container.encode(value)
            } else if let value = value as? Double {
                try container.encode(value)
            } else if let value = value as? String {
                try container.encode(value)
            } else if value is JSONNull {
                try container.encodeNil()
            } else if let value = value as? [Any] {
                var container = container.nestedUnkeyedContainer()
                try encode(to: &container, array: value)
            } else if let value = value as? [String: Any] {
                var container = container.nestedContainer(keyedBy: JSONCodingKey.self)
                try encode(to: &container, dictionary: value)
            } else {
                throw encodingError(forValue: value, codingPath: container.codingPath)
            }
        }
    }

    static func encode(to container: inout KeyedEncodingContainer<JSONCodingKey>, dictionary: [String: Any]) throws {
        for (key, value) in dictionary {
            let key = JSONCodingKey(stringValue: key)!
            if let value = value as? Bool {
                try container.encode(value, forKey: key)
            } else if let value = value as? Int64 {
                try container.encode(value, forKey: key)
            } else if let value = value as? Double {
                try container.encode(value, forKey: key)
            } else if let value = value as? String {
                try container.encode(value, forKey: key)
            } else if value is JSONNull {
                try container.encodeNil(forKey: key)
            } else if let value = value as? [Any] {
                var container = container.nestedUnkeyedContainer(forKey: key)
                try encode(to: &container, array: value)
            } else if let value = value as? [String: Any] {
                var container = container.nestedContainer(keyedBy: JSONCodingKey.self, forKey: key)
                try encode(to: &container, dictionary: value)
            } else {
                throw encodingError(forValue: value, codingPath: container.codingPath)
            }
        }
    }

    static func encode(to container: inout SingleValueEncodingContainer, value: Any) throws {
        if let value = value as? Bool {
            try container.encode(value)
        } else if let value = value as? Int64 {
            try container.encode(value)
        } else if let value = value as? Double {
            try container.encode(value)
        } else if let value = value as? String {
            try container.encode(value)
        } else if value is JSONNull {
            try container.encodeNil()
        } else {
            throw encodingError(forValue: value, codingPath: container.codingPath)
        }
    }

    /// Wraps a JSON-compatible Swift value for arbitrary wire fields.
    public init(_ value: Any) {
        self.value = value
    }

    public required init(from decoder: Decoder) throws {
        if var arrayContainer = try? decoder.unkeyedContainer() {
            self.value = try JSONAny.decodeArray(from: &arrayContainer)
        } else if var container = try? decoder.container(keyedBy: JSONCodingKey.self) {
            self.value = try JSONAny.decodeDictionary(from: &container)
        } else {
            let container = try decoder.singleValueContainer()
            self.value = try JSONAny.decode(from: container)
        }
    }

    public func encode(to encoder: Encoder) throws {
        if let arr = self.value as? [Any] {
            var container = encoder.unkeyedContainer()
            try JSONAny.encode(to: &container, array: arr)
        } else if let dict = self.value as? [String: Any] {
            var container = encoder.container(keyedBy: JSONCodingKey.self)
            try JSONAny.encode(to: &container, dictionary: dict)
        } else {
            var container = encoder.singleValueContainer()
            try JSONAny.encode(to: &container, value: self.value)
        }
    }
}
