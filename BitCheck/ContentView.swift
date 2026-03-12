import AppKit
import Accelerate
import AVFoundation
import AudioToolbox
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var viewModel = ValidationViewModel()
    @State private var isDropTargeted = false
    @State private var selection = Set<ValidationResult.ID>()
    @State private var sortOrder = [KeyPathComparator(\ValidationResult.sortFileName, order: .forward)]

    private var selectedFileURL: URL? {
        guard let selectedID = selection.first else { return nil }
        return fileURL(for: selectedID)
    }

    private var sortedResults: [ValidationResult] {
        viewModel.results.sorted(using: sortOrder)
    }

    private func fileURL(for id: ValidationResult.ID) -> URL? {
        viewModel.results.first(where: { $0.id == id })?.fileURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("True Bitrate Validator")
                .font(.largeTitle)
                .fontWeight(.semibold)

            Text("Drop audio files or folders, or choose them manually.")
                .foregroundStyle(.secondary)

            DropArea(isTargeted: $isDropTargeted)
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
                    viewModel.handleDrop(providers: providers)
                    return true
                }

            HStack(spacing: 12) {
                Button("Choose Files") {
                    viewModel.pickFiles()
                }

                Button("Choose Folder") {
                    viewModel.pickFolder()
                }

                Button("Clear") {
                    viewModel.clearQueue()
                }
                .disabled(viewModel.queuedFiles.isEmpty || viewModel.isRunning)

                Button("Open Selected in Finder") {
                    guard let selectedFileURL else { return }
                    viewModel.openInFinder(url: selectedFileURL)
                }
                .disabled(selectedFileURL == nil)

                Toggle("Training Mode", isOn: $viewModel.trainingModeEnabled)
                    .toggleStyle(.switch)
                    .frame(width: 140)

                Button("Export Training CSV") {
                    viewModel.exportTrainingCSV()
                }
                .disabled(viewModel.trainingSamples.isEmpty || viewModel.isRunning)

                Spacer()

                Button(viewModel.isRunning ? "Running..." : "Run Validation") {
                    Task {
                        await viewModel.validateQueuedFiles()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.queuedFiles.isEmpty || viewModel.isRunning)
            }

            if !viewModel.statusMessage.isEmpty {
                Text(viewModel.statusMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Table(sortedResults, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Run", value: \.sortRunState) { item in
                    Image(systemName: item.state.symbolName)
                        .foregroundStyle(item.state.colour)
                        .help(item.state.label)
                }
                .width(min: 34, ideal: 36)

                TableColumn("File", value: \.sortFileName) { item in
                    Text(item.fileURL.lastPathComponent)
                        .lineLimit(1)
                        .foregroundStyle(item.comparisonColor)
                }
                .width(min: 220, ideal: 280)

                TableColumn("Type", value: \.fileType) { item in
                    Text(item.fileType)
                        .foregroundStyle(item.comparisonColor)
                }
                .width(min: 70, ideal: 90)

                TableColumn("Reported Bitrate", value: \.sortReportedBitrate) { item in
                    Text(item.reportedBitrate)
                        .foregroundStyle(item.comparisonColor)
                }
                .width(min: 120, ideal: 150)

                TableColumn("Mode", value: \.bitrateMode) { item in
                    Text(item.bitrateMode)
                        .foregroundStyle(item.comparisonColor)
                }
                .width(min: 70, ideal: 90)

                TableColumn("Actual Bitrate", value: \.sortActualBitrate) { item in
                    Text(item.actualBitrate)
                        .foregroundStyle(item.comparisonColor)
                }
                .width(min: 120, ideal: 150)

                TableColumn("Frequency", value: \.sortFrequencyKHz) { item in
                    Text(item.frequency)
                        .foregroundStyle(item.comparisonColor)
                }
                .width(min: 130, ideal: 160)

                TableColumn("Confidence", value: \.sortConfidencePercent) { item in
                    Text(item.confidence)
                        .foregroundStyle(item.comparisonColor)
                }
                .width(min: 90, ideal: 110)

                TableColumn("Status", value: \.analysisStatus) { item in
                    Text(item.analysisStatus)
                        .foregroundStyle(item.comparisonColor)
                }
                .width(min: 150, ideal: 200)

            }
            .contextMenu(forSelectionType: ValidationResult.ID.self) { selectedIDs in
                if let selectedID = selectedIDs.first, let fileURL = fileURL(for: selectedID) {
                    Button("Open in Finder") {
                        viewModel.openInFinder(url: fileURL)
                    }
                    Button("View Spectrogram") {
                        Task {
                            await viewModel.presentSpectrogram(for: fileURL)
                        }
                    }
                }
            }
        }
        .padding(20)
    }
}

private struct DropArea: View {
    @Binding var isTargeted: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
            .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05))
            )
            .frame(height: 130)
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.title2)
                    Text("Drop files or folders here")
                        .fontWeight(.medium)
                }
                .foregroundStyle(.secondary)
            }
    }
}

struct SpectrogramPresentation: Identifiable {
    let id = UUID()
    let fileURL: URL
    let image: NSImage
    let fileType: String
    let reportedBitrate: String
    let reportedSampleRateHz: Int
    let durationSeconds: Double
    let cutoffHz: Double?
}

