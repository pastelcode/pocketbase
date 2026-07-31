import Testing
import Foundation
@testable import swift_pocketbase_sdk

struct OptionsTests {
    @Test func testSerializeQueryParamsEmpty() {
        #expect(serializeQueryParams([:]) == "")
        #expect(serializeQueryParams(["a": AnyCodable(nil), "b": AnyCodable(nil)]) == "")
    }

    @Test func testSerializeQueryParamsTypes() {
        var params: [String: AnyCodable] = [:]
        params["@test_null"] = AnyCodable(nil)
        params["@test_number"] = AnyCodable(123.456)
        params["@test_string"] = AnyCodable("@test_str")
        params["@test_bool"] = AnyCodable(false)
        params["@test_array"] = AnyCodable([AnyCodable(123), AnyCodable("@test_arr")])

        let result = serializeQueryParams(params)
        #expect(result.contains("%40test_number=123.456"))
        #expect(result.contains("%40test_string=%40test_str"))
        #expect(result.contains("%40test_bool=false"))
        #expect(result.contains("%40test_array=123"))
        #expect(result.contains("%40test_array=%40test_arr"))
    }
}
