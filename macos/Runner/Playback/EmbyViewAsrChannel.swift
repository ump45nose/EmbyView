import AetherLibavutil
import AetherLibswresample
import CryptoKit
import FlutterMacOS
import Foundation
import whisper

private struct AsrError: LocalizedError {
    let code: String
    let errorDescription: String?

    init(_ code: String, _ description: String) {
        self.code = code
        errorDescription = description
    }
}

enum AsrAudio {
    static func resample(_ pcm: Data, sampleRate: Int) throws -> [Float] {
        let frames = pcm.count / MemoryLayout<Float>.size
        guard sampleRate == 48_000, pcm.count.isMultiple(of: 4), frames <= Int(Int32.max) else {
            throw AsrError("invalidPcm", "听写需要 48 kHz 单声道 Float32 PCM")
        }
        guard frames > 0 else { return [] }

        var mono = AVChannelLayout()
        av_channel_layout_default(&mono, 1)
        var context: OpaquePointer?
        defer {
            swr_free(&context)
            av_channel_layout_uninit(&mono)
        }
        let failure = AsrError("resampleFailed", "无法转换听写音频的采样率")
        guard swr_alloc_set_opts2(&context, &mono, AV_SAMPLE_FMT_FLT, 16_000,
            &mono, AV_SAMPLE_FMT_FLT, 48_000, 0, nil) >= 0,
            let context, swr_init(context) >= 0 else { throw failure }

        let capacity = swr_get_out_samples(context, Int32(frames))
        guard capacity > 0 else { throw failure }
        var samples = [Float](repeating: 0, count: Int(capacity))
        let count = try samples.withUnsafeMutableBytes { output in
            try pcm.withUnsafeBytes { input in
                var source = input.bindMemory(to: UInt8.self).baseAddress
                var destination = output.bindMemory(to: UInt8.self).baseAddress
                let written = swr_convert(context, &destination, capacity, &source, Int32(frames))
                guard written >= 0 else { throw failure }
                destination = destination?.advanced(by: Int(written) * 4)
                let tail = swr_convert(context, &destination, capacity - written, nil, 0)
                guard tail >= 0 else { throw failure }
                return Int(written + tail)
            }
        }
        samples.removeLast(samples.count - count)
        return samples
    }

    // whisper.cpp reports centiseconds. Model padding can extend past the PCM.
    static func segment(start: Int64, end: Int64, text: String, durationUs: Int64) -> [String: Any]? {
        let startUs = min(durationUs, max(0, start) * 10_000)
        let endUs = min(durationUs, max(0, end) * 10_000)
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard endUs > startUs, !line.isEmpty else { return nil }
        return ["startUs": startUs, "endUs": endUs, "text": line]
    }
}

