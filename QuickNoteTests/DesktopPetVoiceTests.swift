import AppKit
@preconcurrency import AVFoundation
@preconcurrency import Speech
import SwiftData
import SwiftUI
import XCTest
@testable import QuickNote

@MainActor
final class DesktopPetVoiceTests: XCTestCase {
    @MainActor
    private final class OfflineReply {
        let started: XCTestExpectation
        var finish: CheckedContinuation<String, any Error>?
        init(_ started: XCTestExpectation) { self.started = started }
        func result() async throws -> String {
            try await withCheckedThrowingContinuation {
                finish = $0
                started.fulfill()
            }
        }
    }

    func testOfflineRefinementKeepsLiveTextUntilSuccessAndIgnoresCancelledResult() async throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4000))
        buffer.frameLength = 4000
        buffer.floatChannelData?[0].initialize(repeating: 0.2, count: 4000)
        let started = expectation(description: "offline refinement started")
        let reply = OfflineReply(started)
        let recorder = LocalVoiceRecorder()
        recorder.refine = { _ in try await reply.result() }
        recorder.start()
        recorder.audioReplay.append(buffer)
        recorder.receiveRecognition("像由心生", isFinal: true, error: nil, token: recorder.generation)
        XCTAssertEqual(recorder.phase, .finishing)
        XCTAssertEqual(recorder.transcript, "像由心生")
        await fulfillment(of: [started], timeout: 2)
        reply.finish?.resume(returning: "相由心生")
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(recorder.transcript, "相由心生")
        XCTAssertEqual(recorder.originalTranscript, "像由心生")
        XCTAssertEqual(recorder.phase, .idle)
        recorder.restoreLiveTranscript()
        XCTAssertEqual(recorder.transcript, "像由心生")

        let pending = expectation(description: "second offline pass")
        let nextReply = OfflineReply(pending)
        recorder.refine = { _ in try await nextReply.result() }
        recorder.start()
        recorder.audioReplay.append(buffer)
        recorder.receiveRecognition("第二次", isFinal: true, error: nil, token: recorder.generation)
        await fulfillment(of: [pending], timeout: 2)
        recorder.discard()
        nextReply.finish?.resume(returning: "不能恢复的迟到文字")
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(recorder.transcript.isEmpty)
        XCTAssertTrue(recorder.originalTranscript.isEmpty)
        XCTAssertTrue(recorder.audioReplay.drain().isEmpty)
    }

    func testOfflineFailureOrEmptyResultPreservesLiveText() async throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000))
        buffer.frameLength = 24_000
        buffer.floatChannelData?[0].initialize(repeating: 0, count: 24_000)
        buffer.floatChannelData?[1].initialize(repeating: 0.2, count: 24_000)
        for fails in [false, true] {
            let recorder = LocalVoiceRecorder()
            recorder.refine = { _ in
                if fails { throw AIAnalyzerError.invalidResponse }
                return " "
            }
            recorder.start()
            recorder.audioReplay.append(buffer)
            recorder.receiveRecognition("原始文字不能丢", isFinal: true, error: nil, token: recorder.generation)
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertEqual(recorder.transcript, "原始文字不能丢")
            XCTAssertEqual(recorder.phase, .idle)
        }
        let replay = VoiceAudioReplay()
        replay.append(buffer)
        let samples = try replay.drainMonoSamples()
        XCTAssertEqual(samples.count, 8_000, accuracy: 2)
        XCTAssertTrue(samples.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(samples.map { abs($0) }.max() ?? 0, 0.05)
        XCTAssertTrue(replay.drain().isEmpty)
    }

    func testNativeOfflineModelDecodesPublicChineseAudio() async throws {
        XCTAssertTrue(VoiceOfflineRecognition.isAvailable, "构建必须准备并打包离线模型")
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "zh", withExtension: "wav"))
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let replay = VoiceAudioReplay()
        replay.append(buffer)
        let began = ContinuousClock.now
        let text = try await VoiceOfflineRecognition.shared.transcribe(replay)
        print("Offline public-sample decode duration: \(began.duration(to: .now))")
        XCTAssertTrue(text.contains("早上9点"))
        XCTAssertTrue(text.contains("下午5点"))
        XCTAssertFalse(text.contains("<|"), "不能把模型内部语言或情绪标记显示给用户")
        XCTAssertTrue(replay.drain().isEmpty)
        let empty = try await VoiceOfflineRecognition.shared.transcribe(samples: [])
        XCTAssertTrue(empty.isEmpty)
    }

    func testEmptyFinalCannotEraseWordsAlreadyRecognized() {
        let recorder = LocalVoiceRecorder()
        recorder.start() // Synchronous callbacks; cancel before the authorization task can run.
        let token = recorder.generation
        recorder.receiveRecognition("相由心生", isFinal: false, error: nil, token: token)
        recorder.receiveRecognition("", isFinal: true, error: nil, token: token)
        XCTAssertEqual(recorder.transcript, "相由心生")
        XCTAssertEqual(recorder.phase, .idle)
        XCTAssertFalse(recorder.notice.contains("没有听到"))
        recorder.discard()
        recorder.receiveRecognition("迟到的旧文字", isFinal: true, error: nil, token: token)
        XCTAssertTrue(recorder.transcript.isEmpty)
    }

    func testLocalRecognitionUsesBriefContextWithoutReplacingHomophones() {
        let request = LocalVoiceRecorder.makeRequest(context: [" 项目复盘 ", "项目复盘", "", String(repeating: "长标题", count: 60)])
        XCTAssertTrue(request.requiresOnDeviceRecognition)
        XCTAssertTrue(request.shouldReportPartialResults)
        XCTAssertTrue(request.addsPunctuation)
        XCTAssertTrue(request.contextualStrings.contains("相由心生"))
        XCTAssertEqual(request.contextualStrings.filter { $0 == "项目复盘" }.count, 1)
        XCTAssertTrue(request.contextualStrings.allSatisfy { !$0.isEmpty && $0.count <= 32 })
        let recorder = LocalVoiceRecorder()
        recorder.start()
        recorder.receiveRecognition("好像快下雨了", isFinal: true, error: nil, token: recorder.generation)
        XCTAssertEqual(recorder.transcript, "好像快下雨了")
    }

    func testCapturedAudioIsCopiedBoundedAndCannotRefillAfterCancel() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4000))
        buffer.frameLength = 4000
        buffer.floatChannelData?[0].initialize(repeating: 0.2, count: 4000)
        let replay = VoiceAudioReplay()
        replay.append(buffer)
        buffer.floatChannelData?[0].update(repeating: 0, count: 4000)
        XCTAssertTrue(replay.hasSignal)
        let copied = try XCTUnwrap(replay.drain().first)
        withExtendedLifetime(copied) { XCTAssertEqual(copied.floatChannelData?[0][0], 0.2) }
        replay.append(buffer)
        XCTAssertTrue(replay.drain().isEmpty, "取消后迟到的音频不能重新进入缓存")
        let bounded = VoiceAudioReplay(maximumBytes: 16_000)
        bounded.append(buffer)
        bounded.append(buffer)
        XCTAssertTrue(bounded.drain().isEmpty, "超限时禁止把不完整的音频当作整段重试")
        let stereoFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 2))
        let stereo = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: 4000))
        stereo.frameLength = 4000
        stereo.floatChannelData?[0].initialize(repeating: 0, count: 4000)
        stereo.floatChannelData?[1].initialize(repeating: 0.2, count: 4000)
        let rightChannel = VoiceAudioReplay()
        rightChannel.append(stereo)
        XCTAssertTrue(rightChannel.hasSignal, "只有右声道有声音时也必须识别为有效输入")
    }

    func testEmptyRecognitionRetriesLocallyOnceAndKeepsCancellationFinal() async throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4000))
        buffer.frameLength = 4000
        buffer.floatChannelData?[0].initialize(repeating: 0.2, count: 4000)
        var replies: [LocalVoiceRecorder.RecognitionHandler] = []
        let recorder = LocalVoiceRecorder(recognize: { request, reply in
            XCTAssertTrue(request.requiresOnDeviceRecognition)
            replies.append(reply)
            return nil // Only the speech-service boundary is replaced; no microphone or cloud.
        })
        recorder.start()
        recorder.audioReplay.append(buffer)
        let original = recorder.generation
        recorder.receiveRecognition("", isFinal: true, error: nil, token: original)
        XCTAssertTrue(recorder.isRecovering)
        XCTAssertEqual(recorder.phase, .finishing)
        XCTAssertEqual(replies.count, 1)
        recorder.receiveRecognition("旧请求的迟到结果", isFinal: true, error: nil, token: original)
        XCTAssertTrue(recorder.transcript.isEmpty)
        replies[0]("相由心生", true, nil)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(recorder.transcript, "相由心生")
        XCTAssertEqual(recorder.phase, .idle)

        recorder.start()
        recorder.audioReplay.append(buffer)
        recorder.receiveRecognition(nil, isFinal: false, error: NSError(domain: "LocalSpeech", code: 1101), token: recorder.generation)
        XCTAssertEqual(replies.count, 2)
        recorder.receiveRecognition("", isFinal: true, error: nil, token: recorder.generation)
        XCTAssertEqual(replies.count, 2, "只能补识别一次，不允许无限重试")
        XCTAssertEqual(recorder.phase, .idle)
        XCTAssertTrue(recorder.notice.contains("已收到声音"))
        recorder.discard()
        replies[1]("取消后不能回来的字", true, nil)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(recorder.transcript.isEmpty)
        XCTAssertTrue(recorder.audioReplay.drain().isEmpty)
    }

    func testVoiceRapidTransitionsKeepWindowAndContentInSync() async throws {
        let (container, repository, documents, session) = try fixture()
        defer { withExtendedLifetime(container) {}; try? FileManager.default.removeItem(at: documents.root) }
        let name = "QuickNote-Voice-Transitions-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let pet = DesktopPetController(defaults: defaults)
        defer { pet.stop() }
        let voice = DesktopPetVoiceController(session: session, allNotes: repository.allNotes, pet: pet,
            showSettings: {}, openNote: { _ in })
        voice.show(startImmediately: false)
        defer { voice.close() }
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "说给小鸟听" && $0.isVisible })
        for index in 1...6 {
            voice.recorder.transcript = String(repeating: "正在确认设计稿", count: index * 3)
            voice.toggleTranscript()
            try await Task.sleep(for: .milliseconds(25))
        }
        voice.recorder.transcript = "确认设计稿"
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(voice.showsTranscript)
        XCTAssertEqual(window.frame.height, 44, accuracy: 1, "短结果与操作应在同一行")
        XCTAssertEqual(window.contentView?.bounds.size, window.frame.size)
        voice.toggleTranscript()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertLessThanOrEqual(window.frame.height, 132)
        XCTAssertEqual(window.contentView?.bounds.size, window.frame.size)
        let view = try XCTUnwrap(window.contentView)
        XCTAssertLessThanOrEqual(view.fittingSize.height, window.frame.height)
        voice.close()
        voice.show() // Cancel before the permission task runs; no real recording.
        let recordingWindow = try XCTUnwrap(NSApp.windows.first { $0.title == "说给小鸟听" && $0.isVisible })
        XCTAssertEqual(recordingWindow.frame.height, 36)
        voice.recorder.cancel()
        voice.close()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(voice.isPresented)
        XCTAssertTrue(voice.recorder.transcript.isEmpty)
    }

    func testVoiceCapsuleUsesScreenBottomInsteadOfPetPosition() {
        let screen = NSRect(x: -1280, y: -100, width: 1280, height: 800)
        for height: CGFloat in [52, 96, 212, 340] {
            let hud = DesktopPetVoiceController.hudFrame(in: screen, height: height)
            XCTAssertEqual(hud.midX, screen.midX)
            XCTAssertEqual(hud.minY, screen.minY + 16)
        }
    }

    func testVoiceRevealHandlesCorrectionsUnicodeAndLongResultsWithoutBacklog() {
        XCTAssertEqual(VoiceTranscriptLine.frames(from: "明天上午", to: "明天下午三点").last, "明天下午三点")
        XCTAssertEqual(VoiceTranscriptLine.frames(from: "一家👨‍👩‍👧‍👦", to: "一家👨‍👩‍👧‍👦出游").last, "一家👨‍👩‍👧‍👦出游")
        XCTAssertEqual(VoiceTranscriptLine.frames(from: "旧内容", to: ""), [""])
        let long = String(repeating: "长内容", count: 300)
        let frames = VoiceTranscriptLine.frames(from: "", to: long)
        XCTAssertLessThanOrEqual(frames.count, 13)
        XCTAssertEqual(frames.last, String(long.suffix(160)))
        let old = String((0..<160).map { Character(UnicodeScalar(0x4e00 + $0)!) })
        let shifted = String(old.dropFirst()) + "新"
        XCTAssertEqual(VoiceTranscriptLine.frames(from: old, to: shifted).first, String(old.dropFirst()),
                       "长句滑动显示时不能清空整行重新打字")
    }

    func testRecordingWidthGrowsFromCompactCapsuleAndCapsWithoutLosingText() throws {
        let short = DesktopPetVoiceController.recordingWidth(for: "明天下午三点")
        let long = String(repeating: "整理项目进展", count: 100)
        XCTAssertEqual(DesktopPetVoiceController.recordingWidth(for: ""), 120)
        XCTAssertGreaterThan(short, 120)
        XCTAssertLessThan(short, 380)
        XCTAssertEqual(DesktopPetVoiceController.recordingWidth(for: long), 380)
        XCTAssertEqual(DesktopPetVoiceController.transcriptEditorHeight(for: ""), 28)
        XCTAssertGreaterThan(DesktopPetVoiceController.transcriptEditorHeight(for: "第一行\n第二行\n第三行"), 28)
        XCTAssertEqual(DesktopPetVoiceController.transcriptEditorHeight(for: long), 112)
        let recorder = LocalVoiceRecorder()
        recorder.transcript = long
        _ = DesktopPetVoiceController.recordingWidth(for: recorder.transcript)
        XCTAssertEqual(recorder.transcript, long)
        for width in [156.0, short, 420] {
            let screen = NSRect(x: -1280, y: -100, width: 1280, height: 800)
            let frame = DesktopPetVoiceController.hudFrame(in: screen, height: 52, width: width)
            XCTAssertTrue(screen.contains(frame))
            XCTAssertEqual(frame.midX, screen.midX)
            XCTAssertEqual(frame.minY, screen.minY + 16)
        }
    }

    func testVoiceMeterUsesActualPCMAndRecordingCapsuleIsOneLine() async throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
        buffer.frameLength = 64
        buffer.floatChannelData?[0].initialize(repeating: 0, count: 64)
        XCTAssertEqual(LocalVoiceRecorder.audioLevel(buffer), 0)
        buffer.floatChannelData?[0].update(repeating: 0.25, count: 64)
        XCTAssertGreaterThan(LocalVoiceRecorder.audioLevel(buffer), 0.8)
        buffer.floatChannelData?[0][0] = .nan
        XCTAssertEqual(LocalVoiceRecorder.audioLevel(buffer), 0)
        let view = NSHostingView(rootView: VoiceRecordingCapsule(phase: .listening,
            text: "明天下午三点，我们一起确认设计稿", level: 0.7, animateText: false, close: {}, stop: {}))
        view.frame = NSRect(x: 0, y: 0, width: 360, height: 36)
        let panel = NSPanel(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = view
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(120))
        view.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(view.fittingSize.height, 36)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/quicknote-recording-capsule.png"))
    }

    func testVoiceContentAnalysisIsAnExplicitChoiceAndNeverAutoWrites() async throws {
        let (container, repository, documents, session) = try fixture()
        defer { withExtendedLifetime(container) {}; try? FileManager.default.removeItem(at: documents.root) }
        try session.createAndOpen()
        let name = "QuickNote-Voice-Choice-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let pet = DesktopPetController(defaults: defaults)
        defer { pet.stop() }
        var calls = 0
        let completed = expectation(description: "explicit content analysis")
        let selection = SelectionActionController(session: session, allNotes: repository.allNotes, showSettings: {},
            aiStore: AIConfigurationStore(defaults: defaults), desktopPet: pet, respond: { instruction, material in
                calls += 1
                XCTAssertEqual(instruction, SelectionActionController.voiceAnalysisInstruction)
                XCTAssertTrue(instruction.contains("润色改写"))
                XCTAssertTrue(instruction.contains("同音错字"))
                XCTAssertTrue(instruction.contains("不强制表格"))
                XCTAssertFalse(instruction.contains("输出以下三部分"))
                XCTAssertFalse(instruction.contains("三列表格结构化整理"))
                XCTAssertEqual(material, "用户更喜欢轻量的输入方式")
                completed.fulfill()
                return AITextResult(text: "用户更喜欢轻便、操作简单的输入方式。", providerName: "隔离测试")
            })
        let capturedID = session.currentNote?.id
        let voice = DesktopPetVoiceController(session: session, allNotes: repository.allNotes, pet: pet,
            showSettings: {}, openNote: { _ in }, showAnalysis: { text, id, revision in
                XCTAssertEqual(id, capturedID)
                selection.presentVoice(text, targetID: id, revision: revision)
            }, confirmSending: { _ in XCTFail("明确点击 AI 识别后不再弹第二次确认框"); return false })
        voice.show(startImmediately: false)
        defer { voice.hide() }
        voice.recorder.transcript = "用户更喜欢轻量的输入方式"
        XCTAssertEqual(calls, 0)
        voice.analyzeTranscript()
        await fulfillment(of: [completed], timeout: 1)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(voice.isPresented)
        XCTAssertFalse(voice.hasProposal, "语音小浮层不再展示旧的创建/追加/排版结果")
        XCTAssertEqual(voice.recorder.transcript, "用户更喜欢轻量的输入方式")
        XCTAssertTrue(session.document.string.isEmpty)
        let panel = try XCTUnwrap(NSApp.windows.first { $0.title == "文字分析" && $0.isVisible })
        defer { panel.orderOut(nil); withExtendedLifetime(selection) {} }
        let view = try XCTUnwrap(panel.contentView)
        func textViews(_ view: NSView) -> [NSTextView] {
            (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
        }
        let result = try XCTUnwrap(textViews(view).first)
        XCTAssertTrue(panel.canBecomeKey, "分析窗口必须支持选择与复制文字，不能把按键留在背后的笔记")
        XCTAssertTrue(panel.makeFirstResponder(result))
        XCTAssertTrue(result.isSelectable)
        XCTAssertEqual(result.string.trimmingCharacters(in: .whitespacesAndNewlines), "用户更喜欢轻便、操作简单的输入方式。",
            "自然段结果也能直接选择、复制，不应强制补出表格和分析模板")
        XCTAssertNil(NSApp.modalWindow)
        XCTAssertTrue(NSScreen.screens.contains { $0.visibleFrame.contains(panel.frame) })
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/quicknote-voice-analysis-window.png"))
    }

    func testVoiceEntryStartsImmediatelyWithoutActivatingALargeWindow() throws {
        let (container, repository, documents, session) = try fixture()
        defer { withExtendedLifetime(container) {}; try? FileManager.default.removeItem(at: documents.root) }
        try session.createAndOpen()
        let name = "QuickNote-Voice-HUD-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let pet = DesktopPetController(defaults: defaults)
        defer { pet.stop() }
        let voice = DesktopPetVoiceController(session: session, allNotes: repository.allNotes, pet: pet,
            showSettings: {}, openNote: { _ in XCTFail("开始录音不能打开便签") })
        voice.show()
        // Cancel synchronously before the authorization task runs: no microphone or OS prompts in tests.
        let phase = voice.recorder.phase
        let recordingWidth = NSApp.windows.first(where: { $0.title == "说给小鸟听" && $0.isVisible })?.frame.width
        let recordingHeight = NSApp.windows.first(where: { $0.title == "说给小鸟听" && $0.isVisible })?.frame.height
        voice.recorder.cancel()
        defer { voice.hide() }
        XCTAssertEqual(phase, .authorizing)
        XCTAssertEqual(recordingHeight, 36)
        XCTAssertLessThanOrEqual(try XCTUnwrap(recordingWidth), 128, "没有文字时只显示小胶囊")
        let panel = try XCTUnwrap(NSApp.windows.first(where: { $0.title == "说给小鸟听" && $0.isVisible }))
        XCTAssertFalse(panel.styleMask.contains(.titled))
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertLessThanOrEqual(panel.frame.width, 360)
        XCTAssertLessThanOrEqual(panel.frame.height, 96)
        XCTAssertTrue(session.document.string.isEmpty)
    }

    func testCompactDictationWritesCapturedTargetOnceAndResumesUnwrittenDraft() async throws {
        let (container, repository, documents, session) = try fixture()
        defer { withExtendedLifetime(container) {}; try? FileManager.default.removeItem(at: documents.root) }
        try session.createAndOpen()
        session.update(document: NSAttributedString(string: "原便签"), cursorLocation: 0)
        let first = try XCTUnwrap(session.currentNote)
        let name = "QuickNote-Voice-Local-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let pet = DesktopPetController(defaults: defaults)
        defer { pet.stop() }
        let voice = DesktopPetVoiceController(session: session, allNotes: repository.allNotes, pet: pet,
            showSettings: {}, openNote: { _ in XCTFail("听写写入不能弹出便签窗口") },
            analyze: { _, _ in XCTFail("直接听写不调用 AI"); throw AIAnalyzerError.invalidResponse },
            confirmSending: { _ in XCTFail("直接听写不上传"); return false })
        voice.show(startImmediately: false)
        defer { voice.hide() }
        voice.recorder.transcript = "明天下午三点评审"
        try await Task.sleep(for: .milliseconds(120))
        let hud = try XCTUnwrap(NSApp.windows.first(where: { $0.title == "说给小鸟听" && $0.isVisible }))
        let view = try XCTUnwrap(hud.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/quicknote-dictation-compact.png"))
        try session.createAndOpen()
        let second = try XCTUnwrap(session.currentNote)
        voice.writeTranscript()
        XCTAssertFalse(voice.isPresented)
        XCTAssertFalse(pet.quickActionsSuppressed)
        XCTAssertEqual(try documents.load(id: first.id).string, "原便签\n明天下午三点评审")
        XCTAssertEqual(session.currentNote?.id, second.id)
        voice.writeTranscript()
        XCTAssertEqual(try documents.load(id: first.id).string, "原便签\n明天下午三点评审")
        voice.show(startImmediately: false)
        voice.recorder.transcript = "还没保存的草稿"
        voice.hide()
        voice.show()
        XCTAssertEqual(voice.recorder.phase, .idle, "重新打开只能恢复草稿，不能自动重录覆盖")
        XCTAssertEqual(voice.recorder.transcript, "还没保存的草稿")
        XCTAssertTrue(pet.quickActionsSuppressed)
        session.update(document: NSAttributedString(string: "已手动修改"), cursorLocation: 0)
        voice.writeTranscript()
        XCTAssertFalse(voice.preview?.consumed ?? true)
        XCTAssertEqual(session.document.string, "已手动修改")
        XCTAssertFalse(voice.notice.isEmpty)
    }

    func testDictationHUDStaysWithinScreen() {
        for screen in [NSRect(x: 0, y: 0, width: 1440, height: 900), NSRect(x: -1280, y: -100, width: 1280, height: 800)] {
            for height: CGFloat in [52, 96, 212, 340] {
                XCTAssertTrue(screen.contains(DesktopPetVoiceController.hudFrame(in: screen, height: height)))
            }
        }
    }

    func testExplicitCancelDiscardsDraftAndIgnoresLateAIResult() async throws {
        let (container, repository, documents, session) = try fixture()
        defer { withExtendedLifetime(container) {}; try? FileManager.default.removeItem(at: documents.root) }
        try session.createAndOpen()
        let name = "QuickNote-Voice-Cancel-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let pet = DesktopPetController(defaults: defaults)
        defer { pet.stop() }
        var pending: CheckedContinuation<AITextResult, any Error>?
        let began = expectation(description: "AI suspended")
        let voice = DesktopPetVoiceController(session: session, allNotes: repository.allNotes, pet: pet,
            showSettings: {}, openNote: { _ in }, analyze: { _, _ in
                try await withCheckedThrowingContinuation { pending = $0; began.fulfill() }
            }, confirmSending: { _ in true })
        voice.show(startImmediately: false)
        defer { voice.hide() }
        voice.recorder.transcript = "这段内容不要保存"
        voice.interpret()
        await fulfillment(of: [began], timeout: 1)
        voice.close()
        pending?.resume(returning: AITextResult(text: "迟到的分析", providerName: "隔离测试"))
        for _ in 0..<8 { await Task.yield() }
        XCTAssertFalse(voice.isPresented)
        XCTAssertFalse(voice.isWorking)
        XCTAssertFalse(voice.hasProposal)
        XCTAssertNil(voice.preview)
        XCTAssertTrue(voice.result.isEmpty)
        XCTAssertTrue(voice.recorder.transcript.isEmpty)
        XCTAssertTrue(voice.notice.isEmpty)
        voice.show(startImmediately: false)
        XCTAssertTrue(voice.recorder.transcript.isEmpty, "取消的内容不能在重开后复活")
        XCTAssertTrue(session.document.string.isEmpty)
        XCTAssertEqual(try repository.allNotes().count, 1)
    }

    func testVoiceDetailsCanCollapseEvenWithNoticeOrProposal() async throws {
        let (container, repository, documents, session) = try fixture()
        defer { withExtendedLifetime(container) {}; try? FileManager.default.removeItem(at: documents.root) }
        try session.createAndOpen()
        let name = "QuickNote-Voice-Collapse-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let pet = DesktopPetController(defaults: defaults)
        defer { pet.stop() }
        let voice = DesktopPetVoiceController(session: session, allNotes: repository.allNotes, pet: pet,
            showSettings: {}, openNote: { _ in })
        voice.show(startImmediately: false)
        defer { voice.hide() }
        let window = try XCTUnwrap(NSApp.windows.first(where: { $0.title == "说给小鸟听" && $0.isVisible }))
        voice.toggleTranscript()
        XCTAssertLessThanOrEqual(window.frame.height, 164, "空转写不能撑出大块编辑区")
        XCTAssertLessThanOrEqual(window.frame.width, 340)
        try await Task.sleep(for: .milliseconds(160))
        let emptyView = try XCTUnwrap(window.contentView)
        emptyView.layoutSubtreeIfNeeded()
        let emptyBitmap = try XCTUnwrap(emptyView.bitmapImageRepForCachingDisplay(in: emptyView.bounds))
        emptyView.cacheDisplay(in: emptyView.bounds, to: emptyBitmap)
        try emptyBitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/quicknote-voice-empty-slim.png"))
        voice.toggleTranscript()
        voice.recorder.transcript = "保留这段原话"
        voice.toggleTranscript()
        try await Task.sleep(for: .milliseconds(220))
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/quicknote-voice-expanded.png"))
        voice.toggleTranscript()
        voice.stopWork()
        if !voice.showsTranscript { voice.toggleTranscript() }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertGreaterThan(window.frame.height, 96)
        voice.toggleTranscript()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertLessThanOrEqual(window.frame.height, 96, "提示信息不能强制撑开详情")
        voice.recordVerbatim()
        if !voice.showsTranscript { voice.toggleTranscript() }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertGreaterThan(window.frame.height, 96)
        voice.toggleTranscript()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertLessThanOrEqual(window.frame.height, 96, "处理结果也能收起")
        voice.toggleTranscript()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertGreaterThan(window.frame.height, 96)
        XCTAssertEqual(voice.recorder.transcript, "保留这段原话")
        XCTAssertEqual(voice.result, "保留这段原话")
        XCTAssertTrue(session.document.string.isEmpty)
    }

    func testSidebarAndThemedVoiceRenderWithoutOversizedRows() async throws {
        let folder = NoteFolder(name: "AI 销售工作台")
        let first = NoteRecord()
        first.title = "8.17 跟进代办"
        first.folderID = folder.id
        let second = NoteRecord()
        second.title = "8.27 上线功能"
        second.folderID = folder.id
        let third = NoteRecord()
        third.title = "注意事项"
        let drawer = NoteDrawerView(notes: [first, second, third], folders: [folder], selectedID: first.id,
            select: { _ in }, create: {}, createFolder: { _ in }, renameFolder: { _, _ in },
            deleteFolder: { _ in }, move: { _, _ in }, togglePin: { _ in }, delete: { _ in },
            theme: .system, search: { _ in [] }, selectMatch: { _, _ in }, editTags: { _ in })
        let samples: [(String, AnyView, NSSize)] = [
            ("sidebar", AnyView(drawer), NSSize(width: 232, height: 410)),
            ("voice-small", AnyView(VoiceRecordingCapsule(phase: .listening, text: "", level: 0.4,
                animateText: false, close: {}, stop: {})), NSSize(width: 120, height: 36)),
            ("voice-midnight", AnyView(VoiceRecordingCapsule(phase: .listening, text: "整理项目进展", level: 0.6,
                animateText: false, theme: .midnight, close: {}, stop: {})), NSSize(width: 300, height: 36))
        ]
        for (name, root, size) in samples {
            let view = NSHostingView(rootView: root)
            view.frame = NSRect(origin: .zero, size: size)
            let window = NSPanel(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = view
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(180))
            view.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(view.fittingSize.width, size.width)
            XCTAssertLessThanOrEqual(view.fittingSize.height, size.height)
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/quicknote-\(name)-refined.png"))
        }
    }

    func testAudioTapAcceptsSyntheticBufferOffMainThreadWithoutRecording() async throws {
        try await Task.detached {
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
            buffer.frameLength = 16
            buffer.floatChannelData?[0].initialize(repeating: 0, count: 16)
            LocalVoiceRecorder.audioTap(for: request, onLevel: { @Sendable level in
                XCTAssertEqual(level, 0)
            })(buffer, AVAudioTime(sampleTime: 0, atRate: 16_000))
            request.endAudio()
        }.value
    }

    func testIncompleteFormattingCannotSilentlyResetUnclassifiedParagraphs() throws {
        let editor = RichTextEditorController()
        let original = NSAttributedString(string: "标题\n正文\n另一个标题", attributes: [.font: EditorTextStyle.heading.font])
        let source = AIFormattingSource(document: original, material: "0\t标题\n1\t正文\n2\t另一个标题")
        let partial = try AIFormattingPlan.parse(#"{"paragraphs":[{"index":0,"style":"title"}]}"#)
        XCTAssertThrowsError(try editor.formattedDocument(partial, source: source))
    }

    func testVoiceIntentRejectsUnsupportedEmptyAndAmbiguousPayloads() throws {
        let proposal = try VoiceProposal.parse(#"{"action":"append","content":"明天 10 点评审","targetTitle":"项目"}"#)
        XCTAssertEqual(proposal.action, .append)
        XCTAssertEqual(proposal.content, "明天 10 点评审")
        for invalid in [#"{"action":"delete","content":"全部","targetTitle":""}"#,
                        #"{"action":"append","content":" ","targetTitle":""}"#,
                        #"{"action":"create","content":"正文"}"#] {
            XCTAssertThrowsError(try VoiceProposal.parse(invalid))
        }
    }

    func testVoiceAppendUsesCapturedNoteAndCannotBeAppliedTwice() throws {
        let (container, repository, documents, session) = try fixture()
        defer { withExtendedLifetime(container) {}; try? FileManager.default.removeItem(at: documents.root) }
        try session.createAndOpen()
        let first = try XCTUnwrap(session.currentNote)
        session.update(document: NSAttributedString(string: "原始便签"), cursorLocation: 0)
        let revision = session.contentRevision(for: first.id)
        var preview = VoiceNotePreview(action: .append, targetID: first.id, revision: revision,
                                       content: NSAttributedString(string: "语音补充"))
        try session.createAndOpen()
        let other = try XCTUnwrap(session.currentNote)
        XCTAssertEqual(try preview.apply(to: session), first.id)
        XCTAssertEqual(session.currentNote?.id, other.id)
        XCTAssertEqual(try documents.load(id: first.id).string, "原始便签\n语音补充")
        XCTAssertThrowsError(try preview.apply(to: session))
        XCTAssertEqual(try repository.allNotes().count, 2)
        XCTAssertTrue(session.document.string.isEmpty)
    }

    func testVoicePreviewRejectsStaleOrDeletedTarget() throws {
        let (container, repository, documents, session) = try fixture()
        defer { withExtendedLifetime(container) {}; try? FileManager.default.removeItem(at: documents.root) }
        try session.createAndOpen()
        let note = try XCTUnwrap(session.currentNote)
        var preview = VoiceNotePreview(action: .append, targetID: note.id, revision: session.contentRevision(for: note.id),
                                       content: NSAttributedString(string: "旧结果"))
        session.update(document: NSAttributedString(string: "更新的内容"), cursorLocation: 0)
        XCTAssertThrowsError(try preview.apply(to: session))
        XCTAssertFalse(preview.consumed)
        XCTAssertEqual(session.document.string, "更新的内容")
        var missing = VoiceNotePreview(action: .append, targetID: UUID(), revision: 0, content: NSAttributedString(string: "正文"))
        XCTAssertThrowsError(try missing.apply(to: session))
        XCTAssertEqual(try repository.allNotes().count, 1)
    }

    func testPreviousSaveFailureDoesNotConsumeANewVoiceDraft() throws {
        let (container, repository, documents, session) = try fixture()
        defer { withExtendedLifetime(container) {}; try? FileManager.default.removeItem(at: documents.root) }
        try session.createAndOpen()
        try session.appendPlainText("原文")
        let note = try XCTUnwrap(session.currentNote)
        var rejectsSave = true
        let failing = NoteSession(repository: repository, documents: documents, saveRepository: {
            if rejectsSave && note.plainText.contains("第一段") { throw CocoaError(.fileWriteNoPermission) }
            try repository.save()
        })
        try failing.open(note)
        var first = VoiceNotePreview(action: .append, targetID: note.id, revision: failing.contentRevision(for: note.id),
                                     content: NSAttributedString(string: "第一段"))
        XCTAssertThrowsError(try first.apply(to: failing))
        XCTAssertTrue(first.consumed)
        var second = VoiceNotePreview(action: .append, targetID: note.id, revision: failing.contentRevision(for: note.id),
                                      content: NSAttributedString(string: "第二段"))
        XCTAssertThrowsError(try second.apply(to: failing))
        XCTAssertFalse(second.consumed, "旧保存失败不能把这份未写入的草稿标为已应用")
        XCTAssertFalse(failing.document.string.contains("第二段"))
        rejectsSave = false
        failing.retrySave()
        XCTAssertNil(failing.saveError)
        _ = try second.apply(to: failing)
        XCTAssertTrue(failing.document.string.hasSuffix("第一段\n第二段"))
    }

    func testHideDuringConsentDoesNotStartAI() async throws {
        let (container, repository, documents, session) = try fixture()
        defer { withExtendedLifetime(container) {}; try? FileManager.default.removeItem(at: documents.root) }
        try session.createAndOpen()
        let defaultsName = "QuickNote-Voice-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let pet = DesktopPetController(defaults: defaults)
        defer { pet.stop() }
        var calls = 0
        var onConfirm: (() -> Void)?
        let voice = DesktopPetVoiceController(session: session, allNotes: repository.allNotes, pet: pet,
            showSettings: {}, openNote: { _ in }, analyze: { _, _ in
                calls += 1
                return AITextResult(text: #"{"action":"create","content":"明天开会","targetTitle":""}"#, providerName: "测试")
            }, confirmSending: { _ in onConfirm?(); return true })
        onConfirm = { [weak voice] in voice?.hide() }
        voice.recorder.transcript = "帮我记下明天开会"
        voice.interpret()
        for _ in 0..<8 { await Task.yield() }
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(voice.isWorking)
        XCTAssertFalse(voice.hasProposal)
        voice.hide()
    }

    func testVoiceFormattingPreservesTextAttachmentAndRevision() throws {
        let (container, _, documents, session) = try fixture()
        defer { withExtendedLifetime(container) {}; try? FileManager.default.removeItem(at: documents.root) }
        try session.createAndOpen()
        let note = try XCTUnwrap(session.currentNote)
        let text = NSMutableAttributedString(string: "标题\n正文\n", attributes: [.font: EditorTextStyle.body.font])
        let attachment = NSTextAttachment()
        let wrapper = FileWrapper(regularFileWithContents: Data([1, 2, 3, 4]))
        wrapper.preferredFilename = "sample.txt"
        attachment.fileWrapper = wrapper
        text.append(NSAttributedString(attachment: attachment))
        session.update(document: text, cursorLocation: 0)
        let original = try session.documentSnapshot(for: note.id)
        let editor = RichTextEditorController()
        let source = try editor.aiFormattingSource(document: original)
        let plan = try AIFormattingPlan.parse(#"{"paragraphs":[{"index":0,"style":"title"},{"index":1,"style":"body"}]}"#)
        let formatted = try editor.formattedDocument(plan, source: source)
        var preview = VoiceNotePreview(action: .format, targetID: note.id, revision: session.contentRevision(for: note.id),
                                       content: formatted, original: original)
        _ = try preview.apply(to: session)
        XCTAssertEqual(session.document.string, original.string)
        let retained = try XCTUnwrap(session.document.attribute(.attachment, at: session.document.length - 1, effectiveRange: nil) as? NSTextAttachment)
        XCTAssertEqual(retained.fileWrapper?.regularFileContents, Data([1, 2, 3, 4]))
        XCTAssertGreaterThan((session.document.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? 0,
                             EditorTextStyle.body.font.pointSize)
    }

    func testApplicationHideInvalidatesPendingAIAndKeepsDraft() async throws {
        let (container, repository, documents, session) = try fixture()
        defer { withExtendedLifetime(container) {}; try? FileManager.default.removeItem(at: documents.root) }
        try session.createAndOpen()
        let defaultsName = "QuickNote-Voice-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let pet = DesktopPetController(defaults: defaults)
        defer { pet.stop() }
        var pending: CheckedContinuation<AITextResult, any Error>?
        let began = expectation(description: "AI boundary suspended")
        let voice = DesktopPetVoiceController(session: session, allNotes: repository.allNotes, pet: pet,
            showSettings: {}, openNote: { _ in }, analyze: { _, _ in
                try await withCheckedThrowingContinuation { pending = $0; began.fulfill() }
            }, confirmSending: { _ in true })
        voice.show(startImmediately: false)
        voice.recorder.transcript = "帮我记下明天开会"
        voice.interpret()
        await fulfillment(of: [began], timeout: 1)
        XCTAssertTrue(voice.isWorking)
        NotificationCenter.default.post(name: NSApplication.didHideNotification, object: NSApp)
        for _ in 0..<8 { await Task.yield() }
        XCTAssertFalse(voice.isPresented)
        XCTAssertEqual(voice.recorder.transcript, "帮我记下明天开会")
        pending?.resume(returning: AITextResult(text: #"{"action":"create","content":"明天开会","targetTitle":""}"#, providerName: "测试"))
        for _ in 0..<8 { await Task.yield() }
        XCTAssertFalse(voice.hasProposal)
        XCTAssertFalse(voice.isWorking)
        XCTAssertNil(voice.preview)
        XCTAssertTrue(session.document.string.isEmpty)
        XCTAssertEqual(try repository.allNotes().count, 1)
        XCTAssertEqual(voice.recorder.phase, .idle)
        voice.hide()
    }

    func testMicrophoneEntryOnlyRevealsOnHoverAtEveryPetScale() throws {
        let defaultsName = "QuickNote-Voice-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let pet = DesktopPetController(defaults: defaults)
        defer { pet.stop() }
        pet.setEnabled(true)
        XCTAssertFalse(pet.quickActionsPanel.isVisible)
        let view = try XCTUnwrap(pet.quickActionsPanel.contentView)
        let mic = try XCTUnwrap(view.subviews.compactMap { $0 as? NSButton }.first(where: { $0.tag == DesktopPetController.Action.voice.rawValue }))
        XCTAssertEqual(mic.accessibilityLabel(), "语音便签")
        var invoked = false
        pet.onAction = { action, _ in invoked = action == .voice }
        for scale: CGFloat in [0.5, 1, 1.5] {
            pet.setScale(scale)
            XCTAssertFalse(pet.quickActionsPanel.isVisible)
            pet.updateQuickActions(at: NSPoint(x: pet.petPanel.frame.midX, y: pet.petPanel.frame.midY))
            XCTAssertTrue(pet.quickActionsPanel.isVisible)
            XCTAssertTrue(view.bounds.contains(mic.frame))
            XCTAssertEqual(mic.frame.size, NSSize(width: 36, height: 36))
        }
        mic.performClick(nil)
        XCTAssertTrue(invoked)
    }

    func testVoiceDraftLocalPreviewDoesNotRestartRecording() async throws {
        let (container, repository, documents, session) = try fixture()
        defer { withExtendedLifetime(container) {}; try? FileManager.default.removeItem(at: documents.root) }
        try session.createAndOpen()
        let defaultsName = "QuickNote-Voice-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let pet = DesktopPetController(defaults: defaults)
        defer { pet.stop() }
        let voice = DesktopPetVoiceController(session: session, allNotes: repository.allNotes, pet: pet,
            showSettings: {}, openNote: { _ in }, analyze: { _, _ in
                XCTFail("本地记录不应调用 AI")
                throw AIAnalyzerError.invalidResponse
            }, confirmSending: { _ in XCTFail("本地记录不应申请上传"); return false })
        voice.show(startImmediately: false)
        defer { voice.hide() }
        XCTAssertEqual(voice.recorder.phase, .idle)
        voice.recorder.transcript = "本周工作计划\n完成产品原型，周五下午三点进行评审。\n\n一、需要准备\n整理用户反馈和功能清单。"
        voice.recordVerbatim()
        voice.preparePreview()
        XCTAssertNotNil(voice.preview)
        XCTAssertTrue(session.document.string.isEmpty)
        try await Task.sleep(for: .milliseconds(100))
        let window = try XCTUnwrap(NSApp.windows.first(where: { $0.title == "说给小鸟听" }))
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/quicknote-voice-preview.png"))
        XCTAssertEqual(voice.recorder.phase, .idle)
        voice.applyPreview()
        XCTAssertEqual(try repository.allNotes().count, 2)
        let saved = session.document.string
        voice.applyPreview()
        XCTAssertEqual(try repository.allNotes().count, 2)
        XCTAssertEqual(session.document.string, saved)
    }

    private func fixture() throws -> (ModelContainer, NoteRepository, NoteDocumentStore, NoteSession) {
        let container = try ModelContainer(for: NoteRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let repository = NoteRepository(context: container.mainContext)
        let documents = NoteDocumentStore(root: FileManager.default.temporaryDirectory.appending(path: "QuickNote-Voice-\(UUID().uuidString)"))
        return (container, repository, documents, NoteSession(repository: repository, documents: documents))
    }
}
