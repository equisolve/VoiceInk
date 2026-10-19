import Foundation

extension ProcessInfo {
    /// True while this process is the host app for a unit test run. The test host must stay away from the
    /// Keychain, history, and model downloads of a copy of VoiceInk installed on the same Mac.
    var isRunningUnitTests: Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }
}
