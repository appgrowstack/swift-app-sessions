import Foundation

// SessionRules: Splitting the app's lifecycle into sessions.
extension SessionRules {
    /// Launch always starts a session. Coming to the foreground starts one when the app was in the
    /// background for ``backgroundTimeoutMs`` or longer. A change of date does not split.
    public static func split(_ steps: [(t: Int, k: LifecycleStep)]) -> Split {
        var sessions: [SplitSession] = []
        var sessionOf: [Int] = []
        var backgroundAt: Int?
        for step in steps {
            switch step.k {
            case .launch:
                if !sessions.isEmpty { sessions[sessions.count - 1].by = .launch }
                sessions.append(SplitSession(start: step.t))
                backgroundAt = nil
            case .background:
                if sessions.isEmpty { sessions.append(SplitSession(start: step.t)) }
                backgroundAt = step.t
            case .foreground:
                if sessions.isEmpty {
                    sessions.append(SplitSession(start: step.t))
                } else if let at = backgroundAt, step.t - at >= backgroundTimeoutMs {
                    sessions[sessions.count - 1].end = at
                    sessions[sessions.count - 1].by = .backgroundTimeout
                    sessions.append(SplitSession(start: step.t))
                }
                backgroundAt = nil
            }
            sessionOf.append(sessions.count - 1)
        }
        return Split(sessionOfStep: sessionOf, sessions: sessions)
    }
}
