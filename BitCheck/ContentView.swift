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
            Text("Bit Check")
                .font(.largeTitle)
                .fontWeight(.semibold)

            Text("Check whether an audio file's spectral quality matches its claimed format.")
                .foregroundStyle(.secondary)

            DropArea(isTargeted: $isDropTargeted)
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
                    viewModel.handleDrop(providers: providers)
                    return true
                }

            HStack {
                Button("Open Selected in Finder") {
                    guard let selectedFileURL else { return }
                    viewModel.openInFinder(url: selectedFileURL)
                }
                .disabled(selectedFileURL == nil)
                Spacer()
                Text("\(viewModel.queuedFiles.count) file(s)")
                    .foregroundStyle(.secondary)
            }

            if !viewModel.statusMessage.isEmpty {
                Text(viewModel.statusMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if viewModel.isRunning, viewModel.totalCount > 0 {
                ProgressView(
                    value: Double(viewModel.completedCount),
                    total: Double(viewModel.totalCount)
                )
                .accessibilityLabel("Analysis progress")
                .accessibilityValue("\(viewModel.completedCount) of \(viewModel.totalCount) files")
            }

            Table(sortedResults, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Run", value: \.sortRunState) { item in
                    Image(systemName: item.state.symbolName)
                        .foregroundStyle(item.state.colour)
                        .help(item.state.label)
                        .accessibilityLabel(item.state.label)
                }
                .width(min: 34, ideal: 36)

                TableColumn("File", value: \.sortFileName) { item in
                    Text(item.fileURL.lastPathComponent)
                        .lineLimit(1)
                        .foregroundStyle(item.comparisonColor)
                }
                .width(min: 220, ideal: 280)

                TableColumn("Format", value: \.fileType) { item in
                    Text(item.fileType)
                        .foregroundStyle(item.comparisonColor)
                }
                .width(min: 75, ideal: 90)

                TableColumn("Estimated Source", value: \.sortActualBitrate) { item in
                    Text(item.actualBitrate)
                        .foregroundStyle(item.comparisonColor)
                }
                .width(min: 110, ideal: 135)

                TableColumn("Cutoff", value: \.sortFrequencyKHz) { item in
                    Text(item.frequency)
                        .foregroundStyle(item.comparisonColor)
                }
                .width(min: 105, ideal: 135)

                TableColumn("Confidence", value: \.sortConfidencePercent) { item in
                    Text(item.confidence)
                        .foregroundStyle(item.comparisonColor)
                }
                .width(min: 90, ideal: 110)

                TableColumn("Verdict", value: \.analysisStatus) { item in
                    Text(item.analysisStatus)
                        .foregroundStyle(item.comparisonColor)
                }
                .width(min: 170, ideal: 230)

                TableColumn("Technical", value: \.technicalSummary) { item in
                    Text(item.technicalSummary)
                        .foregroundStyle(.secondary)
                }
                .width(min: 145, ideal: 190)

            }
            .overlay {
                if sortedResults.isEmpty {
                    ContentUnavailableView(
                        "No audio queued",
                        systemImage: "waveform.badge.plus",
                        description: Text("Drop audio above or add files from the toolbar.")
                    )
                }
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
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Add Files", systemImage: "plus") {
                    viewModel.pickFiles()
                }
                .disabled(viewModel.isRunning || viewModel.isImporting)

                Button("Add Folder", systemImage: "folder.badge.plus") {
                    viewModel.pickFolder()
                }
                .disabled(viewModel.isRunning || viewModel.isImporting)

                Button("Clear", systemImage: "trash") {
                    viewModel.clearQueue()
                }
                .disabled(viewModel.queuedFiles.isEmpty || viewModel.isRunning || viewModel.isImporting)

                Menu("Training", systemImage: "wrench.and.screwdriver") {
                    Toggle("Training Mode", isOn: $viewModel.trainingModeEnabled)
                    Button("Export Training CSV") {
                        viewModel.exportTrainingCSV()
                    }
                    .disabled(viewModel.trainingSamples.isEmpty || viewModel.isRunning)
                }

                Menu("Analysis", systemImage: "waveform.path.ecg") {
                    Toggle("Full-stream technical checks", isOn: $viewModel.deepAnalysisEnabled)
                }
                .disabled(viewModel.isRunning)

                if viewModel.isRunning {
                    Button("Cancel", systemImage: "stop.fill", role: .cancel) {
                        viewModel.cancelValidation()
                    }
                } else {
                    Button("Run", systemImage: "play.fill") {
                        viewModel.startValidation()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(viewModel.queuedFiles.isEmpty || viewModel.isImporting)
                }
            }
        }
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
    let logImage: NSImage
    let linearImage: NSImage
    let fileType: String
    let reportedBitrate: String
    let reportedSampleRateHz: Int
    let durationSeconds: Double
    let cutoffHz: Double?
}

private struct SpectrogramDetailView: View {
    let presentation: SpectrogramPresentation
    @State private var showHorizontalGridLines = false
    @State private var darkBackground = true
    @State private var logScale = true
    private let logFreqTicks: [Double] = [20000, 10000, 5000, 2000, 1000, 500, 200, 100, 50, 20]
    private let minFreqHz: Double = 20.0
    private let xTickCount = 11
    private let yAxisWidth: CGFloat = 58
    private let legendWidth: CGFloat = 50
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

            HStack(spacing: 20) {
                Toggle("Show grid lines", isOn: $showHorizontalGridLines)
                    .toggleStyle(.switch)
                    .font(.caption)
                Toggle("Log scale", isOn: $logScale)
                    .toggleStyle(.switch)
                    .font(.caption)
                Toggle("Dark background", isOn: $darkBackground)
                    .toggleStyle(.switch)
                    .font(.caption)
            }

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

