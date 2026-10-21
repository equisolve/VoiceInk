import Foundation

extension ProcessInfo {
    /// True while this process is the host app for a unit test run. The test host must stay away from the
    /// Keychain, history, and model downloads of a copy of VoiceInk installed on the same Mac. Always false in a
    /// release build, so the launch environment can't move a shipped app's credentials into memory.
    var isRunningUnitTests: Bool {
        #if DEBUG
            environment["XCTestConfigurationFilePath"] != nil
        #else
            false
        #endif
    }
}
