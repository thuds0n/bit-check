//
//  BitCheckTests.swift
//  BitCheckTests
//
//  Created by Timothy Hudson on 28/2/2026.
//

import AudioToolbox
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
}