                                        for freq in activeFreqTicks {
                                            let y = yTickPosition(freqHz: freq, height: axisGeo.size.height)
                                            path.move(to: CGPoint(x: axisGeo.size.width - 7, y: y))
                                            path.addLine(to: CGPoint(x: axisGeo.size.width, y: y))
                                        }
                                    }
                                    .stroke(axisStroke, lineWidth: 1)

                                    ForEach(activeFreqTicks, id: \.self) { freq in
                                        let y = yTickPosition(freqHz: freq, height: axisGeo.size.height)
                                        Text(formatFreqLabel(freq))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .frame(width: axisGeo.size.width - 11, alignment: .trailing)
                                            .position(x: (axisGeo.size.width - 11) / 2, y: y)
                                    }
                                }
                            }
                        }

                        ZStack(alignment: .topLeading) {
                            (darkBackground ? Color.black : Color.white)

                            Image(nsImage: activeImage)
                                .resizable()
                                .interpolation(.none)
                                .frame(maxWidth: .infinity, minHeight: imageHeight, maxHeight: imageHeight)
                                .clipped()

                            if showHorizontalGridLines {
                                GeometryReader { imageGeo in
                                    Path { path in
                                        for freq in activeFreqTicks {
                                            let y = yTickPosition(freqHz: freq, height: imageGeo.size.height)
                                            path.move(to: CGPoint(x: 0, y: y))
                                            path.addLine(to: CGPoint(x: imageGeo.size.width, y: y))
                                        }
                                    }
                                    .stroke(Color.black.opacity(0.40), lineWidth: 1)
                                }
                            }

                            if let cutoffHz = presentation.cutoffHz, cutoffHz > 0 {
                                GeometryReader { imageGeo in
                                    let y = yTickPosition(freqHz: cutoffHz, height: imageGeo.size.height)
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
                        .frame(maxWidth: .infinity, minHeight: imageHeight, maxHeight: imageHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                        dbLegendView
                            .frame(width: legendWidth, height: imageHeight)
                            .padding(.leading, 6)
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
                        // Spacer matching legend width so time axis aligns under the image
                        Color.clear.frame(width: legendWidth + 6)
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

    private var nyquistHz: Double { Double(presentation.reportedSampleRateHz) / 2.0 }

    private var activeImage: NSImage { logScale ? presentation.logImage : presentation.linearImage }

    /// Linear ticks at 2 kHz steps from 0 up to Nyquist
    private var linearFreqTicks: [Double] {
        stride(from: 0.0, through: nyquistHz, by: 2000.0).map { $0 }
    }

    private var activeFreqTicks: [Double] {
        logScale ? logFreqTicks.filter { $0 <= nyquistHz } : linearFreqTicks
    }

    private func yTickPosition(freqHz: Double, height: CGFloat) -> CGFloat {
        if logScale {
            let logFrac = log(max(freqHz, minFreqHz) / minFreqHz) / log(nyquistHz / minFreqHz)
            let frac = 1.0 - logFrac
            return (height * CGFloat(max(0.0, min(1.0, frac)))).rounded()
        } else {
            let frac = 1.0 - freqHz / nyquistHz
            return (height * CGFloat(max(0.0, min(1.0, frac)))).rounded()
        }
    }

    private func formatFreqLabel(_ hz: Double) -> String {
        hz >= 1_000 ? "\(Int(hz / 1_000)) kHz" : "\(Int(hz)) Hz"
    }

    // Gradient stops match colourMap, reversed so top = 0 dB (white) and bottom = -120 dB (black)
    private let dbGradientStops: [Gradient.Stop] = [
        .init(color: .white,                                          location: 0.000), // 0 dB
        .init(color: Color(red: 1,       green: 1,     blue: 0),     location: 0.222), // yellow
        .init(color: Color(red: 1,       green: 100/255, blue: 0),   location: 0.444), // orange
        .init(color: Color(red: 88/255,  green: 0,     blue: 88/255), location: 0.667), // dark purple
        .init(color: .black,                                          location: 1.000), // -120 dB
    ]

    private var dbLegendView: some View {
        Color.clear
            .overlay {
                GeometryReader { geo in
                    ZStack(alignment: .topLeading) {
                        // Colour gradient bar
                        LinearGradient(stops: dbGradientStops, startPoint: .top, endPoint: .bottom)
                            .frame(width: 10, height: geo.size.height)
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                            .position(x: 5, y: geo.size.height / 2)

                        // Tick marks on right edge of bar
                        Path { path in
                            for db in stride(from: 0.0, through: -120.0, by: -20.0) {
                                let y = (-db / 120.0) * geo.size.height
                                path.move(to: CGPoint(x: 10, y: y))
                                path.addLine(to: CGPoint(x: 14, y: y))
                            }
                        }
                        .stroke(axisStroke, lineWidth: 1)

                        // dB labels
                        ForEach(stride(from: 0.0, through: -120.0, by: -20.0).map { $0 }, id: \.self) { db in
                            let y = ((-db / 120.0) * geo.size.height).rounded()
                            Text(db == 0 ? "0 dB" : "\(Int(db))")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                                .frame(width: legendWidth - 17, alignment: .leading)
                                .position(x: 17 + (legendWidth - 17) / 2, y: y)
                        }
                    }
                }
            }
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
        var logIntensities = [Float](repeating: 0, count: timeBins * displayHeight)
        var linearIntensities = [Float](repeating: 0, count: timeBins * displayHeight)
        let nyquistHz = Double(sampleRate) / 2.0
        let minFreqHz = 20.0
        let logMin = log(minFreqHz)
        let logMax = log(nyquistHz)

        for frame in 0..<timeBins {
            let start = frame * hopLength
            let end = start + fftLength
            var windowed = Array(samples[start..<end])
            vDSP.multiply(windowed, hannWindow, result: &windowed)

            real.withUnsafeMutableBufferPointer { realPointer in
                imag.withUnsafeMutableBufferPointer { imagPointer in
                    guard let realBase = realPointer.baseAddress, let imagBase = imagPointer.baseAddress else { return }
                    var split = DSPSplitComplex(realp: realBase, imagp: imagBase)
                    windowed.withUnsafeBufferPointer { windowedPtr in
                        windowedPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: freqBins) { complexPtr in
                            vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(freqBins))
                        }
                    }
                    fft.forward(input: split, output: &split)
                    vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(freqBins))
                }
            }

            // Reference level: expected peak magnitude for a full-scale sine through a Hann window
            // equals N/4 (where N = fftLength). Dividing normalises to dBFS so 0 dBFS → white.
            let refLevel = Double(fftLength / 4)

            // Log-scale image (20 Hz → Nyquist, logarithmic)
            for y in 0..<displayHeight {
                let freqHz = exp(logMin + (logMax - logMin) * Double(y) / Double(max(displayHeight - 1, 1)))
                let bin = max(0, min(freqBins - 1, Int((freqHz / nyquistHz * Double(freqBins - 1)).rounded())))
                let dbFS = 20.0 * log10(Double(max(magnitudes[bin], 1.0e-12)) / refLevel)
                let normalized = Float(max(0.0, min(1.0, (dbFS + 120.0) / 120.0)))
                logIntensities[(y * timeBins) + frame] = normalized
            }

            // Linear-scale image (0 Hz → Nyquist, linear)
            for y in 0..<displayHeight {
                let bin = max(0, min(freqBins - 1, Int((Double(y) / Double(max(displayHeight - 1, 1)) * Double(freqBins - 1)).rounded())))
                let dbFS = 20.0 * log10(Double(max(magnitudes[bin], 1.0e-12)) / refLevel)
                let normalized = Float(max(0.0, min(1.0, (dbFS + 120.0) / 120.0)))
                linearIntensities[(y * timeBins) + frame] = normalized
            }
        }

        return SpectrogramRenderOutput(
            logImage: try makeImage(intensities: logIntensities, width: timeBins, height: displayHeight),
            linearImage: try makeImage(intensities: linearIntensities, width: timeBins, height: displayHeight),
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
                // Alpha fades near-silence to transparent; fully opaque at value >= 0.1 (≈ −108 dBFS)
                let alpha = min(1.0, value * 10.0)
                // Premultiply RGB by alpha for correct compositing
                pixels[offset] = UInt8((Float(colour.r) * alpha).rounded())
                pixels[offset + 1] = UInt8((Float(colour.g) * alpha).rounded())
                pixels[offset + 2] = UInt8((Float(colour.b) * alpha).rounded())
                pixels[offset + 3] = UInt8((alpha * 255.0).rounded())
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
        // Spek palette: black (-120 dB) → dark purple → orange → yellow → white (0 dB)
        typealias Stop = (pos: Float, r: Float, g: Float, b: Float)
        let stops: [Stop] = [
            (0.000,   0,   0,   0),   // black
            (0.333,  88,   0,  88),   // dark purple
            (0.556, 255, 100,   0),   // orange
            (0.778, 255, 255,   0),   // yellow
            (1.000, 255, 255, 255),   // white
        ]
        var lo = stops[0]
        var hi = stops[stops.count - 1]
        for i in 0..<(stops.count - 1) where v >= stops[i].pos && v <= stops[i + 1].pos {
            lo = stops[i]; hi = stops[i + 1]
            break
        }
        let range = hi.pos - lo.pos
        let t = range > 0 ? (v - lo.pos) / range : 0
        return (
            UInt8((lo.r + t * (hi.r - lo.r)).rounded()),
            UInt8((lo.g + t * (hi.g - lo.g)).rounded()),
            UInt8((lo.b + t * (hi.b - lo.b)).rounded())
        )
    }
}

private struct SpectrogramRenderOutput {
    let logImage: NSImage
    let linearImage: NSImage
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
    @Published private(set) var isImporting = false
    @Published var statusMessage = ""
    @Published private(set) var completedCount = 0
    @Published private(set) var totalCount = 0
    @Published var deepAnalysisEnabled = true
    @Published var trainingModeEnabled = false
    @Published private(set) var trainingSamples: [TrainingSample] = []

    private let maxConcurrentAnalyses: Int
    private let analysisOperation: @Sendable (URL, Bool) -> RunResult
    private var validationTask: Task<Void, Never>?

    private let supportedAudioExtensions: Set<String> = [
        "mp3", "flac", "wav", "m4a", "aac", "ogg", "opus", "aiff", "aif", "alac"
    ]

    init(
        maxConcurrentAnalyses: Int = ValidationViewModel.defaultConcurrencyLimit,
        analysisOperation: @escaping @Sendable (URL, Bool) -> RunResult = { file, includeTechnicalEvidence in
            NativeTrueBitrateAnalyzer.analyze(
                file: file,
                includeTechnicalEvidence: includeTechnicalEvidence
            )
        }
    ) {
        self.maxConcurrentAnalyses = max(1, maxConcurrentAnalyses)
        self.analysisOperation = analysisOperation
    }

    nonisolated static var defaultConcurrencyLimit: Int {
        min(4, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
    }

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
        Task { [weak self] in
            var urls: [URL] = []
            for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                if let url = await Self.droppedURL(from: provider) {
                    urls.append(url)
                }
            }
            self?.enqueue(urls: urls)
        }
    }

    func clearQueue() {
        queuedFiles.removeAll()
        results.removeAll()
        trainingSamples.removeAll()
        completedCount = 0
        totalCount = 0
        statusMessage = ""
    }

    func startValidation() {
        guard validationTask == nil, !queuedFiles.isEmpty, !isImporting else { return }
        validationTask = Task { [weak self] in
            await self?.validateQueuedFiles()
        }
    }

    func cancelValidation() {
        guard let validationTask else { return }
        statusMessage = "Cancelling analysis…"
        validationTask.cancel()
    }

    func validateQueuedFiles() async {
        guard !queuedFiles.isEmpty, !isRunning else { return }

        isRunning = true
        defer {
            isRunning = false
            validationTask = nil
        }

        let files = queuedFiles
        let includeTechnicalEvidence = deepAnalysisEnabled
        completedCount = 0
        totalCount = files.count
        statusMessage = "Analysing 0 of \(files.count) files…"
        if trainingModeEnabled {
            trainingSamples.removeAll()
        }

        results = files.map {
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
                fileType: existing.fileType,
                cutoffHz: nil
            )
        }

        await withTaskGroup(of: BatchAnalysisOutput.self) { group in
            var nextFileIndex = 0

            while nextFileIndex < min(maxConcurrentAnalyses, files.count) {
                let file = files[nextFileIndex]
                nextFileIndex += 1
                markRunning(file: file)
                let operation = analysisOperation
                group.addTask(priority: .userInitiated) {
                    BatchAnalysisOutput(
                        file: file,
                        result: operation(file, includeTechnicalEvidence)
                    )
                }
            }

            while let output = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    continue
                }

                apply(output)
                completedCount += 1
                statusMessage = "Analysing \(completedCount) of \(files.count) files…"

                if nextFileIndex < files.count {
                    let file = files[nextFileIndex]
                    nextFileIndex += 1
                    markRunning(file: file)
                    let operation = analysisOperation
                    group.addTask(priority: .userInitiated) {
                        BatchAnalysisOutput(
                            file: file,
                            result: operation(file, includeTechnicalEvidence)
                        )
                    }
                }
            }
        }

        if Task.isCancelled {
            markUnfinishedAsCancelled()
            statusMessage = "Analysis cancelled after \(completedCount) of \(files.count) files."
            return
        }

        let failedCount = results.filter { $0.state == .failed }.count
        if failedCount == 0 {
            statusMessage = "Validation completed for \(results.count) file(s)."
        } else {
            statusMessage = "Validation completed with \(failedCount) failure(s)."
        }
        if trainingModeEnabled {
            let trainableCount = trainingSamples.filter(\.isTrainable).count
            statusMessage += " Training rows: \(trainingSamples.count) (\(trainableCount) trainable)."
        }
    }

    private func markRunning(file: URL) {
        guard let index = results.firstIndex(where: { $0.fileURL == file }) else { return }
        results[index].state = .running
        results[index].analysisStatus = "Analysing"
    }

    private func apply(_ output: BatchAnalysisOutput) {
        guard let index = results.firstIndex(where: { $0.fileURL == output.file }) else { return }
        let result = output.result
        results[index].state = result.success ? .done : .failed
        results[index].actualBitrate = result.actualBitrate
        results[index].frequency = result.frequency
        results[index].confidence = result.confidence
        results[index].analysisStatus = result.analysisStatus
        results[index].reportedBitrate = result.reportedBitrate
        results[index].bitrateMode = result.bitrateMode
        results[index].cutoffHz = result.cutoffHz
        results[index].technicalSummary = result.technicalEvidence?.summary ?? "Not checked"

        if trainingModeEnabled {
            let expectation = TrainingLabelParser.parse(
                fileName: output.file.deletingPathExtension().lastPathComponent,
                reportedBitrate: result.reportedBitrate
            )
            let predictedLabel = TrainingLabelParser.normalize(result.actualBitrate)
            let isMatch = expectation.isTrainable ? expectation.label == predictedLabel : nil
            trainingSamples.append(
                TrainingSample(
                    fileURL: output.file,
                    fileType: results[index].fileType,
                    reportedBitrate: result.reportedBitrate,
                    predictedBitrate: result.actualBitrate,
                    confidenceText: result.confidence,
                    analysisStatus: result.analysisStatus,
                    expectedLabel: expectation.label,
                    expectationType: expectation.type,
                    isTrainable: expectation.isTrainable,
                    isMatch: isMatch,
                    features: result.features,
                    technicalEvidence: result.technicalEvidence
                )
            )
        }
    }

    private func markUnfinishedAsCancelled() {
        for index in results.indices where results[index].state == .pending || results[index].state == .running {
            results[index].state = .cancelled
            results[index].analysisStatus = "Cancelled"
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
        guard !urls.isEmpty, !isRunning, !isImporting else { return }
        isImporting = true
        statusMessage = "Discovering audio files…"
        let supportedExtensions = supportedAudioExtensions

        Task { [weak self] in
            let candidates = await Task.detached(priority: .userInitiated) {
                Self.importCandidates(from: urls, supportedExtensions: supportedExtensions)
            }.value
            guard let self else { return }
            defer { isImporting = false }

            guard !candidates.isEmpty else {
                statusMessage = "No supported audio files found."
                return
            }

            let existingByURL = Dictionary(uniqueKeysWithValues: results.map { ($0.fileURL, $0) })
            let candidateByURL = Dictionary(uniqueKeysWithValues: candidates.map { ($0.fileURL, $0) })
            queuedFiles = Set(queuedFiles).union(candidateByURL.keys).sorted { $0.path < $1.path }
            results = queuedFiles.map { file in
                if let existing = existingByURL[file] {
                    return existing
                }
                guard let candidate = candidateByURL[file] else {
                    return self.existingOrDefaultResult(for: file)
                }
                return self.defaultResult(for: file, metadata: candidate.metadata)
            }
            statusMessage = "Queued \(queuedFiles.count) file(s)."
        }
    }

    private func existingOrDefaultResult(for file: URL) -> ValidationResult {
        if let existing = results.first(where: { $0.fileURL == file }) {
            return existing
        }
        let metadata = metadata(for: file)
        return defaultResult(for: file, metadata: metadata)
    }

    private func defaultResult(for file: URL, metadata: FileMetadata) -> ValidationResult {
        ValidationResult(
            fileURL: file,
            actualBitrate: "—",
            frequency: "—",
            confidence: "—",
            analysisStatus: "Not run",
            state: .pending,
            reportedBitrate: metadata.reportedBitrate,
            bitrateMode: metadata.bitrateMode,
            fileType: metadata.displayFormat,
            cutoffHz: nil
        )
    }

    nonisolated private static func importCandidates(
        from urls: [URL],
        supportedExtensions: Set<String>
    ) -> [QueuedFileCandidate] {
        let files = urls.flatMap { url -> [URL] in
            guard !Task.isCancelled else { return [] }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                return []
            }
            if !isDirectory.boolValue {
                return supportedExtensions.contains(url.pathExtension.lowercased()) ? [url] : []
            }
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }
            var discovered: [URL] = []
            for case let fileURL as URL in enumerator {
                guard !Task.isCancelled else { break }
                if supportedExtensions.contains(fileURL.pathExtension.lowercased()) {
                    discovered.append(fileURL)
                }
            }
            return discovered
        }
        return Array(Set(files)).map { file in
            QueuedFileCandidate(fileURL: file, metadata: NativeTrueBitrateAnalyzer.inspect(file: file))
        }
    }

    private func metadata(for file: URL) -> FileMetadata {
        NativeTrueBitrateAnalyzer.inspect(file: file)
    }

    nonisolated private static func droppedURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(
                    returning: NSURL(absoluteURLWithDataRepresentation: data, relativeTo: nil) as URL?
                )
            }
        }
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
                logImage: renderOutput.logImage,
                linearImage: renderOutput.linearImage,
                fileType: metadata.displayFormat,
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
            "gradient_cutoff_khz",
            "energy_cutoff_khz",
            "noise_floor_cutoff_khz",
            "cutoff_spread_khz",
            "cutoff_mean_deviation_khz",
            "cutoff_agreement",
            "temporal_cutoff_p10_khz",
            "temporal_cutoff_median_khz",
            "temporal_cutoff_p90_khz",
            "temporal_cutoff_spread_khz",
            "temporal_shelf_persistence",
            "cutoff_ratio",
            "drop_score",
            "stability",
            "suppression_score",
            "sample_support",
            "evidence_confidence",
            "classification_confidence",
            "model_confidence",
            "final_confidence",
            "integrity_defective",
            "declared_frames",
            "decoded_frames",
            "shortfall_seconds",
            "shortfall_ratio",
            "integrity_read_error",
            "clipped_samples",
            "clipping_ratio",
            "peak_amplitude",
            "longest_silence_seconds"
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
            row.append(features?.gradientCutoffKHzText ?? "")
            row.append(features?.energyCutoffKHzText ?? "")
            row.append(features?.noiseFloorCutoffKHzText ?? "")
            row.append(features?.cutoffSpreadKHzText ?? "")
            row.append(features?.cutoffMeanDeviationKHzText ?? "")
            row.append(features?.cutoffAgreementText ?? "")
            row.append(features?.temporalCutoffP10KHzText ?? "")
            row.append(features?.temporalCutoffMedianKHzText ?? "")
            row.append(features?.temporalCutoffP90KHzText ?? "")
            row.append(features?.temporalCutoffSpreadKHzText ?? "")
            row.append(features?.temporalShelfPersistenceText ?? "")
            row.append(features?.cutoffRatioText ?? "")
            row.append(features?.dropScoreText ?? "")
            row.append(features?.stabilityText ?? "")
            row.append(features?.suppressionScoreText ?? "")
            row.append(features?.sampleSupportText ?? "")
            row.append(features?.evidenceConfidenceText ?? "")
            row.append(features?.classificationConfidenceText ?? "")
            row.append(features?.modelConfidenceText ?? "")
            row.append(features?.finalConfidenceText ?? "")
            let technical = sample.technicalEvidence
            row.append(technical.map { $0.isTechnicallyDefective ? "true" : "false" } ?? "")
            row.append(technical.map { String($0.declaredFrames) } ?? "")
            row.append(technical.map { String($0.decodedFrames) } ?? "")
            row.append(technical.map { String(format: "%.6f", $0.shortfallSeconds) } ?? "")
            row.append(technical.map { String(format: "%.6f", $0.shortfallRatio) } ?? "")
            row.append(technical?.readError ?? "")
            row.append(technical.map { String($0.clippedSamples) } ?? "")
            row.append(technical.map { String(format: "%.9f", $0.clippingRatio) } ?? "")
            row.append(technical.map { String(format: "%.6f", $0.peakAmplitude) } ?? "")
            row.append(technical.map { String(format: "%.6f", $0.longestSilenceSeconds) } ?? "")
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

