import CoreGraphics
import CoreML
import FlutterMacOS
import Foundation
import ImageIO
import Vision

/// Detects prominent title-like text baked into Emby backdrop images using
/// macOS Vision on a background queue, downscaling inputs to at most 512 px wide.
final class EmbyViewBackdropTextChannel {
    static let channelName = "embyview/backdrop_text"
    static let maxPixelWidth = 512

    private static let workQueue = DispatchQueue(
        label: "embyview.backdrop.text",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private static let concurrencyLimit = DispatchSemaphore(value: 4)
    private static let preferredComputeDevice: MLComputeDevice? = {
        let probe = VNRecognizeTextRequest()
        probe.recognitionLevel = .accurate
        guard let stages = try? probe.supportedComputeStageDevices,
              let devices = stages[.main]
        else { return nil }
        // Prefer CPU over GPU/ANE: on macOS 26 Apple Silicon both ANE and GPU
        // stall ~29 s compiling the CoreML/Metal graph on first run, while CPU
        // runs in ~70-130 ms without competing with Flutter's Metal rendering.
        if let cpu = devices.first(where: { if case .cpu = $0 { return true }; return false }) {
            return cpu
        }
        return devices.first(where: { if case .gpu = $0 { return true }; return false })
    }()

    static func register(messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
        channel.setMethodCallHandler { call, result in
            handle(call, result: result)
        }
    }

    private static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard call.method == "hasLargeText",
              let args = call.arguments as? [String: Any]
        else {
            result(FlutterMethodNotImplemented)
            return
        }

        if let typed = args["bytes"] as? FlutterStandardTypedData {
            let data = typed.data
            workQueue.async {
                concurrencyLimit.wait()
                defer { concurrencyLimit.signal() }
                let outcome = Result { try hasLargeText(in: data) }
                DispatchQueue.main.async {
                    switch outcome {
                    case .success(let value):
                        result(value)
                    case .failure(let error):
                        result(FlutterError(code: "vision_failed", message: error.localizedDescription, details: nil))
                    }
                }
            }
            return
        }

        guard let urlString = args["url"] as? String,
              let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            result(FlutterError(code: "invalid_args", message: "Missing valid image url", details: nil))
            return
        }

        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 6)
        if let headers = args["headers"] as? [String: String] {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        let task = MoonfinURLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                DispatchQueue.main.async {
                    result(FlutterError(code: "fetch_failed", message: error.localizedDescription, details: nil))
                }
                return
            }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let data,
                  !data.isEmpty
            else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                DispatchQueue.main.async {
                    result(FlutterError(code: "http_error", message: "HTTP \(status)", details: nil))
                }
                return
            }
            workQueue.async {
                concurrencyLimit.wait()
                defer { concurrencyLimit.signal() }
                let outcome = Result { try hasLargeText(in: data) }
                DispatchQueue.main.async {
                    switch outcome {
                    case .success(let value):
                        result(value)
                    case .failure(let error):
                        result(FlutterError(code: "vision_failed", message: error.localizedDescription, details: nil))
                    }
                }
            }
        }
        task.resume()
    }

    static func downscale(_ data: Data, maxWidth: Int = maxPixelWidth) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pixelWidth = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let pixelHeight = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        if pixelWidth > 0 && pixelWidth <= maxWidth {
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        let targetMaxDimension: Int
        if pixelWidth > maxWidth && pixelHeight > pixelWidth {
            // Preserve maxWidth constraint even for unusually tall images.
            targetMaxDimension = max(1, Int((Double(pixelHeight) * Double(maxWidth) / Double(pixelWidth)).rounded()))
        } else {
            targetMaxDimension = maxWidth
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: targetMaxDimension,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func hasLargeText(in data: Data) throws -> Bool {
        guard let image = downscale(data) else {
            throw NSError(domain: "EmbyViewBackdropText", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid image data"])
        }
        return try hasLargeText(in: image)
    }

    static func hasLargeText(in image: CGImage) throws -> Bool {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.04
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "ja", "ko", "en-US"]
        if let device = preferredComputeDevice {
            request.setComputeDevice(device, for: .main)
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        return containsProminentText(request.results ?? [])
    }

    static func containsProminentText(_ observations: [VNRecognizedTextObservation]) -> Bool {
        var highConfArea: CGFloat = 0
        var stylizedArea: CGFloat = 0
        var stylizedChars = 0
        var stylizedBoxes = 0

        for observation in observations {
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence >= 0.25
            else { continue }

            let scalars = candidate.string.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            let charCount = scalars.count
            guard charCount > 0 else { continue }

            let box = observation.boundingBox
            let height = box.height
            let width = box.width
            let area = width * height

            let hasCjk = scalars.contains { scalar in
                (0x4E00...0x9FFF).contains(scalar.value) ||
                (0x3400...0x4DBF).contains(scalar.value) ||
                (0x3040...0x30FF).contains(scalar.value) ||
                (0xAC00...0xD7AF).contains(scalar.value)
            }

            if candidate.confidence >= 0.45 {
                if charCount == 1 && !(hasCjk && height >= 0.085 && area >= 0.008) {
                    continue
                }
                if (height >= 0.065 && area >= 0.008) || (height >= 0.055 && width >= 0.18) {
                    return true
                }
                if height >= 0.045 && area >= 0.003 {
                    highConfArea += area
                    if highConfArea >= 0.018 {
                        return true
                    }
                }
            } else {
                // Vision quantizes stylized/calligraphy movie titles to ~0.30 confidence.
                // Require stronger character count and size to reject 1-2 char visual artifacts.
                if charCount >= 3 && ((height >= 0.075 && area >= 0.015) || (height >= 0.050 && width >= 0.14 && charCount >= 5)) {
                    return true
                }
                if charCount >= 2 && height >= 0.045 && area >= 0.004 {
                    stylizedBoxes += 1
                    stylizedChars += charCount
                    stylizedArea += area
                    if stylizedBoxes >= 2 && stylizedChars >= 4 && stylizedArea >= 0.020 {
                        return true
                    }
                }
            }
        }
        return false
    }
}
