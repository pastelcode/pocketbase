import Foundation

// MARK: - ListResult
/// A paginated list response returned by list endpoints.
public struct ListResult<T: Codable & Sendable>: Codable, Sendable {
    /// The requested page number, starting at 1.
    public var page: Int
    /// Maximum number of items returned per page.
    public var perPage: Int
    /// Total number of items matching the query.
    public var totalItems: Int
    /// Total number of pages available.
    public var totalPages: Int
    /// Items in the current page.
    public var items: [T]

    /// Creates a list result with the given pagination metadata.
    public init(page: Int = 1, perPage: Int = 30, totalItems: Int = 0, totalPages: Int = 0, items: [T] = []) {
        self.page = page
        self.perPage = perPage
        self.totalItems = totalItems
        self.totalPages = totalPages
        self.items = items
    }
}

// MARK: - BaseModel Protocol
/// Common interface for models that are identified by an `id`.
public protocol BaseModel: Codable, Sendable {
    /// Unique identifier of the model.
    var id: String { get set }
}

// MARK: - LogModel
/// A single entry returned by the logs service.
public struct LogModel: BaseModel, Equatable, Sendable {
    /// Unique identifier of the log entry.
    public var id: String
    /// Severity level, such as `info`, `warn` or `error`.
    public var level: String
    /// Human-readable log message.
    public var message: String
    /// Creation date as an ISO 8601 string.
    public var created: String
    /// Last update date as an ISO 8601 string.
    public var updated: String
    /// Arbitrary structured data attached to the entry.
    public var data: [String: AnyCodable]

    /// Creates a log entry with the given values.
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
/// A single record from a collection.
///
/// Known system fields are exposed as typed properties, while all other
/// collection fields are stored in ``rawFields`` and can be accessed through
/// the subscript.
public struct RecordModel: BaseModel, Equatable, Sendable {
    /// Unique identifier of the record.
    public var id: String
    /// Identifier of the collection the record belongs to.
    public var collectionId: String
    /// Name of the collection the record belongs to.
    public var collectionName: String
    /// Creation timestamp in ISO 8601 format, or `nil` when absent.
    public var created: String?
    /// Last update timestamp in ISO 8601 format, or `nil` when absent.
    public var updated: String?
    /// Expanded relation data keyed by relation field name, or `nil` when not requested.
    public var expand: [String: AnyCodable]?
    /// Values of the collection's custom fields.
    public var rawFields: [String: AnyCodable]

    /// Creates a record with the given system fields and dynamic values.
    ///
    /// - Parameter id: Unique identifier of the record.
    /// - Parameter collectionId: Identifier of the collection the record belongs to.
    /// - Parameter collectionName: Name of the collection the record belongs to.
    /// - Parameter created: Creation timestamp in ISO 8601 format.
    /// - Parameter updated: Last update timestamp in ISO 8601 format.
    /// - Parameter expand: Expanded relation data keyed by relation field name.
    /// - Parameter rawFields: Values of the collection's custom fields.
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

    /// Accesses a record field by name.
    ///
    /// Known system fields map to their typed properties; any other key reads
    /// from and writes to ``rawFields``.
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

    /// Decodes a record, separating system fields from dynamic collection fields.
    ///
    /// Unknown keys are collected into ``rawFields``.
    ///
    /// - Throws: An error if a decoding container cannot be opened.
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

    /// Encodes the system fields together with the dynamic fields in ``rawFields``.
    ///
    /// - Throws: An error if a dynamic value cannot be encoded.
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
    /// Returns the wrapped string when the value is a string, otherwise `nil`.
    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

// MARK: - Collection Types
/// A single field definition of a collection.
public struct CollectionField: Codable, Equatable, Sendable {
    /// Identifier of the field.
    public var id: String
    /// Name of the field, used as the key in record data.
    public var name: String
    /// Field type, such as `text`, `number` or `relation`.
    public var type: String
    /// Whether the field is a built-in system field.
    public var system: Bool
    /// Whether the field is hidden from API responses.
    public var hidden: Bool
    /// Whether the field can be used as a presentable column.
    public var presentable: Bool

