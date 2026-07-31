import Foundation

open class BaseService: @unchecked Sendable {
    public unowned let client: PocketBase

    public init(_ client: PocketBase) {
        self.client = client
    }
}
