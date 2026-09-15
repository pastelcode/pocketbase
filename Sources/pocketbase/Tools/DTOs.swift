import Foundation

// MARK: - ListResult
public struct ListResult<T: Codable & Sendable>: Codable, Sendable {
    public var page: Int
    public var perPage: Int
    public var totalItems: Int
    public var totalPages: Int
    public var items: [T]

    public init(page: Int = 1, perPage: Int = 30, totalItems: Int = 0, totalPages: Int = 0, items: [T] = []) {
        self.page = page
        self.perPage = perPage
        self.totalItems = totalItems
        self.totalPages = totalPages
        self.items = items
    }
}

// MARK: - BaseModel Protocol
public protocol BaseModel: Codable, Sendable {
    var id: String { get set }
}

// MARK: - LogModel
public struct LogModel: BaseModel, Equatable, Sendable {
    public var id: String
    public var level: String
    public var message: String
    public var created: String
    public var updated: String
    public var data: [String: AnyCodable]

    public init(
        id: String = "",
        level: String = "",
        message: String = "",
        created: String = "",
        updated: String = "",
        data: [String: AnyCodable] = [:]
    ) {
        self.id = id
        self.level = level
        self.message = message
        self.created = created
        self.updated = updated
        self.data = data
    }
}

// MARK: - RecordModel
public struct RecordModel: BaseModel, Equatable, Sendable {
    public var id: String
    public var collectionId: String
    public var collectionName: String
    public var created: String?
    public var updated: String?
    public var expand: [String: AnyCodable]?
    public var rawFields: [String: AnyCodable]

    public init(
        id: String = "",
        collectionId: String = "",
        collectionName: String = "",
        created: String? = nil,
        updated: String? = nil,
        expand: [String: AnyCodable]? = nil,
        rawFields: [String: AnyCodable] = [:]
    ) {
        self.id = id
        self.collectionId = collectionId
        self.collectionName = collectionName
        self.created = created
        self.updated = updated
        self.expand = expand
        self.rawFields = rawFields
    }

    public subscript(key: String) -> AnyCodable? {
        get {
            switch key {
            case "id": return AnyCodable(id)
            case "collectionId": return AnyCodable(collectionId)
            case "collectionName": return AnyCodable(collectionName)
            case "created": return created.map { AnyCodable($0) }
            case "updated": return updated.map { AnyCodable($0) }
            case "expand": return expand.map { AnyCodable($0) }
            default: return rawFields[key]
            }
        }
        set {
            switch key {
            case "id": id = newValue?.value.string ?? id
            case "collectionId": collectionId = newValue?.value.string ?? collectionId
            case "collectionName": collectionName = newValue?.value.string ?? collectionName
            case "created": created = newValue?.value.string
            case "updated": updated = newValue?.value.string
            case "expand":
                if case .dictionary(let dict) = newValue?.value {
                    expand = dict
                } else {
                    expand = nil
                }
            default:
                if let newValue = newValue {
                    rawFields[key] = newValue
                } else {
                    rawFields.removeValue(forKey: key)
                }
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, collectionId, collectionName, created, updated, expand
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? container.decode(String.self, forKey: .id)) ?? ""
        self.collectionId = (try? container.decode(String.self, forKey: .collectionId)) ?? ""
        self.collectionName = (try? container.decode(String.self, forKey: .collectionName)) ?? ""
        self.created = try? container.decode(String.self, forKey: .created)
        self.updated = try? container.decode(String.self, forKey: .updated)
        self.expand = try? container.decode([String: AnyCodable].self, forKey: .expand)

        let dynamicContainer = try decoder.container(keyedBy: DynamicCodingKey.self)
        var fields: [String: AnyCodable] = [:]
        for key in dynamicContainer.allKeys {
            if ["id", "collectionId", "collectionName", "created", "updated", "expand"].contains(key.stringValue) {
                continue
            }
            if let value = try? dynamicContainer.decode(AnyCodable.self, forKey: key) {
                fields[key.stringValue] = value
            }
        }
        self.rawFields = fields
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(collectionId, forKey: .collectionId)
        try container.encode(collectionName, forKey: .collectionName)
        try container.encodeIfPresent(created, forKey: .created)
        try container.encodeIfPresent(updated, forKey: .updated)
        try container.encodeIfPresent(expand, forKey: .expand)

        var dynamicContainer = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in rawFields {
            if let codingKey = DynamicCodingKey(stringValue: key) {
                try dynamicContainer.encode(value, forKey: codingKey)
            }
        }
    }
}

struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

extension AnyCodable.AnySendable {
    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

// MARK: - Collection Types
public struct CollectionField: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var type: String
    public var system: Bool
    public var hidden: Bool
    public var presentable: Bool

