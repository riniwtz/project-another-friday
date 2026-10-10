import Foundation
import AVFoundation
import Accelerate
import CoreML
import CoreAudio
import AudioToolbox

// MARK: - Core ML checkpoint contract
// This sidecar is created by conversion/convert_sslam.py. The app does NOT
// pretend that safetensors are directly executable by Core ML.
struct SSLAMManifest: Decodable {
    let inputName: String
    let outputName: String
    let classLabels: [String]
    let outputType: String
    let frames: Int
    let melBins: Int
    let sampleRate: Int

    func validate() throws {
        guard inputName == "audio", outputName == "logits", outputType == "logits",
              frames == 1024, melBins == 128, sampleRate == 16000,
              classLabels.count == 527 else {
            throw AudioPipelineError.invalidModel("SSLAM manifest does not match the expected AudioSet 527-class contract")
        }
    }
}

enum AudioPipelineError: LocalizedError {
    case invalidModel(String), audioUnavailable(String), permissionDenied, conversionFailed(String)
    var errorDescription: String? {
        switch self {
        case .invalidModel(let s), .audioUnavailable(let s), .conversionFailed(let s): return s
        case .permissionDenied: return "Microphone permission was denied. Enable Hark in System Settings → Privacy & Security → Microphone."
        }
    }
}

// Critical alerts use ground-truth AudioSet class indices, so generic speech/music
// cannot consume all display slots. Highest score wins for each canonical category.
enum AudioSetLabels {
    static let targets: [String: Set<Int>] = [
        "Speech": [0, 1, 2, 3, 4, 5],
        "Clapping": [63, 67],
        "Dog barking": [75, 76, 78],
        "Cat meowing": [83],
        "Rain": [289, 290, 291],
        "Doorbell": [355, 356],
        "Knocking": [359],
        "Crying": [22, 23, 24, 25],
        "Alarm": [310, 388, 395, 399, 400],
        "Glass breaking": [443],
        "Keyboard typing": [384, 386]
    ]

    static func normalize(logits: [Double], threshold: Double) -> [SoundDetection] {
        guard logits.count == 527 else { return [] }
        let categories = targets.compactMap { name, indices -> SoundDetection? in
            let maxProbability = indices.map { index -> Double in
                let z = max(-40, min(40, logits[index]))
                return 1 / (1 + exp(-z))
            }.max() ?? 0
            guard maxProbability >= threshold else { return nil }
            return SoundDetection(label: name, confidence: maxProbability)
        }
        return categories.sorted { $0.confidence > $1.confidence }
    }
}

// Timing reports intentionally exclude disk writes and model compilation. They
// separate the repeated costs from the one-time model load.
struct SSLAMTimings: Codable, Sendable {
    let resampleMS: Double
    let filterbankMS: Double
    let inputCopyMS: Double
    let predictionMS: Double
    let postprocessMS: Double
    let totalMS: Double
}

struct SSLAMResult: Sendable {
    let detections: [SoundDetection]
    let timings: SSLAMTimings
}

struct SSLAMBenchmark: Codable, Sendable {
    let recordedAt: Date
    let model: String
    let computeUnits: String
    let iterations: Int
    let inputSamples: Int
    let timings: [SSLAMTimings]
    let medianPredictionMS: Double
    let p95PredictionMS: Double
    let medianTotalMS: Double
    let medianFilterbankMS: Double

    private static func percentile(_ xs: [Double], _ fraction: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let values = xs.sorted()
        let position = Double(values.count - 1) * fraction
        let a = Int(position.rounded(.down))
        let b = Int(position.rounded(.up))
        return values[a] + (values[b] - values[a]) * (position - Double(a))
    }

