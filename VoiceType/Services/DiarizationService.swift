import Foundation

enum DiarizationError: LocalizedError {
    case modelMissing

    var errorDescription: String? {
        switch self {
        case .modelMissing:
            return "说话人分离模型未安装，请运行 scripts/setup_diarization.sh"
        }
    }
}

struct SpeakerSegment: Codable, Equatable {
    var speaker: Int
    var start: Double
    var end: Double
    var text: String = ""
}

/// 说话人分离：pyannote 分段 + 3D-Speaker 声纹聚类（sherpa-onnx，纯本地）。
/// 推理在专用串行队列执行，模型懒加载常驻。
final class DiarizationService: @unchecked Sendable {
    private var wrapper: SherpaOnnxOfflineSpeakerDiarizationWrapper?
    private var loadedNumClusters: Int = .min
    private let queue = DispatchQueue(
        label: "com.catsonkeyboard.voicetype.diarization", qos: .userInitiated)

    /// numSpeakers 为 nil 时自动估计人数
    func diarize(samples: [Float], numSpeakers: Int?) async throws -> [SpeakerSegment] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    cont.resume(
                        returning: try self.diarizeSync(
                            samples: samples, numSpeakers: numSpeakers))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func diarizeSync(samples: [Float], numSpeakers: Int?) throws -> [SpeakerSegment] {
        guard ModelPaths.diarizationPresent else { throw DiarizationError.modelMissing }
        let clusters = numSpeakers ?? -1
        if wrapper == nil || loadedNumClusters != clusters {
            var config = sherpaOnnxOfflineSpeakerDiarizationConfig(
                segmentation: sherpaOnnxOfflineSpeakerSegmentationModelConfig(
                    pyannote: sherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig(
                        model: ModelPaths.segmentationModel.path),
                    numThreads: 2),
                embedding: sherpaOnnxSpeakerEmbeddingExtractorConfig(
                    model: ModelPaths.speakerEmbeddingModel.path, numThreads: 2),
                clustering: sherpaOnnxFastClusteringConfig(
                    numClusters: clusters, threshold: 0.5))
            wrapper = SherpaOnnxOfflineSpeakerDiarizationWrapper(config: &config)
            loadedNumClusters = clusters
        }
        guard let wrapper, wrapper.impl != nil else { throw DiarizationError.modelMissing }
        return wrapper.process(samples: samples).map {
            SpeakerSegment(speaker: $0.speaker, start: Double($0.start), end: Double($0.end))
        }
    }

    /// 相邻同说话人且间隔 ≤ maxGap 秒的段合并（减少转写碎片）
    static func mergeAdjacent(_ segments: [SpeakerSegment], maxGap: Double = 1.0)
        -> [SpeakerSegment]
    {
        var result: [SpeakerSegment] = []
        for seg in segments.sorted(by: { $0.start < $1.start }) {
            if var last = result.last, last.speaker == seg.speaker,
                seg.start - last.end <= maxGap
            {
                last.end = max(last.end, seg.end)
                result[result.count - 1] = last
            } else {
                result.append(seg)
            }
        }
        return result
    }
}