    public init(id: String = "", name: String = "", type: String = "", system: Bool = false, hidden: Bool = false, presentable: Bool = false) {
        self.id = id
        self.name = name
        self.type = type
        self.system = system
        self.hidden = hidden
        self.presentable = presentable
    }
}

public struct TokenConfig: Codable, Equatable, Sendable {
    public var duration: Int
    public var secret: String?

    public init(duration: Int = 0, secret: String? = nil) {
        self.duration = duration
        self.secret = secret
    }
}

public struct EmailTemplate: Codable, Equatable, Sendable {
    public var subject: String
    public var body: String

    public init(subject: String = "", body: String = "") {
        self.subject = subject
        self.body = body
    }
}

public struct AuthAlertConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var emailTemplate: EmailTemplate

    public init(enabled: Bool = false, emailTemplate: EmailTemplate = EmailTemplate()) {
        self.enabled = enabled
        self.emailTemplate = emailTemplate
    }
}

public struct OTPConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var duration: Int
    public var length: Int
    public var emailTemplate: EmailTemplate

    public init(enabled: Bool = false, duration: Int = 0, length: Int = 0, emailTemplate: EmailTemplate = EmailTemplate()) {
        self.enabled = enabled
        self.duration = duration
        self.length = length
        self.emailTemplate = emailTemplate
    }
}

public struct MFAConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var duration: Int
    public var rule: String

    public init(enabled: Bool = false, duration: Int = 0, rule: String = "") {
        self.enabled = enabled
        self.duration = duration
        self.rule = rule
    }
}

public struct PasswordAuthConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var identityFields: [String]

    public init(enabled: Bool = false, identityFields: [String] = []) {
        self.enabled = enabled
        self.identityFields = identityFields
    }
}

public struct OAuth2Provider: Codable, Equatable, Sendable {
    public var pkce: Bool?
    public var clientId: String
    public var name: String
    public var clientSecret: String
    public var authURL: String
    public var tokenURL: String
    public var userInfoURL: String
    public var displayName: String
    public var logo: String
    public var extra: [String: AnyCodable]?

    public init(
        pkce: Bool? = nil,
        clientId: String = "",
        name: String = "",
        clientSecret: String = "",
        authURL: String = "",
        tokenURL: String = "",
        userInfoURL: String = "",
        displayName: String = "",
        logo: String = "",
        extra: [String: AnyCodable]? = nil
    ) {
        self.pkce = pkce
        self.clientId = clientId
        self.name = name
        self.clientSecret = clientSecret
        self.authURL = authURL
        self.tokenURL = tokenURL
        self.userInfoURL = userInfoURL
        self.displayName = displayName
        self.logo = logo
        self.extra = extra
    }
}

public struct ConfigurableOAuth2Provider: Codable, Equatable, Sendable {
    public var name: String
    public var displayName: String
    public var logo: String

    public init(name: String = "", displayName: String = "", logo: String = "") {
        self.name = name
        self.displayName = displayName
        self.logo = logo
    }
}

public struct OAuth2Config: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var mappedFields: [String: String]
    public var providers: [OAuth2Provider]

    public init(enabled: Bool = false, mappedFields: [String: String] = [:], providers: [OAuth2Provider] = []) {
        self.enabled = enabled
        self.mappedFields = mappedFields
        self.providers = providers
    }
}