private struct SpectrogramDetailView: View {
    let presentation: SpectrogramPresentation
    @State private var showHorizontalGridLines = false
    private let yTickCount = 12 // 0...22 kHz in 2 kHz steps
    private let xTickCount = 11
    private let yAxisWidth: CGFloat = 58
    private let axisStroke = Color.secondary.opacity(0.75)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.fileURL.lastPathComponent)
                    .font(.headline)
                    .lineLimit(2)
                Text(
                    "\(presentation.fileType) • \(presentation.reportedBitrate) • \(presentation.reportedSampleRateHz.formatted()) Hz"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Toggle("Show horizontal grid lines", isOn: $showHorizontalGridLines)
                .toggleStyle(.switch)
                .font(.caption)

            GeometryReader { proxy in
                let xAxisBlockHeight: CGFloat = 42
                let imageHeight = max(120, proxy.size.height - xAxisBlockHeight - 6)

                VStack(spacing: 6) {
                    HStack(spacing: 0) {
                        Color.clear
                            .frame(width: yAxisWidth, height: imageHeight)
                            .overlay(alignment: .topTrailing) {
                            GeometryReader { axisGeo in
                                ZStack(alignment: .topTrailing) {
                                    Path { path in
                                        path.move(to: CGPoint(x: axisGeo.size.width, y: 0))
                                        path.addLine(to: CGPoint(x: axisGeo.size.width, y: axisGeo.size.height))

                                        for index in 0..<yTickCount {
                                            let y = yTickPosition(index: index, height: axisGeo.size.height)
                                            path.move(to: CGPoint(x: axisGeo.size.width - 7, y: y))
                                            path.addLine(to: CGPoint(x: axisGeo.size.width, y: y))
                                        }
                                    }
                                    .stroke(axisStroke, lineWidth: 1)

                                    ForEach(0..<yTickCount, id: \.self) { index in
                                        let y = yTickPosition(index: index, height: axisGeo.size.height)
                                        let khz = (yTickCount - 1 - index) * 2
                                        Text("\(khz) kHz")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .frame(width: axisGeo.size.width - 11, alignment: .trailing)
                                            .position(x: (axisGeo.size.width - 11) / 2, y: y)
                                    }
                                }
                            }
                        }

                        Image(nsImage: presentation.image)
                            .resizable()
                            .interpolation(.none)
                            .frame(maxWidth: .infinity, minHeight: imageHeight, maxHeight: imageHeight)
                            .clipped()
                            .overlay(alignment: .top) {
                                if showHorizontalGridLines {
                                    GeometryReader { imageGeo in
                                        Path { path in
                                            for index in 0..<yTickCount {
                                                let y = yTickPosition(index: index, height: imageGeo.size.height)
                                                path.move(to: CGPoint(x: 0, y: y))
                                                path.addLine(to: CGPoint(x: imageGeo.size.width, y: y))
                                            }
                                        }
                                        .stroke(Color.black.opacity(0.40), lineWidth: 1)
                                    }
                                }
                            }
                            .overlay(alignment: .top) {
                                if let cutoffHz = presentation.cutoffHz, cutoffHz > 0 {
                                    GeometryReader { imageGeo in
                                        let yFraction = max(0, min(1, 1.0 - cutoffHz / 22_000.0))
                                        let y = (yFraction * imageGeo.size.height).rounded()
                                        ZStack(alignment: .topLeading) {
                                            Path { path in
                                                path.move(to: CGPoint(x: 0, y: y))
                                                path.addLine(to: CGPoint(x: imageGeo.size.width, y: y))
                                            }
                                            .stroke(Color.yellow.opacity(0.90), lineWidth: 1.5)
                                            Text(String(format: "%.1f kHz", cutoffHz / 1_000.0))
                                                .font(.caption2)
                                                .foregroundStyle(Color.yellow)
                                                .padding(.horizontal, 4)
                                                .background(Color.black.opacity(0.50))
                                                .position(x: imageGeo.size.width - 36, y: y - 8)
                                        }
                                    }
                                }
                            }
                            .background(Color.black.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }

                    HStack(spacing: 0) {
                        Color.clear.frame(width: yAxisWidth)

                        VStack(spacing: 4) {
                            GeometryReader { axisGeo in
                                Path { path in
                                    path.move(to: CGPoint(x: 0, y: 0))
                                    path.addLine(to: CGPoint(x: axisGeo.size.width, y: 0))

                                    for index in 0..<xTickCount {
                                        let x = xTickPosition(index: index, width: axisGeo.size.width)
                                        path.move(to: CGPoint(x: x, y: 0))
                                        path.addLine(to: CGPoint(x: x, y: 7))
                                    }
                                }
                                .stroke(axisStroke, lineWidth: 1)
                            }
                            .frame(height: 8)

                            GeometryReader { labelGeo in
                                ZStack(alignment: .leading) {
                                    ForEach(0..<xTickCount, id: \.self) { index in
                                        let ratio = Double(index) / Double(max(xTickCount - 1, 1))
                                        let x = xTickPosition(index: index, width: labelGeo.size.width)
                                        Text(formatTimestamp(presentation.durationSeconds * ratio))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .position(x: x, y: 7)
                                    }
                                }
                            }
                            .frame(height: 14)

                            Text("Time (min:sec)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let minutes = total / 60
        let remainder = total % 60
        return String(format: "%d:%02d", minutes, remainder)
    }

    private func yTickPosition(index: Int, height: CGFloat) -> CGFloat {
        let divisor = CGFloat(max(yTickCount - 1, 1))
        return (height * CGFloat(index) / divisor).rounded()
    }

    private func xTickPosition(index: Int, width: CGFloat) -> CGFloat {
        let divisor = CGFloat(max(xTickCount - 1, 1))
        return (width * CGFloat(index) / divisor).rounded()
    }
}

@MainActor
final class SpectrogramWindowManager: NSObject, NSWindowDelegate {
    static let shared = SpectrogramWindowManager()
    private var controllersByFilePath: [String: NSWindowController] = [:]
    private var filePathByWindowID: [ObjectIdentifier: String] = [:]

    func present(_ presentation: SpectrogramPresentation) {
        let filePath = presentation.fileURL.standardizedFileURL.path
        if let existingController = controllersByFilePath[filePath], let existingWindow = existingController.window {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = SpectrogramDetailView(presentation: presentation)
        let host = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: host)
        window.title = "Spectrogram"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 960, height: 560))
        window.minSize = NSSize(width: 700, height: 380)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let controller = NSWindowController(window: window)
        controllersByFilePath[filePath] = controller
        filePathByWindowID[ObjectIdentifier(window)] = filePath
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let windowID = ObjectIdentifier(window)
        guard let filePath = filePathByWindowID[windowID] else { return }
        controllersByFilePath[filePath] = nil
        filePathByWindowID[windowID] = nil
    }
}

private nonisolated enum SpectrogramRenderer {
    static func render(fileURL: URL, maxSeconds: Int? = nil) throws -> SpectrogramRenderOutput {
        let file = try AVAudioFile(forReading: fileURL)
        let format = file.processingFormat
        let sampleRate = Int(format.sampleRate.rounded())
        guard sampleRate > 0 else { throw SpectrogramError.invalidSampleRate }

        let safetyMaxFrames = AVAudioFramePosition(UInt32.max)
        let requestedMaxFrames: AVAudioFramePosition = {
            guard let maxSeconds else { return file.length }
            return AVAudioFramePosition(sampleRate * maxSeconds)
        }()
        let framesToRead = AVAudioFrameCount(min(file.length, min(safetyMaxFrames, requestedMaxFrames)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRead) else {
            throw SpectrogramError.bufferCreationFailed
        }
        try file.read(into: buffer, frameCount: framesToRead)
        guard buffer.frameLength > 0 else { throw SpectrogramError.noAudioData }

        let samples = try extractChannelData(from: buffer)
        let fftLength = 2048
        let hopLength = 512
        guard samples.count > fftLength else { throw SpectrogramError.notEnoughSamples }
        let timeBins = 1 + ((samples.count - fftLength) / hopLength)
        let freqBins = fftLength / 2
        let displayHeight = min(320, freqBins)
        let durationSeconds = Double(buffer.frameLength) / Double(sampleRate)

        var hannWindow = [Float](repeating: 0, count: fftLength)
        vDSP_hann_window(&hannWindow, vDSP_Length(fftLength), Int32(vDSP_HANN_NORM))
        let log2n = vDSP_Length(log2(Double(fftLength)))
        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else {
            throw SpectrogramError.fftSetupFailed
        }

        var real = [Float](repeating: 0, count: freqBins)
        var imag = [Float](repeating: 0, count: freqBins)
        var magnitudes = [Float](repeating: 0, count: freqBins)
        var intensities = [Float](repeating: 0, count: timeBins * displayHeight)

        for frame in 0..<timeBins {
            let start = frame * hopLength
            let end = start + fftLength
            var windowed = Array(samples[start..<end])
            vDSP.multiply(windowed, hannWindow, result: &windowed)

            var interleaved = [DSPComplex](repeating: DSPComplex(real: 0, imag: 0), count: freqBins)
            for index in 0..<freqBins {
                interleaved[index] = DSPComplex(real: windowed[index * 2], imag: windowed[index * 2 + 1])
            }

            real.withUnsafeMutableBufferPointer { realPointer in
                imag.withUnsafeMutableBufferPointer { imagPointer in
                    guard let realBase = realPointer.baseAddress, let imagBase = imagPointer.baseAddress else { return }
                    var split = DSPSplitComplex(realp: realBase, imagp: imagBase)
                    interleaved.withUnsafeBufferPointer { pointer in
                        guard let baseAddress = pointer.baseAddress else { return }
                        baseAddress.withMemoryRebound(to: DSPComplex.self, capacity: freqBins) { reboundPointer in
                            vDSP_ctoz(reboundPointer, 1, &split, 1, vDSP_Length(freqBins))
                        }
                    }
                    fft.forward(input: split, output: &split)
                    vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(freqBins))
                }
            }

            for y in 0..<displayHeight {
                let bin = Int((Double(y) / Double(max(displayHeight - 1, 1))) * Double(freqBins - 1))
                let db = 20.0 * log10(Double(max(magnitudes[bin], 1.0e-12)))
                let normalized = Float(max(0.0, min(1.0, (db + 90.0) / 90.0)))
                intensities[(y * timeBins) + frame] = normalized
            }
        }

        return SpectrogramRenderOutput(
            image: try makeImage(intensities: intensities, width: timeBins, height: displayHeight),
            sampleRateHz: sampleRate,
            durationSeconds: durationSeconds
        )
    }

    private static func extractChannelData(from buffer: AVAudioPCMBuffer) throws -> [Float] {
        let frameCount = Int(buffer.frameLength)
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let channels = buffer.floatChannelData else { throw SpectrogramError.noAudioData }
            return Array(UnsafeBufferPointer(start: channels[0], count: frameCount))
        case .pcmFormatInt16:
            guard let channels = buffer.int16ChannelData else { throw SpectrogramError.noAudioData }
            return (0..<frameCount).map { Float(channels[0][$0]) / Float(Int16.max) }
        case .pcmFormatInt32:
            guard let channels = buffer.int32ChannelData else { throw SpectrogramError.noAudioData }
            return (0..<frameCount).map { Float(channels[0][$0]) / Float(Int32.max) }
        default:
            throw SpectrogramError.unsupportedPCMFormat
        }
    }

    private static func makeImage(intensities: [Float], width: Int, height: Int) throws -> NSImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = intensities[(y * width) + x]
                let colour = colourMap(value)
                let offset = ((y * width) + x) * 4
                pixels[offset] = colour.r
                pixels[offset + 1] = colour.g
                pixels[offset + 2] = colour.b
                pixels[offset + 3] = 255
            }
        }

        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else { throw SpectrogramError.imageCreationFailed }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard
            let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        else {
            throw SpectrogramError.imageCreationFailed
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    private static func colourMap(_ value: Float) -> (r: UInt8, g: UInt8, b: UInt8) {
        let v = max(0.0, min(1.0, value))
        let r = UInt8(max(0.0, min(255.0, 255.0 * pow(v, 0.50))))
        let g = UInt8(max(0.0, min(255.0, 255.0 * pow(v, 1.20))))
        let b = UInt8(max(0.0, min(255.0, 255.0 * pow(v, 2.10))))
        return (r, g, b)
    }
}

private struct SpectrogramRenderOutput {
    let image: NSImage
    let sampleRateHz: Int
    let durationSeconds: Double
}

private enum SpectrogramError: LocalizedError {
    case invalidSampleRate
    case bufferCreationFailed
    case noAudioData
    case unsupportedPCMFormat
    case notEnoughSamples
    case fftSetupFailed
    case imageCreationFailed

    var errorDescription: String? {
        switch self {
        case .invalidSampleRate: return "Invalid sample rate."
        case .bufferCreationFailed: return "Failed to create audio buffer."
        case .noAudioData: return "No audio data found."
        case .unsupportedPCMFormat: return "Unsupported audio format."
        case .notEnoughSamples: return "Not enough audio samples for spectrogram."
        case .fftSetupFailed: return "Failed to initialize FFT."
        case .imageCreationFailed: return "Failed to create spectrogram image."
        }
    }
}

@MainActor
final class ValidationViewModel: ObservableObject {
    @Published var queuedFiles: [URL] = []
    @Published var results: [ValidationResult] = []
    @Published var isRunning = false
    @Published var statusMessage = ""
    @Published var trainingModeEnabled = false
    @Published private(set) var trainingSamples: [TrainingSample] = []

    private let supportedAudioExtensions: Set<String> = [
        "mp3", "flac", "wav", "m4a", "aac", "ogg", "opus", "aiff", "aif", "alac"
    ]

    func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio]

        guard panel.runModal() == .OK else { return }
        enqueue(urls: panel.urls)
    }

    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let folder = panel.url else { return }
        enqueue(urls: [folder])
    }

    func handleDrop(providers: [NSItemProvider]) {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { [weak self] data, _ in
                guard
                    let self,
                    let data,
                    let url = NSURL(absoluteURLWithDataRepresentation: data, relativeTo: nil) as URL?
                else {
                    return
                }

                Task { @MainActor in
                    self.enqueue(urls: [url])
                }
            }
        }
    }

    func clearQueue() {
        queuedFiles.removeAll()
        results.removeAll()
        trainingSamples.removeAll()
        statusMessage = ""
    }

    func validateQueuedFiles() async {
        guard !queuedFiles.isEmpty else { return }

        isRunning = true
        defer { isRunning = false }

        statusMessage = "Validating \(queuedFiles.count) file(s)..."
        if trainingModeEnabled {
            trainingSamples.removeAll()
        }

        var updatedResults = queuedFiles.map {
            let existing = existingOrDefaultResult(for: $0)
            return ValidationResult(
                fileURL: $0,
                actualBitrate: "—",
                frequency: "—",
                confidence: "—",
                analysisStatus: "Waiting",
                state: .pending,
                reportedBitrate: existing.reportedBitrate,
                bitrateMode: existing.bitrateMode,
                fileType: displayFileType(for: $0),
                cutoffHz: nil
            )
        }

        for index in updatedResults.indices {
            updatedResults[index].state = .running
            updatedResults[index].analysisStatus = "Analysing"
            results = updatedResults

            let file = updatedResults[index].fileURL
            let result = await runTrueBitrate(for: file)

            updatedResults[index].state = result.success ? .done : .failed
            updatedResults[index].actualBitrate = result.actualBitrate
            updatedResults[index].frequency = result.frequency
            updatedResults[index].confidence = result.confidence
            updatedResults[index].analysisStatus = result.analysisStatus
            updatedResults[index].reportedBitrate = result.reportedBitrate
            updatedResults[index].bitrateMode = result.bitrateMode
            updatedResults[index].cutoffHz = result.cutoffHz
            results = updatedResults

            if trainingModeEnabled {
                let expectation = TrainingLabelParser.parse(
                    fileName: file.deletingPathExtension().lastPathComponent,
                    reportedBitrate: result.reportedBitrate
                )
                let predictedLabel = TrainingLabelParser.normalize(result.actualBitrate)
                let isMatch = expectation.isTrainable ? expectation.label == predictedLabel : nil
                let sample = TrainingSample(
                    fileURL: file,
                    fileType: updatedResults[index].fileType,
                    reportedBitrate: result.reportedBitrate,
                    predictedBitrate: result.actualBitrate,
                    confidenceText: result.confidence,
                    analysisStatus: result.analysisStatus,
                    expectedLabel: expectation.label,
                    expectationType: expectation.type,
                    isTrainable: expectation.isTrainable,
                    isMatch: isMatch,
                    features: result.features
                )
                trainingSamples.append(sample)
            }
        }

        let failedCount = updatedResults.filter { $0.state == .failed }.count
        if failedCount == 0 {
            statusMessage = "Validation completed for \(updatedResults.count) file(s)."
        } else {
            statusMessage = "Validation completed with \(failedCount) failure(s)."
        }
        if trainingModeEnabled {
            let trainableCount = trainingSamples.filter(\.isTrainable).count
            statusMessage += " Training rows: \(trainingSamples.count) (\(trainableCount) trainable)."
        }
    }

    func exportTrainingCSV() {
        guard !trainingSamples.isEmpty else {
            statusMessage = "No training samples to export."
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Training Dataset"
        panel.message = "Save extracted training samples as CSV."
        panel.nameFieldStringValue = "bitcheck-training-\(Self.timestampForFileName()).csv"
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }

        do {
            try trainingCSV().write(to: destinationURL, atomically: true, encoding: .utf8)
            statusMessage = "Exported \(trainingSamples.count) training rows to \(destinationURL.path)."
        } catch {
            statusMessage = "Failed to export CSV: \(error.localizedDescription)"
        }
    }

    private func enqueue(urls: [URL]) {
        let files = urls.flatMap { collectAudioFiles(from: $0) }
        guard !files.isEmpty else {
            statusMessage = "No supported audio files found."
            return
        }

        let merged = Set(queuedFiles).union(files)
        queuedFiles = merged.sorted { $0.path < $1.path }
        results = queuedFiles.map { existingOrDefaultResult(for: $0) }
        statusMessage = "Queued \(queuedFiles.count) file(s)."
    }

    private func existingOrDefaultResult(for file: URL) -> ValidationResult {
        if let existing = results.first(where: { $0.fileURL == file }) {
            return existing
        }
        let metadata = metadata(for: file)
        return ValidationResult(
            fileURL: file,
            actualBitrate: "—",
            frequency: "—",
            confidence: "—",
            analysisStatus: "Not run",
            state: .pending,
            reportedBitrate: metadata.reportedBitrate,
            bitrateMode: metadata.bitrateMode,
            fileType: displayFileType(for: file),
            cutoffHz: nil
        )
    }

    private func collectAudioFiles(from url: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return []
        }

        if !isDirectory.boolValue {
            return isSupportedAudioFile(url) ? [url] : []
        }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            if isSupportedAudioFile(fileURL) {
                files.append(fileURL)
            }
        }
        return files
    }

    private func isSupportedAudioFile(_ url: URL) -> Bool {
        supportedAudioExtensions.contains(url.pathExtension.lowercased())
    }

    private func displayFileType(for file: URL) -> String {
        let ext = file.pathExtension.uppercased()
        return ext.isEmpty ? "Unknown" : ext
    }

    private func metadata(for file: URL) -> FileMetadata {
        NativeTrueBitrateAnalyzer.inspect(file: file)
    }

    private func runTrueBitrate(for file: URL) async -> RunResult {
        await Task.detached(priority: .userInitiated) {
            NativeTrueBitrateAnalyzer.analyze(file: file)
        }.value
    }

    func openInFinder(url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func presentSpectrogram(for url: URL) async {
        statusMessage = "Rendering spectrogram for \(url.lastPathComponent)..."
        do {
            let renderOutput = try await Task.detached(priority: .userInitiated) {
                try SpectrogramRenderer.render(fileURL: url)
            }.value
            let metadata = metadata(for: url)
            let cutoffHz = results.first(where: { $0.fileURL == url })?.cutoffHz
            let presentation = SpectrogramPresentation(
                fileURL: url,
                image: renderOutput.image,
                fileType: displayFileType(for: url),
                reportedBitrate: metadata.reportedBitrate,
                reportedSampleRateHz: renderOutput.sampleRateHz,
                durationSeconds: renderOutput.durationSeconds,
                cutoffHz: cutoffHz
            )
            SpectrogramWindowManager.shared.present(presentation)
            statusMessage = "Rendered spectrogram for \(url.lastPathComponent)."
        } catch {
            statusMessage = "Failed to render spectrogram: \(error.localizedDescription)"
        }
    }

    private func trainingCSV() -> String {
        let header = [
            "file_path",
            "file_name",
            "file_type",
            "reported_bitrate",
            "predicted_bitrate",
            "confidence_percent",
            "analysis_status",
            "expected_label",
            "expectation_type",
            "is_trainable",
            "is_match",
            "cutoff_khz",
            "cutoff_ratio",
            "drop_score",
            "stability",
            "suppression_score",
            "sample_support",
            "evidence_confidence",
            "classification_confidence",
            "model_confidence",
            "final_confidence"
        ]
        var lines = [header.map(Self.csvEscape).joined(separator: ",")]
        for sample in trainingSamples {
            let features = sample.features
            var row: [String] = []
            row.append(sample.fileURL.path)
            row.append(sample.fileURL.lastPathComponent)
            row.append(sample.fileType)
            row.append(sample.reportedBitrate)
            row.append(sample.predictedBitrate)
            row.append(sample.confidenceText)
            row.append(sample.analysisStatus)
            row.append(sample.expectedLabel)
            row.append(sample.expectationType)
            row.append(sample.isTrainable ? "true" : "false")
            row.append(sample.isMatch.map { $0 ? "true" : "false" } ?? "")
            row.append(features?.cutoffKHzText ?? "")
            row.append(features?.cutoffRatioText ?? "")
            row.append(features?.dropScoreText ?? "")
            row.append(features?.stabilityText ?? "")
            row.append(features?.suppressionScoreText ?? "")
            row.append(features?.sampleSupportText ?? "")
            row.append(features?.evidenceConfidenceText ?? "")
            row.append(features?.classificationConfidenceText ?? "")
            row.append(features?.modelConfidenceText ?? "")
            row.append(features?.finalConfidenceText ?? "")
            lines.append(row.map(Self.csvEscape).joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    private static func csvEscape(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private static func timestampForFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

}

private nonisolated enum NativeTrueBitrateAnalyzer {
    static func inspect(file: URL) -> FileMetadata {
        do {
            let audioFile = try AVAudioFile(forReading: file)
            let format = audioFile.processingFormat
            return metadata(from: audioFile, fileURL: file, format: format)
        } catch {
            return FileMetadata(reportedBitrate: "N/A", bitrateMode: "Unknown")
        }
    }

    static func analyze(file: URL) -> RunResult {
        do {
            let samples = try loadSamples(from: file, maxSeconds: 30)
            guard samples.channel.count >= samplesPerWindow(samples.sampleRate) else {
                return RunResult(
                    success: false,
                    actualBitrate: "N/A",
                    frequency: "N/A",
                    confidence: "0%",
                    analysisStatus: "Audio too short",
                    reportedBitrate: samples.reportedBitrate,
                    bitrateMode: samples.bitrateMode,
                    features: nil,
                    cutoffHz: nil
                )
            }

            let estimate = try estimateBitrate(from: samples)
            return RunResult(
                success: true,
                actualBitrate: estimate.actualBitrate,
                frequency: estimate.frequency,
                confidence: estimate.confidenceText,
                analysisStatus: estimate.status,
                reportedBitrate: samples.reportedBitrate,
                bitrateMode: samples.bitrateMode,
                features: estimate.features,
                cutoffHz: estimate.cutoffHz
            )
        } catch {
            return RunResult(
                success: false,
                actualBitrate: "N/A",
                frequency: "N/A",
                confidence: "0%",
                analysisStatus: "Error: \(error.localizedDescription)",
                reportedBitrate: "N/A",
                bitrateMode: "Unknown",
                features: nil,
                cutoffHz: nil
            )
        }
    }

    private static func loadSamples(from fileURL: URL, maxSeconds: Int) throws -> AudioSamples {
        let file = try AVAudioFile(forReading: fileURL)
        let format = file.processingFormat
        let sampleRate = Int(format.sampleRate.rounded())
        guard sampleRate > 0 else {
            throw AnalyzerError.invalidSampleRate
        }
        let metadata = metadata(from: file, fileURL: fileURL, format: format)

        // For tracks longer than 60 s, skip the first 20% to avoid silent intros and
        // fade-ins that would bias the spectral average toward content-sparse audio.
        // This gives a much more representative sample of the steady-state signal.
        let thresholdFrames = AVAudioFramePosition(sampleRate * 60)
        let skipFraction: Double = file.length > thresholdFrames ? 0.20 : 0.0
        let startFrame = AVAudioFramePosition(Double(file.length) * skipFraction)
        file.framePosition = startFrame

        let maxFrames = AVAudioFramePosition(sampleRate * maxSeconds)
        let availableFrames = max(0, file.length - startFrame)
        let framesToRead = AVAudioFrameCount(min(availableFrames, maxFrames))
        guard
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRead)
        else {
            throw AnalyzerError.bufferCreationFailed
        }

        try file.read(into: buffer, frameCount: framesToRead)
        guard buffer.frameLength > 0 else {
            throw AnalyzerError.noAudioData
        }

        let channelData = try extractChannelData(from: buffer)
        return AudioSamples(
            sampleRate: sampleRate,
            channel: channelData,
            reportedBitrate: metadata.reportedBitrate,
            bitrateMode: metadata.bitrateMode,
            codecProfile: codecProfile(for: fileURL)
        )
    }

    private static func metadata(from file: AVAudioFile, fileURL: URL, format: AVAudioFormat) -> FileMetadata {
        if let metadata = metadataFromAudioToolbox(fileURL: fileURL) {
            return metadata
        }

        let reported = reportedBitrateFromSizeAndDuration(file: file, fileURL: fileURL, format: format) ?? "N/A"
        return FileMetadata(reportedBitrate: reported, bitrateMode: "Unknown")
    }

    private static func metadataFromAudioToolbox(fileURL: URL) -> FileMetadata? {
        var audioFileID: AudioFileID?
        guard AudioFileOpenURL(fileURL as CFURL, .readPermission, 0, &audioFileID) == noErr, let audioFileID else {
            return nil
        }
        defer { AudioFileClose(audioFileID) }

        var bitRate: UInt32 = 0
        var bitRateSize = UInt32(MemoryLayout<UInt32>.size)
        let hasBitRate = AudioFileGetProperty(audioFileID, kAudioFilePropertyBitRate, &bitRateSize, &bitRate) == noErr && bitRate > 0
        let reported = hasBitRate ? "\(Int((Double(bitRate) / 1_000.0).rounded())) kbps" : "N/A"

        var asbd = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let hasASBD = AudioFileGetProperty(audioFileID, kAudioFilePropertyDataFormat, &asbdSize, &asbd) == noErr

        let mode: String
        if hasASBD, asbd.mBytesPerPacket > 0 {
            mode = "CBR"
        } else {
            var upper: UInt32 = 0
            var upperSize = UInt32(MemoryLayout<UInt32>.size)
            let hasUpper = AudioFileGetProperty(audioFileID, kAudioFilePropertyPacketSizeUpperBound, &upperSize, &upper) == noErr

            var maxPacket: UInt32 = 0
            var maxSize = UInt32(MemoryLayout<UInt32>.size)
            let hasMax = AudioFileGetProperty(audioFileID, kAudioFilePropertyMaximumPacketSize, &maxSize, &maxPacket) == noErr

            if hasUpper, hasMax {
                mode = upper == maxPacket ? "CBR" : "VBR"
            } else {
                mode = "Unknown"
            }
        }

        return FileMetadata(reportedBitrate: reported, bitrateMode: mode)
    }

    private static func reportedBitrateFromSizeAndDuration(file: AVAudioFile, fileURL: URL, format: AVAudioFormat) -> String? {
        let durationSeconds = Double(file.length) / format.sampleRate
        if
            durationSeconds > 0,
            let fileSizeNumber = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        {
            let bitsPerSecond = (Double(fileSizeNumber) * 8.0) / durationSeconds
            if bitsPerSecond.isFinite, bitsPerSecond > 0 {
                return "\(Int((bitsPerSecond / 1_000.0).rounded())) kbps"
            }
        }

        if let encoded = file.fileFormat.settings[AVEncoderBitRateKey] as? NSNumber {
            let value = encoded.doubleValue
            if value > 0 {
                return "\(Int((value / 1_000.0).rounded())) kbps"
            }
        }

        return nil
    }

    private static func codecProfile(for fileURL: URL) -> CodecProfile {
        switch fileURL.pathExtension.lowercased() {
        case "mp3":
            return .mp3
        case "m4a", "aac":
            return .aac
        case "ogg", "opus":
            return .opus
        case "flac", "alac", "wav", "aiff", "aif":
            return .lossless
        default:
            return .generic
        }
    }

    private static func extractChannelData(from buffer: AVAudioPCMBuffer) throws -> [Float] {
        let frameCount = Int(buffer.frameLength)
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let channels = buffer.floatChannelData else { throw AnalyzerError.noAudioData }
            let source = channels[0]
            return Array(UnsafeBufferPointer(start: source, count: frameCount))
        case .pcmFormatInt16:
            guard let channels = buffer.int16ChannelData else { throw AnalyzerError.noAudioData }
            let source = channels[0]
            return (0..<frameCount).map { Float(source[$0]) / Float(Int16.max) }
        case .pcmFormatInt32:
            guard let channels = buffer.int32ChannelData else { throw AnalyzerError.noAudioData }
            let source = channels[0]
            return (0..<frameCount).map { Float(source[$0]) / Float(Int32.max) }
        default:
            throw AnalyzerError.unsupportedPCMFormat
        }
    }

    private static func estimateBitrate(from audio: AudioSamples) throws -> BitrateEstimate {
        let sampleRate = audio.sampleRate
        let windowLength = samplesPerWindow(sampleRate)
        let segmentCount = min(audio.channel.count / windowLength, 30)
        guard segmentCount > 0 else {
            throw AnalyzerError.noAudioData
        }

        let fftLength = largestPowerOfTwo(atMost: windowLength)
        guard fftLength >= 1024 else {
            throw AnalyzerError.insufficientSamples
        }

        let frequencyResolution = Double(sampleRate) / Double(fftLength)
        let nyquistHz = Double(sampleRate) / 2.0
        let profile = audio.codecProfile
        var hannWindow = [Float](repeating: 0, count: fftLength)
        vDSP_hann_window(&hannWindow, vDSP_Length(fftLength), Int32(vDSP_HANN_NORM))

        let log2n = vDSP_Length(log2(Double(fftLength)))
        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else {
            throw AnalyzerError.fftSetupFailed
        }

        var averagedSpectrum = [Float](repeating: 0, count: fftLength / 2)
        var real = [Float](repeating: 0, count: fftLength / 2)
        var imag = [Float](repeating: 0, count: fftLength / 2)
        var magnitudes = [Float](repeating: 0, count: fftLength / 2)
        var segmentCutoffRatios: [Double] = []

        for segmentIndex in 0..<segmentCount {
            let start = segmentIndex * windowLength
            let end = start + fftLength
            guard end <= audio.channel.count else { break }

            var windowed = Array(audio.channel[start..<end])
            vDSP.multiply(windowed, hannWindow, result: &windowed)

            var interleaved = [DSPComplex](repeating: DSPComplex(real: 0, imag: 0), count: fftLength / 2)
            for i in 0..<(fftLength / 2) {
                interleaved[i] = DSPComplex(real: windowed[i * 2], imag: windowed[i * 2 + 1])
            }

            real.withUnsafeMutableBufferPointer { realPointer in
                imag.withUnsafeMutableBufferPointer { imagPointer in
                    guard
                        let realBase = realPointer.baseAddress,
                        let imagBase = imagPointer.baseAddress
                    else {
                        return
                    }

                    var split = DSPSplitComplex(realp: realBase, imagp: imagBase)
                    interleaved.withUnsafeBufferPointer { pointer in
                        guard let baseAddress = pointer.baseAddress else { return }
                        baseAddress.withMemoryRebound(to: DSPComplex.self, capacity: fftLength / 2) { reboundPointer in
                            vDSP_ctoz(reboundPointer, 1, &split, 1, vDSP_Length(fftLength / 2))
                        }
                    }

                    fft.forward(input: split, output: &split)
                    vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(fftLength / 2))
                }
            }

            let localDb = magnitudes.map { log10f(max($0, 1.0e-12)) }
            let localSmoothed = movingAverage(localDb, window: max(3, fftLength / 100))
            let localCutoff = estimateCutoffIndex(from: localSmoothed, thresholdDrop: profile.thresholdDropDB)
            segmentCutoffRatios.append((Double(localCutoff) * frequencyResolution) / nyquistHz)
            vDSP.add(averagedSpectrum, magnitudes, result: &averagedSpectrum)
        }

        let scaling = Float(1.0 / Double(segmentCount))
        vDSP.multiply(scaling, averagedSpectrum, result: &averagedSpectrum)

        for i in averagedSpectrum.indices {
            averagedSpectrum[i] = log10f(max(averagedSpectrum[i], 1.0e-12))
        }

        let smoothed = movingAverage(averagedSpectrum, window: max(3, fftLength / 100))
        let cutoffIndex = estimateCutoffIndex(from: smoothed, thresholdDrop: profile.thresholdDropDB)
        let cutoffHz = Double(cutoffIndex) * frequencyResolution

        let cutoffRatio = cutoffHz / nyquistHz
        let transitionWidth = max(8, Int(Double(smoothed.count) * 0.02))
        let preStart = max(0, cutoffIndex - transitionWidth)
        let preEnd = max(preStart + 1, cutoffIndex)
        let postStart = min(smoothed.count - 1, cutoffIndex + 2)
        let postEnd = min(smoothed.count, postStart + transitionWidth)

        let preBand = Array(smoothed[preStart..<preEnd])
        let postBand = postStart < postEnd ? Array(smoothed[postStart..<postEnd]) : []
        let preMean = preBand.reduce(0, +) / Float(max(preBand.count, 1))
        let postMean = postBand.isEmpty ? preMean : postBand.reduce(0, +) / Float(postBand.count)
        let dropAmount = max(0, preMean - postMean)

        let stability = stabilityScore(segmentCutoffRatios)
        let dropScore = normalized(value: Double(dropAmount), minValue: 0.30, maxValue: 2.60)
        let lowBandStart = min(averagedSpectrum.count - 1, 5)
        let lowBandEnd = max(lowBandStart + 1, cutoffIndex)
        let highBandStart = min(
            averagedSpectrum.count - 1,
            cutoffIndex + max(4, Int(Double(averagedSpectrum.count) * 0.03))
        )
        let highBandEnd = max(highBandStart + 1, averagedSpectrum.count)
        let lowBand = Array(averagedSpectrum[lowBandStart..<lowBandEnd])
        let highBand = Array(averagedSpectrum[highBandStart..<highBandEnd])
        let lowMean = Double(lowBand.reduce(0, +)) / Double(max(lowBand.count, 1))
        let highMean = Double(highBand.reduce(0, +)) / Double(max(highBand.count, 1))
        let highBandRatio = highMean / max(lowMean, 1.0e-12)
        let suppressionScore = 1.0 - normalized(value: highBandRatio, minValue: 0.015, maxValue: 0.22)
        let sampleSupport = normalized(value: Double(segmentCount), minValue: 6, maxValue: 24)
        let evidenceConfidence = max(
            0,
            min(
                1,
                0.05
                    + (0.38 * dropScore)
                    + (0.30 * stability)
                    + (0.20 * suppressionScore)
                    + (0.07 * sampleSupport)
            )
        )
        let roundedCutoffKHz = Int(cutoffHz / 1_000.0)
        let classification = profile.classification(for: roundedCutoffKHz, cutoffRatio: cutoffRatio)

        // Confidence is evidence-led. Bucket fit refines confidence but cannot dominate weak evidence.
        var confidence = (0.70 * evidenceConfidence) + (0.30 * classification.score)
        if dropScore < 0.03, stability < 0.10 {
            confidence *= 0.45
        }
        if suppressionScore < 0.20 {
            confidence *= 0.75
        }
        let highBitrateLike = classification.label == "192 kbps"
            || classification.label == "224 kbps"
            || classification.label == "320 kbps"
        if highBitrateLike, evidenceConfidence < 0.30 {
            confidence *= 0.60
        }
        if cutoffRatio > 0.995 {
            confidence *= 0.90
        }
        confidence = max(0, min(1, confidence))

        return BitrateEstimate(
            cutoffHz: cutoffHz,
            nyquistHz: nyquistHz,
            inferredBitrate: classification.label,
            dropScore: dropScore,
            stability: stability,
            suppressionScore: suppressionScore,
            sampleSupport: sampleSupport,
            evidenceConfidence: evidenceConfidence,
            classificationConfidence: classification.score,
            confidence: confidence,
            isLosslessContainer: profile == .lossless
        )
    }

    private static func estimateCutoffIndex(from spectrum: [Float], thresholdDrop: Float) -> Int {
        guard spectrum.count > 10, let peak = spectrum.max() else { return 0 }

        // Primary estimate: last bin still within thresholdDrop of the spectrum peak.
        let threshold = peak - thresholdDrop
        let primary = spectrum.lastIndex(where: { $0 >= threshold }) ?? 0

        // Gradient refinement: within a ±12.5% search window around the primary estimate,
        // look for the bin with the steepest local drop. This finds the true "knee" of the
        // spectral shelf rather than the first point that crosses the flat threshold.
        let window = max(2, spectrum.count / 50)   // ~2% of spectrum width per gradient step
        let searchLo = max(0, primary - spectrum.count / 8)
        let searchHi = min(spectrum.count - window - 1, primary + spectrum.count / 20)

        var steepestDrop: Float = 0
        var kneeIndex = primary

        for i in searchLo...max(searchLo, searchHi) {
            let drop = spectrum[i] - spectrum[min(i + window, spectrum.count - 1)]
            if drop > steepestDrop {
                steepestDrop = drop
                kneeIndex = i
            }
        }

        // Only use the gradient-derived knee when the drop is clearly sharper than noise.
        // A shelf edge from MP3 low-pass filtering will be at least 0.5× thresholdDrop deep
        // over the gradient window; gradual frequency roll-off will not.
        if steepestDrop >= thresholdDrop * 0.5 {
            return kneeIndex
        }

        return primary
    }

    private static func stabilityScore(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0.5 }
        let mean = values.reduce(0, +) / Double(values.count)
        guard mean.isFinite, mean > 0 else { return 0.0 }
        let variance = values.reduce(0) { partial, value in
            let diff = value - mean
            return partial + diff * diff
        } / Double(values.count)
        let stdDev = sqrt(variance)
        return max(0, min(1, 1.0 - (stdDev / 0.12)))
    }

    private static func normalized(value: Double, minValue: Double, maxValue: Double) -> Double {
        guard maxValue > minValue else { return 0 }
        let scaled = (value - minValue) / (maxValue - minValue)
        return max(0, min(1, scaled))
    }

    private static func movingAverage(_ input: [Float], window: Int) -> [Float] {
        guard window > 1, input.count >= window else { return input }
        var output = [Float](repeating: .nan, count: input.count)
        var runningSum: Float = 0

        for index in input.indices {
            runningSum += input[index]
            if index >= window {
                runningSum -= input[index - window]
            }
            if index >= (window - 1) {
                output[index - (window / 2)] = runningSum / Float(window)
            }
        }

        var filled = output
        if let firstValid = filled.firstIndex(where: { !$0.isNaN }) {
            for index in 0..<firstValid {
                filled[index] = filled[firstValid]
            }
        }
        if let lastValid = filled.lastIndex(where: { !$0.isNaN }) {
            for index in (lastValid + 1)..<filled.count {
                filled[index] = filled[lastValid]
            }
        }
        return filled.map { $0.isNaN ? input[0] : $0 }
    }

    private static func samplesPerWindow(_ sampleRate: Int) -> Int {
        sampleRate
    }

    private static func largestPowerOfTwo(atMost value: Int) -> Int {
        var power = 1
        while power << 1 <= value {
            power <<= 1
        }
        return power
    }
}

