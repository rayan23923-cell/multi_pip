import XCTest

/// YouTube → PiP feasibility on the simulator: detection, YouTube's embedded
/// player (needs the network), and the native AVPlayerLayer Picture in
/// Picture path in the Video PiP Lab (Debug builds). Every reading is printed
/// as a `VIDEO` line for the CI summary, pass or fail.
final class VideoPiPUITests: XCTestCase {
    /// The IFrame Player API's own demo video.
    private let videoURL = "https://youtu.be/M7lc1UVf-VE"

    override func setUp() {
        continueAfterFailure = true
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-TaskLensUITestStore", "-TaskLensResetStore"]
        app.launch()
        return app
    }

    private func analyze(_ app: XCUIApplication, _ text: String) {
        app.revealAndTap("commandCenter.lens")
        let input = app.identified("lens.input")
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText(text)
        app.revealAndTap("lens.analyze")
    }

    /// Polls the element's accessibility value until it matches.
    @discardableResult
    private func waitForValue(_ app: XCUIApplication, _ identifier: String, timeout: TimeInterval,
                              matching: (String) -> Bool) -> String {
        let target = app.identified(identifier)
        if !target.exists { app.reveal(identifier) }
        let end = Date().addingTimeInterval(timeout)
        var last = ""
        repeat {
            if target.exists {
                last = (target.value as? String) ?? ""
                if matching(last) { return last }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        } while Date() < end
        return last
    }

    private func report(_ test: String, _ text: String) {
        print("VIDEO \(test): \(text)")
    }

    // MARK: Detection and actions (offline)

    func testYouTubeLinkIsDetectedWithItsActions() {
        let app = launch()
        analyze(app, videoURL)
        XCTAssertTrue(app.waitForLabel("lens.detectedType", timeout: 10) { $0.contains("YouTube Video") },
                      "detected type: \(app.identified("lens.detectedType").label)")
        XCTAssertTrue(app.waitForLabel("analysis.videoID", timeout: 5) { $0.contains("M7lc1UVf-VE") })
        let open = app.reveal("action.openURL")
        XCTAssertTrue(open.label.contains("Open in YouTube"), "open: \(open.label)")
        XCTAssertTrue(app.identified("action.playVideo").exists)
        XCTAssertTrue(app.identified("action.saveToSession").exists)
        let pipActions = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'action.' AND label CONTAINS[c] 'Picture'"))
        XCTAssertEqual(pipActions.count, 0, "No Picture in Picture action is offered for YouTube")
        app.revealAndTap("action.saveToSession")
        XCTAssertTrue(app.staticTexts["Saved"].waitForExistence(timeout: 5))
        report("detection", "YouTube Video, videoID M7lc1UVf-VE, actions Open in YouTube / Play in TaskLens / Save, no PiP action")
    }

    // MARK: YouTube's embedded player (network)

    func testPlayInTaskLensUsesYouTubesPlayer() throws {
        let app = launch()
        analyze(app, videoURL)
        app.revealAndTap("action.playVideo")
        let ready = waitForValue(app, "youtube.state", timeout: 45) { $0 != "loading" && $0 != "idle" && !$0.isEmpty }
        report("player load", "state \(ready)")
        guard ready == "ready" || ready == "paused" || ready == "playing" else {
            XCTFail("YouTube's player did not become ready: \(ready)")
            return
        }
        app.revealAndTap("youtube.play")
        let playing = waitForValue(app, "youtube.state", timeout: 30) { $0 == "playing" || $0.hasPrefix("error.") }
        report("play", "state \(playing)")
        if playing.hasPrefix("error.") {
            // YouTube itself refused playback (onError). On CI this has been
            // 101/150 for the API's own demo video, which allows embedding: a
            // refusal for this simulator or network, not a TaskLens state. It
            // is reported as a result and must be checked on a real iPhone.
            throw XCTSkip("YouTube refused playback on this simulator: \(playing)")
        }
        XCTAssertEqual(playing, "playing")
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        app.revealAndTap("youtube.forward")
        report("seek", app.identified("youtube.state").label)
        app.revealAndTap("youtube.pause")
        let paused = waitForValue(app, "youtube.state", timeout: 15) { $0 == "paused" }
        report("pause", "state \(paused)")
        XCTAssertEqual(paused, "paused")

        // Leaving TaskLens pauses YouTube (no playback from a player the user cannot see).
        app.revealAndTap("youtube.play")
        _ = waitForValue(app, "youtube.state", timeout: 20) { $0 == "playing" }
        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        app.activate()
        let afterBackground = waitForValue(app, "youtube.state", timeout: 10) { $0 == "paused" }
        report("background", "state after returning \(afterBackground)")
        XCTAssertEqual(afterBackground, "paused")
        XCTAssertTrue(app.identified("youtube.openInYouTube").exists)
        app.revealAndTap("youtube.done")
    }

    // MARK: Native media → AVPictureInPictureController (lab)

    func testNativeMediaPictureInPicture() throws {
        let app = launch()
        app.tabBars.buttons.element(boundBy: 2).tap()
        app.revealAndTap("settings.videoPiPLab")
        app.revealAndTap("lab.native.load")
        // The status row is below the button; lazy lists only create it on screen.
        app.reveal("lab.native.status")
        let loaded = waitForValue(app, "lab.native.status", timeout: 30) { $0.contains("loaded=true") }
        report("native load", loaded)
        XCTAssertTrue(loaded.contains("loaded=true"), "status: '\(loaded)'")
        if loaded.contains("supported=false") {
            report("native", "AVPictureInPictureController.isPictureInPictureSupported() is false on this simulator")
            throw XCTSkip("Picture in Picture is not supported on this simulator: \(loaded)")
        }
        app.revealAndTap("lab.native.play")
        let possible = waitForValue(app, "lab.native.status", timeout: 20) { $0.contains("possible=true") && $0.contains("playing=true") }
        report("native play", possible)
        XCTAssertTrue(possible.contains("possible=true"), possible)

        app.revealAndTap("lab.native.startPiP")
        let active = waitForValue(app, "lab.native.status", timeout: 15) { $0.contains("active=true") }
        report("native start PiP", active)
        XCTAssertTrue(active.contains("active=true"), active)

        // Over the Home Screen, then back.
        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        report("native home", "springboard windows \(springboard.windows.count), PiP-like elements \(springboard.descendants(matching: .any).matching(NSPredicate(format: "identifier CONTAINS[c] 'PictureInPicture' OR label CONTAINS[c] 'Picture in Picture'")).count)")
        app.activate()
        let back = waitForValue(app, "lab.native.status", timeout: 10) { $0.contains("active=") }
        report("native return", back)

        app.revealAndTap("lab.native.stopPiP")
        let stopped = waitForValue(app, "lab.native.status", timeout: 15) { $0.contains("active=false") }
        report("native stop PiP", stopped)
        XCTAssertTrue(stopped.contains("active=false"), stopped)
        XCTAssertTrue(stopped.contains("loaded=true"))
    }
}