    init(model: String, computeUnits: String, inputSamples: Int, timings: [SSLAMTimings]) {
        recordedAt = Date()
        self.model = model
        self.computeUnits = computeUnits
        iterations = timings.count
        self.inputSamples = inputSamples
        self.timings = timings
        medianPredictionMS = Self.percentile(timings.map(\.predictionMS), 0.5)
        p95PredictionMS = Self.percentile(timings.map(\.predictionMS), 0.95)
        medianTotalMS = Self.percentile(timings.map(\.totalMS), 0.5)
        medianFilterbankMS = Self.percentile(timings.map(\.filterbankMS), 0.5)
    }
}

enum SSLAMComputeMode: String, CaseIterable, Identifiable {
    case all = "all"
    case cpuAndNeuralEngine = "cpuAndNeuralEngine"
    case cpuAndGPU = "cpuAndGPU"
    case cpuOnly = "cpuOnly"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "Automatic (all)"
        case .cpuAndNeuralEngine: return "CPU + Neural Engine"
        case .cpuAndGPU: return "CPU + GPU"
        case .cpuOnly: return "CPU only"
        }
    }
    var coreMLValue: MLComputeUnits {
        switch self {
        case .all: return .all
        case .cpuAndNeuralEngine: return .cpuAndNeuralEngine
        case .cpuAndGPU: return .cpuAndGPU
        case .cpuOnly: return .cpuOnly
        }
    }
}

