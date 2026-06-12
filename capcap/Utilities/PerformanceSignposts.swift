import OSLog

enum PerformanceSignposts {
    private static let logger = Logger(subsystem: "cn.skyrin.capcap", category: "CapturePerformance")
    private static let signposter = OSSignposter(logger: logger)

    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name)
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }

    static func event(_ name: StaticString) {
        signposter.emitEvent(name)
    }
}