    /// Creates a field definition with the given values.
    public init(id: String = "", name: String = "", type: String = "", system: Bool = false, hidden: Bool = false, presentable: Bool = false) {
        self.id = id
        self.name = name
        self.type = type
        self.system = system
        self.hidden = hidden
        self.presentable = presentable
    }
}

/// Configuration of a token issued by an auth collection.
public struct TokenConfig: Codable, Equatable, Sendable {
    /// Token lifetime in seconds.
    public var duration: Int
    /// Optional custom signing secret.
    public var secret: String?

    /// Creates a token configuration with the given values.
    public init(duration: Int = 0, secret: String? = nil) {
        self.duration = duration
        self.secret = secret
    }
}

/// Subject and body of an email template.
public struct EmailTemplate: Codable, Equatable, Sendable {
    /// Subject line of the email.
    public var subject: String
    /// Body of the email.
    public var body: String

    /// Creates an email template with the given values.
    public init(subject: String = "", body: String = "") {
        self.subject = subject
        self.body = body
    }
}

/// Configuration of the auth alert email sent on suspicious sign-ins.
public struct AuthAlertConfig: Codable, Equatable, Sendable {
    /// Whether auth alert emails are enabled.
    public var enabled: Bool
    /// Template used to render the alert email.
    public var emailTemplate: EmailTemplate

    /// Creates an auth alert configuration with the given values.
    public init(enabled: Bool = false, emailTemplate: EmailTemplate = EmailTemplate()) {
        self.enabled = enabled
        self.emailTemplate = emailTemplate
    }
}

/// Configuration of one-time password (OTP) authentication.
public struct OTPConfig: Codable, Equatable, Sendable {
    /// Whether OTP authentication is enabled.
    public var enabled: Bool
    /// Lifetime of a generated OTP in seconds.
    public var duration: Int
    /// Number of digits in a generated OTP.
    public var length: Int
    /// Template used to send the OTP email.
    public var emailTemplate: EmailTemplate

    /// Creates an OTP configuration with the given values.
    public init(enabled: Bool = false, duration: Int = 0, length: Int = 0, emailTemplate: EmailTemplate = EmailTemplate()) {
        self.enabled = enabled
        self.duration = duration
        self.length = length
        self.emailTemplate = emailTemplate
    }
}

/// Configuration of multi-factor authentication (MFA).
public struct MFAConfig: Codable, Equatable, Sendable {
    /// Whether MFA is enabled.
    public var enabled: Bool
    /// Lifetime of the MFA state in seconds.
    public var duration: Int
    /// Rule expression that determines when MFA is required.
    public var rule: String

    /// Creates an MFA configuration with the given values.
    public init(enabled: Bool = false, duration: Int = 0, rule: String = "") {
        self.enabled = enabled
        self.duration = duration
        self.rule = rule
    }
}

/// Configuration of password-based authentication.
public struct PasswordAuthConfig: Codable, Equatable, Sendable {
    /// Whether password authentication is enabled.
    public var enabled: Bool
    /// Fields accepted as the login identity, such as `email`.
    public var identityFields: [String]

    /// Creates a password auth configuration with the given values.
    public init(enabled: Bool = false, identityFields: [String] = []) {
        self.enabled = enabled
        self.identityFields = identityFields
    }
}

/// Configuration of a single OAuth2 provider.
public struct OAuth2Provider: Codable, Equatable, Sendable {
    /// Whether PKCE is enabled for providers that support it.
    public var pkce: Bool?
    /// OAuth2 client ID.
    public var clientId: String
    /// Provider name, such as `google` or `github`.
    public var name: String
    /// OAuth2 client secret.
    public var clientSecret: String
    /// Authorization endpoint URL.
    public var authURL: String
    /// Token endpoint URL.
    public var tokenURL: String
    /// User info endpoint URL.
    public var userInfoURL: String
    /// Human-readable provider name.
    public var displayName: String
    /// Name of the provider logo file.
    public var logo: String
    /// Additional provider-specific configuration values.
    public var extra: [String: AnyCodable]?