// MARK: - Offline Core ML inference
// Single actor owns the model, filterbank FFT, and Core ML input buffers.
// It never reconstructs these objects on every audio window.
actor SSLAMCoreMLEngine {
    private var loadedURL: URL?
    private var loadedMode: SSLAMComputeMode?
    private var cachedCompiledSource: URL?
    private var cachedCompiledURL: URL?
    private var loadedModel: MLModel?
    private var manifest: SSLAMManifest?
    private var filterbank: KaldiFbank.Processor?
    private var inputArray: MLMultiArray?
    private var inputProvider: MLDictionaryFeatureProvider?

    func load(at modelURL: URL, computeMode: SSLAMComputeMode = .all) throws {
        let path = modelURL.standardizedFileURL
        if loadedURL == path, loadedMode == computeMode, loadedModel != nil { return }
        guard ["mlpackage", "mlmodelc"].contains(path.pathExtension.lowercased()) else {
            throw AudioPipelineError.invalidModel("Choose the exported SSLAM.mlpackage or SSLAM.mlmodelc, not model.safetensors")
        }
        let manifestURL = path.deletingLastPathComponent().appendingPathComponent("sslam_manifest.json")
        let metadata = try JSONDecoder().decode(SSLAMManifest.self, from: Data(contentsOf: manifestURL))
        try metadata.validate()
        let compiled: URL
        if path.pathExtension == "mlmodelc" {
            compiled = path
        } else if cachedCompiledSource == path, let cachedCompiledURL,
                  FileManager.default.fileExists(atPath: cachedCompiledURL.path) {
            compiled = cachedCompiledURL
        } else {
            compiled = try MLModel.compileModel(at: path)
            cachedCompiledSource = path
            cachedCompiledURL = compiled
        }
        // Avoid loading two copies of this ~90M-parameter model at once on 8GB Macs.
        loadedModel = nil
        inputProvider = nil
        inputArray = nil
        filterbank = nil
        loadedURL = nil
        let config = MLModelConfiguration()
        config.computeUnits = computeMode.coreMLValue
        let newModel = try MLModel(contentsOf: compiled, configuration: config)
        guard newModel.modelDescription.inputDescriptionsByName[metadata.inputName] != nil,
              newModel.modelDescription.outputDescriptionsByName[metadata.outputName] != nil else {
            throw AudioPipelineError.invalidModel("Core ML input/output names differ from conversion manifest")
        }
        let input = try MLMultiArray(shape: [1, 1, NSNumber(value: metadata.frames), NSNumber(value: metadata.melBins)], dataType: .float32)
        let provider = try MLDictionaryFeatureProvider(dictionary: [metadata.inputName: MLFeatureValue(multiArray: input)])
        let processor = try KaldiFbank.Processor()
        loadedURL = path
        loadedMode = computeMode
        loadedModel = newModel
        manifest = metadata
        inputArray = input
        inputProvider = provider
        filterbank = processor
    }

    func classify(pcm16k: [Float], threshold: Double, gain: Double) throws -> [SoundDetection] {
        try classifyMeasured(pcm: pcm16k, sampleRate: 16000, threshold: threshold, gain: gain).detections
    }

    func classifyMeasured(pcm: [Float], sampleRate: Double, threshold: Double, gain: Double) throws -> SSLAMResult {
        guard let model = loadedModel, let metadata = manifest,
              let processor = filterbank, let input = inputArray, let provider = inputProvider else {
            throw AudioPipelineError.invalidModel("SSLAM has not been loaded")
        }
        let clock = ProcessInfo.processInfo
        let started = clock.systemUptime
        let pcm16k = try AudioResampler.convert(pcm, rate: sampleRate)
        let resampledAt = clock.systemUptime
        let adjusted = pcm16k.map { Float(max(-1, min(1, Double($0) * gain))) }
        let features = try processor.extract(samples: adjusted)
        let featuresAt = clock.systemUptime
        guard features.count == input.count, features.count == metadata.frames * metadata.melBins else {
            throw AudioPipelineError.invalidModel("Unexpected filterbank feature shape")
        }
        // Reused MLFeatureProvider and MLMultiArray; model inference is serialized
        // by this actor, so Core ML cannot read while another task writes.
        let storage = input.dataPointer.assumingMemoryBound(to: Float.self)
        features.withUnsafeBufferPointer { source in
            if let address = source.baseAddress { storage.update(from: address, count: source.count) }
        }
        let copiedAt = clock.systemUptime
        let prediction = try model.prediction(from: provider)
        let predictedAt = clock.systemUptime
        guard let output = prediction.featureValue(for: metadata.outputName)?.multiArrayValue,
              output.count == 527 else {
            throw AudioPipelineError.invalidModel("SSLAM must output exactly 527 logits")
        }
        let logits = (0..<527).map { output[$0].doubleValue }
        let detections = AudioSetLabels.normalize(logits: logits, threshold: threshold)
        let ended = clock.systemUptime
        return SSLAMResult(detections: detections, timings: SSLAMTimings(
            resampleMS: (resampledAt - started) * 1000,
            filterbankMS: (featuresAt - resampledAt) * 1000,
            inputCopyMS: (copiedAt - featuresAt) * 1000,
            predictionMS: (predictedAt - copiedAt) * 1000,
            postprocessMS: (ended - predictedAt) * 1000,
            totalMS: (ended - started) * 1000
        ))
    }

    // Warm up once, then collect repeated timings on the SAME in-memory input.
    // Run this only while listening is stopped so it doesn't block live inference.
    func benchmark(modelPath: String, mode: SSLAMComputeMode, iterations: Int = 5) throws -> SSLAMBenchmark {
        let referenceURL = URL(fileURLWithPath: modelPath).deletingLastPathComponent()
            .appendingPathComponent("reference_pcm16k.bin")
        let data = try Data(contentsOf: referenceURL)
        guard data.count % MemoryLayout<Float>.size == 0, !data.isEmpty else {
            throw AudioPipelineError.invalidModel("Missing or invalid reference_pcm16k.bin")
        }
        var pcm = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
        _ = pcm.withUnsafeMutableBytes { bytes in data.copyBytes(to: bytes) }
        try load(at: URL(fileURLWithPath: modelPath), computeMode: mode)
        _ = try classifyMeasured(pcm: pcm, sampleRate: 16000, threshold: 0.5, gain: 1) // warm-up
        var results: [SSLAMTimings] = []
        for _ in 0..<max(1, min(iterations, 20)) {
            results.append(try classifyMeasured(pcm: pcm, sampleRate: 16000, threshold: 0.5, gain: 1).timings)
        }
        return SSLAMBenchmark(model: URL(fileURLWithPath: modelPath).lastPathComponent,
                              computeUnits: mode.rawValue, inputSamples: pcm.count, timings: results)
    }
}