nonisolated enum NativeTrueBitrateAnalyzer {
    static func inspect(file: URL) -> FileMetadata {
        do {
            let audioFile = try AVAudioFile(forReading: file)
            let format = audioFile.processingFormat
            return metadata(from: audioFile, fileURL: file, format: format)
        } catch {
            return FileMetadata(
                reportedBitrate: "N/A",
                bitrateMode: "Unknown",
                codecName: "Unknown",
                containerName: containerName(for: file)
            )
        }
    }

    static func inspectStreamIntegrity(file: URL) -> StreamIntegrityEvidence {
        do {
            let audioFile = try AVAudioFile(forReading: file)
            let format = audioFile.processingFormat
            let sampleRate = format.sampleRate
            guard sampleRate > 0 else {
                return StreamIntegrityEvidence(
                    declaredFrames: audioFile.length,
                    decodedFrames: 0,
                    sampleRate: sampleRate,
                    channelCount: Int(format.channelCount),
                    clippedSamples: 0,
                    longestSilentFrames: 0,
                    peakAmplitude: 0,
                    readError: "Unsupported sample rate"
                )
            }

            let declaredFrames = max(0, audioFile.length)
            let chunkFrames: AVAudioFrameCount = 32_768
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
                return StreamIntegrityEvidence(
                    declaredFrames: declaredFrames,
                    decodedFrames: 0,
                    sampleRate: sampleRate,
                    channelCount: Int(format.channelCount),
                    clippedSamples: 0,
                    longestSilentFrames: 0,
                    peakAmplitude: 0,
                    readError: "Failed to allocate integrity buffer"
                )
            }

            audioFile.framePosition = 0
            var decodedFrames: AVAudioFramePosition = 0
            var clippedSamples: Int64 = 0
            var currentSilentFrames: AVAudioFramePosition = 0
            var longestSilentFrames: AVAudioFramePosition = 0
            var peakAmplitude: Float = 0
            var readError: String?

            while declaredFrames == 0 || decodedFrames < declaredFrames {
                if Task.isCancelled {
                    readError = "Cancelled"
                    break
                }
                let requestedFrames: AVAudioFrameCount
                if declaredFrames == 0 {
                    requestedFrames = chunkFrames
                } else {
                    requestedFrames = AVAudioFrameCount(
                        min(AVAudioFramePosition(chunkFrames), declaredFrames - decodedFrames)
                    )
                }

                do {
                    try audioFile.read(into: buffer, frameCount: requestedFrames)
                } catch {
                    readError = error.localizedDescription
                    break
                }

                guard buffer.frameLength > 0 else { break }
                let channels = try extractChannelData(from: buffer)
                let frameCount = Int(buffer.frameLength)
                var framePeaks = [Float](repeating: 0, count: frameCount)
                var magnitudes = [Float](repeating: 0, count: frameCount)
                var thresholdFlags = [Float](repeating: 0, count: frameCount)
                var clippingThreshold: Float = 0.999
                var marker: Float = 1

                for channel in channels {
                    vDSP_vabs(channel, 1, &magnitudes, 1, vDSP_Length(frameCount))
                    vDSP_vmax(
                        framePeaks,
                        1,
                        magnitudes,
                        1,
                        &framePeaks,
                        1,
                        vDSP_Length(frameCount)
                    )
                    vDSP_vthrsc(
                        magnitudes,
                        1,
                        &clippingThreshold,
                        &marker,
                        &thresholdFlags,
                        1,
                        vDSP_Length(frameCount)
                    )
                    var signedSum: Float = 0
                    vDSP_sve(thresholdFlags, 1, &signedSum, vDSP_Length(frameCount))
                    clippedSamples += Int64(((signedSum + Float(frameCount)) * 0.5).rounded())
                }

                var bufferPeak: Float = 0
                vDSP_maxv(framePeaks, 1, &bufferPeak, vDSP_Length(frameCount))
                peakAmplitude = max(peakAmplitude, bufferPeak)
                for framePeak in framePeaks {
                    if framePeak < 0.001 {
                        currentSilentFrames += 1
                        longestSilentFrames = max(longestSilentFrames, currentSilentFrames)
                    } else {
                        currentSilentFrames = 0
                    }
                }
                decodedFrames += AVAudioFramePosition(buffer.frameLength)
            }

            return StreamIntegrityEvidence(
                declaredFrames: declaredFrames,
                decodedFrames: decodedFrames,
                sampleRate: sampleRate,
                channelCount: Int(format.channelCount),
                clippedSamples: clippedSamples,
                longestSilentFrames: longestSilentFrames,
                peakAmplitude: peakAmplitude,
                readError: readError
            )
        } catch {
            return StreamIntegrityEvidence(
                declaredFrames: 0,
                decodedFrames: 0,
                sampleRate: 0,
                channelCount: 0,
                clippedSamples: 0,
                longestSilentFrames: 0,
                peakAmplitude: 0,
                readError: error.localizedDescription
            )
        }
    }

    static func analyze(file: URL, includeTechnicalEvidence: Bool = false) -> RunResult {
        do {
            try Task.checkCancellation()
            let samples = try loadSamples(from: file, maxSeconds: 30)
            guard samples.regionRanges.contains(where: { $0.count >= samplesPerWindow(samples.sampleRate) }) else {
                return RunResult(
                    success: false,
                    actualBitrate: "N/A",
                    frequency: "N/A",
                    confidence: "0%",
                    analysisStatus: "Audio too short",
                    reportedBitrate: samples.reportedBitrate,
                    bitrateMode: samples.bitrateMode,
                    features: nil,
                    cutoffHz: nil,
                    verdict: nil
                )
            }

            let estimate = try estimateBitrate(from: samples)
            let technicalEvidence = includeTechnicalEvidence ? inspectStreamIntegrity(file: file) : nil
            try Task.checkCancellation()
            let verdict: AnalysisVerdict
            if let technicalEvidence, technicalEvidence.isTechnicallyDefective {
                verdict = .technicallyDefective(
                    reason: technicalEvidence.defectReason ?? "stream integrity failure"
                )
            } else {
                verdict = estimate.verdict
            }
            return RunResult(
                success: true,
                actualBitrate: estimate.actualBitrate,
                frequency: estimate.frequency,
                confidence: estimate.confidenceText,
                analysisStatus: verdict.label,
                reportedBitrate: samples.reportedBitrate,
                bitrateMode: samples.bitrateMode,
                features: estimate.features,
                cutoffHz: estimate.cutoffHz,
                verdict: verdict,
                technicalEvidence: technicalEvidence
            )
        } catch is CancellationError {
            return RunResult(
                success: false,
                actualBitrate: "N/A",
                frequency: "N/A",
                confidence: "0%",
                analysisStatus: "Cancelled",
                reportedBitrate: "N/A",
                bitrateMode: "Unknown",
                features: nil,
                cutoffHz: nil,
                verdict: nil
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
                cutoffHz: nil,
                verdict: nil
            )
        }
    }

    private static func loadSamples(from fileURL: URL, maxSeconds: Int) throws -> AudioSamples {
        try Task.checkCancellation()
        let file = try AVAudioFile(forReading: fileURL)
        let format = file.processingFormat
        let sampleRate = Int(format.sampleRate.rounded())
        guard sampleRate > 0 else {
            throw AnalyzerError.invalidSampleRate
        }
        let metadata = metadata(from: file, fileURL: fileURL, format: format)

        let maxFrames = AVAudioFramePosition(sampleRate * maxSeconds)
        let totalFramesToRead = min(file.length, maxFrames)
        guard totalFramesToRead > 0 else { throw AnalyzerError.noAudioData }

        let regionCount = file.length > maxFrames ? 5 : 1
        let baseRegionLength = totalFramesToRead / AVAudioFramePosition(regionCount)
        let remainder = totalFramesToRead % AVAudioFramePosition(regionCount)
        let maxStart = max(0, file.length - baseRegionLength)
        var channels = Array(repeating: [Float](), count: Int(format.channelCount))
        var regionRanges: [Range<Int>] = []

        for regionIndex in 0..<regionCount {
            try Task.checkCancellation()
            let regionLength = baseRegionLength + (regionIndex == regionCount - 1 ? remainder : 0)
            guard regionLength > 0 else { continue }
            let startFrame: AVAudioFramePosition
            if regionCount == 1 {
                startFrame = 0
            } else {
                startFrame = AVAudioFramePosition(
                    (Double(maxStart) * Double(regionIndex) / Double(regionCount - 1)).rounded()
                )
            }
            file.framePosition = startFrame

            let frameCount = AVAudioFrameCount(regionLength)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                throw AnalyzerError.bufferCreationFailed
            }
            try file.read(into: buffer, frameCount: frameCount)
            guard buffer.frameLength > 0 else { continue }

            let extractedChannels = try extractChannelData(from: buffer)
            guard extractedChannels.count == channels.count, let extractedLength = extractedChannels.first?.count else {
                throw AnalyzerError.noAudioData
            }
            let destinationStart = channels.first?.count ?? 0
            for channelIndex in channels.indices {
                channels[channelIndex].append(contentsOf: extractedChannels[channelIndex])
            }
            regionRanges.append(destinationStart..<(destinationStart + extractedLength))
        }

        guard !channels.isEmpty, !regionRanges.isEmpty else { throw AnalyzerError.noAudioData }
        let formatID = file.fileFormat.streamDescription.pointee.mFormatID
        return AudioSamples(
            sampleRate: sampleRate,
            channels: channels,
            regionRanges: regionRanges,
            reportedBitrate: metadata.reportedBitrate,
            bitrateMode: metadata.bitrateMode,
            codecProfile: CodecProfile.detect(formatID: formatID, fileExtension: fileURL.pathExtension)
        )
    }

    private static func metadata(from file: AVAudioFile, fileURL: URL, format: AVAudioFormat) -> FileMetadata {
        if let metadata = metadataFromAudioToolbox(fileURL: fileURL) {
            return metadata
        }

        let reported = reportedBitrateFromSizeAndDuration(file: file, fileURL: fileURL, format: format) ?? "N/A"
        let formatID = file.fileFormat.streamDescription.pointee.mFormatID
        let profile = CodecProfile.detect(formatID: formatID, fileExtension: fileURL.pathExtension)
        return FileMetadata(
            reportedBitrate: reported,
            bitrateMode: "Unknown",
            codecName: profile.displayName,
            containerName: containerName(for: fileURL)
        )
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

        let profile = CodecProfile.detect(
            formatID: hasASBD ? asbd.mFormatID : nil,
            fileExtension: fileURL.pathExtension
        )
        return FileMetadata(
            reportedBitrate: reported,
            bitrateMode: mode,
            codecName: profile.displayName,
            containerName: containerName(for: fileURL)
        )
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

    private static func containerName(for fileURL: URL) -> String {
        let fileExtension = fileURL.pathExtension.uppercased()
        return fileExtension.isEmpty ? "Unknown" : fileExtension
    }

    private static func extractChannelData(from buffer: AVAudioPCMBuffer) throws -> [[Float]] {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { throw AnalyzerError.noAudioData }
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let channels = buffer.floatChannelData else { throw AnalyzerError.noAudioData }
            return (0..<channelCount).map { channelIndex in
                Array(UnsafeBufferPointer(start: channels[channelIndex], count: frameCount))
            }
        case .pcmFormatInt16:
            guard let channels = buffer.int16ChannelData else { throw AnalyzerError.noAudioData }
            return (0..<channelCount).map { channelIndex in
                let source = channels[channelIndex]
                return (0..<frameCount).map { Float(source[$0]) / Float(Int16.max) }
            }
        case .pcmFormatInt32:
            guard let channels = buffer.int32ChannelData else { throw AnalyzerError.noAudioData }
            return (0..<channelCount).map { channelIndex in
                let source = channels[channelIndex]
                return (0..<frameCount).map { Float(source[$0]) / Float(Int32.max) }
            }
        default:
            throw AnalyzerError.unsupportedPCMFormat
        }
    }

    // MARK: - Welch's Method Spectral Analysis

    private static let analysisFFTLength = 8192
    private static let analysisHopFraction = 0.5 // 50% overlap

    static func estimateBitrate(from audio: AudioSamples) throws -> BitrateEstimate {
        try Task.checkCancellation()
        let sampleRate = audio.sampleRate
        let fftLength = analysisFFTLength
        let hopLength = Int(Double(fftLength) * analysisHopFraction)
        let freqBins = fftLength / 2
        let nyquistHz = Double(sampleRate) / 2.0
        let frequencyResolution = Double(sampleRate) / Double(fftLength)
        let profile = audio.codecProfile

        let segmentStarts = analysisWindowStarts(
            regionRanges: audio.regionRanges,
            fftLength: fftLength,
            hopLength: hopLength,
            maxWindows: 200
        )
        guard !audio.channels.isEmpty, !segmentStarts.isEmpty else { throw AnalyzerError.noAudioData }

        var hannWindow = [Float](repeating: 0, count: fftLength)
        vDSP_hann_window(&hannWindow, vDSP_Length(fftLength), Int32(vDSP_HANN_NORM))

        let log2n = vDSP_Length(log2(Double(fftLength)))
        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else {
            throw AnalyzerError.fftSetupFailed
        }

        // Accumulate power spectrum (squared magnitudes) — Welch's method
        var averagedPower = [Float](repeating: 0, count: freqBins)
        var real = [Float](repeating: 0, count: freqBins)
        var imag = [Float](repeating: 0, count: freqBins)
        var magnitudes = [Float](repeating: 0, count: freqBins)
        var power = [Float](repeating: 0, count: freqBins)
        var segmentCutoffsHz: [Double] = []

        var transformCount = 0
        for start in segmentStarts {
            try Task.checkCancellation()
            let end = start + fftLength
            for channel in audio.channels {
                guard end <= channel.count else { continue }

                var windowed = Array(channel[start..<end])
                vDSP.multiply(windowed, hannWindow, result: &windowed)

                real.withUnsafeMutableBufferPointer { rp in
                    imag.withUnsafeMutableBufferPointer { ip in
                        guard let rb = rp.baseAddress, let ib = ip.baseAddress else { return }
                        var split = DSPSplitComplex(realp: rb, imagp: ib)
                        windowed.withUnsafeBufferPointer { wp in
                            wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: freqBins) { cp in
                                vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(freqBins))
                            }
                        }
                        fft.forward(input: split, output: &split)
                        vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(freqBins))
                    }
                }

                // Combining channels in the power domain avoids phase cancellation.
                vDSP.multiply(magnitudes, magnitudes, result: &power)
                vDSP.add(averagedPower, power, result: &averagedPower)
                transformCount += 1

                // Per-channel, per-window estimates retain temporal and channel disagreement.
                let localDb = power.map { 10.0 * log10f(max($0, 1.0e-24)) }
                let localSmoothed = movingAverage(localDb, window: max(3, freqBins / 80))
                let localCutoff = cutoffGradient(spectrum: localSmoothed, frequencyResolution: frequencyResolution)
                segmentCutoffsHz.append(localCutoff)
            }
        }

        guard transformCount > 0 else { throw AnalyzerError.noAudioData }
        let scaling = Float(1.0 / Double(transformCount))
        vDSP.multiply(scaling, averagedPower, result: &averagedPower)

        // Convert averaged power to dB
        var spectrumDb = [Float](repeating: 0, count: freqBins)
        for i in 0..<freqBins {
            spectrumDb[i] = 10.0 * log10f(max(averagedPower[i], 1.0e-24))
        }
        let smoothed = movingAverage(spectrumDb, window: max(3, freqBins / 80))

        // --- Multi-method cutoff detection ---
        let cutoffEvidence = cutoffEvidence(
            powerSpectrum: averagedPower,
            spectrumDb: smoothed,
            frequencyResolution: frequencyResolution,
            nyquistHz: nyquistHz
        )
        let fusedCutoffHz = cutoffEvidence.fusedHz
        let cutoffAgreement = cutoffEvidence.agreement
        let cutoffRatio = fusedCutoffHz / nyquistHz

        // Shelf sharpness: dB drop across the cutoff region
        let fusedIndex = max(0, min(freqBins - 1, Int((fusedCutoffHz / frequencyResolution).rounded())))
        let shelfSharpness = computeShelfSharpness(spectrum: smoothed, cutoffIndex: fusedIndex)

        // --- Sub-band energy analysis ---
        let subBandResult = subBandAnalysis(powerSpectrum: averagedPower, sampleRate: sampleRate, freqBins: freqBins)

        // --- Stability ---
        let segmentCutoffRatios = segmentCutoffsHz.map { $0 / nyquistHz }
        let stability = stabilityScore(segmentCutoffRatios)
        let temporalCutoffEvidence = temporalCutoffEvidence(
            segmentCutoffsHz: segmentCutoffsHz,
            referenceCutoffHz: fusedCutoffHz
        )
        let sampleSupport = normalized(value: Double(segmentStarts.count), minValue: 6, maxValue: 60)

        // --- Lossless discrimination (multi-feature) ---
        let losslessScore =
            0.25 * normalized(value: cutoffRatio, minValue: 0.90, maxValue: 1.00)
            + 0.20 * (1.0 - shelfSharpness)
            + 0.20 * normalized(value: subBandResult.highBandEnergyRatio, minValue: 0.001, maxValue: 0.02)
            + 0.15 * normalized(value: subBandResult.airBandFlatness, minValue: 0.01, maxValue: 0.5)
            + 0.10 * (1.0 - cutoffAgreement)
            + 0.10 * (1.0 - stability)

        // --- Classification ---
        let classification: (label: String, score: Double)
        if profile == .lossless {
            if losslessScore > 0.65 {
                classification = ("lossless", min(0.99, losslessScore))
            } else {
                classification = profile.classifyContinuous(cutoffHz: fusedCutoffHz, sampleRate: sampleRate)
            }
        } else {
            classification = profile.classifyContinuous(cutoffHz: fusedCutoffHz, sampleRate: sampleRate)
        }

        // --- Confidence model ---
        let highBandSuppression = 1.0 - normalized(
            value: subBandResult.highBandEnergyRatio, minValue: 0.001, maxValue: 0.10
        )
        let evidenceConfidence = max(0, min(1,
            0.05
            + 0.25 * shelfSharpness
            + 0.20 * stability
            + 0.15 * highBandSuppression
            + 0.15 * cutoffAgreement
            + 0.10 * normalized(value: subBandResult.airBandFlatness, minValue: 0.0, maxValue: 0.3)
            + 0.05 * sampleSupport
            + 0.05 * normalized(value: shelfSharpness, minValue: 0.0, maxValue: 1.0)
        ))

        var confidence: Double
        if classification.label == "lossless" {
            let bandwidthSupport = normalized(value: cutoffRatio, minValue: 0.92, maxValue: 1.0)
            let highBandPresence = 1.0 - highBandSuppression
            confidence =
                0.55 * classification.score
                + 0.25 * bandwidthSupport
                + 0.10 * highBandPresence
                + 0.10 * sampleSupport
            if cutoffRatio > 0.995 {
                confidence *= 0.95
            }
        } else {
            confidence = 0.65 * evidenceConfidence + 0.35 * classification.score
            if shelfSharpness < 0.05, stability < 0.10 {
                confidence *= 0.45
            }
            if highBandSuppression < 0.20 {
                confidence *= 0.75
            }
            if cutoffAgreement < 0.30 {
                confidence *= 0.60
            }
            let highBitrateLike = ["192 kbps", "224 kbps", "256 kbps", "320 kbps"].contains(classification.label)
            if highBitrateLike, evidenceConfidence < 0.30 {
                confidence *= 0.60
            }
            if cutoffRatio > 0.995 {
                confidence *= 0.90
            }
        }
        confidence = max(0, min(1, confidence))

        return BitrateEstimate(
            cutoffHz: fusedCutoffHz,
            nyquistHz: nyquistHz,
            inferredBitrate: classification.label,
            dropScore: shelfSharpness,
            stability: stability,
            suppressionScore: highBandSuppression,
            sampleSupport: sampleSupport,
            evidenceConfidence: evidenceConfidence,
            classificationConfidence: classification.score,
            confidence: confidence,
            isLosslessContainer: profile == .lossless,
            cutoffEvidence: cutoffEvidence,
            temporalCutoffEvidence: temporalCutoffEvidence
        )
    }

    static func temporalCutoffEvidence(
        segmentCutoffsHz: [Double],
        referenceCutoffHz: Double
    ) -> TemporalCutoffEvidence {
        let sorted = segmentCutoffsHz.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else {
            return TemporalCutoffEvidence(
                sampleCount: 0,
                lowerPercentileHz: 0,
                medianHz: 0,
                upperPercentileHz: 0,
                percentileSpreadHz: 0,
                shelfPersistence: 0
            )
        }

        let lower = percentile(sorted, fraction: 0.10)
        let median = percentile(sorted, fraction: 0.50)
        let upper = percentile(sorted, fraction: 0.90)
        let persistentCount = sorted.reduce(into: 0) { count, cutoff in
            if abs(cutoff - referenceCutoffHz) <= 1_000 {
                count += 1
            }
        }
        return TemporalCutoffEvidence(
            sampleCount: sorted.count,
            lowerPercentileHz: lower,
            medianHz: median,
            upperPercentileHz: upper,
            percentileSpreadHz: max(0, upper - lower),
            shelfPersistence: Double(persistentCount) / Double(sorted.count)
        )
    }

    private static func percentile(_ sortedValues: [Double], fraction: Double) -> Double {
        guard let first = sortedValues.first else { return 0 }
        guard sortedValues.count > 1 else { return first }
        let position = max(0, min(1, fraction)) * Double(sortedValues.count - 1)
        let lowerIndex = Int(position.rounded(.down))
        let upperIndex = Int(position.rounded(.up))
        guard lowerIndex != upperIndex else { return sortedValues[lowerIndex] }
        let interpolation = position - Double(lowerIndex)
        return sortedValues[lowerIndex]
            + interpolation * (sortedValues[upperIndex] - sortedValues[lowerIndex])
    }

    static func analysisWindowStarts(
        regionRanges: [Range<Int>],
        fftLength: Int = analysisFFTLength,
        hopLength: Int = Int(Double(analysisFFTLength) * analysisHopFraction),
        maxWindows: Int = 200
    ) -> [Int] {
        guard fftLength > 0, hopLength > 0, maxWindows > 0 else { return [] }
        let candidates = regionRanges.flatMap { region -> [Int] in
            guard region.count >= fftLength else { return [] }
            return Array(stride(from: region.lowerBound, through: region.upperBound - fftLength, by: hopLength))
        }
        guard candidates.count > maxWindows else { return candidates }
        guard maxWindows > 1 else { return [candidates[candidates.count / 2]] }
        return (0..<maxWindows).map { index in
            let position = Double(index) * Double(candidates.count - 1) / Double(maxWindows - 1)
            return candidates[Int(position.rounded())]
        }
    }

    // MARK: - Cutoff Detection Methods

    static func cutoffEvidence(
        powerSpectrum: [Float],
        spectrumDb: [Float],
        frequencyResolution: Double,
        nyquistHz: Double
    ) -> CutoffEvidence {
        let gradientHz = cutoffGradient(spectrum: spectrumDb, frequencyResolution: frequencyResolution)
        let energyHz = cutoffEnergyRatio(powerSpectrum: powerSpectrum, frequencyResolution: frequencyResolution)
        let noiseFloorHz = cutoffNoiseFloor(
            spectrumDb: spectrumDb,
            frequencyResolution: frequencyResolution,
            nyquistHz: nyquistHz
        )
        let sortedCutoffs = [gradientHz, energyHz, noiseFloorHz].sorted()
        let fusedHz = sortedCutoffs[1]
        let spreadHz = sortedCutoffs[2] - sortedCutoffs[0]
        let meanDeviationHz = [gradientHz, energyHz, noiseFloorHz]
            .map { abs($0 - fusedHz) }
            .reduce(0, +) / 3.0
        return CutoffEvidence(
            gradientHz: gradientHz,
            energyHz: energyHz,
            noiseFloorHz: noiseFloorHz,
            fusedHz: fusedHz,
            spreadHz: spreadHz,
            meanDeviationHz: meanDeviationHz,
            agreement: 1.0 - normalized(value: meanDeviationHz, minValue: 0, maxValue: 2_000)
        )
    }

    /// Method A: Gradient — find frequency with steepest spectral descent
    private static func cutoffGradient(spectrum: [Float], frequencyResolution: Double) -> Double {
        let count = spectrum.count
        guard count > 20 else { return 0 }
        let step = max(4, count / 200)
        var steepestDrop: Float = 0
        var kneeIndex = 0

        // Search from 5% to 95% of spectrum to avoid edges
        let searchLo = max(1, count / 20)
        let searchHi = min(count - step - 1, count * 19 / 20)

        for i in searchLo..<searchHi {
            let drop = spectrum[i] - spectrum[min(i + step, count - 1)]
            if drop > steepestDrop {
                steepestDrop = drop
                kneeIndex = i
            }
        }

        // Require a meaningful drop (at least 3 dB over the step) to declare a cutoff
        if steepestDrop < 3.0 {
            return Double(count - 1) * frequencyResolution  // No clear cutoff → near Nyquist
        }
        return Double(kneeIndex) * frequencyResolution
    }

    /// Method B: Cumulative energy ratio — find frequency containing 99.5% of total energy
    private static func cutoffEnergyRatio(powerSpectrum: [Float], frequencyResolution: Double) -> Double {
        let count = powerSpectrum.count
        guard count > 0 else { return 0 }

        var cumulative = [Double](repeating: 0, count: count)
        cumulative[0] = Double(powerSpectrum[0])
        for i in 1..<count {
            cumulative[i] = cumulative[i - 1] + Double(powerSpectrum[i])
        }

        let totalEnergy = cumulative[count - 1]
        guard totalEnergy > 0 else { return 0 }
        let threshold = totalEnergy * 0.995

        for i in 0..<count where cumulative[i] >= threshold {
            return Double(i) * frequencyResolution
        }
        return Double(count - 1) * frequencyResolution
    }

    /// Method C: Noise floor — scan from top down, find first band above noise floor + margin
    private static func cutoffNoiseFloor(spectrumDb: [Float], frequencyResolution: Double, nyquistHz: Double) -> Double {
        let count = spectrumDb.count
        guard count > 20 else { return 0 }

        // Estimate noise floor from the top 5% of frequency bins
        let noiseStart = count * 95 / 100
        let noiseSlice = Array(spectrumDb[noiseStart..<count])
        let noiseFloor = noiseSlice.reduce(0, +) / Float(max(noiseSlice.count, 1))

        let margin: Float = 10.0  // dB above noise floor
        let bandWidth = max(4, count / 50)  // ~500 Hz bands at typical resolution

        // Scan from high frequency downward
        var bandStart = count - bandWidth
        while bandStart > 0 {
            let bandEnd = min(count, bandStart + bandWidth)
            let bandSlice = Array(spectrumDb[bandStart..<bandEnd])
            let bandMean = bandSlice.reduce(0, +) / Float(bandSlice.count)
            if bandMean > noiseFloor + margin {
                return Double(bandEnd) * frequencyResolution
            }
            bandStart -= bandWidth
        }

        // No distinct shelf above the top-band reference: treat this as bandwidth
        // extending to Nyquist, not as a 0 Hz cutoff outlier.
        return min(nyquistHz, Double(count - 1) * frequencyResolution)
    }

    /// Compute shelf sharpness: normalized dB drop across the cutoff region
    private static func computeShelfSharpness(spectrum: [Float], cutoffIndex: Int) -> Double {
        let count = spectrum.count
        guard count > 20, cutoffIndex > 0, cutoffIndex < count - 1 else { return 0 }

        let width = max(4, count / 100)
        let preStart = max(0, cutoffIndex - width)
        let preEnd = cutoffIndex
        let postStart = min(count - 1, cutoffIndex + 2)
        let postEnd = min(count, postStart + width)

        guard preEnd > preStart, postEnd > postStart else { return 0 }

        let preMean = Array(spectrum[preStart..<preEnd]).reduce(0, +) / Float(preEnd - preStart)
        let postMean = Array(spectrum[postStart..<postEnd]).reduce(0, +) / Float(postEnd - postStart)
        let drop = Double(max(0, preMean - postMean))

        // Normalize: 0 dB drop → 0, ≥20 dB drop → 1
        return normalized(value: drop, minValue: 0, maxValue: 20)
    }

    // MARK: - Sub-Band Analysis

    private struct SubBandResult {
        let highBandEnergyRatio: Double
        let airBandFlatness: Double
    }

    private static func subBandAnalysis(powerSpectrum: [Float], sampleRate: Int, freqBins: Int) -> SubBandResult {
        let nyquist = Double(sampleRate) / 2.0
        let binHz = nyquist / Double(freqBins)

        // 8 sub-bands (Hz boundaries at 44.1 kHz)
        let bandEdges: [(lo: Double, hi: Double)] = [
            (20, 200), (200, 500), (500, 1500), (1500, 4000),
            (4000, 8000), (8000, 12000), (12000, 16000), (16000, nyquist)
        ]

        var bandEnergies = [Double](repeating: 0, count: bandEdges.count)
        for (idx, band) in bandEdges.enumerated() {
            let loIdx = max(0, Int((band.lo / binHz).rounded()))
            let hiIdx = min(freqBins - 1, Int((band.hi / binHz).rounded()))
            guard hiIdx > loIdx else { continue }
            for i in loIdx...hiIdx {
                bandEnergies[idx] += Double(powerSpectrum[i])
            }
        }

        // High-band energy ratio: bands 7+8 vs bands 1-6
        let lowEnergy = bandEnergies[0..<6].reduce(0, +)
        let highEnergy = bandEnergies[6..<8].reduce(0, +)
        let highBandEnergyRatio = lowEnergy > 1e-12 ? highEnergy / lowEnergy : 0

        // Spectral flatness of air band (band 8): geometric mean / arithmetic mean
        let airLo = max(0, Int((16000.0 / binHz).rounded()))
        let airHi = min(freqBins - 1, freqBins - 1)
        var airBandFlatness = 0.0
        if airHi > airLo {
            let airSlice = Array(powerSpectrum[airLo...airHi]).map { Double(max($0, 1e-24)) }
            let logSum = airSlice.reduce(0.0) { $0 + log($1) }
            let geometricMean = exp(logSum / Double(airSlice.count))
            let arithmeticMean = airSlice.reduce(0, +) / Double(airSlice.count)
            airBandFlatness = arithmeticMean > 1e-24 ? geometricMean / arithmeticMean : 0
        }

        return SubBandResult(highBandEnergyRatio: highBandEnergyRatio, airBandFlatness: airBandFlatness)
    }

    // MARK: - Utility Functions

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
        analysisFFTLength
    }

    private static func largestPowerOfTwo(atMost value: Int) -> Int {
        var power = 1
        while power << 1 <= value {
            power <<= 1
        }
        return power
    }
}