    /// Creates an OAuth2 provider configuration with the given values.
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

/// A built-in OAuth2 provider that can be enabled for auth collections.
public struct ConfigurableOAuth2Provider: Codable, Equatable, Sendable {
    /// Provider name, such as `google` or `github`.
    public var name: String
    /// Human-readable provider name.
    public var displayName: String
    /// Name of the provider logo file.
    public var logo: String

    /// Creates a provider description with the given values.
    public init(name: String = "", displayName: String = "", logo: String = "") {
        self.name = name
        self.displayName = displayName
        self.logo = logo
    }
}

/// Configuration of OAuth2 authentication for an auth collection.
public struct OAuth2Config: Codable, Equatable, Sendable {
    /// Whether OAuth2 authentication is enabled.
    public var enabled: Bool
    /// Mapping of provider user fields to collection field names.
    public var mappedFields: [String: String]
    /// Providers enabled for the collection.
    public var providers: [OAuth2Provider]

    /// Creates an OAuth2 configuration with the given values.
    public init(enabled: Bool = false, mappedFields: [String: String] = [:], providers: [OAuth2Provider] = []) {
        self.enabled = enabled
        self.mappedFields = mappedFields
        self.providers = providers
    }
}

/// A collection definition.
///
/// Flattens the base, view and auth collection models of the reference SDK;
/// the ``type`` property determines which optional fields are populated.
public struct CollectionModel: BaseModel, Equatable, Sendable {
    /// Unique identifier of the collection.
    public var id: String
    /// Name of the collection.
    public var name: String
    /// Collection type: `base`, `view` or `auth`.
    public var type: String // "base", "view", "auth"
    /// Field definitions of the collection.
    public var fields: [CollectionField]
    /// Index definitions as raw SQL strings.
    public var indexes: [String]
    /// Whether the collection is a built-in system collection.
    public var system: Bool
    /// API rule for listing records (`nil` means superusers only).
    public var listRule: String?
    /// API rule for viewing a record (`nil` means superusers only).
    public var viewRule: String?
    /// API rule for creating records (`nil` means superusers only).
    public var createRule: String?
    /// API rule for updating records (`nil` means superusers only).
    public var updateRule: String?
    /// API rule for deleting records (`nil` means superusers only).
    public var deleteRule: String?
    /// Query used by `view` collections to select records.
    public var viewQuery: String?

    // Auth collection specific properties
    /// API rule for authenticating as a record (`nil` means superusers only).
    public var authRule: String?
    /// API rule for managing other records (`nil` means superusers only).
    public var manageRule: String?
    /// Auth alert email configuration.
    public var authAlert: AuthAlertConfig?
    /// OAuth2 authentication configuration.
    public var oauth2: OAuth2Config?
    /// Password authentication configuration.
    public var passwordAuth: PasswordAuthConfig?
    /// Multi-factor authentication configuration.
    public var mfa: MFAConfig?
    /// One-time password authentication configuration.
    public var otp: OTPConfig?

    /// Configuration of the auth token issued on sign-in.
    public var authToken: TokenConfig?
    /// Configuration of the password reset token.
    public var passwordResetToken: TokenConfig?
    /// Configuration of the email change token.
    public var emailChangeToken: TokenConfig?
    /// Configuration of the email verification token.
    public var verificationToken: TokenConfig?
    /// Configuration of the protected file access token.
    public var fileToken: TokenConfig?

    /// Email template for address verification.
    public var verificationTemplate: EmailTemplate?
    /// Email template for password reset.
    public var resetPasswordTemplate: EmailTemplate?
    /// Email template for email change confirmation.
    public var confirmEmailChangeTemplate: EmailTemplate?

    /// Creates a collection definition with the given values.
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
/// Aggregated request counts for a single hour.
public struct HourlyStats: Codable, Equatable, Sendable {
    /// Number of requests recorded in the hour.
    public var total: Int
    /// Hour bucket as a date string.
    public var date: String

