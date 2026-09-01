//
//  BitCheckTests.swift
//  BitCheckTests
//
//  Created by Timothy Hudson on 28/2/2026.
//

import AudioToolbox
import AVFoundation
import Foundation
import Testing
@testable import BitCheck

struct BitCheckTests {
    @Test func codecDetectionUsesStreamFormatBeforeContainerExtension() {
        #expect(
            CodecProfile.detect(formatID: kAudioFormatAppleLossless, fileExtension: "m4a") == .lossless
        )
        #expect(
            CodecProfile.detect(formatID: kAudioFormatMPEG4AAC, fileExtension: "m4a") == .aac
        )
        #expect(
            CodecProfile.detect(formatID: kAudioFormatOpus, fileExtension: "ogg") == .opus
        )
    }

    @Test func cutoffClassificationDoesNotScaleWithOutputSampleRate() {
        let standardRate = CodecProfile.mp3.classifyContinuous(cutoffHz: 16_000, sampleRate: 44_100)
        let highRate = CodecProfile.mp3.classifyContinuous(cutoffHz: 16_000, sampleRate: 96_000)

        #expect(standardRate.label == "128 kbps")
        #expect(highRate.label == standardRate.label)
        #expect(highRate.score == standardRate.score)
    }

    @Test func codecFamiliesUseIndependentBandwidthRanges() {
        #expect(CodecProfile.mp3.classifyContinuous(cutoffHz: 11_000, sampleRate: 44_100).label == "64 kbps")
        #expect(CodecProfile.aac.classifyContinuous(cutoffHz: 13_000, sampleRate: 44_100).label == "64 kbps")
        #expect(CodecProfile.opus.classifyContinuous(cutoffHz: 15_500, sampleRate: 48_000).label == "128 kbps")
    }

    @Test func validCutoffsUseTheNearestGranularTierAcrossReferenceGaps() {
        let formerGap = CodecProfile.mp3.classifyContinuous(cutoffHz: 16_600, sampleRate: 44_100)
        let invalid = CodecProfile.mp3.classifyContinuous(cutoffHz: .nan, sampleRate: 44_100)

        #expect(formerGap.label == "128 kbps")
        #expect(formerGap.score >= 0.30)
        #expect(invalid.label == "unknown")
        #expect(invalid.score == 0)
    }

    @Test func onlyIndependentFilenameLabelsAreTrainable() {
        let explicit = TrainingLabelParser.parse(fileName: "reference [REAL 128]", reportedBitrate: "320 kbps")
        let unlabelled = TrainingLabelParser.parse(fileName: "ordinary track", reportedBitrate: "320 kbps")
        let corrupted = TrainingLabelParser.parse(fileName: "track [CORRUPTED]", reportedBitrate: "128 kbps")

        #expect(explicit.label == "128 kbps")
        #expect(explicit.isTrainable)
        #expect(unlabelled.label.isEmpty)
        #expect(!unlabelled.isTrainable)
        #expect(!corrupted.isTrainable)
    }

    @Test func analysisWindowsStayWithinDistributedRegions() {
        let regions = [0..<20_000, 30_000..<50_000]
        let starts = NativeTrueBitrateAnalyzer.analysisWindowStarts(
            regionRanges: regions,
            fftLength: 1_000,
            hopLength: 500,
            maxWindows: 12
        )

        #expect(starts.count == 12)
        #expect(starts.contains(where: { $0 < 20_000 }))
        #expect(starts.contains(where: { $0 >= 30_000 }))
        #expect(starts.allSatisfy { start in
            regions.contains(where: { $0.contains(start) && $0.contains(start + 999) })
        })
    }

    @Test func cutoffFusionFindsAnIdealSixteenKilohertzShelf() {
        let sampleRate = 44_100.0
        let fftLength = 8_192
        let binCount = fftLength / 2
        let frequencyResolution = sampleRate / Double(fftLength)
        let cutoffBin = Int((16_000 / frequencyResolution).rounded())
        let power = (0..<binCount).map { $0 <= cutoffBin ? Float(1) : Float(1e-8) }
        let spectrumDb = power.map { 10 * log10f($0) }

        let evidence = NativeTrueBitrateAnalyzer.cutoffEvidence(
            powerSpectrum: power,
            spectrumDb: spectrumDb,
            frequencyResolution: frequencyResolution,
            nyquistHz: sampleRate / 2
        )

        #expect(abs(evidence.gradientHz - 16_000) < 800)
        #expect(abs(evidence.energyHz - 16_000) < 800)
        #expect(abs(evidence.noiseFloorHz - 16_000) < 800)
        #expect(abs(evidence.fusedHz - 16_000) < 400)
        #expect(evidence.agreement > 0.60)
    }

    @Test func temporalCutoffEvidenceRetainsDistributionAndPersistence() {
        let evidence = NativeTrueBitrateAnalyzer.temporalCutoffEvidence(
            segmentCutoffsHz: [
                15_900, 16_000, 16_000, 16_050, 16_100,
                16_100, 16_150, 16_200, 19_800, 20_000,
            ],
            referenceCutoffHz: 16_000
        )

        #expect(evidence.sampleCount == 10)
        #expect(evidence.lowerPercentileHz < evidence.medianHz)
        #expect(evidence.medianHz < evidence.upperPercentileHz)
        #expect(evidence.percentileSpreadHz > 3_000)
        #expect(evidence.shelfPersistence == 0.8)
    }

    @Test func analysisIncludesAudioPresentOnlyInSecondChannel() throws {
        let sampleRate = 44_100
        let sampleCount = sampleRate * 2
        let silentChannel = [Float](repeating: 0, count: sampleCount)
        var state: UInt64 = 0xC0FFEE
        let noiseChannel: [Float] = (0..<sampleCount).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let unit = Float((state >> 40) & 0xFFFFFF) / Float(0xFFFFFF)
            return unit * 2 - 1
        }
        let audio = AudioSamples(
            sampleRate: sampleRate,
            channels: [silentChannel, noiseChannel],
            regionRanges: [0..<sampleCount],
            reportedBitrate: "N/A",
            bitrateMode: "Unknown",
            codecProfile: .lossless
        )

        let estimate = try NativeTrueBitrateAnalyzer.estimateBitrate(from: audio)

        #expect(estimate.cutoffHz > 16_000)
        #expect(estimate.cutoffRatio > 0.70)
    }

    @Test func generatedPCMFixtureExposesContainerAndCodecSeparately() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "bit-check-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        do {
            let file = try AVAudioFile(forWriting: fileURL, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
            buffer.frameLength = 1_024
            try file.write(from: buffer)
        }

        let metadata = NativeTrueBitrateAnalyzer.inspect(file: fileURL)

        #expect(metadata.containerName == "WAV")
        #expect(metadata.codecName == "Lossless")
        #expect(metadata.displayFormat == "WAV · Lossless")
    }

    @Test func fullStreamReadCapturesClippingAndSilenceEvidence() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "bit-check-technical-quality-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try writeTechnicalQualitySource(to: fileURL)

        let evidence = NativeTrueBitrateAnalyzer.inspectStreamIntegrity(file: fileURL)
        #expect(evidence.readError == nil)
        #expect(evidence.missingFrames == 0)
        #expect(evidence.peakAmplitude >= 0.999)
        #expect(evidence.clippingRatio > 0.20)
        #expect(evidence.longestSilenceSeconds >= 1.9)
    }

    @Test func deepAnalysisRetainsTechnicalEvidenceWithoutOverclassifyingClipping() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "bit-check-deep-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try writeTechnicalQualitySource(to: fileURL)

        let result = NativeTrueBitrateAnalyzer.analyze(
            file: fileURL,
            includeTechnicalEvidence: true
        )
        let evidence = try #require(result.technicalEvidence)

        #expect(result.success)
        #expect(evidence.clippingRatio > 0.20)
        #expect(evidence.longestSilenceSeconds >= 1.9)
        if case .technicallyDefective = result.verdict {
            Issue.record("Raw clipping or silence evidence must not become a stream-defect verdict without calibration")
        }
    }

    @Test func nativeCodecCorpusSeparatesGenuineAndTranscodedLossless() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "bit-check-corpus-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appending(path: "broadband-source.wav")
        try writeBroadbandSource(to: source, durationSeconds: 6)

        let aac = directory.appending(path: "aac-128.m4a")
        let alac = directory.appending(path: "genuine-alac.m4a")
        let flac = directory.appending(path: "genuine-flac.flac")

        try convert(source, to: aac, fileFormat: "m4af", dataFormat: "aac", bitrate: 128_000)
        try convert(source, to: alac, fileFormat: "m4af", dataFormat: "alac")
        try convert(source, to: flac, fileFormat: "flac", dataFormat: "flac")

        for (fileURL, codecName) in [(aac, "AAC")] {
            let metadata = NativeTrueBitrateAnalyzer.inspect(file: fileURL)
            let result = NativeTrueBitrateAnalyzer.analyze(file: fileURL)
            #expect(metadata.codecName == codecName, "Unexpected codec for \(fileURL.lastPathComponent)")
            #expect(result.success, "Analysis failed for \(fileURL.lastPathComponent): \(result.analysisStatus)")
            let expected = AnalysisVerdict.lossyAsExpected(
                estimatedSource: result.actualBitrate == "unknown" ? nil : result.actualBitrate
            )
            #expect(
                result.verdict == expected,
                "Unexpected direct-lossy verdict for \(fileURL.lastPathComponent): \(describe(result))"
            )
        }

        for fileURL in [alac, flac] {
            let result = NativeTrueBitrateAnalyzer.analyze(file: fileURL)
            #expect(result.success, "Analysis failed for \(fileURL.lastPathComponent): \(result.analysisStatus)")
            #expect(
                result.verdict == .likelyAuthentic,
                "Unexpected genuine-lossless verdict for \(fileURL.lastPathComponent): \(describe(result))"
            )
        }

        let aacToALAC = directory.appending(path: "aac-128-to-alac.m4a")
        try convert(aac, to: aacToALAC, fileFormat: "m4af", dataFormat: "alac")

        for fileURL in [aacToALAC] {
            let result = NativeTrueBitrateAnalyzer.analyze(file: fileURL)
            #expect(result.success, "Analysis failed for \(fileURL.lastPathComponent): \(result.analysisStatus)")
            #expect(
                result.verdict == .likelyTranscoded(estimatedSource: result.actualBitrate),
                "Unexpected transcode verdict for \(fileURL.lastPathComponent): \(describe(result))"
            )
        }
    }

    @Test func externalEncoderCorpusCoversMP3AndOpusModesWhenAvailable() throws {
        guard let ffmpegURL = externalFFmpegURL() else { return }

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "bit-check-external-codecs-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appending(path: "broadband-source.wav")
        try writeBroadbandSource(to: source, durationSeconds: 6)

        let fixtures: [(name: String, codec: String, arguments: [String])] = [
            ("mp3-cbr-128.mp3", "MP3", ["-c:a", "libmp3lame", "-b:a", "128k"]),
            ("mp3-vbr-q2.mp3", "MP3", ["-c:a", "libmp3lame", "-q:a", "2"]),
            ("opus-vbr-96.ogg", "Opus", ["-c:a", "libopus", "-b:a", "96k", "-vbr", "on"]),
            ("opus-cbr-160.ogg", "Opus", ["-c:a", "libopus", "-b:a", "160k", "-vbr", "off"]),
        ]

        for fixture in fixtures {
            let fileURL = directory.appending(path: fixture.name)
            try convertWithFFmpeg(
                ffmpegURL: ffmpegURL,
                source: source,
                destination: fileURL,
                codecArguments: fixture.arguments
            )

            let metadata = NativeTrueBitrateAnalyzer.inspect(file: fileURL)
            let result = NativeTrueBitrateAnalyzer.analyze(file: fileURL)
            #expect(metadata.codecName == fixture.codec, "Unexpected codec for \(fixture.name)")
            #expect(result.success, "Analysis failed for \(fixture.name): \(result.analysisStatus)")
            #expect(result.features != nil, "No analysis features for \(fixture.name)")
            #expect(result.cutoffHz ?? 0 > 0, "No cutoff evidence for \(fixture.name)")
        }
    }

    @Test func explicitVerdictsCoverCurrentResultClasses() {
        #expect(
            estimate(inferredBitrate: "lossless", cutoffHz: 21_500, confidence: 0.8, isLossless: true).verdict
                == .likelyAuthentic
        )
        #expect(
            estimate(inferredBitrate: "128 kbps", cutoffHz: 16_000, confidence: 0.8, isLossless: true).verdict
                == .likelyTranscoded(estimatedSource: "128 kbps")
        )
        #expect(
            estimate(inferredBitrate: "128 kbps", cutoffHz: 16_000, confidence: 0.8, isLossless: false).verdict
                == .lossyAsExpected(estimatedSource: "128 kbps")
        )
        #expect(
            estimate(inferredBitrate: "unknown", cutoffHz: 18_000, confidence: 0.2, isLossless: false).verdict
                == .lossyAsExpected(estimatedSource: nil)
        )
        #expect(AnalysisVerdict.technicallyDefective(reason: "truncated stream").label.contains("truncated stream"))
    }

    @Test func ambiguityCapsRemainBounded() {
        let unknown = estimate(inferredBitrate: "unknown", cutoffHz: 18_000, confidence: 0.95, isLossless: false)
        let borderline = estimate(inferredBitrate: "lossless", cutoffHz: 20_000, confidence: 0.95, isLossless: true)
        let transcoded = estimate(inferredBitrate: "128 kbps", cutoffHz: 16_000, confidence: 0.95, isLossless: true)

        #expect(unknown.finalConfidence == 0.55)
        #expect(borderline.finalConfidence == 0.70)
        #expect(transcoded.finalConfidence == 0.85)
    }

    @MainActor
    @Test func resultIdentityIsStableForAFile() {
        let fileURL = URL(fileURLWithPath: "/tmp/bit-check-stable-id.wav")
        let first = result(for: fileURL)
        let second = result(for: fileURL)

        #expect(first.id == second.id)
        #expect(first.id == fileURL.standardizedFileURL.path)
    }

    @MainActor
    @Test func batchValidationRespectsItsConcurrencyLimit() async {
        let recorder = AnalysisConcurrencyRecorder(delay: 0.04)
        let viewModel = ValidationViewModel(maxConcurrentAnalyses: 2) { file, _ in
            recorder.analyse(file)
        }
        viewModel.queuedFiles = (0..<8).map {
            URL(fileURLWithPath: "/tmp/bit-check-batch-\($0).mp3")
        }

        await viewModel.validateQueuedFiles()

        #expect(viewModel.completedCount == 8)
        #expect(viewModel.totalCount == 8)
        #expect(recorder.maximumConcurrent == 2)
        #expect(viewModel.results.allSatisfy { result in
            if case .done = result.state { return true }
            return false
        })
    }

    @MainActor
    @Test func cancellingABatchStopsSchedulingAndMarksUnfinishedRows() async throws {
        let recorder = AnalysisConcurrencyRecorder(delay: 0.20, observesCancellation: true)
        let viewModel = ValidationViewModel(maxConcurrentAnalyses: 2) { file, _ in
            recorder.analyse(file)
        }
        viewModel.queuedFiles = (0..<12).map {
            URL(fileURLWithPath: "/tmp/bit-check-cancel-\($0).mp3")
        }

        viewModel.startValidation()
        try await Task.sleep(for: .milliseconds(40))
        viewModel.cancelValidation()

        while viewModel.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(viewModel.completedCount < viewModel.totalCount)
        #expect(recorder.startedCount <= 2)
        #expect(viewModel.results.contains { result in
            if case .cancelled = result.state { return true }
            return false
        })
        #expect(viewModel.statusMessage.contains("cancelled"))
    }

    /// Opt-in evaluator for an external, filename-labelled audio corpus.
    ///
    /// Set `BITCHECK_EVALUATION_CORPUS` to a directory and optionally
    /// `BITCHECK_EVALUATION_OUTPUT` to a CSV path. The corpus is only read;
    /// the report is written to the separate output path.
    @Test func externalFilenameLabelCorpusEvaluation() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let corpusPath = environment["BITCHECK_EVALUATION_CORPUS"], !corpusPath.isEmpty else {
            return
        }

        let corpusURL = URL(fileURLWithPath: corpusPath, isDirectory: true)
        let files = try externalCorpusFiles(in: corpusURL)
        let outputPath = environment["BITCHECK_EVALUATION_OUTPUT"]
            ?? FileManager.default.temporaryDirectory
                .appending(path: "bitcheck-external-corpus.csv")
                .path
        let outputURL = URL(fileURLWithPath: outputPath)

        var rows = [[
            "file_name",
            "reference_label",
            "reference_label_type",
            "is_scored",
            "reported_bitrate",
            "predicted_bitrate",
            "is_match",
            "analysis_succeeded",
            "analysis_status",
            "confidence_percent",
            "cutoff_khz",
            "gradient_cutoff_khz",
            "energy_cutoff_khz",
            "noise_floor_cutoff_khz",
            "cutoff_agreement",
            "temporal_cutoff_p10_khz",
            "temporal_cutoff_median_khz",
            "temporal_cutoff_p90_khz",
            "temporal_cutoff_spread_khz",
            "temporal_shelf_persistence",
            "evidence_confidence",
            "classification_confidence",
            "integrity_defective",
            "declared_frames",
            "decoded_frames",
            "shortfall_seconds",
            "shortfall_ratio",
            "integrity_read_error",
            "clipped_samples",
            "clipping_ratio",
            "peak_amplitude",
            "longest_silence_seconds",
        ]]

        for (index, fileURL) in files.enumerated() {
            let result = NativeTrueBitrateAnalyzer.analyze(file: fileURL)
            let integrity = NativeTrueBitrateAnalyzer.inspectStreamIntegrity(file: fileURL)
            let expectation = TrainingLabelParser.parse(
                fileName: fileURL.deletingPathExtension().lastPathComponent,
                reportedBitrate: result.reportedBitrate
            )
            let prediction = TrainingLabelParser.normalize(result.actualBitrate)
            let isMatch = expectation.isTrainable ? expectation.label == prediction : nil
            let features = result.features
            rows.append([
                fileURL.lastPathComponent,
                expectation.label,
                expectation.type,
                expectation.isTrainable ? "true" : "false",
                result.reportedBitrate,
                result.actualBitrate,
                isMatch.map { $0 ? "true" : "false" } ?? "",
                result.success ? "true" : "false",
                result.analysisStatus,
                result.confidence,
                features?.cutoffKHzText ?? "",
                features?.gradientCutoffKHzText ?? "",
                features?.energyCutoffKHzText ?? "",
                features?.noiseFloorCutoffKHzText ?? "",
                features?.cutoffAgreementText ?? "",
                features?.temporalCutoffP10KHzText ?? "",
                features?.temporalCutoffMedianKHzText ?? "",
                features?.temporalCutoffP90KHzText ?? "",
                features?.temporalCutoffSpreadKHzText ?? "",
                features?.temporalShelfPersistenceText ?? "",
                features?.evidenceConfidenceText ?? "",
                features?.classificationConfidenceText ?? "",
                integrity.isTechnicallyDefective ? "true" : "false",
                String(integrity.declaredFrames),
                String(integrity.decodedFrames),
                String(format: "%.6f", integrity.shortfallSeconds),
                String(format: "%.6f", integrity.shortfallRatio),
                integrity.readError ?? "",
                String(integrity.clippedSamples),
                String(format: "%.9f", integrity.clippingRatio),
                String(format: "%.6f", integrity.peakAmplitude),
                String(format: "%.6f", integrity.longestSilenceSeconds),
            ])
            print("Evaluated external corpus file \(index + 1) of \(files.count)")
        }

        let csv = rows
            .map { $0.map(Self.csvEscape).joined(separator: ",") }
            .joined(separator: "\n") + "\n"
        try csv.write(to: outputURL, atomically: true, encoding: .utf8)
        print("External corpus report: \(outputURL.path)")
    }

    @MainActor
    private func result(for fileURL: URL) -> ValidationResult {
        ValidationResult(
            fileURL: fileURL,
            actualBitrate: "—",
            frequency: "—",
            confidence: "—",
            analysisStatus: "Not run",
            state: .pending,
            reportedBitrate: "N/A",
            bitrateMode: "Unknown",
            fileType: "WAV · Lossless",
            cutoffHz: nil
        )
    }

    private func estimate(
        inferredBitrate: String,
        cutoffHz: Double,
        confidence: Double,
        isLossless: Bool
    ) -> BitrateEstimate {
        let evidence = CutoffEvidence(
            gradientHz: cutoffHz,
            energyHz: cutoffHz,
            noiseFloorHz: cutoffHz,
            fusedHz: cutoffHz,
            spreadHz: 0,
            meanDeviationHz: 0,
            agreement: 1
        )
        return BitrateEstimate(
            cutoffHz: cutoffHz,
            nyquistHz: 22_050,
            inferredBitrate: inferredBitrate,
            dropScore: 1,
            stability: 1,
            suppressionScore: 1,
            sampleSupport: 1,
            evidenceConfidence: confidence,
            classificationConfidence: confidence,
            confidence: confidence,
            isLosslessContainer: isLossless,
            cutoffEvidence: evidence,
            temporalCutoffEvidence: TemporalCutoffEvidence(
                sampleCount: 1,
                lowerPercentileHz: cutoffHz,
                medianHz: cutoffHz,
                upperPercentileHz: cutoffHz,
                percentileSpreadHz: 0,
                shelfPersistence: 1
            )
        )
    }

    private func externalCorpusFiles(in directory: URL) throws -> [URL] {
        let supportedExtensions: Set<String> = [
            "aac", "aif", "aiff", "alac", "flac", "m4a", "mp3", "ogg", "opus", "wav",
        ]
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            throw CorpusError.cannotEnumerate(directory.path)
        }

        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: Set(keys))
            if values.isRegularFile == true,
               supportedExtensions.contains(fileURL.pathExtension.lowercased()) {
                files.append(fileURL)
            }
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func csvEscape(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func writeBroadbandSource(to fileURL: URL, durationSeconds: Int) throws {
        let sampleRate = 48_000
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 2)
        )
        let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let channelData = try #require(buffer.floatChannelData)
        var state: UInt64 = 0xB17C_4EC5
        for frame in 0..<Int(frameCount) {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let unit = Float((state >> 40) & 0xFFFFFF) / Float(0xFFFFFF)
            let sample = (unit * 2 - 1) * 0.25
            channelData[0][frame] = sample
            channelData[1][frame] = -sample
        }
        let file = try AVAudioFile(forWriting: fileURL, settings: format.settings)
        try file.write(from: buffer)
    }

    private func writeTechnicalQualitySource(to fileURL: URL) throws {
        let sampleRate = 48_000
        let frameCount = AVAudioFrameCount(sampleRate * 4)
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 2)
        )
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let channelData = try #require(buffer.floatChannelData)

        for frame in 0..<Int(frameCount) {
            let sample: Float
            switch frame {
            case 0..<sampleRate:
                sample = frame.isMultiple(of: 2) ? 1 : -1
            case sampleRate..<(sampleRate * 3):
                sample = 0
            default:
                sample = 0.25
            }
            channelData[0][frame] = sample
            channelData[1][frame] = sample
        }

        let file = try AVAudioFile(forWriting: fileURL, settings: format.settings)
        try file.write(from: buffer)
    }

    private func convert(
        _ source: URL,
        to destination: URL,
        fileFormat: String,
        dataFormat: String,
        bitrate: Int? = nil
    ) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.standardError = errorPipe
        var arguments = [
            source.path,
            "-o", destination.path,
            "-f", fileFormat,
            "-d", dataFormat,
        ]
        if let bitrate {
            arguments.append(contentsOf: ["-b", String(bitrate), "-s", "0"])
        }
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(decoding: errorData, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw CorpusError.conversionFailed(
                source: source.lastPathComponent,
                destination: destination.lastPathComponent,
                message: errorText
            )
        }
    }

    private func externalFFmpegURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            environment["BITCHECK_FFMPEG"],
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
        ].compactMap { $0 }
        return candidates
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func convertWithFFmpeg(
        ffmpegURL: URL,
        source: URL,
        destination: URL,
        codecArguments: [String]
    ) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = ffmpegURL
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        process.arguments = [
            "-nostdin",
            "-hide_banner",
            "-loglevel", "error",
            "-y",
            "-i", source.path,
        ] + codecArguments + [destination.path]
        try process.run()
        process.waitUntilExit()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(decoding: errorData, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw CorpusError.externalConversionFailed(
                destination: destination.lastPathComponent,
                message: errorText
            )
        }
    }

    private func describe(_ result: RunResult) -> String {
        guard let features = result.features else {
            return "status=\(result.analysisStatus), no features"
        }
        return "status=\(result.analysisStatus), source=\(result.actualBitrate), confidence=\(result.confidence), "
            + "cutoff=\(features.cutoffKHzText) kHz, gradient=\(features.gradientCutoffKHzText), "
            + "energy=\(features.energyCutoffKHzText), noise=\(features.noiseFloorCutoffKHzText), "
            + "deviation=\(features.cutoffMeanDeviationKHzText), agreement=\(features.cutoffAgreementText), "
            + "drop=\(features.dropScoreText), "
            + "stability=\(features.stabilityText), suppression=\(features.suppressionScoreText), "
            + "evidence=\(features.evidenceConfidenceText), model=\(features.modelConfidenceText)"
    }

    private enum CorpusError: Error {
        case conversionFailed(source: String, destination: String, message: String)
        case externalConversionFailed(destination: String, message: String)
        case cannotEnumerate(String)
    }
}

