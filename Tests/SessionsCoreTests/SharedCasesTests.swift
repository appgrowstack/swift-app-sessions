import Foundation
import Testing
@testable import SessionsCore

/// Runs the light record's tables in `schema/cases/sessions` (copied by `scripts/sync-cases.sh`).
/// Kotlin and TypeScript read the same files. `aggregate` belongs to the server.
struct SharedCasesTests {
    static let directory = Bundle.module.url(forResource: "Cases", withExtension: nil)!.appending(path: "sessions")
    static let notHere: Set<String> = ["aggregate"]

    static let all: [(name: String, rule: String)] = {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }.sorted().compactMap { file in
            guard let json = try? read(String(file.dropLast(5))), let rule = json["rule"] as? String else { return nil }
            return (String(file.dropLast(5)), rule)
        }
    }()

    static let names: [String] = all.filter { !notHere.contains($0.rule) }.map(\.name)

    static func read(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appending(path: "\(name).json"))
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    @Test func everyLightCaseIsRun() {
        #expect(Self.all.count == 98)
        #expect(Self.names.count == 91)
    }

    @Test(arguments: names)
    func sharedCase(_ name: String) throws {
        let json = try Self.read(name)
        let input = json["input"] as! [String: Any]
        let expect = json["expect"] as! [String: Any]
        let actual = try Self.run(rule: json["rule"] as! String, input: input)
        #expect(Self.canonical(actual) == Self.canonical(expect), "\(name)")
    }

    // MARK: - Running one table

    static func run(rule: String, input: [String: Any]) throws -> [String: Any] {
        switch rule {
        case "split":
            let steps = (input["steps"] as! [[String: Any]]).map { (t: int($0["t"]), k: SessionRules.LifecycleStep(rawValue: $0["k"] as! String)!) }
            let split = SessionRules.split(steps)
            return [
                "session_of_step": split.sessionOfStep,
                "sessions": split.sessions.map { s -> [String: Any] in
                    ["start": s.start, "end": s.end.map { $0 as Any } ?? NSNull(), "by": s.by.map { $0.rawValue as Any } ?? NSNull()]
                }
            ]
        case "rage":
            let window = input["window"] as! [String: Any]
            let taps = (input["taps"] as! [[String: Any]]).map { SessionRules.Tap(t: int($0["t"]), x: double($0["x"]), y: double($0["y"])) }
            let found = SessionRules.rage(taps, window: SessionSize(w: double(window["w"]), h: double(window["h"])))
            return ["rage": found.map { ["t": $0.t, "x": $0.x, "y": $0.y, "count": $0.count] }]
        case "dead":
            let tap = input["tap"] as! [String: Any]
            let after = (input["after"] as! [[String: Any]]).map {
                SessionRules.After(t: int($0["t"]), k: SessionRules.After.Kind(rawValue: $0["k"] as! String)!, fingerprint: $0["fingerprint"] as? String)
            }
            return ["dead": SessionRules.isDead(capturing: input["capturing"] as! Bool, tapAt: int(tap["t"]),
                                                 fingerprintBefore: input["fingerprint_before"] as! String, after: after)]
        case "quick_back":
            let steps = (input["nav"] as! [[String: Any]]).map {
                SessionRules.NavigationStep(t: int($0["t"]), op: SessionRules.NavigationOp(rawValue: $0["op"] as! String)!,
                                            screen: $0["screen"] as! String,
                                            by: ($0["by"] as? String).flatMap(SessionBackVia.init(rawValue:)))
            }
            return ["events": SessionRules.navigate(steps).map { event -> [String: Any] in
                switch event {
                case .screen(let t, let screen, let via): ["k": "screen", "t": t, "screen": screen, "via": via.rawValue]
                case .back(let t, let screen, let via): ["k": "back", "t": t, "screen": screen, "via": via.rawValue]
                case .quickBack(let t, let screen, let ms): ["k": "quick_back", "t": t, "screen": screen, "ms": ms]
                }
            }]
        case "end":
            let decision = SessionRules.endReason(.init(
                platform: SessionPlatform(rawValue: input["platform"] as! String)!,
                androidAPI: input["android_api"].map { int($0) },
                previousRecord: input["previous_record"] as! Bool,
                runningFlag: input["running_flag"] as! Bool,
                lastEvent: input["last_event"] as? String,
                metricKitCrash: input["metrickit_crash"] as? Bool ?? false,
                lateMetricKitCrash: input["late_metrickit_crash"] as? Bool ?? false,
                exitReason: input["exit_reason"] as? String,
                crashHandler: input["crash_handler"] as? Bool ?? false))
            var out: [String: Any] = ["reason": decision.reason.rawValue]
            if let revised = decision.revised { out["revised"] = revised.rawValue }
            return out
        case "scroll":
            let samples = (input["samples"] as! [[String: Any]]).map {
                SessionRules.ScrollSample(offsetY: double($0["offset_y"]), height: double($0["height"]),
                                          contentHeight: double($0["content_height"]), row: $0["row"].map { int($0) })
            }
            let depth = SessionRules.scrollDepth(samples)
            var out: [String: Any] = ["max_ratio": depth.maxRatio]
            if let row = depth.maxRow { out["max_row"] = row }
            return out
        case "tap_normalize":
            let tap = input["tap"] as! [String: Any]
            let window = input["window"] as! [String: Any]
            let n = SessionRules.normalizeTap(x: double(tap["x"]), y: double(tap["y"]),
                                              window: SessionRect(x: double(window["x"]), y: double(window["y"]),
                                                                  w: double(window["w"]), h: double(window["h"])))
            return ["x": n.x, "y": n.y, "orientation": n.orientation.rawValue, "col": n.col, "row": n.row, "cell": n.cell]
        case "keep_props":
            let props = (input["props"] as! [String: Any]).mapValues(sessionValue)
            let kept = SessionRules.keepProps(source: SessionRules.EventSource(rawValue: input["source"] as! String)!,
                                              name: input["name"] as! String, props: props,
                                              keepProps: input["keep_props"] as! [String: [String]])
            return ["props": kept.props.mapValues(any), "props_dropped": kept.propsDropped]
        case "sampling":
            let replay = input["replay"] as! [String: Any]
            let eventsData = try JSONSerialization.data(withJSONObject: input["events"]!)
            let events = try JSONDecoder().decode([SessionEvent].self, from: eventsData)
            let s = SessionRules.sampling(.init(
                project: input["project"] as! String, sessionID: input["session_id"] as! String,
                feature: SessionRules.Feature(rawValue: input["feature"] as! String)!,
                replayEnabled: replay["enabled"] as! Bool, sample: double(replay["sample"]),
                dailyCap: int(replay["daily_cap"]), internalDevice: input["internal"] as! Bool,
                recordedToday: int(input["recorded_today"]), events: events))
            var out: [String: Any] = [
                "accept": s.accept,
                "answer": s.answer.map { $0.rawValue as Any } ?? NSNull(),
                "capture": s.capture,
                "upload": s.upload.rawValue,
                "priority": s.priority.map(\.rawValue),
                "previous_session_upload": s.previousSessionUpload,
                "session_replay": s.sessionReplay.map { $0.rawValue as Any } ?? NSNull()
            ]
            if let hash = s.hash { out["hash"] = Int(hash) }
            if let from = s.uploadFromT { out["upload_from_t"] = from }
            return out
        case "mask_rects":
            let image = input["image"] as! [String: Any]
            let rects = (input["rects"] as! [Any]).map { value -> SessionRect? in
                guard let rect = value as? [String: Any] else { return nil }
                return SessionRect(x: double(rect["x"]), y: double(rect["y"]), w: double(rect["w"]), h: double(rect["h"]))
            }
            let found = SessionRules.maskRects(scale: double(input["scale"]), imageW: int(image["w"]), imageH: int(image["h"]), rects: rects)
            var out: [String: Any] = ["drop": found.drop, "rects": found.rects.map { ["x": $0.x, "y": $0.y, "w": $0.w, "h": $0.h] }]
            if let reason = found.reason { out["reason"] = reason.rawValue }
            return out
        case "segment":
            let bytes = Data(base64Encoded: input["bytes"] as! String)!
            do {
                let segment = try SessionReplaySegment.decode(bytes)
                // Written again, it reads the same.
                let again = try SessionReplaySegment.decode(try segment.encoded())
                #expect(again == segment)
                let header = try JSONSerialization.jsonObject(with: JSONEncoder().encode(segment.header))
                return ["header": header, "images": segment.images.map { $0.base64EncodedString() }]
            } catch let error as SessionReplaySegment.DecodeError {
                return ["error": error.rawValue]
            }
        default:
            Issue.record("rule \(rule) is not run here")
            return [:]
        }
    }

    // MARK: - JSON helpers

    static func int(_ value: Any?) -> Int { (value as! NSNumber).intValue }
    static func double(_ value: Any?) -> Double { (value as! NSNumber).doubleValue }

    /// A JSON value as a kept value; anything but text, a number or yes/no is nil.
    static func sessionValue(_ value: Any) -> SessionValue? {
        if let text = value as? String { return .string(text) }
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
        if CFNumberIsFloatType(number) { return .double(number.doubleValue) }
        return .int(number.intValue)
    }

    static func any(_ value: SessionValue) -> Any {
        switch value {
        case .string(let text): text
        case .int(let number): number
        case .double(let number): number
        case .bool(let flag): flag
        }
    }

    static func canonical(_ value: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    }
}