private struct AudioSamples {
    let sampleRate: Int
    let channel: [Float]
    let reportedBitrate: String
    let bitrateMode: String
    let codecProfile: CodecProfile
}

private struct FileMetadata {
    let reportedBitrate: String
    let bitrateMode: String
}

private nonisolated enum CodecProfile {
    case mp3
    case aac
    case opus
    case lossless
    case generic

    var thresholdDropDB: Float {
        switch self {
        case .mp3: return 1.55
        case .aac: return 1.40
        case .opus: return 1.25
        case .lossless: return 1.55  // Match MP3 sensitivity to detect upconverted content in lossless containers
        case .generic: return 1.50
        }
    }

    func classification(for cutoffKHz: Int, cutoffRatio: Double) -> (label: String, score: Double) {
        if self == .lossless {
            // If the spectrum extends close to Nyquist the content is genuinely lossless.
            // If there is a premature cutoff it is likely upconverted from a lossy source —
            // use the same bucket mapping as MP3 since that is by far the most common source.
            if cutoffRatio >= 0.92 {
                let score = normalizedScore(cutoffRatio, center: 0.97, spread: 0.05)
                return ("lossless", score)
            }
            return classify(
                cutoffKHz: cutoffKHz,
                buckets: [
                    (0...11, "64 kbps", 10),
                    (12...14, "128 kbps", 13),
                    (15...16, "160 kbps", 15),
                    (17...18, "192 kbps", 17),
                    (19...19, "224 kbps", 19),
                    (20...21, "320 kbps", 20)
                ]
            )
        }

        switch self {
        case .mp3:
            return classify(
                cutoffKHz: cutoffKHz,
                buckets: [
                    (0...11, "64 kbps", 10),
                    (12...14, "128 kbps", 13),
                    (15...16, "160 kbps", 15),
                    (17...18, "192 kbps", 17),
                    (19...19, "224 kbps", 19),
                    (20...21, "320 kbps", 20)
                ]
            )
        case .aac:
            return classify(
                cutoffKHz: cutoffKHz,
                buckets: [
                    (0...13, "96 kbps", 12),
                    (14...17, "128 kbps", 16),
                    (18...20, "192 kbps", 19),
                    (21...22, "256 kbps", 21)
                ]
            )
        case .opus:
            return classify(
                cutoffKHz: cutoffKHz,
                buckets: [
                    (0...11, "96 kbps", 10),
                    (12...16, "128 kbps", 15),
                    (17...20, "192 kbps", 18)
                ]
            )
        case .lossless:
            // Handled above; unreachable but satisfies exhaustiveness.
            return ("lossless", 0.98)
        case .generic:
            return classify(
                cutoffKHz: cutoffKHz,
                buckets: [
                    (0...11, "64 kbps", 10),
                    (12...14, "128 kbps", 13),
                    (15...16, "160 kbps", 15),
                    (17...18, "192 kbps", 17),
                    (19...19, "224 kbps", 19),
                    (20...20, "320 kbps", 20),
                    (21...22, "500 kbps", 21)
                ]
            )
        }
    }

    private func classify(
        cutoffKHz: Int,
        buckets: [(ClosedRange<Int>, String, Int)]
    ) -> (label: String, score: Double) {
        for (range, label, center) in buckets where range.contains(cutoffKHz) {
            let width = max(1, (range.upperBound - range.lowerBound + 1))
            let spread = Double(width) * 0.55
            let score = normalizedScore(Double(cutoffKHz), center: Double(center), spread: spread)
            return (label, score)
        }
        return ("unknown", 0.35)
    }

    private func normalizedScore(_ value: Double, center: Double, spread: Double) -> Double {
        guard spread > 0 else { return 0.0 }
        let distance = abs(value - center)
        let score = exp(-distance / spread)
        return max(0.30, min(0.99, score))
    }
}

