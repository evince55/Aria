import AVFoundation
import AudioToolbox
import os

/// Shifts pitch without changing duration, by hosting Apple's AUNewTimePitch at
/// rate 1. `AVPlayer` has no pitch control of its own, so this runs inside the
/// `MTAudioProcessingTap` alongside the EQ; independent of the tap so it can be
/// tested on known audio.
///
/// Unlike the EQ, this unit can't work on a caller-supplied slice: its internal
/// analysis window means it pulls however many source frames it wants, which
/// needn't match the frames being rendered. Source audio therefore comes from a
/// `SourceProvider` called during `render`, not from a buffer handed in.
///
/// Threading mirrors `AudioEQ`: `render` runs on the audio thread, the rest come
/// from elsewhere, and `lock` guards the unit's lifetime against a dispose.
final class AudioPitchShifter {
    /// Fills the buffer list with `frames` of source audio. Runs on the audio
    /// thread, so it must not allocate or block.
    typealias SourceProvider = (AVAudioFrameCount, UnsafeMutablePointer<AudioBufferList>) -> OSStatus

    enum ShifterError: Error { case componentNotFound, osstatus(OSStatus) }

    private var au: AudioUnit?
    private let lock = OSAllocatedUnfairLock()
    private var sourceProvider: SourceProvider?
    /// Monotonic clock for `AudioUnitRender`. Only touched inside `lock`.
    private var sampleTime: Float64 = 0

    deinit { unprepare() }

    /// Set once, before rendering starts. A stored closure, so the audio thread
    /// never has to allocate one per slice.
    func setSourceProvider(_ provider: @escaping SourceProvider) {
        lock.withLockUnchecked { sourceProvider = provider }
    }

    func prepare(format: AudioStreamBasicDescription, maximumFrames: AVAudioFrameCount) throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_FormatConverter,
            componentSubType: kAudioUnitSubType_NewTimePitch,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw ShifterError.componentNotFound }

        try lock.withLockUnchecked {
            var unit: AudioUnit?
            try check(AudioComponentInstanceNew(comp, &unit))
            guard let au = unit else { throw ShifterError.componentNotFound }
            self.au = au

            var fmt = format
            let fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
                                           kAudioUnitScope_Input, 0, &fmt, fmtSize))
            try check(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
                                           kAudioUnitScope_Output, 0, &fmt, fmtSize))

            var maxFrames = UInt32(maximumFrames)
            try check(AudioUnitSetProperty(au, kAudioUnitProperty_MaximumFramesPerSlice,
                                           kAudioUnitScope_Global, 0,
                                           &maxFrames, UInt32(MemoryLayout<UInt32>.size)))

            var cb = AURenderCallbackStruct(
                inputProc: audioPitchShifterRenderInput,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try check(AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback,
                                           kAudioUnitScope_Input, 0,
                                           &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))

            try check(AudioUnitInitialize(au))
            sampleTime = 0
        }
    }

    func unprepare() {
        lock.withLockUnchecked {
            if let au = self.au {
                AudioUnitUninitialize(au)
                AudioComponentInstanceDispose(au)
            }
            self.au = nil
        }
    }

    /// Sets the shift in semitones. Safe to call while rendering.
    func setPitch(semitones: Float) {
        lock.withLockUnchecked {
            guard let au = self.au else { return }
            AudioUnitSetParameter(au, kNewTimePitchParam_Pitch, kAudioUnitScope_Global, 0,
                                  AudioUnitParameterValue(semitones * 100), 0)
        }
    }

    /// Clears buffered audio, so re-engaging after a bypass doesn't replay what
    /// the unit was holding when it was last used.
    func reset() {
        lock.withLockUnchecked {
            guard let au = self.au else { return }
            AudioUnitReset(au, kAudioUnitScope_Global, 0)
        }
    }

    /// Renders `frames` of pitch-shifted audio into `output`.
    func render(into output: UnsafeMutablePointer<AudioBufferList>,
                frames: AVAudioFrameCount) -> OSStatus {
        lock.withLockUnchecked {
            guard let au = self.au else { return kAudioUnitErr_Uninitialized }
            var flags = AudioUnitRenderActionFlags()
            var ts = AudioTimeStamp()
            ts.mSampleTime = sampleTime
            ts.mFlags = .sampleTimeValid
            let status = AudioUnitRender(au, &flags, &ts, 0, frames, output)
            sampleTime += Float64(frames)
            return status
        }
    }

    fileprivate func fillInput(frames: UInt32,
                               _ ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let ioData, let sourceProvider else { return kAudioUnitErr_NoConnection }
        return sourceProvider(frames, ioData)
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw ShifterError.osstatus(status) }
    }
}

/// C render callback for the unit's input bus. Called synchronously from
/// `AudioUnitRender`, on the thread already holding `lock`; `fillInput` takes no
/// lock, so there's no re-entrancy.
private func audioPitchShifterRenderInput(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let shifter = Unmanaged<AudioPitchShifter>.fromOpaque(inRefCon).takeUnretainedValue()
    return shifter.fillInput(frames: inNumberFrames, ioData)
}