public struct CollectionModel: BaseModel, Equatable, Sendable {
    public var id: String
    public var name: String
    public var type: String // "base", "view", "auth"
    public var fields: [CollectionField]
    public var indexes: [String]
    public var system: Bool
    public var listRule: String?
    public var viewRule: String?
    public var createRule: String?
    public var updateRule: String?
    public var deleteRule: String?
    public var viewQuery: String?

    // Auth collection specific properties
    public var authRule: String?
    public var manageRule: String?
    public var authAlert: AuthAlertConfig?
    public var oauth2: OAuth2Config?
    public var passwordAuth: PasswordAuthConfig?
    public var mfa: MFAConfig?
    public var otp: OTPConfig?

    public var authToken: TokenConfig?
    public var passwordResetToken: TokenConfig?
    public var emailChangeToken: TokenConfig?
    public var verificationToken: TokenConfig?
    public var fileToken: TokenConfig?

    public var verificationTemplate: EmailTemplate?
    public var resetPasswordTemplate: EmailTemplate?
    public var confirmEmailChangeTemplate: EmailTemplate?

    public init(
        id: String = "",
        name: String = "",
        type: String = "base",
        fields: [CollectionField] = [],
        indexes: [String] = [],
        system: Bool = false,
        listRule: String? = nil,
        viewRule: String? = nil,
        createRule: String? = nil,
        updateRule: String? = nil,
        deleteRule: String? = nil,
        viewQuery: String? = nil,
        authRule: String? = nil,
        manageRule: String? = nil,
        authAlert: AuthAlertConfig? = nil,
        oauth2: OAuth2Config? = nil,
        passwordAuth: PasswordAuthConfig? = nil,
        mfa: MFAConfig? = nil,
        otp: OTPConfig? = nil,
        authToken: TokenConfig? = nil,
        passwordResetToken: TokenConfig? = nil,
        emailChangeToken: TokenConfig? = nil,
        verificationToken: TokenConfig? = nil,
        fileToken: TokenConfig? = nil,
        verificationTemplate: EmailTemplate? = nil,
        resetPasswordTemplate: EmailTemplate? = nil,
        confirmEmailChangeTemplate: EmailTemplate? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.fields = fields
        self.indexes = indexes
        self.system = system
        self.listRule = listRule
        self.viewRule = viewRule
        self.createRule = createRule
        self.updateRule = updateRule
        self.deleteRule = deleteRule
        self.viewQuery = viewQuery
        self.authRule = authRule
        self.manageRule = manageRule
        self.authAlert = authAlert
        self.oauth2 = oauth2
        self.passwordAuth = passwordAuth
        self.mfa = mfa
        self.otp = otp
        self.authToken = authToken
        self.passwordResetToken = passwordResetToken
        self.emailChangeToken = emailChangeToken
        self.verificationToken = verificationToken
        self.fileToken = fileToken
        self.verificationTemplate = verificationTemplate
        self.resetPasswordTemplate = resetPasswordTemplate
        self.confirmEmailChangeTemplate = confirmEmailChangeTemplate
    }
}

// MARK: - Additional Service Response DTOs
public struct HourlyStats: Codable, Equatable, Sendable {
    public var total: Int
    public var date: String

    public init(total: Int = 0, date: String = "") {
        self.total = total
        self.date = date
    }
}

public struct BackupFileInfo: Codable, Equatable, Sendable {
    public var key: String
    public var size: Int64
    public var modified: String

    public init(key: String = "", size: Int64 = 0, modified: String = "") {
        self.key = key
        self.size = size
        self.modified = modified
    }
}

public struct CronJob: Codable, Equatable, Sendable {
    public var id: String
    public var expression: String

    public init(id: String = "", expression: String = "") {
        self.id = id
        self.expression = expression
    }
}

public struct SQLColumn: Codable, Equatable, Sendable {
    public var name: String
    public var type: String
    public var nullable: Bool

    public init(name: String = "", type: String = "", nullable: Bool = false) {
        self.name = name
        self.type = type
        self.nullable = nullable
    }
}

public struct SQLResult: Codable, Equatable, Sendable {
    public var execTime: Double
    public var affectedRows: Int
    public var columns: [SQLColumn]
    public var rows: [[String?]]

