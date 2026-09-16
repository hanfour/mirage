import Testing
import MirageCore

@Suite struct SpeechAudioConverterTests {
    @Test func emptyInputReturnsEmpty() {
        #expect(SpeechAudioConverter.monoAt16k([]).isEmpty)
    }

    @Test func orphanSampleCannotCompleteAFrameOrGroup() {
        #expect(SpeechAudioConverter.monoAt16k([99]).isEmpty)
        #expect(SpeechAudioConverter.monoAt16k([1, 0, 2, 0, 99]).isEmpty)
        #expect(SpeechAudioConverter.monoAt16k([1, 0, 2, 0, 3, 0, 99]) == [0.5])
    }

    @Test func sixFramesSelectFirstAndFourthAverages() {
        let input: [Float] = [1, 0, 10, 20, 30, 40, -1, 0.5, 50, 60, 70, 80]
        #expect(SpeechAudioConverter.monoAt16k(input) == [0.5, -0.25])
    }

    @Test func incompleteGroupsAreDiscardedWithoutCarryingBetweenCalls() {
        #expect(SpeechAudioConverter.monoAt16k([1, 0, 2, 0]).isEmpty)
        #expect(SpeechAudioConverter.monoAt16k([3, 0]).isEmpty)
        #expect(SpeechAudioConverter.monoAt16k([1, 0, 2, 0, 3, 0, 4, 0]) == [0.5])
        #expect(SpeechAudioConverter.monoAt16k([1, 0, 2, 0, 3, 0, 4, 0, 5, 0]) == [0.5])
        #expect(SpeechAudioConverter.monoAt16k(Array(repeating: 1, count: 1114)).count == 185)
    }

    @Test func oneKilohertzTonePreservesPeakAndLength() {
        // 固定的 48kHz 正弦波四分之一週期，避免用轉換實作產生期望值。
        let input: [Float] = [
            0, 0, 0.13052619, 0.13052619, 0.25881905, 0.25881905,
            0.38268343, 0.38268343, 0.5, 0.5, 0.60876143, 0.60876143,
            0.70710678, 0.70710678, 0.79335334, 0.79335334, 0.8660254, 0.8660254,
            0.92387953, 0.92387953, 0.96592583, 0.96592583, 0.99144486, 0.99144486,
            1, 1, 0.99144486, 0.99144486, 0.96592583, 0.96592583,
        ]
        let output = SpeechAudioConverter.monoAt16k(input)
        #expect(output == [0, 0.38268343, 0.70710678, 0.92387953, 1])
        #expect(output.count == 5)
        #expect(output.max() == 1)
    }
}