// MARK: - Kaldi-style 16 kHz, 128-bin, 1024-frame log-filterbanks
// Reference: torchaudio.compliance.kaldi.fbank sample_frequency=16000,
// htk_compat=true, window_type=hanning, frame_shift=10, dither=0.0.
// Exact parity must be verified against conversion/reference WAVs on macOS.
enum KaldiFbank {
    static let frames = 1024
    static let bins = 128
    static let fftSize = 512
    static let windowLength = 400
    static let hop = 160

    static func extract(samples: [Float]) throws -> [Float] {
        try Processor().extract(samples: samples)
    }

    // Reused per SSLAMCoreMLEngine instance, preserving all DSP arithmetic.
    final class Processor {
        private let setup: OpaquePointer
        private let hanning: [Float]
        // Nonzero mel taps only: avoids ~33M zero-weight multiplies per full window.
        private let filters: [[(index: Int, weight: Float)]]
        private var realInput = [Float](repeating: 0, count: KaldiFbank.fftSize)
        private var imagInput = [Float](repeating: 0, count: KaldiFbank.fftSize)
        private var realOutput = [Float](repeating: 0, count: KaldiFbank.fftSize)
        private var imagOutput = [Float](repeating: 0, count: KaldiFbank.fftSize)
        private var powers = [Float](repeating: 0, count: KaldiFbank.fftSize / 2 + 1)

        init() throws {
            guard let fft = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(KaldiFbank.fftSize), .FORWARD) else {
                throw AudioPipelineError.audioUnavailable("Accelerate could not initialize the filterbank FFT")
            }
            setup = fft
            hanning = (0..<KaldiFbank.windowLength).map { i in
                Float(0.5 - 0.5 * cos(2.0 * Double.pi * Double(i) / Double(KaldiFbank.windowLength - 1)))
            }
            filters = KaldiFbank.melFilters().map { band in
                band.enumerated().compactMap { index, weight in
                    weight == 0 ? nil : (index: index, weight: weight)
                }
            }
        }

        deinit { vDSP_DFT_DestroySetup(setup) }

        func extract(samples: [Float]) throws -> [Float] {
        var result = [Float](repeating: Float(4.268 / (4.569 * 2)), count: KaldiFbank.frames * KaldiFbank.bins)
        guard samples.count >= KaldiFbank.windowLength else { return result }
        let count = min(KaldiFbank.frames, (samples.count - KaldiFbank.windowLength) / KaldiFbank.hop + 1)
        for t in 0..<count {
            let offset = t * KaldiFbank.hop
            var localMean: Float = 0
            for i in 0..<KaldiFbank.windowLength { localMean += samples[offset + i] }
            localMean /= Float(KaldiFbank.windowLength)
            var previous = samples[offset] - localMean
            for i in 0..<KaldiFbank.windowLength {
                let current = samples[offset + i] - localMean
                let preemphasized = i == 0 ? current * 0.03 : current - 0.97 * previous
                realInput[i] = preemphasized * hanning[i]
                previous = current
            }
            for i in KaldiFbank.windowLength..<KaldiFbank.fftSize { realInput[i] = 0 }
            realInput.withUnsafeBufferPointer { input in
                imagInput.withUnsafeBufferPointer { imaginary in
                    realOutput.withUnsafeMutableBufferPointer { output in
                        imagOutput.withUnsafeMutableBufferPointer { imaginaryOutput in
                            vDSP_DFT_Execute(setup, input.baseAddress!, imaginary.baseAddress!,
                                             output.baseAddress!, imaginaryOutput.baseAddress!)
                        }
                    }
                }
            }
            for k in powers.indices {
                powers[k] = realOutput[k] * realOutput[k] + imagOutput[k] * imagOutput[k]
            }
            for bin in 0..<KaldiFbank.bins {
                var energy: Float = 0
                let weights = filters[bin]
                for tap in weights { energy += powers[tap.index] * tap.weight }
                let logEnergy = log(max(energy, 1.1920929e-7))
                result[t * KaldiFbank.bins + bin] = (logEnergy + 4.268) / (4.569 * 2)
            }
        }
        return result
        }
    }

    private static func melFilters() -> [[Float]] {
        func mel(_ hz: Double) -> Double { 1127.0 * log(1.0 + hz / 700.0) }
        let lower = mel(20)
        let step = (mel(8000) - lower) / Double(bins + 1)
        let boundaries = (0..<(bins + 2)).map { lower + Double($0) * step }
        return (0..<bins).map { band in
            (0..<(fftSize / 2 + 1)).map { frequencyBin in
                let f = mel(Double(frequencyBin) * 16000 / Double(fftSize))
                let up = (f - boundaries[band]) / (boundaries[band + 1] - boundaries[band])
                let down = (boundaries[band + 2] - f) / (boundaries[band + 2] - boundaries[band + 1])
                return Float(max(0, min(up, down)))
            }
        }
    }
}