    public init(execTime: Double = 0, affectedRows: Int = 0, columns: [SQLColumn] = [], rows: [[String?]] = []) {
        self.execTime = execTime
        self.affectedRows = affectedRows
        self.columns = columns
        self.rows = rows
    }
}

public struct HealthCheckResponse: Codable, Equatable, Sendable {
    public var code: Int
    public var message: String
    public var data: [String: AnyCodable]

    public init(code: Int = 200, message: String = "", data: [String: AnyCodable] = [:]) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public struct RecordAuthResponse<T: Codable & Sendable>: Codable, Sendable {
    public var record: T
    public var token: String
    public var meta: [String: AnyCodable]?

    public init(record: T, token: String, meta: [String: AnyCodable]? = nil) {
        self.record = record
        self.token = token
        self.meta = meta
    }
}

public struct AuthProviderInfo: Codable, Equatable, Sendable {
    public var name: String
    public var displayName: String
    public var state: String
    public var authURL: String
    public var codeVerifier: String
    public var codeChallenge: String
    public var codeChallengeMethod: String

    public init(
        name: String = "",
        displayName: String = "",
        state: String = "",
        authURL: String = "",
        codeVerifier: String = "",
        codeChallenge: String = "",
        codeChallengeMethod: String = ""
    ) {
        self.name = name
        self.displayName = displayName
        self.state = state
        self.authURL = authURL
        self.codeVerifier = codeVerifier
        self.codeChallenge = codeChallenge
        self.codeChallengeMethod = codeChallengeMethod
    }
}

public struct MFAAuthMethod: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var duration: Int

    public init(enabled: Bool = false, duration: Int = 0) {
        self.enabled = enabled
        self.duration = duration
    }
}

public struct OTPAuthMethod: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var duration: Int

    public init(enabled: Bool = false, duration: Int = 0) {
        self.enabled = enabled
        self.duration = duration
    }
}

public struct PasswordAuthMethod: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var identityFields: [String]

    public init(enabled: Bool = false, identityFields: [String] = []) {
        self.enabled = enabled
        self.identityFields = identityFields
    }
}

public struct OAuth2AuthMethod: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var providers: [AuthProviderInfo]

    public init(enabled: Bool = false, providers: [AuthProviderInfo] = []) {
        self.enabled = enabled
        self.providers = providers
    }
}

public struct AuthMethodsList: Codable, Equatable, Sendable {
    public var mfa: MFAAuthMethod
    public var otp: OTPAuthMethod
    public var password: PasswordAuthMethod
    public var oauth2: OAuth2AuthMethod

    public init(
        mfa: MFAAuthMethod = MFAAuthMethod(),
        otp: OTPAuthMethod = OTPAuthMethod(),
        password: PasswordAuthMethod = PasswordAuthMethod(),
        oauth2: OAuth2AuthMethod = OAuth2AuthMethod()
    ) {
        self.mfa = mfa
        self.otp = otp
        self.password = password
        self.oauth2 = oauth2
    }
}

public struct RecordSubscription<T: Codable & Sendable>: Codable, Sendable {
    public var action: String // eg. "create", "update", "delete"
    public var record: T

    public init(action: String, record: T) {
        self.action = action
        self.record = record
    }
}

public struct OTPResponse: Codable, Equatable, Sendable {
    public var otpId: String

    public init(otpId: String = "") {
        self.otpId = otpId
    }
}

public struct BatchRequest: Codable, Equatable, Sendable {
    public var method: String
    public var url: String
    public var json: [String: AnyCodable]?
    public var files: [String: [FileParam]]?
    public var headers: [String: String]?

    public init(method: String, url: String, json: [String: AnyCodable]? = nil, files: [String: [FileParam]]? = nil, headers: [String: String]? = nil) {
        self.method = method
        self.url = url
        self.json = json
        self.files = files
        self.headers = headers
    }
}

public struct BatchRequestResult: Codable, Equatable, Sendable {
    public var status: Int
    public var body: AnyCodable

    public init(status: Int, body: AnyCodable) {
        self.status = status
        self.body = body
    }
}
