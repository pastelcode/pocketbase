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
}
