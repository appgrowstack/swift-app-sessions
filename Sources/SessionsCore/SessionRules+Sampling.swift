import Foundation

// SessionRules: Whether to send the recording, the priority conditions and the hash.
extension SessionRules {
    /// Whether to send the recording (sessions.md 5).
    public static func sampling(_ input: SamplingInput) -> Sampling {
        guard input.feature == .on else {
            return Sampling(accept: false, answer: nil, capture: false, upload: .none, priority: [],
                            previousSessionUpload: false, sessionReplay: nil)
        }
        guard input.replayEnabled else {
            return Sampling(accept: true, answer: .buffer, capture: false, upload: .none, priority: [],
                            previousSessionUpload: false, sessionReplay: SessionReplayState.none)
        }
        let previous = input.events.contains {
            if case .start(_, let end, _, _) = $0 { return [.crashed, .hung, .killed].contains(end) }
            return false
        }
        let hits = priorityHits(input.events)
        let priority = hits.keys.sorted()
        if input.internalDevice {
            return Sampling(accept: true, answer: .record, capture: true, upload: .all, priority: priority,
                            previousSessionUpload: previous, sessionReplay: .record)
        }
        var hash: UInt32?
        if input.recordedToday < input.dailyCap {
            let value = hash32("\(input.project):\(input.sessionID):replay")
            hash = value
            if Double(value) / 4_294_967_296 < input.sample {
                return Sampling(accept: true, answer: .record, capture: true, hash: value, upload: .all,
                                priority: priority, previousSessionUpload: previous, sessionReplay: .record)
            }
        }
        if let hitT = hits.values.min() {
            return Sampling(accept: true, answer: .buffer, capture: true, hash: hash, upload: .buffered,
                            uploadFromT: max(0, hitT - 60_000), priority: priority,
                            previousSessionUpload: previous, sessionReplay: .priority)
        }
        return Sampling(accept: true, answer: .buffer, capture: true, hash: hash, upload: .none, priority: [],
                        previousSessionUpload: previous, sessionReplay: .buffer)
    }

    /// The priority conditions met by the events, each with the time it was first met.
    public static func priorityHits(_ events: [SessionEvent]) -> [PriorityReason: Int] {
        var hits: [PriorityReason: Int] = [:]
        func hit(_ reason: PriorityReason, _ t: Int) { if hits[reason] == nil { hits[reason] = t } }
        var deadCount = 0
        var first = false
        var onboardingCompleted = false
        var campaignShownAt: Int?
        var paywallOpen = false
        for event in events {
            switch event {
            case .start(_, _, _, let isFirst):
                first = isFirst
            case .rage(let t, _, _, _, _):
                hit(.rage, t)
            case .dead(let t, _, _, _):
                deadCount += 1
                if deadCount == 3 { hit(.dead, t) }
            case .hang(let t, _):
                hit(.hang, t)
            case .mark(let t, let kind, let ref, _):
                switch kind {
                case .ticket: hit(.ticket, t)
                case .campaignShown: campaignShownAt = t
                case .paywallShown: paywallOpen = true
                case .purchaseCompleted: paywallOpen = false
                case .onboardingStep where ref == "completed": onboardingCompleted = true
                default: break
                }
            case .event(let t, let name, _, _):
                if name == "paywall_closed", paywallOpen {
                    hit(.paywallNoPurchase, t)
                    paywallOpen = false
                }
            case .end(let t, _):
                if let shown = campaignShownAt, t - shown <= 60_000 { hit(.campaignQuickEnd, t) }
                if paywallOpen { hit(.paywallNoPurchase, t) }
                if first, !onboardingCompleted { hit(.onboardingUnfinished, t) }
            default:
                break
            }
        }
        return hits
    }

    // MARK: - Hash

    /// FNV-1a over UTF-16 code units with murmur3's final mix (the same `hash32` as the server's).
    public static func hash32(_ input: String) -> UInt32 {
        var hash: UInt32 = 0x811c9dc5
        for unit in input.utf16 {
            hash ^= UInt32(unit)
            hash = hash &* 0x01000193
        }
        hash ^= hash >> 16
        hash = hash &* 0x85ebca6b
        hash ^= hash >> 13
        hash = hash &* 0xc2b2ae35
        hash ^= hash >> 16
        return hash
    }
}