private nonisolated struct BitrateEstimate {
    let cutoffHz: Double
    let nyquistHz: Double
    let inferredBitrate: String
    let dropScore: Double
    let stability: Double
    let suppressionScore: Double
    let sampleSupport: Double
    let evidenceConfidence: Double
    let classificationConfidence: Double
    let confidence: Double
    /// True when the audio container is a lossless format (FLAC, WAV, AIFF, ALAC).
    /// When this is true and inferredBitrate is not "lossless", the file is a fake lossless.
    let isLosslessContainer: Bool

    private var roundedCutoffKHz: Int {
        Int(cutoffHz / 1_000.0)
    }

    private var detailedCutoffKHz: String {
        String(format: "%.1f", cutoffHz / 1_000.0)
    }

    private var cutoffRatio: Double {
        cutoffHz / nyquistHz
    }

    private var confidencePercent: Int {
        let finalConfidence = confidenceAdjustedForAmbiguity
        return Int((finalConfidence * 100).rounded())
    }

    private var confidenceAdjustedForAmbiguity: Double {
        var adjusted = max(0, min(1, confidence))
        if inferredBitrate == "unknown" {
            adjusted = min(adjusted, 0.55)
        }
        if inferredBitrate == "lossless" && cutoffRatio < 0.95 {
            adjusted = min(adjusted, 0.70)
        }
        // Fake lossless: cap at 85% — we are confident about the upconversion but
        // cannot be 100% certain without knowing the original encoding history.
        if isLosslessContainer && inferredBitrate != "lossless" {
            adjusted = min(adjusted, 0.85)
        }
        return adjusted
    }

    var actualBitrate: String {
        inferredBitrate
    }

    var frequency: String {
        "\(roundedCutoffKHz) kHz (\(detailedCutoffKHz) kHz)"
    }

    var confidenceText: String {
        "\(confidencePercent)%"
    }

    var features: AnalysisFeatures {
        AnalysisFeatures(
            cutoffKHz: cutoffHz / 1_000.0,
            cutoffRatio: cutoffRatio,
            dropScore: dropScore,
            stability: stability,
            suppressionScore: suppressionScore,
            sampleSupport: sampleSupport,
            evidenceConfidence: evidenceConfidence,
            classificationConfidence: classificationConfidence,
            modelConfidence: confidence,
            finalConfidence: confidenceAdjustedForAmbiguity
        )
    }

    var status: String {
        if confidence < 0.30 {
            return "Inconclusive"
        }
        if inferredBitrate == "lossless" {
            // 0.92–0.95 is a borderline zone: the spectrum almost reaches Nyquist but not
            // convincingly enough to call it clean lossless with high confidence.
            if cutoffRatio < 0.95 {
                return "Possibly lossless (borderline)"
            }
            return "Likely lossless"
        }
        // Lossless container (FLAC/WAV/AIFF) with a premature spectral cutoff —
        // the file was almost certainly transcoded from a lossy source.
        if isLosslessContainer {
            return "Fake lossless — upconverted from ~\(inferredBitrate)"
        }
        if inferredBitrate == "unknown" {
            return "Likely lossy"
        }
        return "Likely lossy (\(inferredBitrate))"
    }
}

