/// This package's name and version. The version is sent as `sdk_version` in each batch, and a
/// connector that sends batches to a server reports both, so the server can count which versions
/// call.
public enum SessionsSDK {
    /// The package name (`swift-app-sessions`).
    public static let name = "swift-app-sessions"
    /// The released version: the newest `## [x.y.z]` section of the CHANGELOG (a test checks it).
    public static let version = "0.3.0"
}