    /// Creates an hourly stats entry with the given values.
    public init(total: Int = 0, date: String = "") {
        self.total = total
        self.date = date
    }
}

/// Metadata of a single backup file.
public struct BackupFileInfo: Codable, Equatable, Sendable {
    /// Storage key of the backup file.
    public var key: String
    /// File size in bytes.
    public var size: Int64
    /// Last modification date as a string.
    public var modified: String

    /// Creates backup file metadata with the given values.
    public init(key: String = "", size: Int64 = 0, modified: String = "") {
        self.key = key
        self.size = size
        self.modified = modified
    }
}

/// A registered cron job.
public struct CronJob: Codable, Equatable, Sendable {
    /// Identifier of the cron job.
    public var id: String
    /// Cron expression that schedules the job.
    public var expression: String

    /// Creates a cron job description with the given values.
    public init(id: String = "", expression: String = "") {
        self.id = id
        self.expression = expression
    }
}

/// A single column in an SQL query result.
public struct SQLColumn: Codable, Equatable, Sendable {
    /// Column name.
    public var name: String
    /// Column type as reported by the database.
    public var type: String
    /// Whether the column accepts `NULL` values.
    public var nullable: Bool

    /// Creates a column description with the given values.
    public init(name: String = "", type: String = "", nullable: Bool = false) {
        self.name = name
        self.type = type
        self.nullable = nullable
    }
}

/// Result of an SQL query executed through the SQL service.
public struct SQLResult: Codable, Equatable, Sendable {
    /// Query execution time in milliseconds.
    public var execTime: Double
    /// Number of rows affected by the statement.
    public var affectedRows: Int
    /// Columns returned by the query.
    public var columns: [SQLColumn]
    /// Rows returned by the query, aligned with ``columns``.
    public var rows: [[String?]]

    /// Creates an SQL result with the given values.
    public init(execTime: Double = 0, affectedRows: Int = 0, columns: [SQLColumn] = [], rows: [[String?]] = []) {
        self.execTime = execTime
        self.affectedRows = affectedRows
        self.columns = columns
        self.rows = rows
    }
}

/// Response returned by the health check endpoint.
public struct HealthCheckResponse: Codable, Equatable, Sendable {
    /// HTTP-style status code, `200` when healthy.
    public var code: Int
    /// Human-readable status message.
    public var message: String
    /// Additional health details keyed by check name.
    public var data: [String: AnyCodable]

    /// Creates a health check response with the given values.
    public init(code: Int = 200, message: String = "", data: [String: AnyCodable] = [:]) {
        self.code = code
        self.message = message
        self.data = data
    }
}

/// Response returned by record authentication and refresh endpoints.
public struct RecordAuthResponse<T: Codable & Sendable>: Codable, Sendable {
    /// The authenticated record.
    public var record: T
    /// Auth token to use for subsequent requests.
    public var token: String
    /// Optional metadata returned by the auth method.
    public var meta: [String: AnyCodable]?

    /// Creates an auth response with the given values.
    public init(record: T, token: String, meta: [String: AnyCodable]? = nil) {
        self.record = record
        self.token = token
        self.meta = meta
    }
}

/// Auth provider details returned by the auth methods endpoint.
public struct AuthProviderInfo: Codable, Equatable, Sendable {
    /// Provider name, such as `google` or `github`.
    public var name: String
    /// Human-readable provider name.
    public var displayName: String
    /// OAuth2 state parameter for the authorization request.
    public var state: String
    /// Authorization endpoint URL to redirect the user to.
    public var authURL: String
    /// PKCE code verifier generated for the request.
    public var codeVerifier: String
    /// PKCE code challenge derived from ``codeVerifier``.
    public var codeChallenge: String
    /// Method used to derive ``codeChallenge``, usually `S256`.
    public var codeChallengeMethod: String

    /// Creates provider details with the given values.
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

/// MFA method availability reported by the auth methods endpoint.
public struct MFAAuthMethod: Codable, Equatable, Sendable {
    /// Whether MFA authentication is available.
    public var enabled: Bool
    /// Lifetime of the MFA state in seconds.
    public var duration: Int