// MARK: - Microphone audio, bounded rolling buffer
// The render callback only copies tiny audio buffers to a worker queue. A ring
// buffer avoids repeated O(n) removeFirst on 10-second source buffers.
struct FixedAudioRingBuffer {
    private var storage: [Float]
    private var writeIndex = 0
    private(set) var count = 0
    var capacity: Int { storage.count }

    init(capacity: Int) { storage = [Float](repeating: 0, count: max(1, capacity)) }

    mutating func append(_ samples: [Float]) {
        for value in samples {
            storage[writeIndex] = value
            writeIndex = (writeIndex + 1) % capacity
            count = min(capacity, count + 1)
        }
    }

    func snapshot() -> [Float] {
        guard count > 0 else { return [] }
        let beginning = (writeIndex - count + capacity) % capacity
        if beginning + count <= capacity { return Array(storage[beginning..<(beginning + count)]) }
        return Array(storage[beginning..<capacity]) + Array(storage[0..<(count - (capacity - beginning))])
    }
}

enum AudioResampler {
    static func convert(_ samples: [Float], rate: Double) throws -> [Float] {
        if abs(rate - 16000) < 0.01 { return samples }
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                         channels: 1, interleaved: false),
              let destination = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                              sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: destination),
              let sourceBuffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)),
              let destinationBuffer = AVAudioPCMBuffer(pcmFormat: destination,
                  frameCapacity: AVAudioFrameCount(ceil(Double(samples.count) * 16000 / rate) + 512)) else {
            throw AudioPipelineError.audioUnavailable("Could not initialize audio resampling")
        }
        sourceBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            if let address = src.baseAddress { sourceBuffer.floatChannelData![0].update(from: address, count: src.count) }
        }
        var supplied = false
        var nsError: NSError?
        let status = converter.convert(to: destinationBuffer, error: &nsError) { _, inputStatus in
            if supplied { inputStatus.pointee = .endOfStream; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return sourceBuffer
        }
        guard status != .error else {
            throw AudioPipelineError.audioUnavailable(nsError?.localizedDescription ?? "Resampling failed")
        }
        return Array(UnsafeBufferPointer(start: destinationBuffer.floatChannelData![0],
                                         count: Int(destinationBuffer.frameLength)))
    }
}

final class MicrophoneCapture {
    // Native-rate audio is resampled only AFTER Hark's busy gate admits it.
    typealias FrameCallback = @Sendable ([Float], Double, TimeInterval) -> Void
    private let engine = AVAudioEngine()
    private let worker = DispatchQueue(label: "dev.rin.hark.audio", qos: .userInitiated)
    private var sampleRate = 48000.0
    private var sourceBuffer = FixedAudioRingBuffer(capacity: 480000)
    private var lastEmission: TimeInterval = 0
    private let callback: FrameCallback

