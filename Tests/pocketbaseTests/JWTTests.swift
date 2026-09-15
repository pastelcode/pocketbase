import Testing
import Foundation
@testable import pocketbase

struct JWTTests {
    @Test func testGetTokenPayload() {
        let token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJ0ZXN0IjoxMjN9.da77dJt5jjPU43vaaCr6WeHEXrxzB37b0edfjwyD-2M"
        let payload = JWTUtils.getTokenPayload(token)
        #expect(payload["test"]?.intValue == 123)

        let invalidCases = ["", "abc", "a.b.c"]
        for c in invalidCases {
            let p = JWTUtils.getTokenPayload(c)
            #expect(p.isEmpty)
        }
    }

    @Test func testIsTokenExpired() {
        // Invalid JWT string
        #expect(JWTUtils.isTokenExpired("") == true)

        // Token with empty payload
        let emptyPayloadToken = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.e30.Et9HFtf9R3GEMA0IICOfFMVXY7kkTX1wr4qCyhIf58U"
        #expect(JWTUtils.isTokenExpired(emptyPayloadToken) == true)

        // Token without exp param
        let noExpToken = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJ0ZXN0IjoxMjN9.da77dJt5jjPU43vaaCr6WeHEXrxzB37b0edfjwyD-2M"
        #expect(JWTUtils.isTokenExpired(noExpToken) == false)

        // Token with exp param in the past (exp: 1624788000)
        let pastToken = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJ0ZXN0IjoxMjMsImV4cCI6MTYyNDc4ODAwMH0.WOzXh8TQh6fBXJJlOvHktBuv7D8eSyrYx4_IBj2Deyo"
        #expect(JWTUtils.isTokenExpired(pastToken) == true)

        // Token with exp param in the future (exp: 1908784800)
        let futureToken = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJ0ZXN0IjoxMjMsImV4cCI6MTkwODc4NDgwMH0.vVbRVx-Bs7pusxfU8TTTOEtNcUEYSzmJUboC68PB5iE"
        #expect(JWTUtils.isTokenExpired(futureToken) == false)
    }

    @Test func testIsTokenExpiredEdgeCases() {
        // Falsy exp values are treated as absent by the reference SDK (valid).
        #expect(JWTUtils.isTokenExpired(dummyJWT(payload: ["exp": 0])) == false)
        #expect(JWTUtils.isTokenExpired(dummyJWT(payload: ["exp": NSNull()])) == false)
        #expect(JWTUtils.isTokenExpired(dummyJWT(payload: ["exp": ""])) == false)
        #expect(JWTUtils.isTokenExpired(dummyJWT(payload: ["exp": false])) == false)

        // Non-numeric truthy exp values produce NaN comparisons (expired).
        #expect(JWTUtils.isTokenExpired(dummyJWT(payload: ["exp": "abc"])) == true)
        #expect(JWTUtils.isTokenExpired(dummyJWT(payload: ["exp": true])) == true)

        // Numeric strings are coerced like in JavaScript (valid when in the future).
        #expect(JWTUtils.isTokenExpired(dummyJWT(payload: ["exp": "9999999999"])) == false)

        // The threshold moves the expiration boundary.
        let soon = Int(Date().timeIntervalSince1970 + 60)
        #expect(JWTUtils.isTokenExpired(dummyJWT(payload: ["exp": soon])) == false)
        #expect(JWTUtils.isTokenExpired(dummyJWT(payload: ["exp": soon]), expirationThreshold: 120) == true)
    }

    @Test func testGetExpirationTimestamp() {
        #expect(JWTUtils.getExpirationTimestamp(dummyJWT(payload: ["exp": 1908784800])) == 1908784800)
        #expect(JWTUtils.getExpirationTimestamp(dummyJWT(payload: ["exp": "1908784800"])) == 1908784800)
        #expect(JWTUtils.getExpirationTimestamp(dummyJWT(payload: ["exp": 0])) == 0)

        // Missing, non-numeric or malformed tokens return nil.
        #expect(JWTUtils.getExpirationTimestamp(dummyJWT(payload: ["test": 1])) == nil)
        #expect(JWTUtils.getExpirationTimestamp(dummyJWT(payload: ["exp": "abc"])) == nil)
        #expect(JWTUtils.getExpirationTimestamp("") == nil)
        #expect(JWTUtils.getExpirationTimestamp("a.b") == nil)
        #expect(JWTUtils.getExpirationTimestamp("a.b.c") == nil)
    }

    @Test func testAuthStoreIsValidUsesStrictChecks() {
        let store = BaseAuthStore()

        // Numeric and numeric-string exp values are valid while in the future.
        store.save(token: dummyJWT(payload: ["exp": 9999999999]), record: nil)
        #expect(store.isValid == true)
        store.save(token: dummyJWT(payload: ["exp": "9999999999"]), record: nil)
        #expect(store.isValid == true)

        // Missing exp is invalid (stricter than the JavaScript SDK).
        store.save(token: dummyJWT(payload: ["test": 1]), record: nil)
        #expect(store.isValid == false)

        // Expired, falsy or non-numeric exp values are invalid.
        store.save(token: dummyJWT(payload: ["exp": 1]), record: nil)
        #expect(store.isValid == false)
        store.save(token: dummyJWT(payload: ["exp": 0]), record: nil)
        #expect(store.isValid == false)
        store.save(token: dummyJWT(payload: ["exp": "abc"]), record: nil)
        #expect(store.isValid == false)

        // Malformed tokens are invalid.
        store.save(token: "", record: nil)
        #expect(store.isValid == false)
        store.save(token: "a.b", record: nil)
        #expect(store.isValid == false)
    }
}
