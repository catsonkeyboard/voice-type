import AVFoundation

enum AudioDecodeError: LocalizedError {
    case unsupportedFormat
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: return "不支持的音频格式"
        case .conversionFailed(let msg): return "音频转换失败：\(msg)"
        }
    }
}

enum AudioFileDecoder {
    /// 解码任意 AVFoundation 支持的音频文件（wav/mp3/m4a...）为 16kHz 单声道 Float32
    static func decode16kMono(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let srcFormat = file.processingFormat
        guard
            let dstFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1,
                interleaved: false),
            let converter = AVAudioConverter(from: srcFormat, to: dstFormat)
        else { throw AudioDecodeError.unsupportedFormat }

        var result: [Float] = []
        var reachedEnd = false
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if reachedEnd {
                status.pointee = .endOfStream
                return nil
            }
            guard let buf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: 8192) else {
                status.pointee = .endOfStream
                return nil
            }
            do { try file.read(into: buf) } catch {
                reachedEnd = true
                status.pointee = .endOfStream
                return nil
            }
            if buf.frameLength == 0 {
                reachedEnd = true
                status.pointee = .endOfStream
                return nil
            }
            status.pointee = .haveData
            return buf
        }

        while true {
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: 8192) else {
                throw AudioDecodeError.unsupportedFormat
            }
            var convError: NSError?
            let status = converter.convert(to: outBuf, error: &convError, withInputFrom: inputBlock)
            if let convError { throw AudioDecodeError.conversionFailed(convError.localizedDescription) }
            if outBuf.frameLength > 0 {
                result.append(
                    contentsOf: UnsafeBufferPointer(
                        start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
            }
            if status == .endOfStream { break }
            if status == .error { throw AudioDecodeError.conversionFailed("convert error") }
        }
        return result
    }
}
