import Testing
import Foundation
@testable import pocketbase

/// Decodes a DTO from a JSON fixture.
private func decodeDTO<T: Decodable>(_ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

/// Encodes and decodes a DTO again, checking JSON round-trip stability.
private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(T.self, from: data)
}

struct DTOTests {
    // MARK: - ListResult

    @Test func listResultKeepsLocalDefaultsAndDecodedValues() throws {
        let empty = ListResult<RecordModel>()
        #expect(empty.page == 1)
        #expect(empty.perPage == 30)
        #expect(empty.totalItems == 0)
        #expect(empty.totalPages == 0)
        #expect(empty.items.isEmpty)

        let decoded: ListResult<RecordModel> = try decodeDTO(#"""
        {"page":3,"perPage":50,"totalItems":120,"totalPages":3,"items":[
            {"id":"rec1","collectionId":"c1","collectionName":"posts"}
        ]}
        """#)
        #expect(decoded.page == 3)
        #expect(decoded.perPage == 50)
        #expect(decoded.totalItems == 120)
        #expect(decoded.totalPages == 3)
        #expect(decoded.items.count == 1)
        #expect(decoded.items.first?.id == "rec1")
        #expect(try roundTrip(decoded) == decoded)
    }

    // MARK: - RecordModel

    @Test func recordModelSplitsSystemAndDynamicFields() throws {
        let record: RecordModel = try decodeDTO(#"""
        {
            "id":"r1",
            "collectionId":"c1",
            "collectionName":"posts",
            "created":"2026-01-01 00:00:00.000Z",
            "updated":"2026-01-02 00:00:00.000Z",
            "title":"Hello",
            "views":42,
            "tags":["a","b"],
            "draft":false,
            "note":null,
            "expand":{"author":{"id":"u1"}}
        }
        """#)

        #expect(record.id == "r1")
        #expect(record.collectionId == "c1")
        #expect(record.collectionName == "posts")
        #expect(record.created == "2026-01-01 00:00:00.000Z")
        #expect(record.updated == "2026-01-02 00:00:00.000Z")
        #expect(record.expand?["author"]?.dictionaryValue?["id"]?.stringValue == "u1")

        #expect(record.rawFields["title"]?.stringValue == "Hello")
        #expect(record.rawFields["views"]?.intValue == 42)
        #expect(record.rawFields["tags"]?.arrayValue?.map(\.stringValue) == ["a", "b"])
        #expect(record["draft"]?.boolValue == false)
        #expect(record["note"]?.value == .null)
        #expect(record["id"]?.stringValue == "r1")
        #expect(try roundTrip(record) == record)
    }

    @Test func recordModelSubscriptUpdatesDynamicFields() throws {
        var record: RecordModel = try decodeDTO(#"{"id":"r1","title":"Hello","views":42}"#)

        record["title"] = AnyCodable("Updated")
        #expect(record["title"]?.stringValue == "Updated")
        #expect(record.rawFields["title"]?.stringValue == "Updated")

        record["views"] = nil
        #expect(record["views"] == nil)
        #expect(record.rawFields["views"] == nil)

        record["extra"] = AnyCodable(["nested": [1, 2]])
        #expect(try roundTrip(record) == record)
    }

    // MARK: - CollectionModel

    @Test func collectionModelBaseRoundTrip() throws {
        let collection: CollectionModel = try decodeDTO(#"""
        {
            "id":"c1","name":"posts","type":"base","system":false,
            "listRule":"","viewRule":null,"createRule":"","updateRule":"","deleteRule":"",
            "indexes":["CREATE INDEX idx_posts_title ON posts (title)"],
            "fields":[{"id":"f1","name":"title","type":"text","system":false,"hidden":false,"presentable":true}]
        }
        """#)

        #expect(collection.collectionType == .base)
        #expect(collection.viewQuery == nil)
        #expect(collection.authRule == nil)
        #expect(collection.oauth2 == nil)
        #expect(collection.listRule == "")
        #expect(collection.viewRule == nil)
        #expect(collection.fields.first?.name == "title")
        #expect(collection.indexes.count == 1)
        #expect(try roundTrip(collection) == collection)
    }

    @Test func collectionModelViewRoundTrip() throws {
        let collection: CollectionModel = try decodeDTO(#"""
        {
            "id":"c2","name":"recent_posts","type":"view","system":false,
            "listRule":null,"viewRule":null,"createRule":null,"updateRule":null,"deleteRule":null,
            "indexes":[],"fields":[],
            "viewQuery":"SELECT id, title FROM posts"
        }
        """#)

        #expect(collection.collectionType == .view)
        #expect(collection.viewQuery == "SELECT id, title FROM posts")
        #expect(collection.passwordAuth == nil)
        #expect(try roundTrip(collection) == collection)
    }

    @Test func collectionModelAuthRoundTrip() throws {
        let collection: CollectionModel = try decodeDTO(#"""
        {
            "id":"c3","name":"users","type":"auth","system":false,
            "listRule":"id != ''","viewRule":null,"createRule":"","updateRule":"id = @request.auth.id","deleteRule":null,
            "indexes":[],"fields":[],
            "authRule":"","manageRule":null,
            "authAlert":{"enabled":true,"emailTemplate":{"subject":"Alert","body":"New login"}},
            "oauth2":{
                "enabled":true,
                "mappedFields":{"name":"name"},
                "providers":[{
                    "pkce":true,"clientId":"client","name":"google","clientSecret":"secret",
                    "authURL":"https://accounts.google.com/o/oauth2/auth",
                    "tokenURL":"https://oauth2.googleapis.com/token",
                    "userInfoURL":"https://openidconnect.googleapis.com/v1/userinfo",
                    "displayName":"Google","logo":"google.png","extra":{"tenant":"t1"}
                }]
            },
            "passwordAuth":{"enabled":true,"identityFields":["email","username"]},
            "mfa":{"enabled":false,"duration":600,"rule":""},
            "otp":{"enabled":true,"duration":300,"length":6,"emailTemplate":{"subject":"OTP","body":"Your code"}},
            "authToken":{"duration":1209600,"secret":""},
            "passwordResetToken":{"duration":1800},
            "emailChangeToken":{"duration":1800},
            "verificationToken":{"duration":1800},
            "fileToken":{"duration":180},
            "verificationTemplate":{"subject":"Verify","body":"Verify your email"},
            "resetPasswordTemplate":{"subject":"Reset","body":"Reset your password"},
            "confirmEmailChangeTemplate":{"subject":"Confirm","body":"Confirm the new email"}
        }
        """#)

        #expect(collection.collectionType == .auth)
        #expect(collection.authRule == "")
        #expect(collection.manageRule == nil)
        #expect(collection.authAlert?.enabled == true)
        #expect(collection.oauth2?.providers.count == 1)
        #expect(collection.oauth2?.providers.first?.pkce == true)
        #expect(collection.oauth2?.providers.first?.extra?["tenant"]?.stringValue == "t1")
        #expect(collection.passwordAuth?.identityFields == ["email", "username"])
        #expect(collection.mfa?.duration == 600)
        #expect(collection.otp?.length == 6)
        #expect(collection.authToken?.duration == 1209600)
        #expect(collection.passwordResetToken?.secret == nil)
        #expect(collection.verificationTemplate?.subject == "Verify")
        #expect(try roundTrip(collection) == collection)
    }

    @Test func unknownCollectionTypeKeepsTheRawString() throws {
        let collection: CollectionModel = try decodeDTO(#"""
        {"id":"c4","name":"future","type":"newkind","system":false,"indexes":[],"fields":[]}
        """#)

        #expect(collection.collectionType == nil)
        #expect(collection.type == "newkind")
        #expect(try roundTrip(collection) == collection)
    }

    // MARK: - Configuration DTOs

    @Test func configurationDTOsRoundTrip() throws {
        let field = CollectionField(id: "f1", name: "title", type: "text", system: true, hidden: false, presentable: true)
        let token = TokenConfig(duration: 1800, secret: "s3cret")
        let template = EmailTemplate(subject: "Subject", body: "Body")
        let authAlert = AuthAlertConfig(enabled: true, emailTemplate: template)
        let otp = OTPConfig(enabled: true, duration: 300, length: 6, emailTemplate: template)
        let mfa = MFAConfig(enabled: true, duration: 600, rule: "true")
        let password = PasswordAuthConfig(enabled: true, identityFields: ["email"])
        let provider = OAuth2Provider(
            pkce: true,
            clientId: "client",
            name: "google",
            clientSecret: "secret",
            authURL: "https://auth",
            tokenURL: "https://token",
            userInfoURL: "https://userinfo",
            displayName: "Google",
            logo: "google.png",
            extra: ["tenant": "t1"]
        )
        let configurable = ConfigurableOAuth2Provider(name: "github", displayName: "GitHub", logo: "github.png")
        let oauth2 = OAuth2Config(enabled: true, mappedFields: ["name": "name"], providers: [provider])

        #expect(try roundTrip(field) == field)
        #expect(try roundTrip(token) == token)
        #expect(try roundTrip(template) == template)
        #expect(try roundTrip(authAlert) == authAlert)
        #expect(try roundTrip(otp) == otp)
        #expect(try roundTrip(mfa) == mfa)
        #expect(try roundTrip(password) == password)
        #expect(try roundTrip(provider) == provider)
        #expect(try roundTrip(configurable) == configurable)
        #expect(try roundTrip(oauth2) == oauth2)
    }

    // MARK: - Service response DTOs

    @Test func logAndStatsDTOsRoundTrip() throws {
        let log = LogModel(
            id: "log1",
            level: "error",
            message: "Something failed",
            created: "2026-01-01 00:00:00.000Z",
            updated: "2026-01-01 00:00:00.000Z",
            data: ["error": "boom", "attempts": 3]
        )
        let stats = HourlyStats(total: 12, date: "2026-01-01 00:00:00.000Z")
        let backup = BackupFileInfo(key: "backup.zip", size: 1024, modified: "2026-01-01 00:00:00.000Z")
        let cron = CronJob(id: "cron1", expression: "0 * * * *")

        #expect(try roundTrip(log) == log)
        #expect(try roundTrip(stats) == stats)
        #expect(try roundTrip(backup) == backup)
        #expect(try roundTrip(cron) == cron)
    }

    @Test func sqlResultDecodesNullableStringCells() throws {
        let result: SQLResult = try decodeDTO(#"""
        {
            "execTime":1.5,
            "affectedRows":0,
            "columns":[
                {"name":"id","type":"TEXT","nullable":false},
                {"name":"views","type":"INTEGER","nullable":true}
            ],
            "rows":[["r1","42"],["r2",null],[]]
        }
        """#)

        #expect(result.execTime == 1.5)
        #expect(result.affectedRows == 0)
        #expect(result.columns.map(\.name) == ["id", "views"])
        #expect(result.columns.last?.nullable == true)
        #expect(result.rows.count == 3)
        #expect(result.rows[0] == ["r1", "42"])
        #expect(result.rows[1][0] == "r2")
        #expect(result.rows[1][1] == nil)
        #expect(result.rows[2].isEmpty)
        #expect(try roundTrip(result) == result)
    }

    @Test func healthCheckResponseRoundTrip() throws {
        let response = HealthCheckResponse(code: 200, message: "API is healthy", data: ["db": true, "uptime": 12.5])
        #expect(try roundTrip(response) == response)
    }

    // MARK: - Auth DTOs

    @Test func authMethodDTOsRoundTrip() throws {
        let provider = AuthProviderInfo(
            name: "google",
            displayName: "Google",
            state: "state",
            authURL: "https://auth",
            codeVerifier: "verifier",
            codeChallenge: "challenge",
            codeChallengeMethod: "S256"
        )
        let methods = AuthMethodsList(
            mfa: MFAAuthMethod(enabled: true, duration: 600),
            otp: OTPAuthMethod(enabled: false, duration: 0),
            password: PasswordAuthMethod(enabled: true, identityFields: ["email"]),
            oauth2: OAuth2AuthMethod(enabled: true, providers: [provider])
        )

        #expect(try roundTrip(provider) == provider)
        #expect(try roundTrip(methods) == methods)
        #expect(try roundTrip(OTPResponse(otpId: "otp1")) == OTPResponse(otpId: "otp1"))
    }

    @Test func recordAuthResponseAndSubscriptionRoundTrip() throws {
        let record = RecordModel(
            id: "r1",
            collectionId: "c1",
            collectionName: "users",
            created: "2026-01-01 00:00:00.000Z",
            updated: "2026-01-01 00:00:00.000Z",
            expand: nil,
            rawFields: ["email": "user@example.com"]
        )
        let response = RecordAuthResponse(record: record, token: "token", meta: ["verified": true])
        let subscription = RecordSubscription(action: "create", record: record)

        #expect(try roundTrip(response) == response)
        #expect(try roundTrip(subscription) == subscription)
    }

    // MARK: - Batch DTOs

    @Test func batchDTOsRoundTrip() throws {
        let request = BatchRequest(
            method: "POST",
            url: "/api/collections/posts/records",
            json: ["title": AnyCodable("Hello"), "views": AnyCodable(3)],
            files: ["attachments": [FileParam(filename: "a.txt", mimeType: "text/plain", data: Data("A".utf8))]],
            headers: ["X-Test": "1"]
        )
        let result = BatchRequestResult(status: 200, body: AnyCodable(["id": "rec1"]))

        #expect(try roundTrip(request) == request)
        #expect(try roundTrip(result) == result)
        #expect(try roundTrip(BatchRequest(method: "DELETE", url: "/api/collections/posts/records/1")) != request)
    }
}