nonisolated struct AudioSamples {
    let sampleRate: Int
    let channels: [[Float]]
    let regionRanges: [Range<Int>]
    let reportedBitrate: String
    let bitrateMode: String
    let codecProfile: CodecProfile
}

nonisolated struct CutoffEvidence: Equatable {
    let gradientHz: Double
    let energyHz: Double
    let noiseFloorHz: Double
    let fusedHz: Double
    let spreadHz: Double
    let meanDeviationHz: Double
    let agreement: Double
}

nonisolated struct TemporalCutoffEvidence: Equatable, Sendable {
    let sampleCount: Int
    let lowerPercentileHz: Double
    let medianHz: Double
    let upperPercentileHz: Double
    let percentileSpreadHz: Double
    let shelfPersistence: Double
}

nonisolated struct FileMetadata: Sendable {
    let reportedBitrate: String
    let bitrateMode: String
    let codecName: String
    let containerName: String

    var displayFormat: String {
        codecName == containerName ? codecName : "\(containerName) · \(codecName)"
    }
}

nonisolated private struct QueuedFileCandidate: Sendable {
    let fileURL: URL
    let metadata: FileMetadata
}

nonisolated enum CodecProfile: Equatable {
    case mp3
    case aac
    case opus
    case lossless
    case generic

    var displayName: String {
        switch self {
        case .mp3: return "MP3"
        case .aac: return "AAC"
        case .opus: return "Opus"
        case .lossless: return "Lossless"
        case .generic: return "Unknown"
        }
    }

    static func detect(formatID: AudioFormatID?, fileExtension: String) -> CodecProfile {
        if let formatID {
            switch formatID {
            case kAudioFormatMPEGLayer3:
                return .mp3
            case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2:
                return .aac
            case kAudioFormatOpus:
                return .opus
            case kAudioFormatAppleLossless, kAudioFormatFLAC, kAudioFormatLinearPCM:
                return .lossless
            default:
                break
            }
        }

        switch fileExtension.lowercased() {
        case "mp3": return .mp3
        case "aac": return .aac
        case "opus", "ogg": return .opus
        case "flac", "alac", "wav", "aiff", "aif": return .lossless
        default: return .generic
        }
    }

    /// Hz-precision bitrate buckets expressed as absolute decoded bandwidths.
    /// Each tuple: (lowHz, highHz, centerHz, label)
    private typealias Bucket = (lo: Double, hi: Double, center: Double, label: String)

    private var referenceBuckets: [Bucket] {
        switch self {
        case .mp3, .lossless, .generic:
            return [
                (3500,  4500,  4000,  "32 kbps"),
                (10500, 11500, 11000, "64 kbps"),
                (13500, 14500, 14000, "96 kbps"),
                (15500, 16500, 16000, "128 kbps"),
                (17000, 18000, 17500, "160 kbps"),
                (18500, 19500, 19000, "192 kbps"),
                (19200, 19800, 19500, "224 kbps"),
                (19800, 20200, 20000, "256 kbps"),
                (20000, 20500, 20250, "320 kbps"),
            ]
        case .aac:
            return [
                (12500, 13500, 13000, "64 kbps"),
                (14500, 15500, 15000, "96 kbps"),
                (15500, 17000, 16000, "128 kbps"),
                (17000, 18000, 17500, "160 kbps"),
                (18500, 19500, 19000, "192 kbps"),
                (19800, 20500, 20000, "256 kbps"),
            ]
        case .opus:
            return [
                (10000, 12000, 11000, "64 kbps"),
                (12000, 14000, 13000, "96 kbps"),
                (14000, 17000, 15500, "128 kbps"),
                (17000, 19000, 18000, "160 kbps"),
                (19000, 20500, 19500, "192 kbps"),
            ]
        }
    }

    /// Classify a cutoff frequency (in Hz) to a bitrate label using Hz-precision thresholds.
    /// Output sample rate is deliberately not used to scale an earlier source's bandwidth.
    func classifyContinuous(cutoffHz: Double, sampleRate: Int) -> (label: String, score: Double) {
        _ = sampleRate
        let buckets = referenceBuckets
        guard cutoffHz.isFinite, cutoffHz > 0,
              let nearest = buckets.min(by: {
                  abs(cutoffHz - $0.center) < abs(cutoffHz - $1.center)
              }) else {
            return ("unknown", 0)
        }

        // The named tiers are a product vocabulary, while the confidence
        // remains continuous. Always return the nearest tier for a valid
        // cutoff; gaps between provisional reference ranges should reduce the
        // score rather than erase the estimate altogether.
        let spread = max(100, (nearest.hi - nearest.lo) * 0.55)
        let score = distanceScore(cutoffHz, center: nearest.center, spread: spread)
        return (nearest.label, score)
    }

    private func distanceScore(_ value: Double, center: Double, spread: Double) -> Double {
        guard spread > 0 else { return 0 }
        let distance = abs(value - center)
        let score = exp(-distance / spread)
        return max(0.30, min(0.99, score))
    }
}