    init(onWindow: @escaping FrameCallback) { callback = onWindow }

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
        }
    }

    func start(deviceID: String) throws {
        let input = engine.inputNode
        if deviceID != "system" {
            guard var id = AudioDeviceID(deviceID), let unit = input.audioUnit else {
                throw AudioPipelineError.audioUnavailable("Selected audio device is unavailable")
            }
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global, 0, &id,
                                              UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else {
                throw AudioPipelineError.audioUnavailable("Could not select input device (OSStatus \(status))")
            }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved, format.channelCount > 0 else {
            throw AudioPipelineError.audioUnavailable("Microphone must provide non-interleaved Float32 PCM")
        }
        sampleRate = format.sampleRate
        worker.sync {
            sourceBuffer = FixedAudioRingBuffer(capacity: Int(sampleRate * 10))
            lastEmission = 0
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self, let channels = buffer.floatChannelData else { return }
            let count = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)
            var mono = [Float](repeating: 0, count: count)
            for channel in 0..<channelCount {
                for frame in 0..<count { mono[frame] += channels[channel][frame] / Float(channelCount) }
            }
            self.worker.async { self.receive(mono) }
        }
        do { try engine.start() }
        catch { input.removeTap(onBus: 0); throw error }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        worker.async { self.sourceBuffer = FixedAudioRingBuffer(capacity: Int(self.sampleRate * 10)) }
    }

    private func receive(_ samples: [Float]) {
        sourceBuffer.append(samples)
        let now = ProcessInfo.processInfo.systemUptime
        // A shorter hop catches brief sounds sooner while the store's busy gate prevents
        // overlapping Core ML work on slower hardware.
        guard sourceBuffer.count >= Int(sampleRate), now - lastEmission >= 0.4 else { return }
        lastEmission = now
        callback(sourceBuffer.snapshot(), sampleRate, now)
    }
}

// Byte-for-byte reference vectors are generated during one-time Python conversion.
// This gate intentionally fails closed if Swift and reference mel features diverge.
// A successful test verifies preprocessing on one reference clip, not real-world accuracy.
enum FeatureParityVerifier {
    private struct ConversionParityReport: Decodable {
        let modelParityPassed: Bool
    }

    struct Report {
        let meanAbsoluteError: Double
        let maximumAbsoluteError: Double
    }

    static func verify(modelPath: String) throws -> Report {
        let root = URL(fileURLWithPath: modelPath).deletingLastPathComponent()
        let reportURL = root.appendingPathComponent("parity_report.json")
        let report = try JSONDecoder().decode(ConversionParityReport.self, from: Data(contentsOf: reportURL))
        guard report.modelParityPassed else {
            throw AudioPipelineError.invalidModel("PyTorch and Core ML predictions have not passed conversion parity")
        }
        let pcm = try readFloat32(root.appendingPathComponent("reference_pcm16k.bin"))
        let reference = try readFloat32(root.appendingPathComponent("reference_fbank.bin"))
        guard !pcm.isEmpty, reference.count == 1024 * 128 else {
            throw AudioPipelineError.invalidModel("Missing or invalid SSLAM reference features. Rerun one-time conversion with --reference-wav.")
        }
        let actual = try KaldiFbank.extract(samples: pcm)
        var total = 0.0
        var maximum = 0.0
        for (lhs, rhs) in zip(actual, reference) {
            let error = abs(Double(lhs) - Double(rhs))
            total += error
            maximum = max(maximum, error)
        }
        let mean = total / Double(reference.count)
        guard mean <= 0.05, maximum <= 0.5 else {
            throw AudioPipelineError.invalidModel(
                "Swift/Kaldi feature parity FAILED (MAE \(String(format: "%.4f", mean)), max \(String(format: "%.4f", maximum))). Live alerts are disabled until the filterbank is corrected."
            )
        }
        return Report(meanAbsoluteError: mean, maximumAbsoluteError: maximum)
    }

    private static func readFloat32(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count % MemoryLayout<Float>.size == 0 else {
            throw AudioPipelineError.invalidModel("Invalid reference binary length at \(url.lastPathComponent)")
        }
        var values = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
        _ = values.withUnsafeMutableBytes { destination in data.copyBytes(to: destination) }
        return values
    }
}
