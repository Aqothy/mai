// This file was generated from JSON Schema using quicktype, do not modify it directly.
// To parse the JSON, add this file to your project and do:
//
//   let maidClientAPI = try MaidClientAPI(json)

import Foundation

// MARK: - ACPRegistryAgent
public struct ACPRegistryAgent: Codable {
    public var args: [String]?
    public var description, icon: String?
    public var id, instanceID, name, package: String
    public var version: String?

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

// MARK: - ACPRegistryInstallParams
public struct ACPRegistryInstallParams: Codable {
    public var registryID: String

    public enum CodingKeys: String, CodingKey {
        case registryID = "registryId"
    }

    public init(registryID: String) {
        self.registryID = registryID
    }
}

// MARK: ACPRegistryInstallParams convenience initializers and mutators

public extension ACPRegistryInstallParams {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ACPRegistryInstallParams.self, from: data)
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
        registryID: String? = nil
    ) -> ACPRegistryInstallParams {
        return ACPRegistryInstallParams(
            registryID: registryID ?? self.registryID
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ACPRegistryInstalledAgent
public struct ACPRegistryInstalledAgent: Codable {
    public var args: [String]?
    public var description, icon: String?
    public var id: String
    public var installedAt: Date
    public var instanceID, name, package, version: String

    public enum CodingKeys: String, CodingKey {
        case args, description, icon, id, installedAt
        case instanceID = "instanceId"
        case name, package, version
    }

    public init(args: [String]?, description: String?, icon: String?, id: String, installedAt: Date, instanceID: String, name: String, package: String, version: String) {
        self.args = args
        self.description = description
        self.icon = icon
        self.id = id
        self.installedAt = installedAt
        self.instanceID = instanceID
        self.name = name
        self.package = package
        self.version = version
    }
}

// MARK: ACPRegistryInstalledAgent convenience initializers and mutators

public extension ACPRegistryInstalledAgent {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ACPRegistryInstalledAgent.self, from: data)
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
        installedAt: Date? = nil,
        instanceID: String? = nil,
        name: String? = nil,
        package: String? = nil,
        version: String? = nil
    ) -> ACPRegistryInstalledAgent {
        return ACPRegistryInstalledAgent(
            args: args ?? self.args,
            description: description ?? self.description,
            icon: icon ?? self.icon,
            id: id ?? self.id,
            installedAt: installedAt ?? self.installedAt,
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
    public var registryID: String
    public var restart: Bool?

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
    public var args: JSONAny?
    public var createdAt: Date
    public var decision, optionID: String?
    public var options: [ApprovalOption]?
    public var requestID, status: String
    public var turnID: String?
    public var updatedAt: Date

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
    public var kind: String?
    public var name, optionID: String

    public enum CodingKeys: String, CodingKey {
        case kind, name
        case optionID = "optionId"
    }

    public init(kind: String?, name: String, optionID: String) {
        self.kind = kind
        self.name = name
        self.optionID = optionID
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
        name: String? = nil,
        optionID: String? = nil
    ) -> ApprovalOption {
        return ApprovalOption(
            kind: kind ?? self.kind,
            name: name ?? self.name,
            optionID: optionID ?? self.optionID
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
    public var args: JSONAny?
    public var cancelled: Bool?
    public var decision, detail, optionID: String?
    public var options: [ApprovalOption]?
    public var requestID: String
    public var requestType, turnID: String?

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
    public var data: String?
    public var kind: String
    public var mimeType, name, uri: String?

    public init(data: String?, kind: String, mimeType: String?, name: String?, uri: String?) {
        self.data = data
        self.kind = kind
        self.mimeType = mimeType
        self.name = name
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
        mimeType: String?? = nil,
        name: String?? = nil,
        uri: String?? = nil
    ) -> Attachment {
        return Attachment(
            data: data ?? self.data,
            kind: kind ?? self.kind,
            mimeType: mimeType ?? self.mimeType,
            name: name ?? self.name,
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
    public var commandID: String?
    public var configSelections: [ConfigOptionSelection]?
    public var createdAt: Date?
    public var cwd, decision: String?
    public var message: CommandMessage?
    public var modelSelection: ModelSelection?
    public var optionID, providerInstanceID, requestID, threadID: String?
    public var title, turnID: String?
    public var type: String
    public var value: JSONAny?

    public enum CodingKeys: String, CodingKey {
        case commandID = "commandId"
        case configSelections, createdAt, cwd, decision, message, modelSelection
        case optionID = "optionId"
        case providerInstanceID = "providerInstanceId"
        case requestID = "requestId"
        case threadID = "threadId"
        case title
        case turnID = "turnId"
        case type, value
    }

    public init(commandID: String?, configSelections: [ConfigOptionSelection]?, createdAt: Date?, cwd: String?, decision: String?, message: CommandMessage?, modelSelection: ModelSelection?, optionID: String?, providerInstanceID: String?, requestID: String?, threadID: String?, title: String?, turnID: String?, type: String, value: JSONAny?) {
        self.commandID = commandID
        self.configSelections = configSelections
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
        configSelections: [ConfigOptionSelection]?? = nil,
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
            configSelections: configSelections ?? self.configSelections,
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

// MARK: - ConfigOptionSelection
public struct ConfigOptionSelection: Codable {
    public var category: String?
    public var optionID: String
    public var value: JSONAny

    public enum CodingKeys: String, CodingKey {
        case category
        case optionID = "optionId"
        case value
    }

    public init(category: String?, optionID: String, value: JSONAny) {
        self.category = category
        self.optionID = optionID
        self.value = value
    }
}

// MARK: ConfigOptionSelection convenience initializers and mutators

public extension ConfigOptionSelection {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ConfigOptionSelection.self, from: data)
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
        optionID: String? = nil,
        value: JSONAny? = nil
    ) -> ConfigOptionSelection {
        return ConfigOptionSelection(
            category: category ?? self.category,
            optionID: optionID ?? self.optionID,
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
    public var attachments: [Attachment]?
    public var messageID: String?
    public var text: String

    public enum CodingKeys: String, CodingKey {
        case attachments
        case messageID = "messageId"
        case text
    }

    public init(attachments: [Attachment]?, messageID: String?, text: String) {
        self.attachments = attachments
        self.messageID = messageID
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
        text: String? = nil
    ) -> CommandMessage {
        return CommandMessage(
            attachments: attachments ?? self.attachments,
            messageID: messageID ?? self.messageID,
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
    public var model: String?
    public var options: JSONAny?

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
    public var label: String?
    public var value: String

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
    public var category: String?
    public var choices: [ConfigChoice]?
    public var currentValue: JSONAny?
    public var description: String?
    public var id: String
    public var label: String?
    public var type: String

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
    public var sequence: Int

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
    public var actor, commandID: String?
    public var eventID: String
    public var metadata: EventMetadata?
    public var occurredAt: Date
    public var payload: EventPayload
    public var sequence: Int
    public var type: String

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
    public var requestID: String?

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
    public var approval: ApprovalEvent?
    public var attachments: [Attachment]?
    public var configOptions: [ConfigOption]?
    public var createdAt: Date?
    public var cwd, decision: String?
    public var item: Item?
    public var messageID: String?
    public var modelSelection: ModelSelection?
    public var optionID: String?
    public var plan: Plan?
    public var providerInstanceID, requestID, role: String?
    public var session: SessionBinding?
    public var sessionCleared: Bool?
    public var slashCommands: [SlashCommand]?
    public var stopReason, text, threadID, title: String?
    public var tokenUsage: TokenUsage?
    public var turnID: String?
    public var updatedAt: Date?
    public var value: JSONAny?

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
    public var createdAt: Date
    public var detailAvailable: Bool?
    public var id, kind: String
    public var payload: JSONAny?
    public var sequence: Int?
    public var status: String
    public var textDelta, title: String?
    public var toolCall: ToolCall?
    public var toolCallSummary: ToolCallSummary?
    public var turnID: String?
    public var updatedAt: Date

    public enum CodingKeys: String, CodingKey {
        case createdAt, detailAvailable, id, kind, payload, sequence, status, textDelta, title, toolCall, toolCallSummary
        case turnID = "turnId"
        case updatedAt
    }

    public init(createdAt: Date, detailAvailable: Bool?, id: String, kind: String, payload: JSONAny?, sequence: Int?, status: String, textDelta: String?, title: String?, toolCall: ToolCall?, toolCallSummary: ToolCallSummary?, turnID: String?, updatedAt: Date) {
        self.createdAt = createdAt
        self.detailAvailable = detailAvailable
        self.id = id
        self.kind = kind
        self.payload = payload
        self.sequence = sequence
        self.status = status
        self.textDelta = textDelta
        self.title = title
        self.toolCall = toolCall
        self.toolCallSummary = toolCallSummary
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
        detailAvailable: Bool?? = nil,
        id: String? = nil,
        kind: String? = nil,
        payload: JSONAny?? = nil,
        sequence: Int?? = nil,
        status: String? = nil,
        textDelta: String?? = nil,
        title: String?? = nil,
        toolCall: ToolCall?? = nil,
        toolCallSummary: ToolCallSummary?? = nil,
        turnID: String?? = nil,
        updatedAt: Date? = nil
    ) -> Item {
        return Item(
            createdAt: createdAt ?? self.createdAt,
            detailAvailable: detailAvailable ?? self.detailAvailable,
            id: id ?? self.id,
            kind: kind ?? self.kind,
            payload: payload ?? self.payload,
            sequence: sequence ?? self.sequence,
            status: status ?? self.status,
            textDelta: textDelta ?? self.textDelta,
            title: title ?? self.title,
            toolCall: toolCall ?? self.toolCall,
            toolCallSummary: toolCallSummary ?? self.toolCallSummary,
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

// MARK: - ToolCall
public struct ToolCall: Codable {
    public var action: String
    public var attachments: [Attachment]?
    public var changes: [FileChange]?
    public var command, cwd: String?
    public var durationMilliseconds: Int?
    public var error: String?
    public var exitCode: Int?
    public var locations: [ToolLocation]?
    public var name, namespace, output, providerKind: String?
    public var query: String?

    public init(action: String, attachments: [Attachment]?, changes: [FileChange]?, command: String?, cwd: String?, durationMilliseconds: Int?, error: String?, exitCode: Int?, locations: [ToolLocation]?, name: String?, namespace: String?, output: String?, providerKind: String?, query: String?) {
        self.action = action
        self.attachments = attachments
        self.changes = changes
        self.command = command
        self.cwd = cwd
        self.durationMilliseconds = durationMilliseconds
        self.error = error
        self.exitCode = exitCode
        self.locations = locations
        self.name = name
        self.namespace = namespace
        self.output = output
        self.providerKind = providerKind
        self.query = query
    }
}

// MARK: ToolCall convenience initializers and mutators

public extension ToolCall {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ToolCall.self, from: data)
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
        action: String? = nil,
        attachments: [Attachment]?? = nil,
        changes: [FileChange]?? = nil,
        command: String?? = nil,
        cwd: String?? = nil,
        durationMilliseconds: Int?? = nil,
        error: String?? = nil,
        exitCode: Int?? = nil,
        locations: [ToolLocation]?? = nil,
        name: String?? = nil,
        namespace: String?? = nil,
        output: String?? = nil,
        providerKind: String?? = nil,
        query: String?? = nil
    ) -> ToolCall {
        return ToolCall(
            action: action ?? self.action,
            attachments: attachments ?? self.attachments,
            changes: changes ?? self.changes,
            command: command ?? self.command,
            cwd: cwd ?? self.cwd,
            durationMilliseconds: durationMilliseconds ?? self.durationMilliseconds,
            error: error ?? self.error,
            exitCode: exitCode ?? self.exitCode,
            locations: locations ?? self.locations,
            name: name ?? self.name,
            namespace: namespace ?? self.namespace,
            output: output ?? self.output,
            providerKind: providerKind ?? self.providerKind,
            query: query ?? self.query
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - FileChange
public struct FileChange: Codable {
    public var diff, kind, movePath, newText: String?
    public var oldText: String?
    public var path: String

    public init(diff: String?, kind: String?, movePath: String?, newText: String?, oldText: String?, path: String) {
        self.diff = diff
        self.kind = kind
        self.movePath = movePath
        self.newText = newText
        self.oldText = oldText
        self.path = path
    }
}

// MARK: FileChange convenience initializers and mutators

public extension FileChange {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(FileChange.self, from: data)
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
        diff: String?? = nil,
        kind: String?? = nil,
        movePath: String?? = nil,
        newText: String?? = nil,
        oldText: String?? = nil,
        path: String? = nil
    ) -> FileChange {
        return FileChange(
            diff: diff ?? self.diff,
            kind: kind ?? self.kind,
            movePath: movePath ?? self.movePath,
            newText: newText ?? self.newText,
            oldText: oldText ?? self.oldText,
            path: path ?? self.path
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ToolLocation
public struct ToolLocation: Codable {
    public var line: Int?
    public var path: String

    public init(line: Int?, path: String) {
        self.line = line
        self.path = path
    }
}

// MARK: ToolLocation convenience initializers and mutators

public extension ToolLocation {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ToolLocation.self, from: data)
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
        line: Int?? = nil,
        path: String? = nil
    ) -> ToolLocation {
        return ToolLocation(
            line: line ?? self.line,
            path: path ?? self.path
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ToolCallSummary
public struct ToolCallSummary: Codable {
    public var action: String
    public var attachmentCount: Int?
    public var attachments: [ToolAttachmentSummary]?
    public var changeCount: Int?
    public var changes: [FileChangeSummary]?
    public var commandPreview, cwd: String?
    public var durationMilliseconds: Int?
    public var errorPreview: String?
    public var exitCode, locationCount: Int?
    public var locations: [ToolLocation]?
    public var name, namespace, outputPreview, providerKind: String?
    public var queryPreview: String?
    public var truncated: Bool?

    public init(action: String, attachmentCount: Int?, attachments: [ToolAttachmentSummary]?, changeCount: Int?, changes: [FileChangeSummary]?, commandPreview: String?, cwd: String?, durationMilliseconds: Int?, errorPreview: String?, exitCode: Int?, locationCount: Int?, locations: [ToolLocation]?, name: String?, namespace: String?, outputPreview: String?, providerKind: String?, queryPreview: String?, truncated: Bool?) {
        self.action = action
        self.attachmentCount = attachmentCount
        self.attachments = attachments
        self.changeCount = changeCount
        self.changes = changes
        self.commandPreview = commandPreview
        self.cwd = cwd
        self.durationMilliseconds = durationMilliseconds
        self.errorPreview = errorPreview
        self.exitCode = exitCode
        self.locationCount = locationCount
        self.locations = locations
        self.name = name
        self.namespace = namespace
        self.outputPreview = outputPreview
        self.providerKind = providerKind
        self.queryPreview = queryPreview
        self.truncated = truncated
    }
}

// MARK: ToolCallSummary convenience initializers and mutators

public extension ToolCallSummary {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ToolCallSummary.self, from: data)
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
        action: String? = nil,
        attachmentCount: Int?? = nil,
        attachments: [ToolAttachmentSummary]?? = nil,
        changeCount: Int?? = nil,
        changes: [FileChangeSummary]?? = nil,
        commandPreview: String?? = nil,
        cwd: String?? = nil,
        durationMilliseconds: Int?? = nil,
        errorPreview: String?? = nil,
        exitCode: Int?? = nil,
        locationCount: Int?? = nil,
        locations: [ToolLocation]?? = nil,
        name: String?? = nil,
        namespace: String?? = nil,
        outputPreview: String?? = nil,
        providerKind: String?? = nil,
        queryPreview: String?? = nil,
        truncated: Bool?? = nil
    ) -> ToolCallSummary {
        return ToolCallSummary(
            action: action ?? self.action,
            attachmentCount: attachmentCount ?? self.attachmentCount,
            attachments: attachments ?? self.attachments,
            changeCount: changeCount ?? self.changeCount,
            changes: changes ?? self.changes,
            commandPreview: commandPreview ?? self.commandPreview,
            cwd: cwd ?? self.cwd,
            durationMilliseconds: durationMilliseconds ?? self.durationMilliseconds,
            errorPreview: errorPreview ?? self.errorPreview,
            exitCode: exitCode ?? self.exitCode,
            locationCount: locationCount ?? self.locationCount,
            locations: locations ?? self.locations,
            name: name ?? self.name,
            namespace: namespace ?? self.namespace,
            outputPreview: outputPreview ?? self.outputPreview,
            providerKind: providerKind ?? self.providerKind,
            queryPreview: queryPreview ?? self.queryPreview,
            truncated: truncated ?? self.truncated
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ToolAttachmentSummary
public struct ToolAttachmentSummary: Codable {
    public var kind: String
    public var mimeType, name, uri: String?

    public init(kind: String, mimeType: String?, name: String?, uri: String?) {
        self.kind = kind
        self.mimeType = mimeType
        self.name = name
        self.uri = uri
    }
}

// MARK: ToolAttachmentSummary convenience initializers and mutators

public extension ToolAttachmentSummary {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ToolAttachmentSummary.self, from: data)
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
        mimeType: String?? = nil,
        name: String?? = nil,
        uri: String?? = nil
    ) -> ToolAttachmentSummary {
        return ToolAttachmentSummary(
            kind: kind ?? self.kind,
            mimeType: mimeType ?? self.mimeType,
            name: name ?? self.name,
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

// MARK: - FileChangeSummary
public struct FileChangeSummary: Codable {
    public var kind, movePath: String?
    public var path: String

    public init(kind: String?, movePath: String?, path: String) {
        self.kind = kind
        self.movePath = movePath
        self.path = path
    }
}

// MARK: FileChangeSummary convenience initializers and mutators

public extension FileChangeSummary {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(FileChangeSummary.self, from: data)
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
        movePath: String?? = nil,
        path: String? = nil
    ) -> FileChangeSummary {
        return FileChangeSummary(
            kind: kind ?? self.kind,
            movePath: movePath ?? self.movePath,
            path: path ?? self.path
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
    public var entries: [PlanEntry]
    public var updatedAt: Date

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
    public var content: String
    public var priority, status: String?

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
    public var activeTurnID: String?
    public var configOptions: [ConfigOption]?
    public var cwd, driver, lastError: String?
    public var providerInstanceID: String
    public var providerName: String?
    public var slashCommands: [SlashCommand]?
    public var status: String
    public var stopRequested: Bool?
    public var threadID: String
    public var tokenUsage: TokenUsage?
    public var updatedAt: Date

    public enum CodingKeys: String, CodingKey {
        case activeTurnID = "activeTurnId"
        case configOptions, cwd, driver, lastError
        case providerInstanceID = "providerInstanceId"
        case providerName, slashCommands, status, stopRequested
        case threadID = "threadId"
        case tokenUsage, updatedAt
    }

    public init(activeTurnID: String?, configOptions: [ConfigOption]?, cwd: String?, driver: String?, lastError: String?, providerInstanceID: String, providerName: String?, slashCommands: [SlashCommand]?, status: String, stopRequested: Bool?, threadID: String, tokenUsage: TokenUsage?, updatedAt: Date) {
        self.activeTurnID = activeTurnID
        self.configOptions = configOptions
        self.cwd = cwd
        self.driver = driver
        self.lastError = lastError
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
        driver: String?? = nil,
        lastError: String?? = nil,
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
            driver: driver ?? self.driver,
            lastError: lastError ?? self.lastError,
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
    public var description: String?
    public var hasInput: Bool?
    public var name: String

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
    public var cost: Double?
    public var currency: String?
    public var maxTokens: Int?
    public var usedTokens: Int

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

// MARK: - GetItemDetailInput
public struct GetItemDetailInput: Codable {
    public var itemID, threadID: String

    public enum CodingKeys: String, CodingKey {
        case itemID = "itemId"
        case threadID = "threadId"
    }

    public init(itemID: String, threadID: String) {
        self.itemID = itemID
        self.threadID = threadID
    }
}

// MARK: GetItemDetailInput convenience initializers and mutators

public extension GetItemDetailInput {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(GetItemDetailInput.self, from: data)
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
        itemID: String? = nil,
        threadID: String? = nil
    ) -> GetItemDetailInput {
        return GetItemDetailInput(
            itemID: itemID ?? self.itemID,
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

// MARK: - InstanceInfo
public struct InstanceInfo: Codable {
    public var auth: Auth
    public var capabilities: Capabilities
    public var driver: String
    public var initializedAt: Date
    public var instanceID, name: String
    public var pid: Int?
    public var startedAt: Date
    public var status: String

    public enum CodingKeys: String, CodingKey {
        case auth, capabilities, driver, initializedAt
        case instanceID = "instanceId"
        case name, pid, startedAt, status
    }

    public init(auth: Auth, capabilities: Capabilities, driver: String, initializedAt: Date, instanceID: String, name: String, pid: Int?, startedAt: Date, status: String) {
        self.auth = auth
        self.capabilities = capabilities
        self.driver = driver
        self.initializedAt = initializedAt
        self.instanceID = instanceID
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
    public var methods: [AuthMethod]?
    public var status: String?

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
    public var description: String?
    public var id: String
    public var name: String?

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
    public var auth, configOptions, loadReplay, logout: Bool?
    public var mcp: MCPCapabilities?
    public var modelSwitch: String?
    public var promptContent: PromptContentCapabilities?
    public var resume, sessionList: Bool?

    public init(auth: Bool?, configOptions: Bool?, loadReplay: Bool?, logout: Bool?, mcp: MCPCapabilities?, modelSwitch: String?, promptContent: PromptContentCapabilities?, resume: Bool?, sessionList: Bool?) {
        self.auth = auth
        self.configOptions = configOptions
        self.loadReplay = loadReplay
        self.logout = logout
        self.mcp = mcp
        self.modelSwitch = modelSwitch
        self.promptContent = promptContent
        self.resume = resume
        self.sessionList = sessionList
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
        configOptions: Bool?? = nil,
        loadReplay: Bool?? = nil,
        logout: Bool?? = nil,
        mcp: MCPCapabilities?? = nil,
        modelSwitch: String?? = nil,
        promptContent: PromptContentCapabilities?? = nil,
        resume: Bool?? = nil,
        sessionList: Bool?? = nil
    ) -> Capabilities {
        return Capabilities(
            auth: auth ?? self.auth,
            configOptions: configOptions ?? self.configOptions,
            loadReplay: loadReplay ?? self.loadReplay,
            logout: logout ?? self.logout,
            mcp: mcp ?? self.mcp,
            modelSwitch: modelSwitch ?? self.modelSwitch,
            promptContent: promptContent ?? self.promptContent,
            resume: resume ?? self.resume,
            sessionList: sessionList ?? self.sessionList
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
    public var http, sse: Bool?

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
    public var audio, embeddedContext, image: Bool?

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
    public var attachments: [Attachment]?
    public var createdAt: Date
    public var id, role, text: String
    public var turnID: String?
    public var updatedAt: Date

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
    public var instanceID, methodID: String

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
    public var instanceID: String
    public var session: SessionSummary

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
    public var cwd: String?
    public var sessionID: String
    public var title, updatedAt: String?

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
    public var imported: Bool
    public var threadID: String

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
    public var instanceID: String

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
    public var cwd: String?
    public var instanceID: String

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

// MARK: - ProviderOptionsGetParams
public struct ProviderOptionsGetParams: Codable {
    public var cwd, providerInstanceID: String

    public enum CodingKeys: String, CodingKey {
        case cwd
        case providerInstanceID = "providerInstanceId"
    }

    public init(cwd: String, providerInstanceID: String) {
        self.cwd = cwd
        self.providerInstanceID = providerInstanceID
    }
}

// MARK: ProviderOptionsGetParams convenience initializers and mutators

public extension ProviderOptionsGetParams {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ProviderOptionsGetParams.self, from: data)
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
        cwd: String? = nil,
        providerInstanceID: String? = nil
    ) -> ProviderOptionsGetParams {
        return ProviderOptionsGetParams(
            cwd: cwd ?? self.cwd,
            providerInstanceID: providerInstanceID ?? self.providerInstanceID
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ProviderOptionsInvalidated
public struct ProviderOptionsInvalidated: Codable {
    public var optionsSessionID: String

    public enum CodingKeys: String, CodingKey {
        case optionsSessionID = "optionsSessionId"
    }

    public init(optionsSessionID: String) {
        self.optionsSessionID = optionsSessionID
    }
}

// MARK: ProviderOptionsInvalidated convenience initializers and mutators

public extension ProviderOptionsInvalidated {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ProviderOptionsInvalidated.self, from: data)
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
        optionsSessionID: String? = nil
    ) -> ProviderOptionsInvalidated {
        return ProviderOptionsInvalidated(
            optionsSessionID: optionsSessionID ?? self.optionsSessionID
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ProviderOptionsResult
public struct ProviderOptionsResult: Codable {
    public var configOptions: [ConfigOption]
    public var optionsSessionID: String

    public enum CodingKeys: String, CodingKey {
        case configOptions
        case optionsSessionID = "optionsSessionId"
    }

    public init(configOptions: [ConfigOption], optionsSessionID: String) {
        self.configOptions = configOptions
        self.optionsSessionID = optionsSessionID
    }
}

// MARK: ProviderOptionsResult convenience initializers and mutators

public extension ProviderOptionsResult {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ProviderOptionsResult.self, from: data)
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
        configOptions: [ConfigOption]? = nil,
        optionsSessionID: String? = nil
    ) -> ProviderOptionsResult {
        return ProviderOptionsResult(
            configOptions: configOptions ?? self.configOptions,
            optionsSessionID: optionsSessionID ?? self.optionsSessionID
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ProviderOptionsSetParams
public struct ProviderOptionsSetParams: Codable {
    public var optionID, optionsSessionID: String
    public var value: JSONAny

    public enum CodingKeys: String, CodingKey {
        case optionID = "optionId"
        case optionsSessionID = "optionsSessionId"
        case value
    }

    public init(optionID: String, optionsSessionID: String, value: JSONAny) {
        self.optionID = optionID
        self.optionsSessionID = optionsSessionID
        self.value = value
    }
}

// MARK: ProviderOptionsSetParams convenience initializers and mutators

public extension ProviderOptionsSetParams {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ProviderOptionsSetParams.self, from: data)
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
        optionID: String? = nil,
        optionsSessionID: String? = nil,
        value: JSONAny? = nil
    ) -> ProviderOptionsSetParams {
        return ProviderOptionsSetParams(
            optionID: optionID ?? self.optionID,
            optionsSessionID: optionsSessionID ?? self.optionsSessionID,
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

// MARK: - ProviderSessionParams
public struct ProviderSessionParams: Codable {
    public var instanceID, sessionID: String

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
    public var config: JSONAny?
    public var driver, instanceID, name: String?
    public var restart: Bool?

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

// MARK: - SubscribeThreadInput
public struct SubscribeThreadInput: Codable {
    public var threadID: String

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
    public var createdAt: Date
    public var cwd: String?
    public var id: String
    public var latestTurn: Turn?
    public var modelSelection: ModelSelection?
    public var plan: Plan?
    public var providerInstanceID: String?
    public var session: SessionBinding?
    public var timeline: [TimelineEntry]
    public var title: String
    public var updatedAt: Date

    public enum CodingKeys: String, CodingKey {
        case createdAt, cwd, id, latestTurn, modelSelection, plan
        case providerInstanceID = "providerInstanceId"
        case session, timeline, title, updatedAt
    }

    public init(createdAt: Date, cwd: String?, id: String, latestTurn: Turn?, modelSelection: ModelSelection?, plan: Plan?, providerInstanceID: String?, session: SessionBinding?, timeline: [TimelineEntry], title: String, updatedAt: Date) {
        self.createdAt = createdAt
        self.cwd = cwd
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
    public var completedAt: Date?
    public var error: String?
    public var interruptRequested: Bool?
    public var requestedAt: Date
    public var startedAt: Date?
    public var state: String
    public var stopReason: String?
    public var turnID: String

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
    public var approval: Approval?
    public var item: Item?
    public var kind: String
    public var message: Message?

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
    public var historyRestorePending: Bool?
    public var snapshotSequence: Int
    public var thread: Thread

    public init(historyRestorePending: Bool?, snapshotSequence: Int, thread: Thread) {
        self.historyRestorePending = historyRestorePending
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
        historyRestorePending: Bool?? = nil,
        snapshotSequence: Int? = nil,
        thread: Thread? = nil
    ) -> ThreadDetailSnapshot {
        return ThreadDetailSnapshot(
            historyRestorePending: historyRestorePending ?? self.historyRestorePending,
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
    public var createdAt: Date
    public var cwd: String?
    public var hasPendingApprovals: Bool
    public var id: String
    public var latestTurn: Turn?
    public var modelSelection: ModelSelection?
    public var providerInstanceID: String?
    public var session: SessionBinding?
    public var title: String
    public var updatedAt: Date

    public enum CodingKeys: String, CodingKey {
        case createdAt, cwd, hasPendingApprovals, id, latestTurn, modelSelection
        case providerInstanceID = "providerInstanceId"
        case session, title, updatedAt
    }

    public init(createdAt: Date, cwd: String?, hasPendingApprovals: Bool, id: String, latestTurn: Turn?, modelSelection: ModelSelection?, providerInstanceID: String?, session: SessionBinding?, title: String, updatedAt: Date) {
        self.createdAt = createdAt
        self.cwd = cwd
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
    public var snapshotSequence: Int
    public var threads: [ThreadListEntry]
    public var updatedAt: Date

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
    public var kind: String
    public var sequence: Int?
    public var snapshot: ThreadListSnapshot?
    public var thread: ThreadListEntry?

    public init(kind: String, sequence: Int?, snapshot: ThreadListSnapshot?, thread: ThreadListEntry?) {
        self.kind = kind
        self.sequence = sequence
        self.snapshot = snapshot
        self.thread = thread
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
        thread: ThreadListEntry?? = nil
    ) -> ThreadListStreamItem {
        return ThreadListStreamItem(
            kind: kind ?? self.kind,
            sequence: sequence ?? self.sequence,
            snapshot: snapshot ?? self.snapshot,
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

// MARK: - ThreadStreamItem
public struct ThreadStreamItem: Codable {
    public var event: Event?
    public var kind: String
    public var snapshot: ThreadDetailSnapshot?

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

final class JSONCodingKey: CodingKey {
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