private enum AnalyzerError: LocalizedError {
    case invalidSampleRate
    case bufferCreationFailed
    case noAudioData
    case unsupportedPCMFormat
    case insufficientSamples
    case fftSetupFailed

    var errorDescription: String? {
        switch self {
        case .invalidSampleRate:
            return "Unsupported sample rate."
        case .bufferCreationFailed:
            return "Failed to allocate audio buffer."
        case .noAudioData:
            return "No audio data could be read."
        case .unsupportedPCMFormat:
            return "Unsupported PCM format."
        case .insufficientSamples:
            return "Not enough samples for FFT analysis."
        case .fftSetupFailed:
            return "Failed to initialize FFT engine."
        }
    }
}

private struct RunResult {
    let success: Bool
    let actualBitrate: String
    let frequency: String
    let confidence: String
    let analysisStatus: String
    let reportedBitrate: String
    let bitrateMode: String
    let features: AnalysisFeatures?
    let cutoffHz: Double?
}

struct AnalysisFeatures {
    let cutoffKHz: Double
    let cutoffRatio: Double
    let dropScore: Double
    let stability: Double
    let suppressionScore: Double
    let sampleSupport: Double
    let evidenceConfidence: Double
    let classificationConfidence: Double
    let modelConfidence: Double
    let finalConfidence: Double