private final class AnalysisConcurrencyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let delay: TimeInterval
    private let observesCancellation: Bool
    private var activeCount = 0
    private var recordedMaximum = 0
    private var recordedStartedCount = 0

    init(delay: TimeInterval, observesCancellation: Bool = false) {
        self.delay = delay
        self.observesCancellation = observesCancellation
    }

    var maximumConcurrent: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedMaximum
    }

    var startedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedStartedCount
    }

    func analyse(_ file: URL) -> RunResult {
        lock.lock()
        activeCount += 1
        recordedStartedCount += 1
        recordedMaximum = max(recordedMaximum, activeCount)
        lock.unlock()

        defer {
            lock.lock()
            activeCount -= 1
            lock.unlock()
        }

        let deadline = Date().addingTimeInterval(delay)
        while Date() < deadline {
            if observesCancellation, Task.isCancelled { break }
            Thread.sleep(forTimeInterval: 0.005)
        }

        return RunResult(
            success: true,
            actualBitrate: "128 kbps",
            frequency: "16 kHz (16.0 kHz)",
            confidence: "80%",
            analysisStatus: "Likely lossy (128 kbps)",
            reportedBitrate: "320 kbps",
            bitrateMode: "CBR",
            features: nil,
            cutoffHz: 16_000,
            verdict: .lossyAsExpected(estimatedSource: "128 kbps")
        )
    }
}