nonisolated struct StreamIntegrityEvidence: Equatable, Sendable {
    let declaredFrames: AVAudioFramePosition
    let decodedFrames: AVAudioFramePosition
    let sampleRate: Double
    let channelCount: Int
    let clippedSamples: Int64
    let longestSilentFrames: AVAudioFramePosition
    let peakAmplitude: Float
    let readError: String?

    var missingFrames: AVAudioFramePosition {
        max(0, declaredFrames - decodedFrames)
    }

    var shortfallSeconds: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(missingFrames) / sampleRate
    }

    var shortfallRatio: Double {
        guard declaredFrames > 0 else { return 0 }
        return Double(missingFrames) / Double(declaredFrames)
    }

    var clippingRatio: Double {
        let decodedSamples = decodedFrames * AVAudioFramePosition(channelCount)
        guard decodedSamples > 0 else { return 0 }
        return Double(clippedSamples) / Double(decodedSamples)
    }

    var longestSilenceSeconds: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(longestSilentFrames) / sampleRate
    }

    var defectReason: String? {
        if let readError {
            return "stream read failed: \(readError)"
        }
        if isDurationTruncated {
            return String(format: "decoded duration is %.1f seconds short", shortfallSeconds)
        }
        return nil
    }

    var summary: String {
        if let defectReason {
            return defectReason
        }
        return String(
            format: "Clip %.3f%% · silence %.1fs",
            clippingRatio * 100,
            longestSilenceSeconds
        )
    }

    private var isDurationTruncated: Bool {
        guard declaredFrames > 0 else { return false }
        let toleranceFrames = max(
            AVAudioFramePosition(sampleRate.rounded()),
            AVAudioFramePosition((Double(declaredFrames) * 0.005).rounded())
        )
        return missingFrames > toleranceFrames
    }

    /// A full read error is always material. Frame-count shortfalls need to
    /// exceed both normal codec padding and one second of programme material.
    var isTechnicallyDefective: Bool {
        if readError != nil { return true }
        return isDurationTruncated
    }
}