    var cutoffKHzText: String { Self.format(cutoffKHz) }
    var cutoffRatioText: String { Self.format(cutoffRatio) }
    var dropScoreText: String { Self.format(dropScore) }
    var stabilityText: String { Self.format(stability) }
    var suppressionScoreText: String { Self.format(suppressionScore) }
    var sampleSupportText: String { Self.format(sampleSupport) }
    var evidenceConfidenceText: String { Self.format(evidenceConfidence) }
    var classificationConfidenceText: String { Self.format(classificationConfidence) }
    var modelConfidenceText: String { Self.format(modelConfidence) }
    var finalConfidenceText: String { Self.format(finalConfidence) }

    private static func format(_ value: Double) -> String {
        String(format: "%.6f", value)
    }
}

struct TrainingSample {
    let fileURL: URL
    let fileType: String
    let reportedBitrate: String
    let predictedBitrate: String
    let confidenceText: String
    let analysisStatus: String
    let expectedLabel: String
    let expectationType: String
    let isTrainable: Bool
    let isMatch: Bool?
    let features: AnalysisFeatures?
}

private enum TrainingLabelParser {
    static func parse(fileName: String, reportedBitrate: String) -> (label: String, type: String, isTrainable: Bool) {
        let uppercased = fileName.uppercased()
        if uppercased.contains("[CORRUPTED]") {
            return ("corrupted", "corrupted", false)
        }

        if let realTag = realBitrateTag(from: uppercased) {
            return (realTag, "real_tag", true)
        }

        if uppercased.contains("[REAL") {
            return ("unparsed_tag", "unknown_tag", false)
        }

        let normalizedReported = normalize(reportedBitrate)
        guard !normalizedReported.isEmpty else {
            return ("missing_reported", "aligned_reported", false)
        }
        return (normalizedReported, "aligned_reported", true)
    }