final class AsrModelStore: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let filename = "ggml-large-v3-turbo-q5_0.bin"
    private static let sources = [
        "https://modelscope.cn/models/iceCream2025/whisper.cpp/resolve/7a197569abec2d6035db01d32c09c408c5af9418/",
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/",
    ].map { URL(string: $0 + filename)! }

    let modelURL: URL
    private let partial: URL
    private let sources: [URL]
    private let size: Int64
    private let digest: String
    private let configuration: URLSessionConfiguration
    private let queue = DispatchQueue(label: "embyview.asr.model", qos: .utility)
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var file: FileHandle?
    private var state: String
    private var error: String?
    private var received: Int64
    private var responseEnd: Int64 = 0
    private var sourceIndex = 0
    private var generation = UUID()

    convenience override init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "org.moonfin.app")
            .appendingPathComponent("EmbyView/models", isDirectory: true)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        self.init(directory: directory, sources: Self.sources, size: 574_041_195,
            digest: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2", configuration: config)
    }

    init(directory: URL, sources: [URL], size: Int64, digest: String, configuration: URLSessionConfiguration) {
        self.sources = sources
        self.size = size
        self.digest = digest
        self.configuration = configuration
        modelURL = directory.appendingPathComponent(Self.filename)
        partial = modelURL.appendingPathExtension("part")
        let ready = Self.fileSize(modelURL) == size
        state = ready ? "ready" : "notDownloaded"
        received = ready ? size : Self.fileSize(partial)
        super.init()
    }

    private static func fileSize(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    func status() -> [String: Any] {
        queue.sync {
            var values: [String: Any] = ["state": state, "receivedBytes": received, "totalBytes": size]
            values["error"] = error
            return values
        }
    }

    func download() {
        queue.sync {
            guard state != "ready", state != "downloading" else { return }
            do {
                try FileManager.default.createDirectory(at: modelURL.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                received = Self.fileSize(partial)
                if received > size {
                    try FileManager.default.removeItem(at: partial)
                    received = 0
                }
                state = "downloading"
                error = nil
                sourceIndex = 0
                if received == size { try verify(); return }
                startRequest()
            } catch { finish(error) }
        }
    }

    func cancel() {
        queue.sync {
            guard state == "downloading" else { return }
            stop()
            state = "notDownloaded"
        }
    }

    func delete() throws {
        try queue.sync {
            stop()
            do {
                for url in [partial, modelURL] where FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                received = 0
                state = "notDownloaded"
                error = nil
            } catch {
                finish(error)
                throw error
            }
        }
    }

    private func startRequest() {
        if session == nil {
            let callbacks = OperationQueue()
            callbacks.maxConcurrentOperationCount = 1
            callbacks.underlyingQueue = queue
            session = URLSession(configuration: configuration, delegate: self, delegateQueue: callbacks)
        }
        var request = URLRequest(url: sources[sourceIndex])
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if received > 0 { request.setValue("bytes=\(received)-", forHTTPHeaderField: "Range") }
        task = session?.dataTask(with: request)
        task?.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard dataTask === task else { completionHandler(.cancel); return }
        do {
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            let offset: Int64
            switch http.statusCode {
            case 200:
                offset = 0 // A mirror may ignore Range. Start its full body at byte zero.
                responseEnd = size
            case 206:
                let value = http.value(forHTTPHeaderField: "Content-Range") ?? ""
                let parts = value.components(separatedBy: CharacterSet(charactersIn: " -/"))
                guard parts.count == 4, parts[0].lowercased() == "bytes", Int64(parts[1]) == received,
                      let end = Int64(parts[2]), end >= received, end < size,
                      Int64(parts[3]) == size else { throw URLError(.badServerResponse) }
                offset = received
                responseEnd = end + 1
            default:
                throw AsrError("modelDownload", "模型下载失败（HTTP \(http.statusCode)）")
            }
            if !FileManager.default.fileExists(atPath: partial.path) {
                guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            file = try FileHandle(forWritingTo: partial)
            if offset == 0 { try file?.truncate(atOffset: 0) }
            try file?.seek(toOffset: UInt64(offset))
            received = offset
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
            tryNextSource(error)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask === task, let file else { return }
        do {
            guard Int64(data.count) <= responseEnd - received else { throw URLError(.badServerResponse) }
            try file.write(contentsOf: data)
            received += Int64(data.count)
        } catch { tryNextSource(error) }
    }

    func urlSession(_ session: URLSession, task completed: URLSessionTask, didCompleteWithError error: Error?) {
        guard completed === task else { return }
        do {
            try file?.close()
            file = nil
            task = nil
            if let error { throw error }
            guard received == responseEnd, received > 0 else { throw URLError(.networkConnectionLost) }
            if received == size { try verify() } else { startRequest() }
        } catch { tryNextSource(error) }
    }

    // Verification runs off the delegate queue so status, deletion and cancellation
    // keep responding. The open descriptor and generation bind the hash to one file.
    private func verify() throws {
        let handle = try FileHandle(forReadingFrom: partial)
        let generation = self.generation
        DispatchQueue.global(qos: .utility).async {
            let checksum = Result<String, Error> {
                defer { try? handle.close() }
                var hash = SHA256()
                while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
                    hash.update(data: data)
                }
                return hash.finalize().map { String(format: "%02x", $0) }.joined()
            }
            self.queue.async {
                guard generation == self.generation else { return }
                do {
                    guard try checksum.get() == self.digest else {
                        try FileManager.default.removeItem(at: self.partial)
                        self.received = 0
                        throw AsrError("modelChecksum", "听写模型 SHA-256 校验失败")
                    }
                    if FileManager.default.fileExists(atPath: self.modelURL.path) {
                        _ = try FileManager.default.replaceItemAt(self.modelURL, withItemAt: self.partial)
                    } else {
                        try FileManager.default.moveItem(at: self.partial, to: self.modelURL)
                    }
                    self.stop()
                    self.state = "ready"
                } catch { self.tryNextSource(error) }
            }
        }
    }

    private func tryNextSource(_ error: Error) {
        task?.cancel()
        task = nil
        try? file?.close()
        file = nil
        received = Self.fileSize(partial)
        sourceIndex += 1
        if sourceIndex < sources.count, received < size { startRequest() }
        else { finish(error) }
    }

    private func stop() {
        generation = UUID()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        try? file?.close()
        file = nil
    }

    private func finish(_ failure: Error) {
        stop()
        state = "failed"
        error = failure.localizedDescription
    }
}

private final class AsrRequest {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
    static let cancellation = AsrError("cancelled", "已取消听写")
}

// whisper_context is not thread-safe. Only the serial inference queue owns it.
private final class AsrRecognizer {
    private var context: OpaquePointer?
    deinit { reset() }

    func reset() {
        if let context { whisper_free(context) }
        context = nil
    }

    func transcribe(_ pcm: Data, sampleRate: Int, model: URL, request: AsrRequest) throws -> [String: Any] {
        guard !request.isCancelled else { throw AsrRequest.cancellation }
        let samples = try AsrAudio.resample(pcm, sampleRate: sampleRate)
        guard !samples.isEmpty else { return ["language": "und", "segments": []] }
        if context == nil {
            var options = whisper_context_default_params()
            options.use_gpu = true
            context = whisper_init_from_file_with_params(model.path, options)
        }
        guard let context else { throw AsrError("modelLoadFailed", "无法载入本机听写模型") }
        guard !request.isCancelled else { throw AsrRequest.cancellation }

        var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        params.no_context = true
        params.n_max_text_ctx = 0
        params.vad = false
        params.language = nil // Auto-detect and continue decoding in the original language.
        params.translate = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.abort_callback_user_data = Unmanaged.passUnretained(request).toOpaque()
        params.abort_callback = { pointer in
            guard let pointer else { return false }
            return Unmanaged<AsrRequest>.fromOpaque(pointer).takeUnretainedValue().isCancelled
        }
        let code = samples.withUnsafeBufferPointer { buffer in
            whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
        }
        if request.isCancelled || code != 0 {
            reset()
            if request.isCancelled { throw AsrRequest.cancellation }
            throw AsrError("transcriptionFailed", "本机听写失败（\(code)）")
        }
        let language = whisper_lang_str(whisper_full_lang_id(context)).map { String(cString: $0) } ?? "und"
        let durationUs = Int64(pcm.count / 4) * 1_000_000 / Int64(sampleRate)
        let segments = (0..<whisper_full_n_segments(context)).compactMap { index -> [String: Any]? in
            guard let text = whisper_full_get_segment_text(context, index) else { return nil }
            return AsrAudio.segment(start: whisper_full_get_segment_t0(context, index),
                end: whisper_full_get_segment_t1(context, index), text: String(cString: text), durationUs: durationUs)
        }
        return ["language": language, "segments": segments]
    }
}

final class EmbyViewAsrChannel {
    private let store = AsrModelStore()
    private let recognizer = AsrRecognizer()
    private let inference = DispatchQueue(label: "embyview.asr.inference", qos: .utility)
    private var requests: [String: AsrRequest] = [:] // Main (Flutter platform) thread.

    static func register(messenger: FlutterBinaryMessenger) {
        let bridge = EmbyViewAsrChannel()
        let channel = FlutterMethodChannel(name: "embyview/asr", binaryMessenger: messenger)
        channel.setMethodCallHandler(bridge.handle)
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        do {
            switch call.method {
            case "modelStatus":
                result(store.status())
            case "downloadModel":
                store.download()
                result(nil)
            case "cancelDownload":
                store.cancel()
                result(nil)
            case "deleteModel":
                requests.values.forEach { $0.cancel() }
                inference.async { self.recognizer.reset() }
                try store.delete()
                result(nil)
            case "cancelTranscription":
                if let id = args?["requestId"] as? String { requests[id]?.cancel() }
                result(nil)
            case "transcribe":
                guard let id = args?["requestId"] as? String, !id.isEmpty,
                      let pcm = args?["pcm"] as? FlutterStandardTypedData, let rate = args?["sampleRate"] as? Int else {
                    throw AsrError("invalidArguments", "缺少听写音频、采样率或请求编号")
                }
                guard requests[id] == nil else { throw AsrError("duplicateRequest", "听写请求编号重复") }
                guard store.status()["state"] as? String == "ready" else {
                    throw AsrError("modelNotReady", "请在设置中下载本机听写模型")
                }
                let request = AsrRequest()
                requests[id] = request
                let data = pcm.data
                inference.async {
                    let answer = Result { try self.recognizer.transcribe(data, sampleRate: rate,
                                                                        model: self.store.modelURL, request: request) }
                    DispatchQueue.main.async {
                        self.requests.removeValue(forKey: id)
                        do {
                            if request.isCancelled { throw AsrRequest.cancellation }
                            result(try answer.get())
                        } catch { result(Self.flutterError(error)) }
                    }
                }
            default:
                result(FlutterMethodNotImplemented)
            }
        } catch { result(Self.flutterError(error)) }
    }

    private static func flutterError(_ error: Error) -> FlutterError {
        FlutterError(code: (error as? AsrError)?.code ?? "asrError", message: error.localizedDescription, details: nil)
    }
}