    /// Creates an MFA method description with the given values.
    public init(enabled: Bool = false, duration: Int = 0) {
        self.enabled = enabled
        self.duration = duration
    }
}

/// OTP method availability reported by the auth methods endpoint.
public struct OTPAuthMethod: Codable, Equatable, Sendable {
    /// Whether OTP authentication is available.
    public var enabled: Bool
    /// Lifetime of a generated OTP in seconds.
    public var duration: Int

    /// Creates an OTP method description with the given values.
    public init(enabled: Bool = false, duration: Int = 0) {
        self.enabled = enabled
        self.duration = duration
    }
}

/// Password method availability reported by the auth methods endpoint.
public struct PasswordAuthMethod: Codable, Equatable, Sendable {
    /// Whether password authentication is available.
    public var enabled: Bool
    /// Fields accepted as the login identity.
    public var identityFields: [String]

    /// Creates a password method description with the given values.
    public init(enabled: Bool = false, identityFields: [String] = []) {
        self.enabled = enabled
        self.identityFields = identityFields
    }
}

/// OAuth2 method availability reported by the auth methods endpoint.
public struct OAuth2AuthMethod: Codable, Equatable, Sendable {
    /// Whether OAuth2 authentication is available.
    public var enabled: Bool
    /// Providers available for authentication.
    public var providers: [AuthProviderInfo]

    /// Creates an OAuth2 method description with the given values.
    public init(enabled: Bool = false, providers: [AuthProviderInfo] = []) {
        self.enabled = enabled
        self.providers = providers
    }
}

/// Auth methods supported by a collection.
public struct AuthMethodsList: Codable, Equatable, Sendable {
    /// MFA method details.
    public var mfa: MFAAuthMethod
    /// OTP method details.
    public var otp: OTPAuthMethod
    /// Password method details.
    public var password: PasswordAuthMethod
    /// OAuth2 method details.
    public var oauth2: OAuth2AuthMethod

    /// Creates an auth methods list with the given values.
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

/// A realtime record change delivered to subscribers.
public struct RecordSubscription<T: Codable & Sendable>: Codable, Sendable {
    /// Action that triggered the event, such as `create`, `update` or `delete`.
    public var action: String // eg. "create", "update", "delete"
    /// The record the event refers to.
    public var record: T

    /// Creates a subscription event with the given action and record.
    public init(action: String, record: T) {
        self.action = action
        self.record = record
    }
}

/// Response returned when an OTP is requested.
public struct OTPResponse: Codable, Equatable, Sendable {
    /// Identifier required to complete OTP authentication.
    public var otpId: String

    /// Creates an OTP response with the given identifier.
    public init(otpId: String = "") {
        self.otpId = otpId
    }
}

/// A single request inside a batch.
public struct BatchRequest: Codable, Equatable, Sendable {
    /// HTTP method of the request.
    public var method: String
    /// Request path relative to the API base URL.
    public var url: String
    /// JSON body of the request.
    ///
    /// Always serialized as the `body` field of the batch payload, even when
    /// empty.
    public var json: [String: AnyCodable]?
    /// Files to upload, keyed by field name.
    ///
    /// A key ending with `+` tells the server to append to the existing field
    /// instead of replacing it.
    public var files: [String: [FileParam]]?
    /// Additional request headers.
    public var headers: [String: String]?

    /// Creates a batch request with the given values.
    public init(method: String, url: String, json: [String: AnyCodable]? = nil, files: [String: [FileParam]]? = nil, headers: [String: String]? = nil) {
        self.method = method
        self.url = url
        self.json = json
        self.files = files
        self.headers = headers
    }
}

/// The result of a single request within a batch response.
public struct BatchRequestResult: Codable, Equatable, Sendable {
    /// HTTP status code of the response.
    public var status: Int
    /// Response body.
    public var body: AnyCodable

    /// Creates a batch request result with the given values.
    public init(status: Int, body: AnyCodable) {
        self.status = status
        self.body = body
    }
}