    static func normalize(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty || trimmed == "n/a" || trimmed == "unknown" || trimmed == "—" {
            return ""
        }
        if trimmed == "lossless" {
            return "lossless"
        }
        let digits = trimmed.filter { $0.isNumber }
        guard let bitrate = Int(digits), bitrate > 0 else {
            return ""
        }
        return "\(bitrate) kbps"
    }

    private static func realBitrateTag(from uppercasedName: String) -> String? {
        guard let matchRange = uppercasedName.range(of: #"\[REAL\s+([0-9]{2,4}|LOSSLESS)\]"#, options: .regularExpression) else {
            return nil
        }
        let fullTag = String(uppercasedName[matchRange])
        if fullTag.contains("LOSSLESS") {
            return "lossless"
        }
        let digits = fullTag.filter { $0.isNumber }
        guard let bitrate = Int(digits), bitrate > 0 else {
            return nil
        }
        return "\(bitrate) kbps"
    }
}

struct ValidationResult: Identifiable {
    let id = UUID()
    let fileURL: URL
    var actualBitrate: String
    var frequency: String
    var confidence: String
    var analysisStatus: String
    var state: ValidationState
    var reportedBitrate: String
    var bitrateMode: String
    var fileType: String
    var cutoffHz: Double?

    var sortFileName: String {
        fileURL.lastPathComponent.lowercased()
    }

