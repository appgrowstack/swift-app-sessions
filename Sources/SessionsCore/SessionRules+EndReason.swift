import Foundation

// SessionRules: Why the previous session ended.
extension SessionRules {
    public static func endReason(_ input: EndInput) -> EndDecision {
        let reason = baseEndReason(input)
        var revised: SessionEndReason?
        if input.platform == .ios, input.lateMetricKitCrash, input.runningFlag, reason == .killed || reason == .hung {
            revised = .crashed
        }
        return EndDecision(reason: reason, revised: revised)
    }

    private static func baseEndReason(_ input: EndInput) -> SessionEndReason {
        guard input.previousRecord else { return .unknown }
        let android = input.platform == .android
        let modernAndroid = (input.androidAPI ?? 30) >= 30
        if android, modernAndroid, input.exitReason == "REASON_USER_REQUESTED" { return .userClosed }
        guard input.runningFlag else { return .backgroundTimeout }
        let crashed: Bool
        if android {
            crashed = modernAndroid
                ? input.exitReason == "REASON_CRASH" || input.exitReason == "REASON_CRASH_NATIVE"
                : input.crashHandler
        } else {
            crashed = input.metricKitCrash
        }
        if crashed { return .crashed }
        if input.lastEvent == "hang" || (android && modernAndroid && input.exitReason == "REASON_ANR") { return .hung }
        if android, !modernAndroid { return .unknown }
        return .killed
    }
}
