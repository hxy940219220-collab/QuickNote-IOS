@preconcurrency import AppKit
@preconcurrency import AVFAudio

final class AudioTextAttachment: NSTextAttachment {
    private(set) var originalFilename = "音频"
    private(set) var playback = AudioPlaybackController(data: Data())
    var maximumWidth: CGFloat = 360

    init(audioFileWrapper: FileWrapper) {
        super.init(data: nil, ofType: nil)
        fileWrapper = audioFileWrapper
        configureFromFileWrapper()
    }

    override init(data contentData: Data?, ofType uti: String?) {
        super.init(data: contentData, ofType: uti)
        configureFromFileWrapper()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureFromFileWrapper()
    }

    override func viewProvider(
        for parentView: NSView?,
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        AudioAttachmentViewProvider(
            textAttachment: self,
            parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager,
            location: location
        )
    }

    private func configureFromFileWrapper() {
        let stored = fileWrapper?.preferredFilename ?? fileWrapper?.filename ?? "音频"
        originalFilename = AttachmentPresentation.originalAudioFilename(from: stored) ?? stored
        playback = AudioPlaybackController(data: fileWrapper?.regularFileContents ?? Data())
        allowsTextAttachmentView = true
        attachmentCell = nil
    }
}

final class AudioAttachmentViewProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        guard let attachment = textAttachment as? AudioTextAttachment else {
            view = MainActor.assumeIsolated { NSView() }
            return
        }
        let filename = attachment.originalFilename
        let playback = attachment.playback
        let maximumWidth = attachment.maximumWidth
        let playerView = MainActor.assumeIsolated {
            let view = AudioAttachmentPlayerView(
                filename: filename,
                playback: playback
            )
            view.frame = NSRect(x: 0, y: 0, width: maximumWidth, height: 34)
            return view
        }
        view = playerView
        tracksTextAttachmentViewBounds = true
    }

    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {
        let maximum = (textAttachment as? AudioTextAttachment)?.maximumWidth ?? 360
        let available = proposedLineFragment.width > 0 ? proposedLineFragment.width : maximum
        return CGRect(x: 0, y: -6, width: min(maximum, available), height: 34)
    }
}

final class AudioPlaybackController: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private var player: AVAudioPlayer?
    private var progressTimer: Timer?
    var onUpdate: ((Bool, TimeInterval, TimeInterval) -> Void)?

    init(data: Data) {
        player = try? AVAudioPlayer(data: data)
        super.init()
        player?.delegate = self
        player?.prepareToPlay()
    }

    var duration: TimeInterval { player?.duration ?? 0 }

    func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            stopProgressTimer()
        } else {
            player.play()
            startProgressTimer()
        }
        emitUpdate()
    }

    func seek(to time: TimeInterval) {
        player?.currentTime = min(max(time, 0), duration)
        emitUpdate()
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        stopProgressTimer()
        emitUpdate()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        player.currentTime = 0
        stopProgressTimer()
        emitUpdate()
    }

    private func startProgressTimer() {
        stopProgressTimer()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.emitUpdate()
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func emitUpdate() {
        onUpdate?(player?.isPlaying == true, player?.currentTime ?? 0, duration)
    }
}

final class AudioAttachmentPlayerView: NSView {
    private let playback: AudioPlaybackController
    private let playButton = NSButton()
    private let filenameLabel = NSTextField(labelWithString: "")
    private let progressSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let timeLabel = NSTextField(labelWithString: "0:00 / 0:00")

    init(filename: String, playback: AudioPlaybackController) {
        self.playback = playback
        super.init(frame: .zero)
        setup(filename: filename)
        playback.onUpdate = { [weak self] isPlaying, currentTime, duration in
            self?.update(isPlaying: isPlaying, currentTime: currentTime, duration: duration)
        }
        update(isPlaying: false, currentTime: 0, duration: playback.duration)
    }

    required init?(coder: NSCoder) { nil }

    private func setup(filename: String) {
        playButton.identifier = NSUserInterfaceItemIdentifier("quicknote.audio.playPause")
        playButton.isBordered = false
        playButton.imagePosition = .imageOnly
        playButton.contentTintColor = .controlAccentColor
        playButton.target = self
        playButton.action = #selector(togglePlayback)

        filenameLabel.stringValue = filename
        filenameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        filenameLabel.lineBreakMode = .byTruncatingMiddle
        filenameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        progressSlider.identifier = NSUserInterfaceItemIdentifier("quicknote.audio.progress")
        progressSlider.controlSize = .small
        progressSlider.isContinuous = true
        progressSlider.target = self
        progressSlider.action = #selector(seek)

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.alignment = .right

        let views = [playButton, filenameLabel, progressSlider, timeLabel]
        views.forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            playButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            playButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 34),
            playButton.heightAnchor.constraint(equalToConstant: 34),
            filenameLabel.leadingAnchor.constraint(equalTo: playButton.trailingAnchor, constant: 6),
            filenameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            filenameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 130),
            progressSlider.leadingAnchor.constraint(equalTo: filenameLabel.trailingAnchor, constant: 8),
            progressSlider.centerYAnchor.constraint(equalTo: centerYAnchor),
            timeLabel.leadingAnchor.constraint(equalTo: progressSlider.trailingAnchor, constant: 8),
            timeLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            timeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            timeLabel.widthAnchor.constraint(equalToConstant: 76),
        ])
    }

    @objc private func togglePlayback() {
        playback.toggle()
    }

    @objc private func seek() {
        playback.seek(to: progressSlider.doubleValue)
    }

    private func update(isPlaying: Bool, currentTime: TimeInterval, duration: TimeInterval) {
        let action = isPlaying ? "暂停" : "播放"
        let image = NSImage(
            systemSymbolName: isPlaying ? "pause.circle.fill" : "play.circle.fill",
            accessibilityDescription: action
        )
        playButton.image = image?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        )
        playButton.toolTip = action
        playButton.setAccessibilityLabel(action)
        progressSlider.maxValue = max(duration, 1)
        progressSlider.doubleValue = currentTime
        timeLabel.stringValue = "\(format(currentTime)) / \(format(duration))"
    }

    private func format(_ time: TimeInterval) -> String {
        let seconds = max(0, Int(time.rounded(.down)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
