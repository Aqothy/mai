// This file was generated from JSON Schema using quicktype, do not modify it directly.
// To parse the JSON, add this file to your project and do:
//
//   let maidClientAPI = try MaidClientAPI(json)

import Foundation

// MARK: - ACPCustomAgentAddParams
public struct ACPCustomAgentAddParams: Codable {
    public var args: [String]?
    public var command: String
    public var env: [String: String]?
    public var name: String

    public init(args: [String]?, command: String, env: [String: String]?, name: String) {
        self.args = args
        self.command = command
        self.env = env
        self.name = name
    }
}

// MARK: ACPCustomAgentAddParams convenience initializers and mutators

public extension ACPCustomAgentAddParams {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ACPCustomAgentAddParams.self, from: data)
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
        command: String? = nil,
        env: [String: String]?? = nil,
        name: String? = nil
    ) -> ACPCustomAgentAddParams {
        return ACPCustomAgentAddParams(
            args: args ?? self.args,
            command: command ?? self.command,
            env: env ?? self.env,
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
    public var instanceID, name, package, source: String
    public var version: String

    public enum CodingKeys: String, CodingKey {
        case args, description, icon, id, installedAt
        case instanceID = "instanceId"
        case name, package, source, version
    }

    public init(args: [String]?, description: String?, icon: String?, id: String, installedAt: Date, instanceID: String, name: String, package: String, source: String, version: String) {
        self.args = args
        self.description = description
        self.icon = icon
        self.id = id
        self.installedAt = installedAt
        self.instanceID = instanceID
        self.name = name
        self.package = package
        self.source = source
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
        source: String? = nil,
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
            source: source ?? self.source,
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
    public var answers: [String: [String]]?
    public var args: JSONAny?
    public var createdAt: Date
    public var decision, optionID: String?
    public var options: [ApprovalOption]?
    public var requestID, status: String
    public var turnID: String?
    public var updatedAt: Date
    public var userInput: UserInputRequest?

    public enum CodingKeys: String, CodingKey {
        case answers, args, createdAt, decision
        case optionID = "optionId"
        case options
        case requestID = "requestId"
        case status
        case turnID = "turnId"
        case updatedAt, userInput
    }

    public init(answers: [String: [String]]?, args: JSONAny?, createdAt: Date, decision: String?, optionID: String?, options: [ApprovalOption]?, requestID: String, status: String, turnID: String?, updatedAt: Date, userInput: UserInputRequest?) {
        self.answers = answers
        self.args = args
        self.createdAt = createdAt
        self.decision = decision
        self.optionID = optionID
        self.options = options
        self.requestID = requestID
        self.status = status
        self.turnID = turnID
        self.updatedAt = updatedAt
        self.userInput = userInput
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
        answers: [String: [String]]?? = nil,
        args: JSONAny?? = nil,
        createdAt: Date? = nil,
        decision: String?? = nil,
        optionID: String?? = nil,
        options: [ApprovalOption]?? = nil,
        requestID: String? = nil,
        status: String? = nil,
        turnID: String?? = nil,
        updatedAt: Date? = nil,
        userInput: UserInputRequest?? = nil
    ) -> Approval {
        return Approval(
            answers: answers ?? self.answers,
            args: args ?? self.args,
            createdAt: createdAt ?? self.createdAt,
            decision: decision ?? self.decision,
            optionID: optionID ?? self.optionID,
            options: options ?? self.options,
            requestID: requestID ?? self.requestID,
            status: status ?? self.status,
            turnID: turnID ?? self.turnID,
            updatedAt: updatedAt ?? self.updatedAt,
            userInput: userInput ?? self.userInput
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

// MARK: - UserInputRequest
public struct UserInputRequest: Codable {
    public var message: String
    public var questions: [Question]?
    public var url: String?

    public init(message: String, questions: [Question]?, url: String?) {
        self.message = message
        self.questions = questions
        self.url = url
    }
}

// MARK: UserInputRequest convenience initializers and mutators

public extension UserInputRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(UserInputRequest.self, from: data)
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
        message: String? = nil,
        questions: [Question]?? = nil,
        url: String?? = nil
    ) -> UserInputRequest {
        return UserInputRequest(
            message: message ?? self.message,
            questions: questions ?? self.questions,
            url: url ?? self.url
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - Question
public struct Question: Codable {
    public var allowsFreeText: Bool?
    public var questionDefault: [String]?
    public var description: String?
    public var id, kind: String
    public var multiSelect: Bool?
    public var options: [QuestionOption]?
    public var questionRequired: Bool?
    public var title: String?

    public enum CodingKeys: String, CodingKey {
        case allowsFreeText
        case questionDefault = "default"
        case description, id, kind, multiSelect, options
        case questionRequired = "required"
        case title
    }

    public init(allowsFreeText: Bool?, questionDefault: [String]?, description: String?, id: String, kind: String, multiSelect: Bool?, options: [QuestionOption]?, questionRequired: Bool?, title: String?) {
        self.allowsFreeText = allowsFreeText
        self.questionDefault = questionDefault
        self.description = description
        self.id = id
        self.kind = kind
        self.multiSelect = multiSelect
        self.options = options
        self.questionRequired = questionRequired
        self.title = title
    }
}

// MARK: Question convenience initializers and mutators

public extension Question {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Question.self, from: data)
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
        allowsFreeText: Bool?? = nil,
        questionDefault: [String]?? = nil,
        description: String?? = nil,
        id: String? = nil,
        kind: String? = nil,
        multiSelect: Bool?? = nil,
        options: [QuestionOption]?? = nil,
        questionRequired: Bool?? = nil,
        title: String?? = nil
    ) -> Question {
        return Question(
            allowsFreeText: allowsFreeText ?? self.allowsFreeText,
            questionDefault: questionDefault ?? self.questionDefault,
            description: description ?? self.description,
            id: id ?? self.id,
            kind: kind ?? self.kind,
            multiSelect: multiSelect ?? self.multiSelect,
            options: options ?? self.options,
            questionRequired: questionRequired ?? self.questionRequired,
            title: title ?? self.title
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - QuestionOption
public struct QuestionOption: Codable {
    public var description: String?
    public var label, value: String

    public init(description: String?, label: String, value: String) {
        self.description = description
        self.label = label
        self.value = value
    }
}

// MARK: QuestionOption convenience initializers and mutators

public extension QuestionOption {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(QuestionOption.self, from: data)
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
        label: String? = nil,
        value: String? = nil
    ) -> QuestionOption {
        return QuestionOption(
            description: description ?? self.description,
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

// MARK: - ApprovalEvent
public struct ApprovalEvent: Codable {
    public var answers: [String: [String]]?
    public var args: JSONAny?
    public var cancelled: Bool?
    public var decision, detail, optionID: String?
    public var options: [ApprovalOption]?
    public var requestID: String
    public var requestType, turnID: String?
    public var userInput: UserInputRequest?

    public enum CodingKeys: String, CodingKey {
        case answers, args, cancelled, decision, detail
        case optionID = "optionId"
        case options
        case requestID = "requestId"
        case requestType
        case turnID = "turnId"
        case userInput
    }

    public init(answers: [String: [String]]?, args: JSONAny?, cancelled: Bool?, decision: String?, detail: String?, optionID: String?, options: [ApprovalOption]?, requestID: String, requestType: String?, turnID: String?, userInput: UserInputRequest?) {
        self.answers = answers
        self.args = args
        self.cancelled = cancelled
        self.decision = decision
        self.detail = detail
        self.optionID = optionID
        self.options = options
        self.requestID = requestID
        self.requestType = requestType
        self.turnID = turnID
        self.userInput = userInput
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
        answers: [String: [String]]?? = nil,
        args: JSONAny?? = nil,
        cancelled: Bool?? = nil,
        decision: String?? = nil,
        detail: String?? = nil,
        optionID: String?? = nil,
        options: [ApprovalOption]?? = nil,
        requestID: String? = nil,
        requestType: String?? = nil,
        turnID: String?? = nil,
        userInput: UserInputRequest?? = nil
    ) -> ApprovalEvent {
        return ApprovalEvent(
            answers: answers ?? self.answers,
            args: args ?? self.args,
            cancelled: cancelled ?? self.cancelled,
            decision: decision ?? self.decision,
            detail: detail ?? self.detail,
            optionID: optionID ?? self.optionID,
            options: options ?? self.options,
            requestID: requestID ?? self.requestID,
            requestType: requestType ?? self.requestType,
            turnID: turnID ?? self.turnID,
            userInput: userInput ?? self.userInput
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
    public var meta: [String: JSONAny]?
    public var annotations: ContentAnnotations?
    public var data, description, id: String?
    public var kind: String
    public var mimeType, name: String?
    public var resourceMeta: [String: JSONAny]?
    public var size: Int?
    public var title, uri: String?

    public enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case annotations, data, description, id, kind, mimeType, name, resourceMeta, size, title, uri
    }

    public init(meta: [String: JSONAny]?, annotations: ContentAnnotations?, data: String?, description: String?, id: String?, kind: String, mimeType: String?, name: String?, resourceMeta: [String: JSONAny]?, size: Int?, title: String?, uri: String?) {
        self.meta = meta
        self.annotations = annotations
        self.data = data
        self.description = description
        self.id = id
        self.kind = kind
        self.mimeType = mimeType
        self.name = name
        self.resourceMeta = resourceMeta
        self.size = size
        self.title = title
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
        meta: [String: JSONAny]?? = nil,
        annotations: ContentAnnotations?? = nil,
        data: String?? = nil,
        description: String?? = nil,
        id: String?? = nil,
        kind: String? = nil,
        mimeType: String?? = nil,
        name: String?? = nil,
        resourceMeta: [String: JSONAny]?? = nil,
        size: Int?? = nil,
        title: String?? = nil,
        uri: String?? = nil
    ) -> Attachment {
        return Attachment(
            meta: meta ?? self.meta,
            annotations: annotations ?? self.annotations,
            data: data ?? self.data,
            description: description ?? self.description,
            id: id ?? self.id,
            kind: kind ?? self.kind,
            mimeType: mimeType ?? self.mimeType,
            name: name ?? self.name,
            resourceMeta: resourceMeta ?? self.resourceMeta,
            size: size ?? self.size,
            title: title ?? self.title,
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

// MARK: - ContentAnnotations
public struct ContentAnnotations: Codable {
    public var meta: [String: JSONAny]?
    public var audience: [String]?
    public var lastModified: String?
    public var priority: Double?

    public enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case audience, lastModified, priority
    }

    public init(meta: [String: JSONAny]?, audience: [String]?, lastModified: String?, priority: Double?) {
        self.meta = meta
        self.audience = audience
        self.lastModified = lastModified
        self.priority = priority
    }
}

// MARK: ContentAnnotations convenience initializers and mutators

public extension ContentAnnotations {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ContentAnnotations.self, from: data)
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
        meta: [String: JSONAny]?? = nil,
        audience: [String]?? = nil,
        lastModified: String?? = nil,
        priority: Double?? = nil
    ) -> ContentAnnotations {
        return ContentAnnotations(
            meta: meta ?? self.meta,
            audience: audience ?? self.audience,
            lastModified: lastModified ?? self.lastModified,
            priority: priority ?? self.priority
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - AttachmentUploadParams
public struct AttachmentUploadParams: Codable {
    public var data, id: String

    public init(data: String, id: String) {
        self.data = data
        self.id = id
    }
}

// MARK: AttachmentUploadParams convenience initializers and mutators

public extension AttachmentUploadParams {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(AttachmentUploadParams.self, from: data)
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
        data: String? = nil,
        id: String? = nil
    ) -> AttachmentUploadParams {
        return AttachmentUploadParams(
            data: data ?? self.data,
            id: id ?? self.id
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - AuthenticationResult
public struct AuthenticationResult: Codable {
    public var challenge: AuthChallenge?
    public var instance: InstanceInfo

    public init(challenge: AuthChallenge?, instance: InstanceInfo) {
        self.challenge = challenge
        self.instance = instance
    }
}

// MARK: AuthenticationResult convenience initializers and mutators

public extension AuthenticationResult {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(AuthenticationResult.self, from: data)
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
        challenge: AuthChallenge?? = nil,
        instance: InstanceInfo? = nil
    ) -> AuthenticationResult {
        return AuthenticationResult(
            challenge: challenge ?? self.challenge,
            instance: instance ?? self.instance
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - AuthChallenge
public struct AuthChallenge: Codable {
    public var kind, loginID, terminalID, url: String?
    public var userCode, verificationURL: String?

    public enum CodingKeys: String, CodingKey {
        case kind
        case loginID = "loginId"
        case terminalID = "terminalId"
        case url, userCode
        case verificationURL = "verificationUrl"
    }

    public init(kind: String?, loginID: String?, terminalID: String?, url: String?, userCode: String?, verificationURL: String?) {
        self.kind = kind
        self.loginID = loginID
        self.terminalID = terminalID
        self.url = url
        self.userCode = userCode
        self.verificationURL = verificationURL
    }
}

// MARK: AuthChallenge convenience initializers and mutators

public extension AuthChallenge {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(AuthChallenge.self, from: data)
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
        loginID: String?? = nil,
        terminalID: String?? = nil,
        url: String?? = nil,
        userCode: String?? = nil,
        verificationURL: String?? = nil
    ) -> AuthChallenge {
        return AuthChallenge(
            kind: kind ?? self.kind,
            loginID: loginID ?? self.loginID,
            terminalID: terminalID ?? self.terminalID,
            url: url ?? self.url,
            userCode: userCode ?? self.userCode,
            verificationURL: verificationURL ?? self.verificationURL
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
    public var kind, name: String?
    public var requiresSecret: Bool?

    public init(description: String?, id: String, kind: String?, name: String?, requiresSecret: Bool?) {
        self.description = description
        self.id = id
        self.kind = kind
        self.name = name
        self.requiresSecret = requiresSecret
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
        kind: String?? = nil,
        name: String?? = nil,
        requiresSecret: Bool?? = nil
    ) -> AuthMethod {
        return AuthMethod(
            description: description ?? self.description,
            id: id ?? self.id,
            kind: kind ?? self.kind,
            name: name ?? self.name,
            requiresSecret: requiresSecret ?? self.requiresSecret
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
    public var additionalDirectories, auth, configOptions, fork: Bool?
    public var loadReplay, logout: Bool?
    public var mcp: MCPCapabilities?
    public var modelSwitch: String?
    public var promptContent: PromptContentCapabilities?
    public var resume, sessionClose, sessionDelete, sessionList: Bool?
    public var skills: Bool?

    public init(additionalDirectories: Bool?, auth: Bool?, configOptions: Bool?, fork: Bool?, loadReplay: Bool?, logout: Bool?, mcp: MCPCapabilities?, modelSwitch: String?, promptContent: PromptContentCapabilities?, resume: Bool?, sessionClose: Bool?, sessionDelete: Bool?, sessionList: Bool?, skills: Bool?) {
        self.additionalDirectories = additionalDirectories
        self.auth = auth
        self.configOptions = configOptions
        self.fork = fork
        self.loadReplay = loadReplay
        self.logout = logout
        self.mcp = mcp
        self.modelSwitch = modelSwitch
        self.promptContent = promptContent
        self.resume = resume
        self.sessionClose = sessionClose
        self.sessionDelete = sessionDelete
        self.sessionList = sessionList
        self.skills = skills
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
        additionalDirectories: Bool?? = nil,
        auth: Bool?? = nil,
        configOptions: Bool?? = nil,
        fork: Bool?? = nil,
        loadReplay: Bool?? = nil,
        logout: Bool?? = nil,
        mcp: MCPCapabilities?? = nil,
        modelSwitch: String?? = nil,
        promptContent: PromptContentCapabilities?? = nil,
        resume: Bool?? = nil,
        sessionClose: Bool?? = nil,
        sessionDelete: Bool?? = nil,
        sessionList: Bool?? = nil,
        skills: Bool?? = nil
    ) -> Capabilities {
        return Capabilities(
            additionalDirectories: additionalDirectories ?? self.additionalDirectories,
            auth: auth ?? self.auth,
            configOptions: configOptions ?? self.configOptions,
            fork: fork ?? self.fork,
            loadReplay: loadReplay ?? self.loadReplay,
            logout: logout ?? self.logout,
            mcp: mcp ?? self.mcp,
            modelSwitch: modelSwitch ?? self.modelSwitch,
            promptContent: promptContent ?? self.promptContent,
            resume: resume ?? self.resume,
            sessionClose: sessionClose ?? self.sessionClose,
            sessionDelete: sessionDelete ?? self.sessionDelete,
            sessionList: sessionList ?? self.sessionList,
            skills: skills ?? self.skills
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

// MARK: - Command
public struct Command: Codable {
    public var additionalDirectories: [String]?
    public var answers: [String: [String]]?
    public var commandID: String?
    public var configSelections: [ConfigOptionSelection]?
    public var createdAt: Date?
    public var cwd, decision, itemID: String?
    public var message: CommandMessage?
    public var messageID: String?
    public var modelSelection: ModelSelection?
    public var optionID, providerInstanceID, requestID, threadID: String?
    public var title, turnID: String?
    public var type: String
    public var value: JSONAny?

    public enum CodingKeys: String, CodingKey {
        case additionalDirectories, answers
        case commandID = "commandId"
        case configSelections, createdAt, cwd, decision
        case itemID = "itemId"
        case message
        case messageID = "messageId"
        case modelSelection
        case optionID = "optionId"
        case providerInstanceID = "providerInstanceId"
        case requestID = "requestId"
        case threadID = "threadId"
        case title
        case turnID = "turnId"
        case type, value
    }

    public init(additionalDirectories: [String]?, answers: [String: [String]]?, commandID: String?, configSelections: [ConfigOptionSelection]?, createdAt: Date?, cwd: String?, decision: String?, itemID: String?, message: CommandMessage?, messageID: String?, modelSelection: ModelSelection?, optionID: String?, providerInstanceID: String?, requestID: String?, threadID: String?, title: String?, turnID: String?, type: String, value: JSONAny?) {
        self.additionalDirectories = additionalDirectories
        self.answers = answers
        self.commandID = commandID
        self.configSelections = configSelections
        self.createdAt = createdAt
        self.cwd = cwd
        self.decision = decision
        self.itemID = itemID
        self.message = message
        self.messageID = messageID
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
        additionalDirectories: [String]?? = nil,
        answers: [String: [String]]?? = nil,
        commandID: String?? = nil,
        configSelections: [ConfigOptionSelection]?? = nil,
        createdAt: Date?? = nil,
        cwd: String?? = nil,
        decision: String?? = nil,
        itemID: String?? = nil,
        message: CommandMessage?? = nil,
        messageID: String?? = nil,
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
            additionalDirectories: additionalDirectories ?? self.additionalDirectories,
            answers: answers ?? self.answers,
            commandID: commandID ?? self.commandID,
            configSelections: configSelections ?? self.configSelections,
            createdAt: createdAt ?? self.createdAt,
            cwd: cwd ?? self.cwd,
            decision: decision ?? self.decision,
            itemID: itemID ?? self.itemID,
            message: message ?? self.message,
            messageID: messageID ?? self.messageID,
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
    public var annotations: [PromptAnnotation]?
    public var attachments: [Attachment]?
    public var messageID: String?
    public var text: String

    public enum CodingKeys: String, CodingKey {
        case annotations, attachments
        case messageID = "messageId"
        case text
    }

    public init(annotations: [PromptAnnotation]?, attachments: [Attachment]?, messageID: String?, text: String) {
        self.annotations = annotations
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
        annotations: [PromptAnnotation]?? = nil,
        attachments: [Attachment]?? = nil,
        messageID: String?? = nil,
        text: String? = nil
    ) -> CommandMessage {
        return CommandMessage(
            annotations: annotations ?? self.annotations,
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

// MARK: - PromptAnnotation
public struct PromptAnnotation: Codable {
    public var id: String
    public var messageID, note: String?
    public var quote: String
    public var role: String?

    public enum CodingKeys: String, CodingKey {
        case id
        case messageID = "messageId"
        case note, quote, role
    }

    public init(id: String, messageID: String?, note: String?, quote: String, role: String?) {
        self.id = id
        self.messageID = messageID
        self.note = note
        self.quote = quote
        self.role = role
    }
}

// MARK: PromptAnnotation convenience initializers and mutators

public extension PromptAnnotation {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(PromptAnnotation.self, from: data)
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
        id: String? = nil,
        messageID: String?? = nil,
        note: String?? = nil,
        quote: String? = nil,
        role: String?? = nil
    ) -> PromptAnnotation {
        return PromptAnnotation(
            id: id ?? self.id,
            messageID: messageID ?? self.messageID,
            note: note ?? self.note,
            quote: quote ?? self.quote,
            role: role ?? self.role
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

// MARK: - CommandCompletion
public struct CommandCompletion: Codable {
    public var description: String?
    public var input, label: String

    public init(description: String?, input: String, label: String) {
        self.description = description
        self.input = input
        self.label = label
    }
}

// MARK: CommandCompletion convenience initializers and mutators

public extension CommandCompletion {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(CommandCompletion.self, from: data)
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
        input: String? = nil,
        label: String? = nil
    ) -> CommandCompletion {
        return CommandCompletion(
            description: description ?? self.description,
            input: input ?? self.input,
            label: label ?? self.label
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
    public var description, group, groupLabel, label: String?
    public var value: String

    public init(description: String?, group: String?, groupLabel: String?, label: String?, value: String) {
        self.description = description
        self.group = group
        self.groupLabel = groupLabel
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
        description: String?? = nil,
        group: String?? = nil,
        groupLabel: String?? = nil,
        label: String?? = nil,
        value: String? = nil
    ) -> ConfigChoice {
        return ConfigChoice(
            description: description ?? self.description,
            group: group ?? self.group,
            groupLabel: groupLabel ?? self.groupLabel,
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
    public var additionalDirectories: [String]?
    public var annotations: [PromptAnnotation]?
    public var answers: [String: [String]]?
    public var approval: ApprovalEvent?
    public var attachments: [Attachment]?
    public var configOptions: [ConfigOption]?
    public var createdAt: Date?
    public var cwd, decision, delivery, deliveryError: String?
    public var goal: Goal?
    public var item: Item?
    public var itemID, messageID: String?
    public var modelSelection: ModelSelection?
    public var optionID: String?
    public var plan: Plan?
    public var providerInstanceID, requestID, role: String?
    public var session: SessionBinding?
    public var sessionCleared: Bool?
    public var skills: [Skill]?
    public var slashCommands: [SlashCommand]?
    public var stopReason, text, threadID, title: String?
    public var tokenUsage: TokenUsage?
    public var turnID: String?
    public var updatedAt: Date?
    public var value: JSONAny?

    public enum CodingKeys: String, CodingKey {
        case additionalDirectories, annotations, answers, approval, attachments, configOptions, createdAt, cwd, decision, delivery, deliveryError, goal, item
        case itemID = "itemId"
        case messageID = "messageId"
        case modelSelection
        case optionID = "optionId"
        case plan
        case providerInstanceID = "providerInstanceId"
        case requestID = "requestId"
        case role, session, sessionCleared, skills, slashCommands, stopReason, text
        case threadID = "threadId"
        case title, tokenUsage
        case turnID = "turnId"
        case updatedAt, value
    }

    public init(additionalDirectories: [String]?, annotations: [PromptAnnotation]?, answers: [String: [String]]?, approval: ApprovalEvent?, attachments: [Attachment]?, configOptions: [ConfigOption]?, createdAt: Date?, cwd: String?, decision: String?, delivery: String?, deliveryError: String?, goal: Goal?, item: Item?, itemID: String?, messageID: String?, modelSelection: ModelSelection?, optionID: String?, plan: Plan?, providerInstanceID: String?, requestID: String?, role: String?, session: SessionBinding?, sessionCleared: Bool?, skills: [Skill]?, slashCommands: [SlashCommand]?, stopReason: String?, text: String?, threadID: String?, title: String?, tokenUsage: TokenUsage?, turnID: String?, updatedAt: Date?, value: JSONAny?) {
        self.additionalDirectories = additionalDirectories
        self.annotations = annotations
        self.answers = answers
        self.approval = approval
        self.attachments = attachments
        self.configOptions = configOptions
        self.createdAt = createdAt
        self.cwd = cwd
        self.decision = decision
        self.delivery = delivery
        self.deliveryError = deliveryError
        self.goal = goal
        self.item = item
        self.itemID = itemID
        self.messageID = messageID
        self.modelSelection = modelSelection
        self.optionID = optionID
        self.plan = plan
        self.providerInstanceID = providerInstanceID
        self.requestID = requestID
        self.role = role
        self.session = session
        self.sessionCleared = sessionCleared
        self.skills = skills
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
        additionalDirectories: [String]?? = nil,
        annotations: [PromptAnnotation]?? = nil,
        answers: [String: [String]]?? = nil,
        approval: ApprovalEvent?? = nil,
        attachments: [Attachment]?? = nil,
        configOptions: [ConfigOption]?? = nil,
        createdAt: Date?? = nil,
        cwd: String?? = nil,
        decision: String?? = nil,
        delivery: String?? = nil,
        deliveryError: String?? = nil,
        goal: Goal?? = nil,
        item: Item?? = nil,
        itemID: String?? = nil,
        messageID: String?? = nil,
        modelSelection: ModelSelection?? = nil,
        optionID: String?? = nil,
        plan: Plan?? = nil,
        providerInstanceID: String?? = nil,
        requestID: String?? = nil,
        role: String?? = nil,
        session: SessionBinding?? = nil,
        sessionCleared: Bool?? = nil,
        skills: [Skill]?? = nil,
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
            additionalDirectories: additionalDirectories ?? self.additionalDirectories,
            annotations: annotations ?? self.annotations,
            answers: answers ?? self.answers,
            approval: approval ?? self.approval,
            attachments: attachments ?? self.attachments,
            configOptions: configOptions ?? self.configOptions,
            createdAt: createdAt ?? self.createdAt,
            cwd: cwd ?? self.cwd,
            decision: decision ?? self.decision,
            delivery: delivery ?? self.delivery,
            deliveryError: deliveryError ?? self.deliveryError,
            goal: goal ?? self.goal,
            item: item ?? self.item,
            itemID: itemID ?? self.itemID,
            messageID: messageID ?? self.messageID,
            modelSelection: modelSelection ?? self.modelSelection,
            optionID: optionID ?? self.optionID,
            plan: plan ?? self.plan,
            providerInstanceID: providerInstanceID ?? self.providerInstanceID,
            requestID: requestID ?? self.requestID,
            role: role ?? self.role,
            session: session ?? self.session,
            sessionCleared: sessionCleared ?? self.sessionCleared,
            skills: skills ?? self.skills,
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

// MARK: - Goal
public struct Goal: Codable {
    public var objective, status: String
    public var timeUsedSeconds: Int
    public var tokenBudget: Int?
    public var tokensUsed: Int

    public init(objective: String, status: String, timeUsedSeconds: Int, tokenBudget: Int?, tokensUsed: Int) {
        self.objective = objective
        self.status = status
        self.timeUsedSeconds = timeUsedSeconds
        self.tokenBudget = tokenBudget
        self.tokensUsed = tokensUsed
    }
}

// MARK: Goal convenience initializers and mutators

public extension Goal {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Goal.self, from: data)
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
        objective: String? = nil,
        status: String? = nil,
        timeUsedSeconds: Int? = nil,
        tokenBudget: Int?? = nil,
        tokensUsed: Int? = nil
    ) -> Goal {
        return Goal(
            objective: objective ?? self.objective,
            status: status ?? self.status,
            timeUsedSeconds: timeUsedSeconds ?? self.timeUsedSeconds,
            tokenBudget: tokenBudget ?? self.tokenBudget,
            tokensUsed: tokensUsed ?? self.tokensUsed
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
    public var action: String?
    public var attachments: [Attachment]?
    public var background: Bool?
    public var changes: [FileChange]?
    public var command, cwd: String?
    public var durationMilliseconds: Int?
    public var error: String?
    public var exitCode: Int?
    public var locations: [ToolLocation]?
    public var name, namespace, output, outputFormat: String?
    public var providerKind, query: String?

    public init(action: String?, attachments: [Attachment]?, background: Bool?, changes: [FileChange]?, command: String?, cwd: String?, durationMilliseconds: Int?, error: String?, exitCode: Int?, locations: [ToolLocation]?, name: String?, namespace: String?, output: String?, outputFormat: String?, providerKind: String?, query: String?) {
        self.action = action
        self.attachments = attachments
        self.background = background
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
        self.outputFormat = outputFormat
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
        action: String?? = nil,
        attachments: [Attachment]?? = nil,
        background: Bool?? = nil,
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
        outputFormat: String?? = nil,
        providerKind: String?? = nil,
        query: String?? = nil
    ) -> ToolCall {
        return ToolCall(
            action: action ?? self.action,
            attachments: attachments ?? self.attachments,
            background: background ?? self.background,
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
            outputFormat: outputFormat ?? self.outputFormat,
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
    public var action: String?
    public var attachmentCount: Int?
    public var attachments: [ToolAttachmentSummary]?
    public var background: Bool?
    public var changeCount: Int?
    public var changes: [FileChangeSummary]?
    public var commandPreview, cwd: String?
    public var durationMilliseconds: Int?
    public var errorPreview: String?
    public var exitCode, locationCount: Int?
    public var locations: [ToolLocation]?
    public var name, namespace, outputFormat, outputPreview: String?
    public var providerKind, queryPreview: String?
    public var truncated: Bool?

    public init(action: String?, attachmentCount: Int?, attachments: [ToolAttachmentSummary]?, background: Bool?, changeCount: Int?, changes: [FileChangeSummary]?, commandPreview: String?, cwd: String?, durationMilliseconds: Int?, errorPreview: String?, exitCode: Int?, locationCount: Int?, locations: [ToolLocation]?, name: String?, namespace: String?, outputFormat: String?, outputPreview: String?, providerKind: String?, queryPreview: String?, truncated: Bool?) {
        self.action = action
        self.attachmentCount = attachmentCount
        self.attachments = attachments
        self.background = background
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
        self.outputFormat = outputFormat
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
        action: String?? = nil,
        attachmentCount: Int?? = nil,
        attachments: [ToolAttachmentSummary]?? = nil,
        background: Bool?? = nil,
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
        outputFormat: String?? = nil,
        outputPreview: String?? = nil,
        providerKind: String?? = nil,
        queryPreview: String?? = nil,
        truncated: Bool?? = nil
    ) -> ToolCallSummary {
        return ToolCallSummary(
            action: action ?? self.action,
            attachmentCount: attachmentCount ?? self.attachmentCount,
            attachments: attachments ?? self.attachments,
            background: background ?? self.background,
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
            outputFormat: outputFormat ?? self.outputFormat,
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
    public var additionalDirectories: [String]?
    public var configOptions: [ConfigOption]?
    public var cwd, driver: String?
    public var goal: Goal?
    public var lastError: String?
    public var providerInstanceID: String
    public var providerName: String?
    public var skills: [Skill]?
    public var slashCommands: [SlashCommand]?
    public var status: String
    public var stopRequested: Bool?
    public var threadID: String
    public var tokenUsage: TokenUsage?
    public var updatedAt: Date

    public enum CodingKeys: String, CodingKey {
        case activeTurnID = "activeTurnId"
        case additionalDirectories, configOptions, cwd, driver, goal, lastError
        case providerInstanceID = "providerInstanceId"
        case providerName, skills, slashCommands, status, stopRequested
        case threadID = "threadId"
        case tokenUsage, updatedAt
    }

    public init(activeTurnID: String?, additionalDirectories: [String]?, configOptions: [ConfigOption]?, cwd: String?, driver: String?, goal: Goal?, lastError: String?, providerInstanceID: String, providerName: String?, skills: [Skill]?, slashCommands: [SlashCommand]?, status: String, stopRequested: Bool?, threadID: String, tokenUsage: TokenUsage?, updatedAt: Date) {
        self.activeTurnID = activeTurnID
        self.additionalDirectories = additionalDirectories
        self.configOptions = configOptions
        self.cwd = cwd
        self.driver = driver
        self.goal = goal
        self.lastError = lastError
        self.providerInstanceID = providerInstanceID
        self.providerName = providerName
        self.skills = skills
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
        additionalDirectories: [String]?? = nil,
        configOptions: [ConfigOption]?? = nil,
        cwd: String?? = nil,
        driver: String?? = nil,
        goal: Goal?? = nil,
        lastError: String?? = nil,
        providerInstanceID: String? = nil,
        providerName: String?? = nil,
        skills: [Skill]?? = nil,
        slashCommands: [SlashCommand]?? = nil,
        status: String? = nil,
        stopRequested: Bool?? = nil,
        threadID: String? = nil,
        tokenUsage: TokenUsage?? = nil,
        updatedAt: Date? = nil
    ) -> SessionBinding {
        return SessionBinding(
            activeTurnID: activeTurnID ?? self.activeTurnID,
            additionalDirectories: additionalDirectories ?? self.additionalDirectories,
            configOptions: configOptions ?? self.configOptions,
            cwd: cwd ?? self.cwd,
            driver: driver ?? self.driver,
            goal: goal ?? self.goal,
            lastError: lastError ?? self.lastError,
            providerInstanceID: providerInstanceID ?? self.providerInstanceID,
            providerName: providerName ?? self.providerName,
            skills: skills ?? self.skills,
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

// MARK: - Skill
public struct Skill: Codable {
    public var description: String?
    public var enabled: Bool
    public var name: String
    public var path, scope, shortDescription: String?

    public init(description: String?, enabled: Bool, name: String, path: String?, scope: String?, shortDescription: String?) {
        self.description = description
        self.enabled = enabled
        self.name = name
        self.path = path
        self.scope = scope
        self.shortDescription = shortDescription
    }
}

// MARK: Skill convenience initializers and mutators

public extension Skill {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Skill.self, from: data)
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
        enabled: Bool? = nil,
        name: String? = nil,
        path: String?? = nil,
        scope: String?? = nil,
        shortDescription: String?? = nil
    ) -> Skill {
        return Skill(
            description: description ?? self.description,
            enabled: enabled ?? self.enabled,
            name: name ?? self.name,
            path: path ?? self.path,
            scope: scope ?? self.scope,
            shortDescription: shortDescription ?? self.shortDescription
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
    public var completes: Bool?
    public var description: String?
    public var hasInput: Bool?
    public var inputHint: String?
    public var name: String

    public init(completes: Bool?, description: String?, hasInput: Bool?, inputHint: String?, name: String) {
        self.completes = completes
        self.description = description
        self.hasInput = hasInput
        self.inputHint = inputHint
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
        completes: Bool?? = nil,
        description: String?? = nil,
        hasInput: Bool?? = nil,
        inputHint: String?? = nil,
        name: String? = nil
    ) -> SlashCommand {
        return SlashCommand(
            completes: completes ?? self.completes,
            description: description ?? self.description,
            hasInput: hasInput ?? self.hasInput,
            inputHint: inputHint ?? self.inputHint,
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

// MARK: - GetAttachmentInput
public struct GetAttachmentInput: Codable {
    public var attachmentID, threadID: String

    public enum CodingKeys: String, CodingKey {
        case attachmentID = "attachmentId"
        case threadID = "threadId"
    }

    public init(attachmentID: String, threadID: String) {
        self.attachmentID = attachmentID
        self.threadID = threadID
    }
}

// MARK: GetAttachmentInput convenience initializers and mutators

public extension GetAttachmentInput {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(GetAttachmentInput.self, from: data)
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
        attachmentID: String? = nil,
        threadID: String? = nil
    ) -> GetAttachmentInput {
        return GetAttachmentInput(
            attachmentID: attachmentID ?? self.attachmentID,
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

// MARK: - Message
public struct Message: Codable {
    public var annotations: [PromptAnnotation]?
    public var attachments: [Attachment]?
    public var createdAt: Date
    public var delivery, deliveryError: String?
    public var id, role, text: String
    public var turnID: String?
    public var updatedAt: Date

    public enum CodingKeys: String, CodingKey {
        case annotations, attachments, createdAt, delivery, deliveryError, id, role, text
        case turnID = "turnId"
        case updatedAt
    }

    public init(annotations: [PromptAnnotation]?, attachments: [Attachment]?, createdAt: Date, delivery: String?, deliveryError: String?, id: String, role: String, text: String, turnID: String?, updatedAt: Date) {
        self.annotations = annotations
        self.attachments = attachments
        self.createdAt = createdAt
        self.delivery = delivery
        self.deliveryError = deliveryError
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
        annotations: [PromptAnnotation]?? = nil,
        attachments: [Attachment]?? = nil,
        createdAt: Date? = nil,
        delivery: String?? = nil,
        deliveryError: String?? = nil,
        id: String? = nil,
        role: String? = nil,
        text: String? = nil,
        turnID: String?? = nil,
        updatedAt: Date? = nil
    ) -> Message {
        return Message(
            annotations: annotations ?? self.annotations,
            attachments: attachments ?? self.attachments,
            createdAt: createdAt ?? self.createdAt,
            delivery: delivery ?? self.delivery,
            deliveryError: deliveryError ?? self.deliveryError,
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
    public var secret: String?

    public enum CodingKeys: String, CodingKey {
        case instanceID = "instanceId"
        case methodID = "methodId"
        case secret
    }

    public init(instanceID: String, methodID: String, secret: String?) {
        self.instanceID = instanceID
        self.methodID = methodID
        self.secret = secret
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
        methodID: String? = nil,
        secret: String?? = nil
    ) -> ProviderAuthenticateParams {
        return ProviderAuthenticateParams(
            instanceID: instanceID ?? self.instanceID,
            methodID: methodID ?? self.methodID,
            secret: secret ?? self.secret
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - CompleteCommandInput
public struct CompleteCommandInput: Codable {
    public var command, input, threadID: String

    public enum CodingKeys: String, CodingKey {
        case command, input
        case threadID = "threadId"
    }

    public init(command: String, input: String, threadID: String) {
        self.command = command
        self.input = input
        self.threadID = threadID
    }
}

// MARK: CompleteCommandInput convenience initializers and mutators

public extension CompleteCommandInput {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(CompleteCommandInput.self, from: data)
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
        command: String? = nil,
        input: String? = nil,
        threadID: String? = nil
    ) -> CompleteCommandInput {
        return CompleteCommandInput(
            command: command ?? self.command,
            input: input ?? self.input,
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

// MARK: - ProviderForkThreadParams
public struct ProviderForkThreadParams: Codable {
    public var sourceThreadID: String

    public enum CodingKeys: String, CodingKey {
        case sourceThreadID = "sourceThreadId"
    }

    public init(sourceThreadID: String) {
        self.sourceThreadID = sourceThreadID
    }
}

// MARK: ProviderForkThreadParams convenience initializers and mutators

public extension ProviderForkThreadParams {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ProviderForkThreadParams.self, from: data)
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
        sourceThreadID: String? = nil
    ) -> ProviderForkThreadParams {
        return ProviderForkThreadParams(
            sourceThreadID: sourceThreadID ?? self.sourceThreadID
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
    public var additionalDirectories: [String]?
    public var cwd: String?
    public var sessionID: String
    public var title, updatedAt: String?

    public enum CodingKeys: String, CodingKey {
        case additionalDirectories, cwd
        case sessionID = "sessionId"
        case title, updatedAt
    }

    public init(additionalDirectories: [String]?, cwd: String?, sessionID: String, title: String?, updatedAt: String?) {
        self.additionalDirectories = additionalDirectories
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
        additionalDirectories: [String]?? = nil,
        cwd: String?? = nil,
        sessionID: String? = nil,
        title: String?? = nil,
        updatedAt: String?? = nil
    ) -> SessionSummary {
        return SessionSummary(
            additionalDirectories: additionalDirectories ?? self.additionalDirectories,
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
    public var skills: [Skill]?

    public enum CodingKeys: String, CodingKey {
        case configOptions
        case optionsSessionID = "optionsSessionId"
        case skills
    }

    public init(configOptions: [ConfigOption], optionsSessionID: String, skills: [Skill]?) {
        self.configOptions = configOptions
        self.optionsSessionID = optionsSessionID
        self.skills = skills
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
        optionsSessionID: String? = nil,
        skills: [Skill]?? = nil
    ) -> ProviderOptionsResult {
        return ProviderOptionsResult(
            configOptions: configOptions ?? self.configOptions,
            optionsSessionID: optionsSessionID ?? self.optionsSessionID,
            skills: skills ?? self.skills
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

// MARK: - ProviderQuestion
public struct ProviderQuestion: Codable {
    public var instanceID: String
    public var request: UserInputRequest
    public var requestID: String

    public enum CodingKeys: String, CodingKey {
        case instanceID = "instanceId"
        case request
        case requestID = "requestId"
    }

    public init(instanceID: String, request: UserInputRequest, requestID: String) {
        self.instanceID = instanceID
        self.request = request
        self.requestID = requestID
    }
}

// MARK: ProviderQuestion convenience initializers and mutators

public extension ProviderQuestion {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ProviderQuestion.self, from: data)
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
        request: UserInputRequest? = nil,
        requestID: String? = nil
    ) -> ProviderQuestion {
        return ProviderQuestion(
            instanceID: instanceID ?? self.instanceID,
            request: request ?? self.request,
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

// MARK: - ProviderQuestionAnswerParams
public struct ProviderQuestionAnswerParams: Codable {
    public var answers: [String: [String]]?
    public var decision, requestID: String

    public enum CodingKeys: String, CodingKey {
        case answers, decision
        case requestID = "requestId"
    }

    public init(answers: [String: [String]]?, decision: String, requestID: String) {
        self.answers = answers
        self.decision = decision
        self.requestID = requestID
    }
}

// MARK: ProviderQuestionAnswerParams convenience initializers and mutators

public extension ProviderQuestionAnswerParams {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ProviderQuestionAnswerParams.self, from: data)
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
        answers: [String: [String]]?? = nil,
        decision: String? = nil,
        requestID: String? = nil
    ) -> ProviderQuestionAnswerParams {
        return ProviderQuestionAnswerParams(
            answers: answers ?? self.answers,
            decision: decision ?? self.decision,
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

// MARK: - TerminalAttachParams
public struct TerminalAttachParams: Codable {
    public var attachmentID: String
    public var columns, rows: Int
    public var terminalID: String

    public enum CodingKeys: String, CodingKey {
        case attachmentID = "attachmentId"
        case columns, rows
        case terminalID = "terminalId"
    }

    public init(attachmentID: String, columns: Int, rows: Int, terminalID: String) {
        self.attachmentID = attachmentID
        self.columns = columns
        self.rows = rows
        self.terminalID = terminalID
    }
}

// MARK: TerminalAttachParams convenience initializers and mutators

public extension TerminalAttachParams {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(TerminalAttachParams.self, from: data)
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
        attachmentID: String? = nil,
        columns: Int? = nil,
        rows: Int? = nil,
        terminalID: String? = nil
    ) -> TerminalAttachParams {
        return TerminalAttachParams(
            attachmentID: attachmentID ?? self.attachmentID,
            columns: columns ?? self.columns,
            rows: rows ?? self.rows,
            terminalID: terminalID ?? self.terminalID
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - TerminalAttachSnapshot
public struct TerminalAttachSnapshot: Codable {
    public var columns, rows: Int
    public var runID: String
    public var sequence: Int
    public var snapshot, snapshotFormat: String
    public var terminal: TerminalSummary

    public enum CodingKeys: String, CodingKey {
        case columns, rows
        case runID = "runId"
        case sequence, snapshot, snapshotFormat, terminal
    }

    public init(columns: Int, rows: Int, runID: String, sequence: Int, snapshot: String, snapshotFormat: String, terminal: TerminalSummary) {
        self.columns = columns
        self.rows = rows
        self.runID = runID
        self.sequence = sequence
        self.snapshot = snapshot
        self.snapshotFormat = snapshotFormat
        self.terminal = terminal
    }
}

// MARK: TerminalAttachSnapshot convenience initializers and mutators

public extension TerminalAttachSnapshot {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(TerminalAttachSnapshot.self, from: data)
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
        columns: Int? = nil,
        rows: Int? = nil,
        runID: String? = nil,
        sequence: Int? = nil,
        snapshot: String? = nil,
        snapshotFormat: String? = nil,
        terminal: TerminalSummary? = nil
    ) -> TerminalAttachSnapshot {
        return TerminalAttachSnapshot(
            columns: columns ?? self.columns,
            rows: rows ?? self.rows,
            runID: runID ?? self.runID,
            sequence: sequence ?? self.sequence,
            snapshot: snapshot ?? self.snapshot,
            snapshotFormat: snapshotFormat ?? self.snapshotFormat,
            terminal: terminal ?? self.terminal
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - TerminalSummary
public struct TerminalSummary: Codable {
    public var agentActivity: String?
    public var agentActivityUpdatedAt: Date?
    public var agentKind: String?
    public var createdAt: Date
    public var cwd: String
    public var exitCode: Int?
    public var observedTitle: String?
    public var status, terminalID, title: String
    public var updatedAt: Date

    public enum CodingKeys: String, CodingKey {
        case agentActivity, agentActivityUpdatedAt, agentKind, createdAt, cwd, exitCode, observedTitle, status
        case terminalID = "terminalId"
        case title, updatedAt
    }

    public init(agentActivity: String?, agentActivityUpdatedAt: Date?, agentKind: String?, createdAt: Date, cwd: String, exitCode: Int?, observedTitle: String?, status: String, terminalID: String, title: String, updatedAt: Date) {
        self.agentActivity = agentActivity
        self.agentActivityUpdatedAt = agentActivityUpdatedAt
        self.agentKind = agentKind
        self.createdAt = createdAt
        self.cwd = cwd
        self.exitCode = exitCode
        self.observedTitle = observedTitle
        self.status = status
        self.terminalID = terminalID
        self.title = title
        self.updatedAt = updatedAt
    }
}

// MARK: TerminalSummary convenience initializers and mutators

public extension TerminalSummary {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(TerminalSummary.self, from: data)
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
        agentActivity: String?? = nil,
        agentActivityUpdatedAt: Date?? = nil,
        agentKind: String?? = nil,
        createdAt: Date? = nil,
        cwd: String? = nil,
        exitCode: Int?? = nil,
        observedTitle: String?? = nil,
        status: String? = nil,
        terminalID: String? = nil,
        title: String? = nil,
        updatedAt: Date? = nil
    ) -> TerminalSummary {
        return TerminalSummary(
            agentActivity: agentActivity ?? self.agentActivity,
            agentActivityUpdatedAt: agentActivityUpdatedAt ?? self.agentActivityUpdatedAt,
            agentKind: agentKind ?? self.agentKind,
            createdAt: createdAt ?? self.createdAt,
            cwd: cwd ?? self.cwd,
            exitCode: exitCode ?? self.exitCode,
            observedTitle: observedTitle ?? self.observedTitle,
            status: status ?? self.status,
            terminalID: terminalID ?? self.terminalID,
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

// MARK: - TerminalCreateParams
public struct TerminalCreateParams: Codable {
    public var attachmentID: String
    public var columns: Int
    public var cwd: String
    public var rows: Int
    public var title: String?

    public enum CodingKeys: String, CodingKey {
        case attachmentID = "attachmentId"
        case columns, cwd, rows, title
    }

    public init(attachmentID: String, columns: Int, cwd: String, rows: Int, title: String?) {
        self.attachmentID = attachmentID
        self.columns = columns
        self.cwd = cwd
        self.rows = rows
        self.title = title
    }
}

// MARK: TerminalCreateParams convenience initializers and mutators

public extension TerminalCreateParams {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(TerminalCreateParams.self, from: data)
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
        attachmentID: String? = nil,
        columns: Int? = nil,
        cwd: String? = nil,
        rows: Int? = nil,
        title: String?? = nil
    ) -> TerminalCreateParams {
        return TerminalCreateParams(
            attachmentID: attachmentID ?? self.attachmentID,
            columns: columns ?? self.columns,
            cwd: cwd ?? self.cwd,
            rows: rows ?? self.rows,
            title: title ?? self.title
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - TerminalDetachParams
public struct TerminalDetachParams: Codable {
    public var attachmentID, terminalID: String

    public enum CodingKeys: String, CodingKey {
        case attachmentID = "attachmentId"
        case terminalID = "terminalId"
    }

    public init(attachmentID: String, terminalID: String) {
        self.attachmentID = attachmentID
        self.terminalID = terminalID
    }
}

// MARK: TerminalDetachParams convenience initializers and mutators

public extension TerminalDetachParams {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(TerminalDetachParams.self, from: data)
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
        attachmentID: String? = nil,
        terminalID: String? = nil
    ) -> TerminalDetachParams {
        return TerminalDetachParams(
            attachmentID: attachmentID ?? self.attachmentID,
            terminalID: terminalID ?? self.terminalID
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - TerminalIDParams
public struct TerminalIDParams: Codable {
    public var terminalID: String

    public enum CodingKeys: String, CodingKey {
        case terminalID = "terminalId"
    }

    public init(terminalID: String) {
        self.terminalID = terminalID
    }
}

// MARK: TerminalIDParams convenience initializers and mutators

public extension TerminalIDParams {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(TerminalIDParams.self, from: data)
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
        terminalID: String? = nil
    ) -> TerminalIDParams {
        return TerminalIDParams(
            terminalID: terminalID ?? self.terminalID
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - TerminalListStreamItem
public struct TerminalListStreamItem: Codable {
    public var kind: String
    public var terminal: TerminalSummary?
    public var terminalID: String?
    public var terminals: [TerminalSummary]?

    public enum CodingKeys: String, CodingKey {
        case kind, terminal
        case terminalID = "terminalId"
        case terminals
    }

    public init(kind: String, terminal: TerminalSummary?, terminalID: String?, terminals: [TerminalSummary]?) {
        self.kind = kind
        self.terminal = terminal
        self.terminalID = terminalID
        self.terminals = terminals
    }
}

// MARK: TerminalListStreamItem convenience initializers and mutators

public extension TerminalListStreamItem {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(TerminalListStreamItem.self, from: data)
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
        terminal: TerminalSummary?? = nil,
        terminalID: String?? = nil,
        terminals: [TerminalSummary]?? = nil
    ) -> TerminalListStreamItem {
        return TerminalListStreamItem(
            kind: kind ?? self.kind,
            terminal: terminal ?? self.terminal,
            terminalID: terminalID ?? self.terminalID,
            terminals: terminals ?? self.terminals
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - TerminalRenameParams
public struct TerminalRenameParams: Codable {
    public var terminalID, title: String

    public enum CodingKeys: String, CodingKey {
        case terminalID = "terminalId"
        case title
    }

    public init(terminalID: String, title: String) {
        self.terminalID = terminalID
        self.title = title
    }
}

// MARK: TerminalRenameParams convenience initializers and mutators

public extension TerminalRenameParams {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(TerminalRenameParams.self, from: data)
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
        terminalID: String? = nil,
        title: String? = nil
    ) -> TerminalRenameParams {
        return TerminalRenameParams(
            terminalID: terminalID ?? self.terminalID,
            title: title ?? self.title
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - TerminalResizeParams
public struct TerminalResizeParams: Codable {
    public var columns, rows: Int
    public var runID, terminalID: String

    public enum CodingKeys: String, CodingKey {
        case columns, rows
        case runID = "runId"
        case terminalID = "terminalId"
    }

    public init(columns: Int, rows: Int, runID: String, terminalID: String) {
        self.columns = columns
        self.rows = rows
        self.runID = runID
        self.terminalID = terminalID
    }
}

// MARK: TerminalResizeParams convenience initializers and mutators

public extension TerminalResizeParams {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(TerminalResizeParams.self, from: data)
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
        columns: Int? = nil,
        rows: Int? = nil,
        runID: String? = nil,
        terminalID: String? = nil
    ) -> TerminalResizeParams {
        return TerminalResizeParams(
            columns: columns ?? self.columns,
            rows: rows ?? self.rows,
            runID: runID ?? self.runID,
            terminalID: terminalID ?? self.terminalID
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - TerminalStreamItem
public struct TerminalStreamItem: Codable {
    public var data: String?
    public var exitCode: Int?
    public var kind: String
    public var message, runID: String?
    public var sequence: Int?
    public var status: String?
    public var terminalID: String

    public enum CodingKeys: String, CodingKey {
        case data, exitCode, kind, message
        case runID = "runId"
        case sequence, status
        case terminalID = "terminalId"
    }

    public init(data: String?, exitCode: Int?, kind: String, message: String?, runID: String?, sequence: Int?, status: String?, terminalID: String) {
        self.data = data
        self.exitCode = exitCode
        self.kind = kind
        self.message = message
        self.runID = runID
        self.sequence = sequence
        self.status = status
        self.terminalID = terminalID
    }
}

// MARK: TerminalStreamItem convenience initializers and mutators

public extension TerminalStreamItem {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(TerminalStreamItem.self, from: data)
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
        exitCode: Int?? = nil,
        kind: String? = nil,
        message: String?? = nil,
        runID: String?? = nil,
        sequence: Int?? = nil,
        status: String?? = nil,
        terminalID: String? = nil
    ) -> TerminalStreamItem {
        return TerminalStreamItem(
            data: data ?? self.data,
            exitCode: exitCode ?? self.exitCode,
            kind: kind ?? self.kind,
            message: message ?? self.message,
            runID: runID ?? self.runID,
            sequence: sequence ?? self.sequence,
            status: status ?? self.status,
            terminalID: terminalID ?? self.terminalID
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - TerminalWriteParams
public struct TerminalWriteParams: Codable {
    public var data, runID, terminalID: String

    public enum CodingKeys: String, CodingKey {
        case data
        case runID = "runId"
        case terminalID = "terminalId"
    }

    public init(data: String, runID: String, terminalID: String) {
        self.data = data
        self.runID = runID
        self.terminalID = terminalID
    }
}

// MARK: TerminalWriteParams convenience initializers and mutators

public extension TerminalWriteParams {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(TerminalWriteParams.self, from: data)
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
        data: String? = nil,
        runID: String? = nil,
        terminalID: String? = nil
    ) -> TerminalWriteParams {
        return TerminalWriteParams(
            data: data ?? self.data,
            runID: runID ?? self.runID,
            terminalID: terminalID ?? self.terminalID
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
    public var additionalDirectories: [String]?
    public var createdAt: Date
    public var cwd: String?
    public var id: String
    public var latestTurn: Turn?
    public var modelSelection: ModelSelection?
    public var plan: Plan?
    public var previousTurns: [Turn]?
    public var providerInstanceID: String?
    public var queuedPrompts: [QueuedPrompt]?
    public var session: SessionBinding?
    public var timeline: [TimelineEntry]
    public var title: String
    public var updatedAt: Date

    public enum CodingKeys: String, CodingKey {
        case additionalDirectories, createdAt, cwd, id, latestTurn, modelSelection, plan, previousTurns
        case providerInstanceID = "providerInstanceId"
        case queuedPrompts, session, timeline, title, updatedAt
    }

    public init(additionalDirectories: [String]?, createdAt: Date, cwd: String?, id: String, latestTurn: Turn?, modelSelection: ModelSelection?, plan: Plan?, previousTurns: [Turn]?, providerInstanceID: String?, queuedPrompts: [QueuedPrompt]?, session: SessionBinding?, timeline: [TimelineEntry], title: String, updatedAt: Date) {
        self.additionalDirectories = additionalDirectories
        self.createdAt = createdAt
        self.cwd = cwd
        self.id = id
        self.latestTurn = latestTurn
        self.modelSelection = modelSelection
        self.plan = plan
        self.previousTurns = previousTurns
        self.providerInstanceID = providerInstanceID
        self.queuedPrompts = queuedPrompts
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
        additionalDirectories: [String]?? = nil,
        createdAt: Date? = nil,
        cwd: String?? = nil,
        id: String? = nil,
        latestTurn: Turn?? = nil,
        modelSelection: ModelSelection?? = nil,
        plan: Plan?? = nil,
        previousTurns: [Turn]?? = nil,
        providerInstanceID: String?? = nil,
        queuedPrompts: [QueuedPrompt]?? = nil,
        session: SessionBinding?? = nil,
        timeline: [TimelineEntry]? = nil,
        title: String? = nil,
        updatedAt: Date? = nil
    ) -> Thread {
        return Thread(
            additionalDirectories: additionalDirectories ?? self.additionalDirectories,
            createdAt: createdAt ?? self.createdAt,
            cwd: cwd ?? self.cwd,
            id: id ?? self.id,
            latestTurn: latestTurn ?? self.latestTurn,
            modelSelection: modelSelection ?? self.modelSelection,
            plan: plan ?? self.plan,
            previousTurns: previousTurns ?? self.previousTurns,
            providerInstanceID: providerInstanceID ?? self.providerInstanceID,
            queuedPrompts: queuedPrompts ?? self.queuedPrompts,
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

// MARK: - QueuedPrompt
public struct QueuedPrompt: Codable {
    public var annotations: [PromptAnnotation]?
    public var attachments: [Attachment]?
    public var createdAt: Date
    public var messageID, text: String

    public enum CodingKeys: String, CodingKey {
        case annotations, attachments, createdAt
        case messageID = "messageId"
        case text
    }

    public init(annotations: [PromptAnnotation]?, attachments: [Attachment]?, createdAt: Date, messageID: String, text: String) {
        self.annotations = annotations
        self.attachments = attachments
        self.createdAt = createdAt
        self.messageID = messageID
        self.text = text
    }
}

// MARK: QueuedPrompt convenience initializers and mutators

public extension QueuedPrompt {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(QueuedPrompt.self, from: data)
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
        annotations: [PromptAnnotation]?? = nil,
        attachments: [Attachment]?? = nil,
        createdAt: Date? = nil,
        messageID: String? = nil,
        text: String? = nil
    ) -> QueuedPrompt {
        return QueuedPrompt(
            annotations: annotations ?? self.annotations,
            attachments: attachments ?? self.attachments,
            createdAt: createdAt ?? self.createdAt,
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
    public var additionalDirectories: [String]?
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
        case additionalDirectories, createdAt, cwd, hasPendingApprovals, id, latestTurn, modelSelection
        case providerInstanceID = "providerInstanceId"
        case session, title, updatedAt
    }

    public init(additionalDirectories: [String]?, createdAt: Date, cwd: String?, hasPendingApprovals: Bool, id: String, latestTurn: Turn?, modelSelection: ModelSelection?, providerInstanceID: String?, session: SessionBinding?, title: String, updatedAt: Date) {
        self.additionalDirectories = additionalDirectories
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
        additionalDirectories: [String]?? = nil,
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
            additionalDirectories: additionalDirectories ?? self.additionalDirectories,
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

// MARK: - WorkspaceBrowseDirectoriesParams
public struct WorkspaceBrowseDirectoriesParams: Codable {
    public var path: String?

    public init(path: String?) {
        self.path = path
    }
}

// MARK: WorkspaceBrowseDirectoriesParams convenience initializers and mutators

public extension WorkspaceBrowseDirectoriesParams {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WorkspaceBrowseDirectoriesParams.self, from: data)
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
        path: String?? = nil
    ) -> WorkspaceBrowseDirectoriesParams {
        return WorkspaceBrowseDirectoriesParams(
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

// MARK: - WorkspaceBrowseDirectoriesResult
public struct WorkspaceBrowseDirectoriesResult: Codable {
    public var entries: [WorkspaceDirectoryEntry]
    public var parentPath: String?
    public var path: String

    public init(entries: [WorkspaceDirectoryEntry], parentPath: String?, path: String) {
        self.entries = entries
        self.parentPath = parentPath
        self.path = path
    }
}

// MARK: WorkspaceBrowseDirectoriesResult convenience initializers and mutators

public extension WorkspaceBrowseDirectoriesResult {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WorkspaceBrowseDirectoriesResult.self, from: data)
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
        entries: [WorkspaceDirectoryEntry]? = nil,
        parentPath: String?? = nil,
        path: String? = nil
    ) -> WorkspaceBrowseDirectoriesResult {
        return WorkspaceBrowseDirectoriesResult(
            entries: entries ?? self.entries,
            parentPath: parentPath ?? self.parentPath,
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

// MARK: - WorkspaceDirectoryEntry
public struct WorkspaceDirectoryEntry: Codable {
    public var name, path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

// MARK: WorkspaceDirectoryEntry convenience initializers and mutators

public extension WorkspaceDirectoryEntry {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WorkspaceDirectoryEntry.self, from: data)
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
        name: String? = nil,
        path: String? = nil
    ) -> WorkspaceDirectoryEntry {
        return WorkspaceDirectoryEntry(
            name: name ?? self.name,
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

// MARK: - WorkspaceFileEntry
public struct WorkspaceFileEntry: Codable {
    public var displayName, relativePath: String

    public init(displayName: String, relativePath: String) {
        self.displayName = displayName
        self.relativePath = relativePath
    }
}

// MARK: WorkspaceFileEntry convenience initializers and mutators

public extension WorkspaceFileEntry {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WorkspaceFileEntry.self, from: data)
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
        displayName: String? = nil,
        relativePath: String? = nil
    ) -> WorkspaceFileEntry {
        return WorkspaceFileEntry(
            displayName: displayName ?? self.displayName,
            relativePath: relativePath ?? self.relativePath
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WorkspaceSearchFilesParams
public struct WorkspaceSearchFilesParams: Codable {
    public var cwd: String?
    public var limit: Int?
    public var query: String
    public var threadID: String?

    public enum CodingKeys: String, CodingKey {
        case cwd, limit, query
        case threadID = "threadId"
    }

    public init(cwd: String?, limit: Int?, query: String, threadID: String?) {
        self.cwd = cwd
        self.limit = limit
        self.query = query
        self.threadID = threadID
    }
}

// MARK: WorkspaceSearchFilesParams convenience initializers and mutators

public extension WorkspaceSearchFilesParams {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WorkspaceSearchFilesParams.self, from: data)
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
        limit: Int?? = nil,
        query: String? = nil,
        threadID: String?? = nil
    ) -> WorkspaceSearchFilesParams {
        return WorkspaceSearchFilesParams(
            cwd: cwd ?? self.cwd,
            limit: limit ?? self.limit,
            query: query ?? self.query,
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

// MARK: - WorkspaceSearchFilesResult
public struct WorkspaceSearchFilesResult: Codable {
    public var entries: [WorkspaceFileEntry]
    public var indexing: Bool?

    public init(entries: [WorkspaceFileEntry], indexing: Bool?) {
        self.entries = entries
        self.indexing = indexing
    }
}

// MARK: WorkspaceSearchFilesResult convenience initializers and mutators

public extension WorkspaceSearchFilesResult {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WorkspaceSearchFilesResult.self, from: data)
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
        entries: [WorkspaceFileEntry]? = nil,
        indexing: Bool?? = nil
    ) -> WorkspaceSearchFilesResult {
        return WorkspaceSearchFilesResult(
            entries: entries ?? self.entries,
            indexing: indexing ?? self.indexing
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
    WireJSON.makeDecoder()
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
    // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
    nonisolated deinit {}

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
    // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
    nonisolated deinit {}

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