nonisolated struct BitrateEstimate {
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
    let cutoffEvidence: CutoffEvidence
    let temporalCutoffEvidence: TemporalCutoffEvidence

    private var roundedCutoffKHz: Int {
        Int(cutoffHz / 1_000.0)
    }

    private var detailedCutoffKHz: String {
        String(format: "%.1f", cutoffHz / 1_000.0)
    }

    var cutoffRatio: Double {
        cutoffHz / nyquistHz
    }

    private var confidencePercent: Int {
        return Int((finalConfidence * 100).rounded())
    }

    var finalConfidence: Double {
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
            gradientCutoffKHz: cutoffEvidence.gradientHz / 1_000.0,
            energyCutoffKHz: cutoffEvidence.energyHz / 1_000.0,
            noiseFloorCutoffKHz: cutoffEvidence.noiseFloorHz / 1_000.0,
            cutoffSpreadKHz: cutoffEvidence.spreadHz / 1_000.0,
            cutoffMeanDeviationKHz: cutoffEvidence.meanDeviationHz / 1_000.0,
            cutoffAgreement: cutoffEvidence.agreement,
            temporalCutoffP10KHz: temporalCutoffEvidence.lowerPercentileHz / 1_000.0,
            temporalCutoffMedianKHz: temporalCutoffEvidence.medianHz / 1_000.0,
            temporalCutoffP90KHz: temporalCutoffEvidence.upperPercentileHz / 1_000.0,
            temporalCutoffSpreadKHz: temporalCutoffEvidence.percentileSpreadHz / 1_000.0,
            temporalShelfPersistence: temporalCutoffEvidence.shelfPersistence,
            cutoffRatio: cutoffRatio,
            dropScore: dropScore,
            stability: stability,
            suppressionScore: suppressionScore,
            sampleSupport: sampleSupport,
            evidenceConfidence: evidenceConfidence,
            classificationConfidence: classificationConfidence,
            modelConfidence: confidence,
            finalConfidence: finalConfidence
        )
    }

    var verdict: AnalysisVerdict {
        if !isLosslessContainer {
            let estimatedSource = confidence >= 0.30 && inferredBitrate != "unknown" ? inferredBitrate : nil
            return .lossyAsExpected(estimatedSource: estimatedSource)
        }
        if confidence < 0.30 {
            return .inconclusive(reason: nil)
        }
        if inferredBitrate == "lossless" {
            if cutoffRatio < 0.95 {
                return .inconclusive(reason: "Possibly lossless (borderline)")
            }
            return .likelyAuthentic
        }
        return .likelyTranscoded(estimatedSource: inferredBitrate)
    }

    var status: String {
        verdict.label
    }
}

