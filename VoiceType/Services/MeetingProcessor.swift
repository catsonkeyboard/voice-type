import Foundation

/// 会议处理编排：解码 → 说话人分离 → 段合并 → 逐段转写 → 落盘 JSON。
/// 分离失败自动降级为整段转写（degraded 标记）。
final class MeetingProcessor: @unchecked Sendable {
    private let asr: AsrService
    private let diarization = DiarizationService()

    init(asr: AsrService) {
        self.asr = asr
    }

    func process(
        url: URL,
        numSpeakers: Int?,
        onProgress: @escaping @Sendable @MainActor (String, Double) -> Void
    ) async throws -> (transcript: MeetingTranscript, jsonURL: URL) {
        await onProgress("解码音频…", 0)
        let samples = try AudioFileDecoder.decode16kMono(url: url)
        let duration = Double(samples.count) / 16000.0

        var segments: [SpeakerSegment] = []
        var degraded = false
        do {
            await onProgress("说话人分离…", 0.1)
            let raw = try await diarization.diarize(samples: samples, numSpeakers: numSpeakers)
            segments = DiarizationService.mergeAdjacent(raw)
            if segments.isEmpty { degraded = true }
        } catch {
            degraded = true
        }

        if degraded {
            let text = try await asr.transcribeFile(url: url) { p in
                Task { @MainActor in onProgress("整段转写中…", 0.3 + p * 0.65) }
            }
            segments = [SpeakerSegment(speaker: 0, start: 0, end: duration, text: text)]
        } else {
            for i in segments.indices {
                await onProgress(
                    "转写 \(i + 1)/\(segments.count) 段…",
                    0.2 + 0.75 * Double(i) / Double(max(segments.count, 1)))
                let lo = max(0, Int(segments[i].start * 16000))
                let hi = min(samples.count, Int(segments[i].end * 16000))
                guard hi > lo else { continue }
                segments[i].text =
                    (try? await asr.transcribe(samples: Array(samples[lo..<hi]))) ?? ""
            }
            segments.removeAll { $0.text.isEmpty }
        }

        await onProgress("保存…", 0.98)
        let transcript = MeetingTranscript(
            createdAt: .now, duration: duration, audioFile: url.lastPathComponent,
            segments: segments, speakerNames: [:], degraded: degraded)
        let jsonName = url.deletingPathExtension().lastPathComponent + ".json"
        let jsonURL = MeetingTranscript.meetingsDir.appendingPathComponent(jsonName)
        try transcript.save(to: jsonURL)
        return (transcript, jsonURL)
    }
}
