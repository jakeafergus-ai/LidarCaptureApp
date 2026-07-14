import AVFoundation

final class VideoWriter {
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var sessionStarted = false

    func start(outputURL: URL, formatDescription: CMFormatDescription, bitsPerSecond: Int) throws {
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: dimensions.width,
            AVVideoHeightKey: dimensions.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitsPerSecond,
                AVVideoExpectedSourceFrameRateKey: 30
            ]
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw NSError(domain: "VideoWriter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot add video input"])
        }
        writer.add(input)
        writer.startWriting()

        assetWriter = writer
        videoInput = input
        sessionStarted = false
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard let writer = assetWriter, let input = videoInput else { return }

        if !sessionStarted {
            let startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: startTime)
            sessionStarted = true
        }

        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }

    func finish(completion: @escaping () -> Void) {
        guard let writer = assetWriter, let input = videoInput, sessionStarted else {
            completion()
            return
        }
        input.markAsFinished()
        writer.finishWriting(completionHandler: completion)
    }
}