nonisolated enum AnalysisVerdict: Equatable, Sendable {
    case likelyAuthentic
    case likelyTranscoded(estimatedSource: String)
    case lossyAsExpected(estimatedSource: String?)
    case technicallyDefective(reason: String)
    case inconclusive(reason: String?)

    var label: String {
        switch self {
        case .likelyAuthentic:
            return "Likely lossless"
        case .likelyTranscoded(let estimatedSource):
            return "Fake lossless — upconverted from ~\(estimatedSource)"
        case .lossyAsExpected(let estimatedSource):
            return estimatedSource.map { "Likely lossy (\($0))" } ?? "Likely lossy"
        case .technicallyDefective(let reason):
            return "Technically defective — \(reason)"
        case .inconclusive(let reason):
            return reason ?? "Inconclusive"
        }
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

nonisolated struct RunResult: Sendable {
    let success: Bool
    let actualBitrate: String
    let frequency: String
    let confidence: String
    let analysisStatus: String
    let reportedBitrate: String
    let bitrateMode: String
    let features: AnalysisFeatures?
    let cutoffHz: Double?
    let verdict: AnalysisVerdict?
    let technicalEvidence: StreamIntegrityEvidence?

    init(
        success: Bool,
        actualBitrate: String,
        frequency: String,
        confidence: String,
        analysisStatus: String,
        reportedBitrate: String,
        bitrateMode: String,
        features: AnalysisFeatures?,
        cutoffHz: Double?,
        verdict: AnalysisVerdict?,
        technicalEvidence: StreamIntegrityEvidence? = nil
    ) {
        self.success = success
        self.actualBitrate = actualBitrate
        self.frequency = frequency
        self.confidence = confidence
        self.analysisStatus = analysisStatus
        self.reportedBitrate = reportedBitrate
        self.bitrateMode = bitrateMode
        self.features = features
        self.cutoffHz = cutoffHz
        self.verdict = verdict
        self.technicalEvidence = technicalEvidence
    }
}

nonisolated struct AnalysisFeatures: Sendable {
    let cutoffKHz: Double
    let gradientCutoffKHz: Double
    let energyCutoffKHz: Double
    let noiseFloorCutoffKHz: Double
    let cutoffSpreadKHz: Double
    let cutoffMeanDeviationKHz: Double
    let cutoffAgreement: Double
    let temporalCutoffP10KHz: Double
    let temporalCutoffMedianKHz: Double
    let temporalCutoffP90KHz: Double
    let temporalCutoffSpreadKHz: Double
    let temporalShelfPersistence: Double
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
    var gradientCutoffKHzText: String { Self.format(gradientCutoffKHz) }
    var energyCutoffKHzText: String { Self.format(energyCutoffKHz) }
    var noiseFloorCutoffKHzText: String { Self.format(noiseFloorCutoffKHz) }
    var cutoffSpreadKHzText: String { Self.format(cutoffSpreadKHz) }
    var cutoffMeanDeviationKHzText: String { Self.format(cutoffMeanDeviationKHz) }
    var cutoffAgreementText: String { Self.format(cutoffAgreement) }
    var temporalCutoffP10KHzText: String { Self.format(temporalCutoffP10KHz) }
    var temporalCutoffMedianKHzText: String { Self.format(temporalCutoffMedianKHz) }
    var temporalCutoffP90KHzText: String { Self.format(temporalCutoffP90KHz) }
    var temporalCutoffSpreadKHzText: String { Self.format(temporalCutoffSpreadKHz) }
    var temporalShelfPersistenceText: String { Self.format(temporalShelfPersistence) }
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

nonisolated struct BatchAnalysisOutput: Sendable {
    let file: URL
    let result: RunResult
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
    let technicalEvidence: StreamIntegrityEvidence?
}

nonisolated enum TrainingLabelParser {
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

        _ = reportedBitrate
        return ("", "unlabelled", false)
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
    var id: String { fileURL.standardizedFileURL.path }
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
    var technicalSummary: String = "—"

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
        case .cancelled: return 2
        case .done: return 3
        case .failed: return 4
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
        if state == .pending || state == .running || state == .cancelled {
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
    case cancelled
    case done
    case failed

    var label: String {
        switch self {
        case .pending: return "Pending"
        case .running: return "Running"
        case .cancelled: return "Cancelled"
        case .done: return "Done"
        case .failed: return "Failed"
        }
    }

    var colour: Color {
        switch self {
        case .pending: return .secondary
        case .running: return .orange
        case .cancelled: return .secondary
        case .done: return .green
        case .failed: return .red
        }
    }

    var symbolName: String {
        switch self {
        case .pending: return "clock.badge.questionmark"
        case .running: return "hourglass.circle"
        case .cancelled: return "stop.circle"
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }
}
