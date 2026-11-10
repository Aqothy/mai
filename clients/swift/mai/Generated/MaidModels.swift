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

// MARK: - ACPCustomAgentUpdateParams
public struct ACPCustomAgentUpdateParams: Codable {
    public var args: [String]?
    public var command: String
    public var env: [String: String]?
    public var keepEnv: [String]?
    public var name, registryID: String

    public enum CodingKeys: String, CodingKey {
        case args, command, env, keepEnv, name
        case registryID = "registryId"
    }

    public init(args: [String]?, command: String, env: [String: String]?, keepEnv: [String]?, name: String, registryID: String) {
        self.args = args
        self.command = command
        self.env = env
        self.keepEnv = keepEnv
        self.name = name
        self.registryID = registryID
    }
}

// MARK: ACPCustomAgentUpdateParams convenience initializers and mutators

public extension ACPCustomAgentUpdateParams {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ACPCustomAgentUpdateParams.self, from: data)
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
        keepEnv: [String]?? = nil,
        name: String? = nil,
        registryID: String? = nil
    ) -> ACPCustomAgentUpdateParams {
        return ACPCustomAgentUpdateParams(
            args: args ?? self.args,
            command: command ?? self.command,
            env: env ?? self.env,
            keepEnv: keepEnv ?? self.keepEnv,
            name: name ?? self.name,
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

// MARK: - ACPRegistryAgent
public struct ACPRegistryAgent: Codable {
    public var args: [String]?
    public var availableReleasedAt: Date?
    public var availableVersion, blocker, command, description: String?
    public var envNames: [String]?
    public var error, icon: String?
    public var id: String
    public var installedVersion: String?
    public var instanceID: String
    public var licenseURL: String?
    public var name: String
    public var repository: String?
    public var source, state: String
    public var website: String?

    public enum CodingKeys: String, CodingKey {
        case args, availableReleasedAt, availableVersion, blocker, command, description, envNames, error, icon, id, installedVersion
        case instanceID = "instanceId"
        case licenseURL = "licenseUrl"
        case name, repository, source, state, website
    }

    public init(args: [String]?, availableReleasedAt: Date?, availableVersion: String?, blocker: String?, command: String?, description: String?, envNames: [String]?, error: String?, icon: String?, id: String, installedVersion: String?, instanceID: String, licenseURL: String?, name: String, repository: String?, source: String, state: String, website: String?) {
        self.args = args
        self.availableReleasedAt = availableReleasedAt
        self.availableVersion = availableVersion
        self.blocker = blocker
        self.command = command
        self.description = description
        self.envNames = envNames
        self.error = error
        self.icon = icon
        self.id = id
        self.installedVersion = installedVersion
        self.instanceID = instanceID
        self.licenseURL = licenseURL
        self.name = name
        self.repository = repository
        self.source = source
        self.state = state
        self.website = website
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
        availableReleasedAt: Date?? = nil,
        availableVersion: String?? = nil,
        blocker: String?? = nil,
        command: String?? = nil,
        description: String?? = nil,
        envNames: [String]?? = nil,
        error: String?? = nil,
        icon: String?? = nil,
        id: String? = nil,
        installedVersion: String?? = nil,
        instanceID: String? = nil,
        licenseURL: String?? = nil,
        name: String? = nil,
        repository: String?? = nil,
        source: String? = nil,
        state: String? = nil,
        website: String?? = nil
    ) -> ACPRegistryAgent {
        return ACPRegistryAgent(
            args: args ?? self.args,
            availableReleasedAt: availableReleasedAt ?? self.availableReleasedAt,
            availableVersion: availableVersion ?? self.availableVersion,
            blocker: blocker ?? self.blocker,
            command: command ?? self.command,
            description: description ?? self.description,
            envNames: envNames ?? self.envNames,
            error: error ?? self.error,
            icon: icon ?? self.icon,
            id: id ?? self.id,
            installedVersion: installedVersion ?? self.installedVersion,
            instanceID: instanceID ?? self.instanceID,
            licenseURL: licenseURL ?? self.licenseURL,
            name: name ?? self.name,
            repository: repository ?? self.repository,
            source: source ?? self.source,
            state: state ?? self.state,
            website: website ?? self.website
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

// MARK: - ACPRegistryList
public struct ACPRegistryList: Codable {
    public var agents: [ACPRegistryAgent]

    public init(agents: [ACPRegistryAgent]) {
        self.agents = agents
    }
}

// MARK: ACPRegistryList convenience initializers and mutators

public extension ACPRegistryList {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ACPRegistryList.self, from: data)
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
        agents: [ACPRegistryAgent]? = nil
    ) -> ACPRegistryList {
        return ACPRegistryList(
            agents: agents ?? self.agents
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ACPRegistryRemoveParams
public struct ACPRegistryRemoveParams: Codable {
    public var registryID: String

    public enum CodingKeys: String, CodingKey {
        case registryID = "registryId"
    }

    public init(registryID: String) {
        self.registryID = registryID
    }
}

// MARK: ACPRegistryRemoveParams convenience initializers and mutators

public extension ACPRegistryRemoveParams {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ACPRegistryRemoveParams.self, from: data)
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
    ) -> ACPRegistryRemoveParams {
        return ACPRegistryRemoveParams(
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

// MARK: - ACPRegistryStartParams
public struct ACPRegistryStartParams: Codable {
    public var cwd: String?
    public var registryID: String

    public enum CodingKeys: String, CodingKey {
        case cwd
        case registryID = "registryId"
    }

    public init(cwd: String?, registryID: String) {
        self.cwd = cwd
        self.registryID = registryID
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
        cwd: String?? = nil,
        registryID: String? = nil
    ) -> ACPRegistryStartParams {
        return ACPRegistryStartParams(
            cwd: cwd ?? self.cwd,
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

// MARK: - ActorView
public struct ActorView: Codable {
    public var kind, name: String
    public var participant, thread: String?

    public init(kind: String, name: String, participant: String?, thread: String?) {
        self.kind = kind
        self.name = name
        self.participant = participant
        self.thread = thread
    }
}

// MARK: ActorView convenience initializers and mutators

public extension ActorView {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ActorView.self, from: data)
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
        name: String? = nil,
        participant: String?? = nil,
        thread: String?? = nil
    ) -> ActorView {
        return ActorView(
            kind: kind ?? self.kind,
            name: name ?? self.name,
            participant: participant ?? self.participant,
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

// MARK: - AddParticipant
public struct AddParticipant: Codable {
    public var instance: String
    public var session: String?
    public var settings: [ConfigOptionSelection]?
    public var thread: String

    public init(instance: String, session: String?, settings: [ConfigOptionSelection]?, thread: String) {
        self.instance = instance
        self.session = session
        self.settings = settings
        self.thread = thread
    }
}

// MARK: AddParticipant convenience initializers and mutators

public extension AddParticipant {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(AddParticipant.self, from: data)
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
        instance: String? = nil,
        session: String?? = nil,
        settings: [ConfigOptionSelection]?? = nil,
        thread: String? = nil
    ) -> AddParticipant {
        return AddParticipant(
            instance: instance ?? self.instance,
            session: session ?? self.session,
            settings: settings ?? self.settings,
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

// MARK: - AttachmentParams
public struct AttachmentParams: Codable {
    public var id: String

    public init(id: String) {
        self.id = id
    }
}

// MARK: AttachmentParams convenience initializers and mutators

public extension AttachmentParams {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(AttachmentParams.self, from: data)
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
        id: String? = nil
    ) -> AttachmentParams {
        return AttachmentParams(
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

// MARK: - AttachmentUploadParams
public struct AttachmentUploadParams: Codable {
    public var data: String

    public init(data: String) {
        self.data = data
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
        data: String? = nil
    ) -> AttachmentUploadParams {
        return AttachmentUploadParams(
            data: data ?? self.data
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - AttachmentUploadResult
public struct AttachmentUploadResult: Codable {
    public var id: String

    public init(id: String) {
        self.id = id
    }
}

// MARK: AttachmentUploadResult convenience initializers and mutators

public extension AttachmentUploadResult {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(AttachmentUploadResult.self, from: data)
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
        id: String? = nil
    ) -> AttachmentUploadResult {
        return AttachmentUploadResult(
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

// MARK: - Attention
public struct Attention: Codable {
    public var failed, needsInput, unread: Bool

    public init(failed: Bool, needsInput: Bool, unread: Bool) {
        self.failed = failed
        self.needsInput = needsInput
        self.unread = unread
    }
}

// MARK: Attention convenience initializers and mutators

public extension Attention {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Attention.self, from: data)
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
        failed: Bool? = nil,
        needsInput: Bool? = nil,
        unread: Bool? = nil
    ) -> Attention {
        return Attention(
            failed: failed ?? self.failed,
            needsInput: needsInput ?? self.needsInput,
            unread: unread ?? self.unread
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
    public var access: AccessModes?
    public var auth: Auth
    public var capabilities: Capabilities
    public var driver: String
    public var initializedAt: Date
    public var instanceID, name: String
    public var pid: Int?
    public var startedAt: Date
    public var status: String

    public enum CodingKeys: String, CodingKey {
        case access, auth, capabilities, driver, initializedAt
        case instanceID = "instanceId"
        case name, pid, startedAt, status
    }

    public init(access: AccessModes?, auth: Auth, capabilities: Capabilities, driver: String, initializedAt: Date, instanceID: String, name: String, pid: Int?, startedAt: Date, status: String) {
        self.access = access
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
        access: AccessModes?? = nil,
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
            access: access ?? self.access,
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

// MARK: - AccessModes
public struct AccessModes: Codable {
    public var levels: [String: String]
    public var option: String

    public init(levels: [String: String], option: String) {
        self.levels = levels
        self.option = option
    }
}

// MARK: AccessModes convenience initializers and mutators

public extension AccessModes {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(AccessModes.self, from: data)
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
        levels: [String: String]? = nil,
        option: String? = nil
    ) -> AccessModes {
        return AccessModes(
            levels: levels ?? self.levels,
            option: option ?? self.option
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
    public var additionalDirectories, auth, commandCompletion, delete: Bool?
    public var fork: Bool?
    public var history: String
    public var historyVersion: Int
    public var instructions, logout: Bool?
    public var mcp: MCPCapabilities?
    public var messageIDS: Bool?
    public var promptContent: PromptContentCapabilities?
    public var rename, resume, sessions, steer: Bool?
    public var subagents: Bool?

    public enum CodingKeys: String, CodingKey {
        case additionalDirectories, auth, commandCompletion, delete, fork, history, historyVersion, instructions, logout, mcp
        case messageIDS = "messageIds"
        case promptContent, rename, resume, sessions, steer, subagents
    }

    public init(additionalDirectories: Bool?, auth: Bool?, commandCompletion: Bool?, delete: Bool?, fork: Bool?, history: String, historyVersion: Int, instructions: Bool?, logout: Bool?, mcp: MCPCapabilities?, messageIDS: Bool?, promptContent: PromptContentCapabilities?, rename: Bool?, resume: Bool?, sessions: Bool?, steer: Bool?, subagents: Bool?) {
        self.additionalDirectories = additionalDirectories
        self.auth = auth
        self.commandCompletion = commandCompletion
        self.delete = delete
        self.fork = fork
        self.history = history
        self.historyVersion = historyVersion
        self.instructions = instructions
        self.logout = logout
        self.mcp = mcp
        self.messageIDS = messageIDS
        self.promptContent = promptContent
        self.rename = rename
        self.resume = resume
        self.sessions = sessions
        self.steer = steer
        self.subagents = subagents
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
        commandCompletion: Bool?? = nil,
        delete: Bool?? = nil,
        fork: Bool?? = nil,
        history: String? = nil,
        historyVersion: Int? = nil,
        instructions: Bool?? = nil,
        logout: Bool?? = nil,
        mcp: MCPCapabilities?? = nil,
        messageIDS: Bool?? = nil,
        promptContent: PromptContentCapabilities?? = nil,
        rename: Bool?? = nil,
        resume: Bool?? = nil,
        sessions: Bool?? = nil,
        steer: Bool?? = nil,
        subagents: Bool?? = nil
    ) -> Capabilities {
        return Capabilities(
            additionalDirectories: additionalDirectories ?? self.additionalDirectories,
            auth: auth ?? self.auth,
            commandCompletion: commandCompletion ?? self.commandCompletion,
            delete: delete ?? self.delete,
            fork: fork ?? self.fork,
            history: history ?? self.history,
            historyVersion: historyVersion ?? self.historyVersion,
            instructions: instructions ?? self.instructions,
            logout: logout ?? self.logout,
            mcp: mcp ?? self.mcp,
            messageIDS: messageIDS ?? self.messageIDS,
            promptContent: promptContent ?? self.promptContent,
            rename: rename ?? self.rename,
            resume: resume ?? self.resume,
            sessions: sessions ?? self.sessions,
            steer: steer ?? self.steer,
            subagents: subagents ?? self.subagents
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
    public var http, stdio: Bool?

    public init(http: Bool?, stdio: Bool?) {
        self.http = http
        self.stdio = stdio
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
        stdio: Bool?? = nil
    ) -> MCPCapabilities {
        return MCPCapabilities(
            http: http ?? self.http,
            stdio: stdio ?? self.stdio
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

// MARK: - CancelDelivery
public struct CancelDelivery: Codable {
    public var delivery: String

    public init(delivery: String) {
        self.delivery = delivery
    }
}

// MARK: CancelDelivery convenience initializers and mutators

public extension CancelDelivery {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(CancelDelivery.self, from: data)
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
        delivery: String? = nil
    ) -> CancelDelivery {
        return CancelDelivery(
            delivery: delivery ?? self.delivery
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

// MARK: - CommandParams
public struct CommandParams: Codable {
    public var addParticipant: AddParticipant?
    public var cancelDelivery: CancelDelivery?
    public var commandParamsContinue: Continue?
    public var createThread: CreateThread?
    public var deleteThread: DeleteThread?
    public var deliver: Deliver?
    public var forkThread: ForkThread?
    public var interrupt: Interrupt?
    public var key: String?
    public var moveDelivery: MoveDelivery?
    public var respond: Respond?
    public var retryDelivery: RetryDelivery?
    public var spawn: Spawn?
    public var steerDelivery: SteerDelivery?
    public var stop: Stop?
    public var stopItem: StopItem?
    public var updateParticipant: UpdateParticipant?
    public var updateThread: UpdateThread?

    public enum CodingKeys: String, CodingKey {
        case addParticipant, cancelDelivery
        case commandParamsContinue = "continue"
        case createThread, deleteThread, deliver, forkThread, interrupt, key, moveDelivery, respond, retryDelivery, spawn, steerDelivery, stop, stopItem, updateParticipant, updateThread
    }

    public init(addParticipant: AddParticipant?, cancelDelivery: CancelDelivery?, commandParamsContinue: Continue?, createThread: CreateThread?, deleteThread: DeleteThread?, deliver: Deliver?, forkThread: ForkThread?, interrupt: Interrupt?, key: String?, moveDelivery: MoveDelivery?, respond: Respond?, retryDelivery: RetryDelivery?, spawn: Spawn?, steerDelivery: SteerDelivery?, stop: Stop?, stopItem: StopItem?, updateParticipant: UpdateParticipant?, updateThread: UpdateThread?) {
        self.addParticipant = addParticipant
        self.cancelDelivery = cancelDelivery
        self.commandParamsContinue = commandParamsContinue
        self.createThread = createThread
        self.deleteThread = deleteThread
        self.deliver = deliver
        self.forkThread = forkThread
        self.interrupt = interrupt
        self.key = key
        self.moveDelivery = moveDelivery
        self.respond = respond
        self.retryDelivery = retryDelivery
        self.spawn = spawn
        self.steerDelivery = steerDelivery
        self.stop = stop
        self.stopItem = stopItem
        self.updateParticipant = updateParticipant
        self.updateThread = updateThread
    }
}

// MARK: CommandParams convenience initializers and mutators

public extension CommandParams {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(CommandParams.self, from: data)
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
        addParticipant: AddParticipant?? = nil,
        cancelDelivery: CancelDelivery?? = nil,
        commandParamsContinue: Continue?? = nil,
        createThread: CreateThread?? = nil,
        deleteThread: DeleteThread?? = nil,
        deliver: Deliver?? = nil,
        forkThread: ForkThread?? = nil,
        interrupt: Interrupt?? = nil,
        key: String?? = nil,
        moveDelivery: MoveDelivery?? = nil,
        respond: Respond?? = nil,
        retryDelivery: RetryDelivery?? = nil,
        spawn: Spawn?? = nil,
        steerDelivery: SteerDelivery?? = nil,
        stop: Stop?? = nil,
        stopItem: StopItem?? = nil,
        updateParticipant: UpdateParticipant?? = nil,
        updateThread: UpdateThread?? = nil
    ) -> CommandParams {
        return CommandParams(
            addParticipant: addParticipant ?? self.addParticipant,
            cancelDelivery: cancelDelivery ?? self.cancelDelivery,
            commandParamsContinue: commandParamsContinue ?? self.commandParamsContinue,
            createThread: createThread ?? self.createThread,
            deleteThread: deleteThread ?? self.deleteThread,
            deliver: deliver ?? self.deliver,
            forkThread: forkThread ?? self.forkThread,
            interrupt: interrupt ?? self.interrupt,
            key: key ?? self.key,
            moveDelivery: moveDelivery ?? self.moveDelivery,
            respond: respond ?? self.respond,
            retryDelivery: retryDelivery ?? self.retryDelivery,
            spawn: spawn ?? self.spawn,
            steerDelivery: steerDelivery ?? self.steerDelivery,
            stop: stop ?? self.stop,
            stopItem: stopItem ?? self.stopItem,
            updateParticipant: updateParticipant ?? self.updateParticipant,
            updateThread: updateThread ?? self.updateThread
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - Continue
public struct Continue: Codable {
    public var thread: String

    public init(thread: String) {
        self.thread = thread
    }
}

// MARK: Continue convenience initializers and mutators

public extension Continue {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Continue.self, from: data)
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
        thread: String? = nil
    ) -> Continue {
        return Continue(
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

// MARK: - CreateThread
public struct CreateThread: Codable {
    public var participant: NewParticipant
    public var prompt: MessageBody?
    public var title: String?
    public var workspace: Workspace

    public init(participant: NewParticipant, prompt: MessageBody?, title: String?, workspace: Workspace) {
        self.participant = participant
        self.prompt = prompt
        self.title = title
        self.workspace = workspace
    }
}

// MARK: CreateThread convenience initializers and mutators

public extension CreateThread {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(CreateThread.self, from: data)
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
        participant: NewParticipant? = nil,
        prompt: MessageBody?? = nil,
        title: String?? = nil,
        workspace: Workspace? = nil
    ) -> CreateThread {
        return CreateThread(
            participant: participant ?? self.participant,
            prompt: prompt ?? self.prompt,
            title: title ?? self.title,
            workspace: workspace ?? self.workspace
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - NewParticipant
public struct NewParticipant: Codable {
    public var instance: String
    public var session: String?
    public var settings: [ConfigOptionSelection]?

    public init(instance: String, session: String?, settings: [ConfigOptionSelection]?) {
        self.instance = instance
        self.session = session
        self.settings = settings
    }
}

// MARK: NewParticipant convenience initializers and mutators

public extension NewParticipant {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(NewParticipant.self, from: data)
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
        instance: String? = nil,
        session: String?? = nil,
        settings: [ConfigOptionSelection]?? = nil
    ) -> NewParticipant {
        return NewParticipant(
            instance: instance ?? self.instance,
            session: session ?? self.session,
            settings: settings ?? self.settings
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - MessageBody
public struct MessageBody: Codable {
    public var annotations: [PromptAnnotation]?
    public var attachments: [Attachment]?
    public var text: String?

    public init(annotations: [PromptAnnotation]?, attachments: [Attachment]?, text: String?) {
        self.annotations = annotations
        self.attachments = attachments
        self.text = text
    }
}

// MARK: MessageBody convenience initializers and mutators

public extension MessageBody {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(MessageBody.self, from: data)
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
        text: String?? = nil
    ) -> MessageBody {
        return MessageBody(
            annotations: annotations ?? self.annotations,
            attachments: attachments ?? self.attachments,
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

// MARK: - Workspace
public struct Workspace: Codable {
    public var additionalDirectories: [String]?
    public var cwd: String

    public init(additionalDirectories: [String]?, cwd: String) {
        self.additionalDirectories = additionalDirectories
        self.cwd = cwd
    }
}

// MARK: Workspace convenience initializers and mutators

public extension Workspace {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Workspace.self, from: data)
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
        cwd: String? = nil
    ) -> Workspace {
        return Workspace(
            additionalDirectories: additionalDirectories ?? self.additionalDirectories,
            cwd: cwd ?? self.cwd
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - DeleteThread
public struct DeleteThread: Codable {
    public var thread: String

    public init(thread: String) {
        self.thread = thread
    }
}

// MARK: DeleteThread convenience initializers and mutators

public extension DeleteThread {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(DeleteThread.self, from: data)
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
        thread: String? = nil
    ) -> DeleteThread {
        return DeleteThread(
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

// MARK: - Deliver
public struct Deliver: Codable {
    public var body: MessageBody
    public var mode: String?
    public var thread: String
    public var to: String?
    public var wantsReply: Bool?

    public init(body: MessageBody, mode: String?, thread: String, to: String?, wantsReply: Bool?) {
        self.body = body
        self.mode = mode
        self.thread = thread
        self.to = to
        self.wantsReply = wantsReply
    }
}

// MARK: Deliver convenience initializers and mutators

public extension Deliver {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Deliver.self, from: data)
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
        body: MessageBody? = nil,
        mode: String?? = nil,
        thread: String? = nil,
        to: String?? = nil,
        wantsReply: Bool?? = nil
    ) -> Deliver {
        return Deliver(
            body: body ?? self.body,
            mode: mode ?? self.mode,
            thread: thread ?? self.thread,
            to: to ?? self.to,
            wantsReply: wantsReply ?? self.wantsReply
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ForkThread
public struct ForkThread: Codable {
    public var agent: NewParticipant?
    public var prompt: MessageBody
    public var thread: String
    public var through: String?

    public init(agent: NewParticipant?, prompt: MessageBody, thread: String, through: String?) {
        self.agent = agent
        self.prompt = prompt
        self.thread = thread
        self.through = through
    }
}

// MARK: ForkThread convenience initializers and mutators

public extension ForkThread {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ForkThread.self, from: data)
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
        agent: NewParticipant?? = nil,
        prompt: MessageBody? = nil,
        thread: String? = nil,
        through: String?? = nil
    ) -> ForkThread {
        return ForkThread(
            agent: agent ?? self.agent,
            prompt: prompt ?? self.prompt,
            thread: thread ?? self.thread,
            through: through ?? self.through
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - Interrupt
public struct Interrupt: Codable {
    public var thread: String

    public init(thread: String) {
        self.thread = thread
    }
}

// MARK: Interrupt convenience initializers and mutators

public extension Interrupt {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Interrupt.self, from: data)
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
        thread: String? = nil
    ) -> Interrupt {
        return Interrupt(
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

// MARK: - MoveDelivery
public struct MoveDelivery: Codable {
    public var before: String?
    public var delivery: String

    public init(before: String?, delivery: String) {
        self.before = before
        self.delivery = delivery
    }
}

// MARK: MoveDelivery convenience initializers and mutators

public extension MoveDelivery {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(MoveDelivery.self, from: data)
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
        before: String?? = nil,
        delivery: String? = nil
    ) -> MoveDelivery {
        return MoveDelivery(
            before: before ?? self.before,
            delivery: delivery ?? self.delivery
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - Respond
public struct Respond: Codable {
    public var action: String
    public var answers: [String: [String]]?
    public var request, thread: String
    public var why: String?

    public init(action: String, answers: [String: [String]]?, request: String, thread: String, why: String?) {
        self.action = action
        self.answers = answers
        self.request = request
        self.thread = thread
        self.why = why
    }
}

// MARK: Respond convenience initializers and mutators

public extension Respond {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Respond.self, from: data)
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
        answers: [String: [String]]?? = nil,
        request: String? = nil,
        thread: String? = nil,
        why: String?? = nil
    ) -> Respond {
        return Respond(
            action: action ?? self.action,
            answers: answers ?? self.answers,
            request: request ?? self.request,
            thread: thread ?? self.thread,
            why: why ?? self.why
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - RetryDelivery
public struct RetryDelivery: Codable {
    public var delivery: String

    public init(delivery: String) {
        self.delivery = delivery
    }
}

// MARK: RetryDelivery convenience initializers and mutators

public extension RetryDelivery {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(RetryDelivery.self, from: data)
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
        delivery: String? = nil
    ) -> RetryDelivery {
        return RetryDelivery(
            delivery: delivery ?? self.delivery
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - Spawn
public struct Spawn: Codable {
    public var access: String?
    public var agent: NewParticipant
    public var brief: String
    public var context: ForkPoint?
    public var parent: String
    public var resultSchema: JSONAny?
    public var title, wake: String?

    public init(access: String?, agent: NewParticipant, brief: String, context: ForkPoint?, parent: String, resultSchema: JSONAny?, title: String?, wake: String?) {
        self.access = access
        self.agent = agent
        self.brief = brief
        self.context = context
        self.parent = parent
        self.resultSchema = resultSchema
        self.title = title
        self.wake = wake
    }
}

// MARK: Spawn convenience initializers and mutators

public extension Spawn {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Spawn.self, from: data)
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
        access: String?? = nil,
        agent: NewParticipant? = nil,
        brief: String? = nil,
        context: ForkPoint?? = nil,
        parent: String? = nil,
        resultSchema: JSONAny?? = nil,
        title: String?? = nil,
        wake: String?? = nil
    ) -> Spawn {
        return Spawn(
            access: access ?? self.access,
            agent: agent ?? self.agent,
            brief: brief ?? self.brief,
            context: context ?? self.context,
            parent: parent ?? self.parent,
            resultSchema: resultSchema ?? self.resultSchema,
            title: title ?? self.title,
            wake: wake ?? self.wake
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ForkPoint
public struct ForkPoint: Codable {
    public var thread: String
    public var turn: String?

    public init(thread: String, turn: String?) {
        self.thread = thread
        self.turn = turn
    }
}

// MARK: ForkPoint convenience initializers and mutators

public extension ForkPoint {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ForkPoint.self, from: data)
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
        thread: String? = nil,
        turn: String?? = nil
    ) -> ForkPoint {
        return ForkPoint(
            thread: thread ?? self.thread,
            turn: turn ?? self.turn
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - SteerDelivery
public struct SteerDelivery: Codable {
    public var delivery: String

    public init(delivery: String) {
        self.delivery = delivery
    }
}

// MARK: SteerDelivery convenience initializers and mutators

public extension SteerDelivery {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(SteerDelivery.self, from: data)
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
        delivery: String? = nil
    ) -> SteerDelivery {
        return SteerDelivery(
            delivery: delivery ?? self.delivery
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - Stop
public struct Stop: Codable {
    public var thread: String

    public init(thread: String) {
        self.thread = thread
    }
}

// MARK: Stop convenience initializers and mutators

public extension Stop {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Stop.self, from: data)
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
        thread: String? = nil
    ) -> Stop {
        return Stop(
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

// MARK: - StopItem
public struct StopItem: Codable {
    public var item, thread: String

    public init(item: String, thread: String) {
        self.item = item
        self.thread = thread
    }
}

// MARK: StopItem convenience initializers and mutators

public extension StopItem {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(StopItem.self, from: data)
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
        item: String? = nil,
        thread: String? = nil
    ) -> StopItem {
        return StopItem(
            item: item ?? self.item,
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

// MARK: - UpdateParticipant
public struct UpdateParticipant: Codable {
    public var participant: String
    public var setting: ConfigOptionSelection

    public init(participant: String, setting: ConfigOptionSelection) {
        self.participant = participant
        self.setting = setting
    }
}

// MARK: UpdateParticipant convenience initializers and mutators

public extension UpdateParticipant {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(UpdateParticipant.self, from: data)
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
        participant: String? = nil,
        setting: ConfigOptionSelection? = nil
    ) -> UpdateParticipant {
        return UpdateParticipant(
            participant: participant ?? self.participant,
            setting: setting ?? self.setting
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - UpdateThread
public struct UpdateThread: Codable {
    public var policy: TreePolicy?
    public var read: Bool?
    public var thread: String
    public var title: String?

    public init(policy: TreePolicy?, read: Bool?, thread: String, title: String?) {
        self.policy = policy
        self.read = read
        self.thread = thread
        self.title = title
    }
}

// MARK: UpdateThread convenience initializers and mutators

public extension UpdateThread {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(UpdateThread.self, from: data)
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
        policy: TreePolicy?? = nil,
        read: Bool?? = nil,
        thread: String? = nil,
        title: String?? = nil
    ) -> UpdateThread {
        return UpdateThread(
            policy: policy ?? self.policy,
            read: read ?? self.read,
            thread: thread ?? self.thread,
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

// MARK: - TreePolicy
public struct TreePolicy: Codable {
    public var hopLimit, maxDepth, maxRunning: Int

    public init(hopLimit: Int, maxDepth: Int, maxRunning: Int) {
        self.hopLimit = hopLimit
        self.maxDepth = maxDepth
        self.maxRunning = maxRunning
    }
}

// MARK: TreePolicy convenience initializers and mutators

public extension TreePolicy {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(TreePolicy.self, from: data)
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
        hopLimit: Int? = nil,
        maxDepth: Int? = nil,
        maxRunning: Int? = nil
    ) -> TreePolicy {
        return TreePolicy(
            hopLimit: hopLimit ?? self.hopLimit,
            maxDepth: maxDepth ?? self.maxDepth,
            maxRunning: maxRunning ?? self.maxRunning
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - CommandResult
public struct CommandResult: Codable {
    public var delivery, participant, thread: String?

    public init(delivery: String?, participant: String?, thread: String?) {
        self.delivery = delivery
        self.participant = participant
        self.thread = thread
    }
}

// MARK: CommandResult convenience initializers and mutators

public extension CommandResult {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(CommandResult.self, from: data)
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
        delivery: String?? = nil,
        participant: String?? = nil,
        thread: String?? = nil
    ) -> CommandResult {
        return CommandResult(
            delivery: delivery ?? self.delivery,
            participant: participant ?? self.participant,
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

// MARK: - DeliveryView
public struct DeliveryView: Codable {
    public var annotations: [PromptAnnotation]?
    public var answers: String?
    public var attachments: [Attachment]?
    public var createdAt: Date
    public var from: ActorView
    public var id, kind, mode: String
    public var position: Double
    public var reason: String?
    public var state: String
    public var text: String?
    public var to: String
    public var turn: String?

    public init(annotations: [PromptAnnotation]?, answers: String?, attachments: [Attachment]?, createdAt: Date, from: ActorView, id: String, kind: String, mode: String, position: Double, reason: String?, state: String, text: String?, to: String, turn: String?) {
        self.annotations = annotations
        self.answers = answers
        self.attachments = attachments
        self.createdAt = createdAt
        self.from = from
        self.id = id
        self.kind = kind
        self.mode = mode
        self.position = position
        self.reason = reason
        self.state = state
        self.text = text
        self.to = to
        self.turn = turn
    }
}

// MARK: DeliveryView convenience initializers and mutators

public extension DeliveryView {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(DeliveryView.self, from: data)
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
        answers: String?? = nil,
        attachments: [Attachment]?? = nil,
        createdAt: Date? = nil,
        from: ActorView? = nil,
        id: String? = nil,
        kind: String? = nil,
        mode: String? = nil,
        position: Double? = nil,
        reason: String?? = nil,
        state: String? = nil,
        text: String?? = nil,
        to: String? = nil,
        turn: String?? = nil
    ) -> DeliveryView {
        return DeliveryView(
            annotations: annotations ?? self.annotations,
            answers: answers ?? self.answers,
            attachments: attachments ?? self.attachments,
            createdAt: createdAt ?? self.createdAt,
            from: from ?? self.from,
            id: id ?? self.id,
            kind: kind ?? self.kind,
            mode: mode ?? self.mode,
            position: position ?? self.position,
            reason: reason ?? self.reason,
            state: state ?? self.state,
            text: text ?? self.text,
            to: to ?? self.to,
            turn: turn ?? self.turn
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

// MARK: - Entry
public struct Entry: Codable {
    public var annotations: [PromptAnnotation]?
    public var at: Date?
    public var attachments: [Attachment]?
    public var delivery: String?
    public var envelope: Envelope?
    public var kind: String
    public var local: Bool?
    public var ref: String
    public var request: RequestRecord?
    public var status, text, title: String?
    public var tool: ToolCall?
    public var turn: String

    public init(annotations: [PromptAnnotation]?, at: Date?, attachments: [Attachment]?, delivery: String?, envelope: Envelope?, kind: String, local: Bool?, ref: String, request: RequestRecord?, status: String?, text: String?, title: String?, tool: ToolCall?, turn: String) {
        self.annotations = annotations
        self.at = at
        self.attachments = attachments
        self.delivery = delivery
        self.envelope = envelope
        self.kind = kind
        self.local = local
        self.ref = ref
        self.request = request
        self.status = status
        self.text = text
        self.title = title
        self.tool = tool
        self.turn = turn
    }
}

// MARK: Entry convenience initializers and mutators

public extension Entry {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Entry.self, from: data)
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
        at: Date?? = nil,
        attachments: [Attachment]?? = nil,
        delivery: String?? = nil,
        envelope: Envelope?? = nil,
        kind: String? = nil,
        local: Bool?? = nil,
        ref: String? = nil,
        request: RequestRecord?? = nil,
        status: String?? = nil,
        text: String?? = nil,
        title: String?? = nil,
        tool: ToolCall?? = nil,
        turn: String? = nil
    ) -> Entry {
        return Entry(
            annotations: annotations ?? self.annotations,
            at: at ?? self.at,
            attachments: attachments ?? self.attachments,
            delivery: delivery ?? self.delivery,
            envelope: envelope ?? self.envelope,
            kind: kind ?? self.kind,
            local: local ?? self.local,
            ref: ref ?? self.ref,
            request: request ?? self.request,
            status: status ?? self.status,
            text: text ?? self.text,
            title: title ?? self.title,
            tool: tool ?? self.tool,
            turn: turn ?? self.turn
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - Envelope
public struct Envelope: Codable {
    public var answers, body, covers, delivery: String?
    public var from: String?
    public var kind: String
    public var thread: String?

    public init(answers: String?, body: String?, covers: String?, delivery: String?, from: String?, kind: String, thread: String?) {
        self.answers = answers
        self.body = body
        self.covers = covers
        self.delivery = delivery
        self.from = from
        self.kind = kind
        self.thread = thread
    }
}

// MARK: Envelope convenience initializers and mutators

public extension Envelope {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Envelope.self, from: data)
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
        answers: String?? = nil,
        body: String?? = nil,
        covers: String?? = nil,
        delivery: String?? = nil,
        from: String?? = nil,
        kind: String? = nil,
        thread: String?? = nil
    ) -> Envelope {
        return Envelope(
            answers: answers ?? self.answers,
            body: body ?? self.body,
            covers: covers ?? self.covers,
            delivery: delivery ?? self.delivery,
            from: from ?? self.from,
            kind: kind ?? self.kind,
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

// MARK: - RequestRecord
public struct RequestRecord: Codable {
    public var action: String?
    public var answers: [String: [String]]?
    public var ask: Request
    public var request: String

    public init(action: String?, answers: [String: [String]]?, ask: Request, request: String) {
        self.action = action
        self.answers = answers
        self.ask = ask
        self.request = request
    }
}

// MARK: RequestRecord convenience initializers and mutators

public extension RequestRecord {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(RequestRecord.self, from: data)
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
        answers: [String: [String]]?? = nil,
        ask: Request? = nil,
        request: String? = nil
    ) -> RequestRecord {
        return RequestRecord(
            action: action ?? self.action,
            answers: answers ?? self.answers,
            ask: ask ?? self.ask,
            request: request ?? self.request
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - Request
public struct Request: Codable {
    public var actions: [RequestAction]
    public var details: JSONAny?
    public var message: String?
    public var questions: [Question]?
    public var url: String?

    public init(actions: [RequestAction], details: JSONAny?, message: String?, questions: [Question]?, url: String?) {
        self.actions = actions
        self.details = details
        self.message = message
        self.questions = questions
        self.url = url
    }
}

// MARK: Request convenience initializers and mutators

public extension Request {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Request.self, from: data)
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
        actions: [RequestAction]? = nil,
        details: JSONAny?? = nil,
        message: String?? = nil,
        questions: [Question]?? = nil,
        url: String?? = nil
    ) -> Request {
        return Request(
            actions: actions ?? self.actions,
            details: details ?? self.details,
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

// MARK: - RequestAction
public struct RequestAction: Codable {
    public var decision, id, label: String
    public var submit: Bool?

    public init(decision: String, id: String, label: String, submit: Bool?) {
        self.decision = decision
        self.id = id
        self.label = label
        self.submit = submit
    }
}

// MARK: RequestAction convenience initializers and mutators

public extension RequestAction {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(RequestAction.self, from: data)
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
        decision: String? = nil,
        id: String? = nil,
        label: String? = nil,
        submit: Bool?? = nil
    ) -> RequestAction {
        return RequestAction(
            decision: decision ?? self.decision,
            id: id ?? self.id,
            label: label ?? self.label,
            submit: submit ?? self.submit
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

// MARK: - EntryView
public struct EntryView: Codable {
    public var annotations: [PromptAnnotation]?
    public var at: Date?
    public var attachments: [Attachment]?
    public var delivery: String?
    public var detailAvailable: Bool?
    public var envelope: Envelope?
    public var kind, ref: String
    public var request: RequestRecord?
    public var status, text, title: String?
    public var tool: ToolCallSummary?

    public init(annotations: [PromptAnnotation]?, at: Date?, attachments: [Attachment]?, delivery: String?, detailAvailable: Bool?, envelope: Envelope?, kind: String, ref: String, request: RequestRecord?, status: String?, text: String?, title: String?, tool: ToolCallSummary?) {
        self.annotations = annotations
        self.at = at
        self.attachments = attachments
        self.delivery = delivery
        self.detailAvailable = detailAvailable
        self.envelope = envelope
        self.kind = kind
        self.ref = ref
        self.request = request
        self.status = status
        self.text = text
        self.title = title
        self.tool = tool
    }
}

// MARK: EntryView convenience initializers and mutators

public extension EntryView {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(EntryView.self, from: data)
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
        at: Date?? = nil,
        attachments: [Attachment]?? = nil,
        delivery: String?? = nil,
        detailAvailable: Bool?? = nil,
        envelope: Envelope?? = nil,
        kind: String? = nil,
        ref: String? = nil,
        request: RequestRecord?? = nil,
        status: String?? = nil,
        text: String?? = nil,
        title: String?? = nil,
        tool: ToolCallSummary?? = nil
    ) -> EntryView {
        return EntryView(
            annotations: annotations ?? self.annotations,
            at: at ?? self.at,
            attachments: attachments ?? self.attachments,
            delivery: delivery ?? self.delivery,
            detailAvailable: detailAvailable ?? self.detailAvailable,
            envelope: envelope ?? self.envelope,
            kind: kind ?? self.kind,
            ref: ref ?? self.ref,
            request: request ?? self.request,
            status: status ?? self.status,
            text: text ?? self.text,
            title: title ?? self.title,
            tool: tool ?? self.tool
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

// MARK: - ForkPreview
public struct ForkPreview: Codable {
    public var native: Bool
    public var summary: String?

    public init(native: Bool, summary: String?) {
        self.native = native
        self.summary = summary
    }
}

// MARK: ForkPreview convenience initializers and mutators

public extension ForkPreview {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ForkPreview.self, from: data)
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
        native: Bool? = nil,
        summary: String?? = nil
    ) -> ForkPreview {
        return ForkPreview(
            native: native ?? self.native,
            summary: summary ?? self.summary
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

// MARK: - OriginSummary
public struct OriginSummary: Codable {
    public var acceptsInput: Bool
    public var at, brief, by: String?
    public var forkedFrom: ForkPoint?
    public var kind: String
    public var parent: String?

    public init(acceptsInput: Bool, at: String?, brief: String?, by: String?, forkedFrom: ForkPoint?, kind: String, parent: String?) {
        self.acceptsInput = acceptsInput
        self.at = at
        self.brief = brief
        self.by = by
        self.forkedFrom = forkedFrom
        self.kind = kind
        self.parent = parent
    }
}

// MARK: OriginSummary convenience initializers and mutators

public extension OriginSummary {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(OriginSummary.self, from: data)
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
        acceptsInput: Bool? = nil,
        at: String?? = nil,
        brief: String?? = nil,
        by: String?? = nil,
        forkedFrom: ForkPoint?? = nil,
        kind: String? = nil,
        parent: String?? = nil
    ) -> OriginSummary {
        return OriginSummary(
            acceptsInput: acceptsInput ?? self.acceptsInput,
            at: at ?? self.at,
            brief: brief ?? self.brief,
            by: by ?? self.by,
            forkedFrom: forkedFrom ?? self.forkedFrom,
            kind: kind ?? self.kind,
            parent: parent ?? self.parent
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ParticipantSummary
public struct ParticipantSummary: Codable {
    public var driver, id, instance: String
    public var model: String?
    public var name: String

    public init(driver: String, id: String, instance: String, model: String?, name: String) {
        self.driver = driver
        self.id = id
        self.instance = instance
        self.model = model
        self.name = name
    }
}

// MARK: ParticipantSummary convenience initializers and mutators

public extension ParticipantSummary {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ParticipantSummary.self, from: data)
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
        driver: String? = nil,
        id: String? = nil,
        instance: String? = nil,
        model: String?? = nil,
        name: String? = nil
    ) -> ParticipantSummary {
        return ParticipantSummary(
            driver: driver ?? self.driver,
            id: id ?? self.id,
            instance: instance ?? self.instance,
            model: model ?? self.model,
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

// MARK: - ParticipantView
public struct ParticipantView: Codable {
    public var access: String?
    public var commands: [SlashCommand]
    public var driver: String
    public var goal: Goal?
    public var id, instance: String
    public var live: Bool
    public var model: String?
    public var name: String
    public var options: [ConfigOption]
    public var settings: [ConfigOptionSelection]
    public var skills: [Skill]
    public var usage: TokenUsage?

    public init(access: String?, commands: [SlashCommand], driver: String, goal: Goal?, id: String, instance: String, live: Bool, model: String?, name: String, options: [ConfigOption], settings: [ConfigOptionSelection], skills: [Skill], usage: TokenUsage?) {
        self.access = access
        self.commands = commands
        self.driver = driver
        self.goal = goal
        self.id = id
        self.instance = instance
        self.live = live
        self.model = model
        self.name = name
        self.options = options
        self.settings = settings
        self.skills = skills
        self.usage = usage
    }
}

// MARK: ParticipantView convenience initializers and mutators

public extension ParticipantView {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ParticipantView.self, from: data)
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
        access: String?? = nil,
        commands: [SlashCommand]? = nil,
        driver: String? = nil,
        goal: Goal?? = nil,
        id: String? = nil,
        instance: String? = nil,
        live: Bool? = nil,
        model: String?? = nil,
        name: String? = nil,
        options: [ConfigOption]? = nil,
        settings: [ConfigOptionSelection]? = nil,
        skills: [Skill]? = nil,
        usage: TokenUsage?? = nil
    ) -> ParticipantView {
        return ParticipantView(
            access: access ?? self.access,
            commands: commands ?? self.commands,
            driver: driver ?? self.driver,
            goal: goal ?? self.goal,
            id: id ?? self.id,
            instance: instance ?? self.instance,
            live: live ?? self.live,
            model: model ?? self.model,
            name: name ?? self.name,
            options: options ?? self.options,
            settings: settings ?? self.settings,
            skills: skills ?? self.skills,
            usage: usage ?? self.usage
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

// MARK: - Project
public struct Project: Codable {
    public var addedAt: Date
    public var path: String

    public init(addedAt: Date, path: String) {
        self.addedAt = addedAt
        self.path = path
    }
}

// MARK: Project convenience initializers and mutators

public extension Project {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Project.self, from: data)
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
        addedAt: Date? = nil,
        path: String? = nil
    ) -> Project {
        return Project(
            addedAt: addedAt ?? self.addedAt,
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

// MARK: - ProjectList
public struct ProjectList: Codable {
    public var projects: [Project]

    public init(projects: [Project]) {
        self.projects = projects
    }
}

// MARK: ProjectList convenience initializers and mutators

public extension ProjectList {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ProjectList.self, from: data)
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
        projects: [Project]? = nil
    ) -> ProjectList {
        return ProjectList(
            projects: projects ?? self.projects
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ProjectParams
public struct ProjectParams: Codable {
    public var path: String

    public init(path: String) {
        self.path = path
    }
}

// MARK: ProjectParams convenience initializers and mutators

public extension ProjectParams {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ProjectParams.self, from: data)
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
        path: String? = nil
    ) -> ProjectParams {
        return ProjectParams(
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

// MARK: - ProviderCompleteCommandParams
public struct ProviderCompleteCommandParams: Codable {
    public var command, input: String
    public var participant: String?
    public var thread: String

    public init(command: String, input: String, participant: String?, thread: String) {
        self.command = command
        self.input = input
        self.participant = participant
        self.thread = thread
    }
}

// MARK: ProviderCompleteCommandParams convenience initializers and mutators

public extension ProviderCompleteCommandParams {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ProviderCompleteCommandParams.self, from: data)
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
        participant: String?? = nil,
        thread: String? = nil
    ) -> ProviderCompleteCommandParams {
        return ProviderCompleteCommandParams(
            command: command ?? self.command,
            input: input ?? self.input,
            participant: participant ?? self.participant,
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
    public var request: Request
    public var requestID: String

    public enum CodingKeys: String, CodingKey {
        case instanceID = "instanceId"
        case request
        case requestID = "requestId"
    }

    public init(instanceID: String, request: Request, requestID: String) {
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
        request: Request? = nil,
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
    public var actionID: String
    public var answers: [String: [String]]?
    public var requestID: String

    public enum CodingKeys: String, CodingKey {
        case actionID = "actionId"
        case answers
        case requestID = "requestId"
    }

    public init(actionID: String, answers: [String: [String]]?, requestID: String) {
        self.actionID = actionID
        self.answers = answers
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
        actionID: String? = nil,
        answers: [String: [String]]?? = nil,
        requestID: String? = nil
    ) -> ProviderQuestionAnswerParams {
        return ProviderQuestionAnswerParams(
            actionID: actionID ?? self.actionID,
            answers: answers ?? self.answers,
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

    public enum CodingKeys: String, CodingKey {
        case config, driver
        case instanceID = "instanceId"
        case name
    }

    public init(config: JSONAny?, driver: String?, instanceID: String?, name: String?) {
        self.config = config
        self.driver = driver
        self.instanceID = instanceID
        self.name = name
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
        name: String?? = nil
    ) -> ProviderStartParams {
        return ProviderStartParams(
            config: config ?? self.config,
            driver: driver ?? self.driver,
            instanceID: instanceID ?? self.instanceID,
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

// MARK: - RequestResolution
public struct RequestResolution: Codable {
    public var record: RequestRecord
    public var request: String

    public init(record: RequestRecord, request: String) {
        self.record = record
        self.request = request
    }
}

// MARK: RequestResolution convenience initializers and mutators

public extension RequestResolution {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(RequestResolution.self, from: data)
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
        record: RequestRecord? = nil,
        request: String? = nil
    ) -> RequestResolution {
        return RequestResolution(
            record: record ?? self.record,
            request: request ?? self.request
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - RequestView
public struct RequestView: Codable {
    public var answering: String?
    public var ask: Request
    public var entry: String?
    public var id: String
    public var openedAt: Date
    public var participant: String
    public var turn: String?

    public init(answering: String?, ask: Request, entry: String?, id: String, openedAt: Date, participant: String, turn: String?) {
        self.answering = answering
        self.ask = ask
        self.entry = entry
        self.id = id
        self.openedAt = openedAt
        self.participant = participant
        self.turn = turn
    }
}

// MARK: RequestView convenience initializers and mutators

public extension RequestView {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(RequestView.self, from: data)
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
        answering: String?? = nil,
        ask: Request? = nil,
        entry: String?? = nil,
        id: String? = nil,
        openedAt: Date? = nil,
        participant: String? = nil,
        turn: String?? = nil
    ) -> RequestView {
        return RequestView(
            answering: answering ?? self.answering,
            ask: ask ?? self.ask,
            entry: entry ?? self.entry,
            id: id ?? self.id,
            openedAt: openedAt ?? self.openedAt,
            participant: participant ?? self.participant,
            turn: turn ?? self.turn
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

// MARK: - TerminalAttachParams
public struct TerminalAttachParams: Codable {
    public var appearance: TerminalAppearance
    public var attachmentID: String
    public var columns: Int
    public var focus: Bool?
    public var rows: Int
    public var terminalID: String

    public enum CodingKeys: String, CodingKey {
        case appearance
        case attachmentID = "attachmentId"
        case columns, focus, rows
        case terminalID = "terminalId"
    }

    public init(appearance: TerminalAppearance, attachmentID: String, columns: Int, focus: Bool?, rows: Int, terminalID: String) {
        self.appearance = appearance
        self.attachmentID = attachmentID
        self.columns = columns
        self.focus = focus
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
        appearance: TerminalAppearance? = nil,
        attachmentID: String? = nil,
        columns: Int? = nil,
        focus: Bool?? = nil,
        rows: Int? = nil,
        terminalID: String? = nil
    ) -> TerminalAttachParams {
        return TerminalAttachParams(
            appearance: appearance ?? self.appearance,
            attachmentID: attachmentID ?? self.attachmentID,
            columns: columns ?? self.columns,
            focus: focus ?? self.focus,
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

// MARK: - TerminalAppearance
public struct TerminalAppearance: Codable {
    public var background, colorScheme, foreground: String
    public var palette: [String]?

    public init(background: String, colorScheme: String, foreground: String, palette: [String]?) {
        self.background = background
        self.colorScheme = colorScheme
        self.foreground = foreground
        self.palette = palette
    }
}

// MARK: TerminalAppearance convenience initializers and mutators

public extension TerminalAppearance {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(TerminalAppearance.self, from: data)
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
        background: String? = nil,
        colorScheme: String? = nil,
        foreground: String? = nil,
        palette: [String]?? = nil
    ) -> TerminalAppearance {
        return TerminalAppearance(
            background: background ?? self.background,
            colorScheme: colorScheme ?? self.colorScheme,
            foreground: foreground ?? self.foreground,
            palette: palette ?? self.palette
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - TerminalAttachResult
public struct TerminalAttachResult: Codable {
    public var streamTicket: String
    public var terminal: TerminalSummary

    public init(streamTicket: String, terminal: TerminalSummary) {
        self.streamTicket = streamTicket
        self.terminal = terminal
    }
}

// MARK: TerminalAttachResult convenience initializers and mutators

public extension TerminalAttachResult {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(TerminalAttachResult.self, from: data)
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
        streamTicket: String? = nil,
        terminal: TerminalSummary? = nil
    ) -> TerminalAttachResult {
        return TerminalAttachResult(
            streamTicket: streamTicket ?? self.streamTicket,
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
    public var createdAt: Date
    public var cwd: String
    public var programStatus: TerminalProgramStatus?
    public var programTitle, pwd: String?
    public var terminalID, title: String
    public var updatedAt: Date

    public enum CodingKeys: String, CodingKey {
        case createdAt, cwd, programStatus, programTitle, pwd
        case terminalID = "terminalId"
        case title, updatedAt
    }

    public init(createdAt: Date, cwd: String, programStatus: TerminalProgramStatus?, programTitle: String?, pwd: String?, terminalID: String, title: String, updatedAt: Date) {
        self.createdAt = createdAt
        self.cwd = cwd
        self.programStatus = programStatus
        self.programTitle = programTitle
        self.pwd = pwd
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
        createdAt: Date? = nil,
        cwd: String? = nil,
        programStatus: TerminalProgramStatus?? = nil,
        programTitle: String?? = nil,
        pwd: String?? = nil,
        terminalID: String? = nil,
        title: String? = nil,
        updatedAt: Date? = nil
    ) -> TerminalSummary {
        return TerminalSummary(
            createdAt: createdAt ?? self.createdAt,
            cwd: cwd ?? self.cwd,
            programStatus: programStatus ?? self.programStatus,
            programTitle: programTitle ?? self.programTitle,
            pwd: pwd ?? self.pwd,
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

// MARK: - TerminalProgramStatus
public struct TerminalProgramStatus: Codable {
    public var app, message, need: String?
    public var progress: Int?
    public var state: String
    public var title: String?
    public var updatedAt: Date

    public init(app: String?, message: String?, need: String?, progress: Int?, state: String, title: String?, updatedAt: Date) {
        self.app = app
        self.message = message
        self.need = need
        self.progress = progress
        self.state = state
        self.title = title
        self.updatedAt = updatedAt
    }
}

// MARK: TerminalProgramStatus convenience initializers and mutators

public extension TerminalProgramStatus {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(TerminalProgramStatus.self, from: data)
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
        app: String?? = nil,
        message: String?? = nil,
        need: String?? = nil,
        progress: Int?? = nil,
        state: String? = nil,
        title: String?? = nil,
        updatedAt: Date? = nil
    ) -> TerminalProgramStatus {
        return TerminalProgramStatus(
            app: app ?? self.app,
            message: message ?? self.message,
            need: need ?? self.need,
            progress: progress ?? self.progress,
            state: state ?? self.state,
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
    public var appearance: TerminalAppearance
    public var attachmentID: String
    public var columns: Int
    public var cwd: String
    public var rows: Int
    public var title: String?

    public enum CodingKeys: String, CodingKey {
        case appearance
        case attachmentID = "attachmentId"
        case columns, cwd, rows, title
    }

    public init(appearance: TerminalAppearance, attachmentID: String, columns: Int, cwd: String, rows: Int, title: String?) {
        self.appearance = appearance
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
        appearance: TerminalAppearance? = nil,
        attachmentID: String? = nil,
        columns: Int? = nil,
        cwd: String? = nil,
        rows: Int? = nil,
        title: String?? = nil
    ) -> TerminalCreateParams {
        return TerminalCreateParams(
            appearance: appearance ?? self.appearance,
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
    public var appearance: TerminalAppearance
    public var columns, rows: Int
    public var terminalID: String

    public enum CodingKeys: String, CodingKey {
        case appearance, columns, rows
        case terminalID = "terminalId"
    }

    public init(appearance: TerminalAppearance, columns: Int, rows: Int, terminalID: String) {
        self.appearance = appearance
        self.columns = columns
        self.rows = rows
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
        appearance: TerminalAppearance? = nil,
        columns: Int? = nil,
        rows: Int? = nil,
        terminalID: String? = nil
    ) -> TerminalResizeParams {
        return TerminalResizeParams(
            appearance: appearance ?? self.appearance,
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

// MARK: - TerminalStreamResized
public struct TerminalStreamResized: Codable {
    public var columns, rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }
}

// MARK: TerminalStreamResized convenience initializers and mutators

public extension TerminalStreamResized {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(TerminalStreamResized.self, from: data)
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
        rows: Int? = nil
    ) -> TerminalStreamResized {
        return TerminalStreamResized(
            columns: columns ?? self.columns,
            rows: rows ?? self.rows
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - TerminalStreamSnapshot
public struct TerminalStreamSnapshot: Codable {
    public var size: Int
    public var snapshotFormat: String

    public init(size: Int, snapshotFormat: String) {
        self.size = size
        self.snapshotFormat = snapshotFormat
    }
}

// MARK: TerminalStreamSnapshot convenience initializers and mutators

public extension TerminalStreamSnapshot {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(TerminalStreamSnapshot.self, from: data)
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
        size: Int? = nil,
        snapshotFormat: String? = nil
    ) -> TerminalStreamSnapshot {
        return TerminalStreamSnapshot(
            size: size ?? self.size,
            snapshotFormat: snapshotFormat ?? self.snapshotFormat
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
    public var data, terminalID: String

    public enum CodingKeys: String, CodingKey {
        case data
        case terminalID = "terminalId"
    }

    public init(data: String, terminalID: String) {
        self.data = data
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
        terminalID: String? = nil
    ) -> TerminalWriteParams {
        return TerminalWriteParams(
            data: data ?? self.data,
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

// MARK: - TextAppend
public struct TextAppend: Codable {
    public var entry, stream, text, turn: String

    public init(entry: String, stream: String, text: String, turn: String) {
        self.entry = entry
        self.stream = stream
        self.text = text
        self.turn = turn
    }
}

// MARK: TextAppend convenience initializers and mutators

public extension TextAppend {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(TextAppend.self, from: data)
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
        entry: String? = nil,
        stream: String? = nil,
        text: String? = nil,
        turn: String? = nil
    ) -> TextAppend {
        return TextAppend(
            entry: entry ?? self.entry,
            stream: stream ?? self.stream,
            text: text ?? self.text,
            turn: turn ?? self.turn
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ThreadEntryParams
public struct ThreadEntryParams: Codable {
    public var ref, thread: String

    public init(ref: String, thread: String) {
        self.ref = ref
        self.thread = thread
    }
}

// MARK: ThreadEntryParams convenience initializers and mutators

public extension ThreadEntryParams {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ThreadEntryParams.self, from: data)
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
        ref: String? = nil,
        thread: String? = nil
    ) -> ThreadEntryParams {
        return ThreadEntryParams(
            ref: ref ?? self.ref,
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

// MARK: - ThreadEvent
public struct ThreadEvent: Codable {
    public var delivery: DeliveryView?
    public var entry: EntryView?
    public var kind: String
    public var participant: ParticipantView?
    public var plan: [PlanEntry]?
    public var request: RequestView?
    public var resolved: RequestResolution?
    public var seq: Int
    public var summary: ThreadSummary?
    public var text: TextAppend?
    public var thread: String
    public var turn: TurnView?

    public init(delivery: DeliveryView?, entry: EntryView?, kind: String, participant: ParticipantView?, plan: [PlanEntry]?, request: RequestView?, resolved: RequestResolution?, seq: Int, summary: ThreadSummary?, text: TextAppend?, thread: String, turn: TurnView?) {
        self.delivery = delivery
        self.entry = entry
        self.kind = kind
        self.participant = participant
        self.plan = plan
        self.request = request
        self.resolved = resolved
        self.seq = seq
        self.summary = summary
        self.text = text
        self.thread = thread
        self.turn = turn
    }
}

// MARK: ThreadEvent convenience initializers and mutators

public extension ThreadEvent {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ThreadEvent.self, from: data)
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
        delivery: DeliveryView?? = nil,
        entry: EntryView?? = nil,
        kind: String? = nil,
        participant: ParticipantView?? = nil,
        plan: [PlanEntry]?? = nil,
        request: RequestView?? = nil,
        resolved: RequestResolution?? = nil,
        seq: Int? = nil,
        summary: ThreadSummary?? = nil,
        text: TextAppend?? = nil,
        thread: String? = nil,
        turn: TurnView?? = nil
    ) -> ThreadEvent {
        return ThreadEvent(
            delivery: delivery ?? self.delivery,
            entry: entry ?? self.entry,
            kind: kind ?? self.kind,
            participant: participant ?? self.participant,
            plan: plan ?? self.plan,
            request: request ?? self.request,
            resolved: resolved ?? self.resolved,
            seq: seq ?? self.seq,
            summary: summary ?? self.summary,
            text: text ?? self.text,
            thread: thread ?? self.thread,
            turn: turn ?? self.turn
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ThreadSummary
public struct ThreadSummary: Codable {
    public var address: String?
    public var attention: Attention
    public var children: Int
    public var createdAt: Date
    public var hold: String?
    public var id: String
    public var origin: OriginSummary
    public var participants: [ParticipantSummary]
    public var status, title: String
    public var updatedAt: Date
    public var workspace: Workspace

    public init(address: String?, attention: Attention, children: Int, createdAt: Date, hold: String?, id: String, origin: OriginSummary, participants: [ParticipantSummary], status: String, title: String, updatedAt: Date, workspace: Workspace) {
        self.address = address
        self.attention = attention
        self.children = children
        self.createdAt = createdAt
        self.hold = hold
        self.id = id
        self.origin = origin
        self.participants = participants
        self.status = status
        self.title = title
        self.updatedAt = updatedAt
        self.workspace = workspace
    }
}

// MARK: ThreadSummary convenience initializers and mutators

public extension ThreadSummary {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ThreadSummary.self, from: data)
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
        address: String?? = nil,
        attention: Attention? = nil,
        children: Int? = nil,
        createdAt: Date? = nil,
        hold: String?? = nil,
        id: String? = nil,
        origin: OriginSummary? = nil,
        participants: [ParticipantSummary]? = nil,
        status: String? = nil,
        title: String? = nil,
        updatedAt: Date? = nil,
        workspace: Workspace? = nil
    ) -> ThreadSummary {
        return ThreadSummary(
            address: address ?? self.address,
            attention: attention ?? self.attention,
            children: children ?? self.children,
            createdAt: createdAt ?? self.createdAt,
            hold: hold ?? self.hold,
            id: id ?? self.id,
            origin: origin ?? self.origin,
            participants: participants ?? self.participants,
            status: status ?? self.status,
            title: title ?? self.title,
            updatedAt: updatedAt ?? self.updatedAt,
            workspace: workspace ?? self.workspace
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - TurnView
public struct TurnView: Codable {
    public var entries: [EntryView]
    public var error: String?
    public var id, participant: String
    public var settledAt: Date?
    public var startedAt: Date
    public var startedBy, state: String
    public var stopReason: String?

    public init(entries: [EntryView], error: String?, id: String, participant: String, settledAt: Date?, startedAt: Date, startedBy: String, state: String, stopReason: String?) {
        self.entries = entries
        self.error = error
        self.id = id
        self.participant = participant
        self.settledAt = settledAt
        self.startedAt = startedAt
        self.startedBy = startedBy
        self.state = state
        self.stopReason = stopReason
    }
}

// MARK: TurnView convenience initializers and mutators

public extension TurnView {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(TurnView.self, from: data)
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
        entries: [EntryView]? = nil,
        error: String?? = nil,
        id: String? = nil,
        participant: String? = nil,
        settledAt: Date?? = nil,
        startedAt: Date? = nil,
        startedBy: String? = nil,
        state: String? = nil,
        stopReason: String?? = nil
    ) -> TurnView {
        return TurnView(
            entries: entries ?? self.entries,
            error: error ?? self.error,
            id: id ?? self.id,
            participant: participant ?? self.participant,
            settledAt: settledAt ?? self.settledAt,
            startedAt: startedAt ?? self.startedAt,
            startedBy: startedBy ?? self.startedBy,
            state: state ?? self.state,
            stopReason: stopReason ?? self.stopReason
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ThreadForkPreviewParams
public struct ThreadForkPreviewParams: Codable {
    public var agent: String?
    public var thread: String
    public var through: String?

    public init(agent: String?, thread: String, through: String?) {
        self.agent = agent
        self.thread = thread
        self.through = through
    }
}

// MARK: ThreadForkPreviewParams convenience initializers and mutators

public extension ThreadForkPreviewParams {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ThreadForkPreviewParams.self, from: data)
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
        agent: String?? = nil,
        thread: String? = nil,
        through: String?? = nil
    ) -> ThreadForkPreviewParams {
        return ThreadForkPreviewParams(
            agent: agent ?? self.agent,
            thread: thread ?? self.thread,
            through: through ?? self.through
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ThreadListItem
public struct ThreadListItem: Codable {
    public var kind: String
    public var removed: String?
    public var seq: Int
    public var thread: ThreadSummary?
    public var threads: [ThreadSummary]?

    public init(kind: String, removed: String?, seq: Int, thread: ThreadSummary?, threads: [ThreadSummary]?) {
        self.kind = kind
        self.removed = removed
        self.seq = seq
        self.thread = thread
        self.threads = threads
    }
}

// MARK: ThreadListItem convenience initializers and mutators

public extension ThreadListItem {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ThreadListItem.self, from: data)
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
        removed: String?? = nil,
        seq: Int? = nil,
        thread: ThreadSummary?? = nil,
        threads: [ThreadSummary]?? = nil
    ) -> ThreadListItem {
        return ThreadListItem(
            kind: kind ?? self.kind,
            removed: removed ?? self.removed,
            seq: seq ?? self.seq,
            thread: thread ?? self.thread,
            threads: threads ?? self.threads
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ThreadParams
public struct ThreadParams: Codable {
    public var thread: String

    public init(thread: String) {
        self.thread = thread
    }
}

// MARK: ThreadParams convenience initializers and mutators

public extension ThreadParams {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ThreadParams.self, from: data)
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
        thread: String? = nil
    ) -> ThreadParams {
        return ThreadParams(
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

// MARK: - ThreadSnapshot
public struct ThreadSnapshot: Codable {
    public var children: [ThreadSummary]
    public var older: String?
    public var participants: [ParticipantView]
    public var plan: [PlanEntry]
    public var queue: [DeliveryView]
    public var requests: [RequestView]
    public var seq: Int
    public var thread: ThreadSummary
    public var turns: [TurnView]

    public init(children: [ThreadSummary], older: String?, participants: [ParticipantView], plan: [PlanEntry], queue: [DeliveryView], requests: [RequestView], seq: Int, thread: ThreadSummary, turns: [TurnView]) {
        self.children = children
        self.older = older
        self.participants = participants
        self.plan = plan
        self.queue = queue
        self.requests = requests
        self.seq = seq
        self.thread = thread
        self.turns = turns
    }
}

// MARK: ThreadSnapshot convenience initializers and mutators

public extension ThreadSnapshot {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ThreadSnapshot.self, from: data)
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
        children: [ThreadSummary]? = nil,
        older: String?? = nil,
        participants: [ParticipantView]? = nil,
        plan: [PlanEntry]? = nil,
        queue: [DeliveryView]? = nil,
        requests: [RequestView]? = nil,
        seq: Int? = nil,
        thread: ThreadSummary? = nil,
        turns: [TurnView]? = nil
    ) -> ThreadSnapshot {
        return ThreadSnapshot(
            children: children ?? self.children,
            older: older ?? self.older,
            participants: participants ?? self.participants,
            plan: plan ?? self.plan,
            queue: queue ?? self.queue,
            requests: requests ?? self.requests,
            seq: seq ?? self.seq,
            thread: thread ?? self.thread,
            turns: turns ?? self.turns
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ThreadTurnsParams
public struct ThreadTurnsParams: Codable {
    public var before: String?
    public var limit: Int?
    public var thread: String

    public init(before: String?, limit: Int?, thread: String) {
        self.before = before
        self.limit = limit
        self.thread = thread
    }
}

// MARK: ThreadTurnsParams convenience initializers and mutators

public extension ThreadTurnsParams {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ThreadTurnsParams.self, from: data)
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
        before: String?? = nil,
        limit: Int?? = nil,
        thread: String? = nil
    ) -> ThreadTurnsParams {
        return ThreadTurnsParams(
            before: before ?? self.before,
            limit: limit ?? self.limit,
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

// MARK: - ThreadTurnsResult
public struct ThreadTurnsResult: Codable {
    public var older: String?
    public var turns: [TurnView]

    public init(older: String?, turns: [TurnView]) {
        self.older = older
        self.turns = turns
    }
}

// MARK: ThreadTurnsResult convenience initializers and mutators

public extension ThreadTurnsResult {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ThreadTurnsResult.self, from: data)
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
        older: String?? = nil,
        turns: [TurnView]? = nil
    ) -> ThreadTurnsResult {
        return ThreadTurnsResult(
            older: older ?? self.older,
            turns: turns ?? self.turns
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