    var sortReportedBitrate: Int {
        Self.parseBitrateKbps(reportedBitrate) ?? -1
    }

    var sortActualBitrate: Int {
        Self.parseBitrateKbps(actualBitrate) ?? -1
    }

    var sortFrequencyKHz: Int {
        Self.parseLeadingInt(frequency) ?? -1
    }

    var sortConfidencePercent: Int {
        Self.parseLeadingInt(confidence) ?? -1
    }

    var sortRunState: Int {
        switch state {
        case .pending: return 0
        case .running: return 1
        case .done: return 2
        case .failed: return 3
        }
    }

    var comparisonColor: Color {
        switch comparisonOutcome {
        case .unprocessed:
            return .primary
        case .match:
            return .green
        case .mismatch:
            return .red
        case .actualHigher:
            return .orange
        }
    }

    private var comparisonOutcome: BitrateComparisonOutcome {
        if state == .pending || state == .running {
            return .unprocessed
        }

        guard
            let reported = Self.parseBitrateKbps(reportedBitrate),
            let actual = Self.parseBitrateKbps(actualBitrate)
        else {
            let normalizedReported = reportedBitrate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let normalizedActual = actualBitrate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !normalizedReported.isEmpty, normalizedReported == normalizedActual {
                return .match
            }
            return .mismatch
        }

        if actual == reported {
            return .match
        }
        if actual > reported {
            return .actualHigher
        }
        return .mismatch
    }

    private static func parseBitrateKbps(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if trimmed == "n/a" || trimmed == "unknown" || trimmed == "lossless" || trimmed == "—" {
            return nil
        }

        let digits = trimmed.filter { $0.isNumber }
        return Int(digits)
    }

    private static func parseLeadingInt(_ text: String) -> Int? {
        let digits = text.prefix { $0.isNumber }
        return Int(digits)
    }
}

private enum BitrateComparisonOutcome {
    case unprocessed
    case match
    case mismatch
    case actualHigher
}

enum ValidationState {
    case pending
    case running
    case done
    case failed

    var label: String {
        switch self {
        case .pending: return "Pending"
        case .running: return "Running"
        case .done: return "Done"
        case .failed: return "Failed"
        }
    }

    var colour: Color {
        switch self {
        case .pending: return .secondary
        case .running: return .orange
        case .done: return .green
        case .failed: return .red
        }
    }

    var symbolName: String {
        switch self {
        case .pending: return "clock.badge.questionmark"
        case .running: return "hourglass.circle"
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }
}
