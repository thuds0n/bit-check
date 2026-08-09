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
        let fileURL = URL(fileURLWithPath: "/tmp/bit-check-\(UUID().uuidString).wav")
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
            cutoffEvidence: evidence
        )
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
    }
}
