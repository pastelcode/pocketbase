import Foundation

/// The base class for all PocketBase services.
///
/// Each service keeps an unowned reference to its ``PocketBase`` client.
open class BaseService: @unchecked Sendable {
    /// The client this service belongs to.
    public unowned let client: PocketBase

    /// Creates a service bound to the given client.
    ///
    /// - Parameter client: The client the service belongs to.
    public init(_ client: PocketBase) {
        self.client = client
    }
}
