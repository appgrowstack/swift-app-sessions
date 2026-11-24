import Testing
@testable import SessionsCore

struct SessionReplayFrameCostTests {
    @Test("Frames under 16ms keep one a second")
    func fastFrames() {
        var cost = SessionReplayFrameCost()
        for _ in 0..<40 { cost.add(8) }
        #expect(cost.verdict == .normal)
        #expect(cost.intervalMs(live: false) == 1000)
    }

    @Test("Over 16ms at p95 spaces frames to 2 seconds; under it again goes back to 1 second")
    func slowFrames() {
        var cost = SessionReplayFrameCost()
        for _ in 0..<13 { cost.add(20) }
        #expect(cost.verdict == .slow)
        #expect(cost.intervalMs(live: false) == 2000)
        #expect(cost.intervalMs(live: true) == 500)
        for _ in 0..<30 { cost.add(5) }
        #expect(cost.verdict == .normal)
    }

    @Test("Over 33ms at p95 spaces frames to 5 seconds and does not stop the recording")
    func verySlowFrames() {
        var cost = SessionReplayFrameCost()
        for _ in 0..<40 { cost.add(50) }
        #expect(cost.verdict == .verySlow)
        #expect(cost.intervalMs(live: false) == 5000)
        for _ in 0..<30 { cost.add(5) }
        #expect(cost.verdict == .normal)
    }

    @Test("Over 100ms at p95 stops the recording and stays stopped until reset")
    func degraded() {
        var cost = SessionReplayFrameCost()
        for _ in 0..<13 { cost.add(150) }
        #expect(cost.verdict == .degraded)
        for _ in 0..<40 { cost.add(1) }
        #expect(cost.verdict == .degraded)
        cost.reset()
        #expect(cost.verdict == .normal)
    }

    @Test("The first frames after launch are not counted")
    func warmUp() {
        var cost = SessionReplayFrameCost()
        // Three slow frames while the first screen lays out, then fast ones.
        for _ in 0..<3 { cost.add(3000) }
        for _ in 0..<10 { cost.add(6) }
        #expect(cost.verdict == .normal)
    }

    @Test("No stop threshold (the simulator) only spaces frames out")
    func neverStops() {
        var cost = SessionReplayFrameCost(stopP95Ms: nil)
        for _ in 0..<40 { cost.add(200) }
        #expect(cost.verdict == .verySlow)
    }

    @Test("Fewer than 10 counted frames decide nothing")
    func tooFew() {
        var cost = SessionReplayFrameCost()
        for _ in 0..<12 { cost.add(150) }
        #expect(cost.verdict == .normal)
        cost.add(150)
        #expect(cost.verdict == .degraded)
    }

    @Test("Percentiles of the counted frames")
    func percentiles() {
        var cost = SessionReplayFrameCost(warmUpFrames: 0)
        #expect(cost.percentiles == nil)
        for ms in 1...20 { cost.add(Double(ms)) }
        #expect(cost.percentiles?.p50 == 11)
        #expect(cost.percentiles?.p95 == 20)
    }
}
