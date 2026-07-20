import AVFoundation
import AudioToolbox
import os

/// DSP core for the streaming EQ: hosts Apple's N-Band EQ AudioUnit and renders
/// audio buffers through it. This is deliberately independent of
/// `MTAudioProcessingTap` so it can be unit-tested in isolation — feed a known
/// buffer to `process` and assert the result.
///
/// In production the `MTAudioProcessingTap` process callback stashes the source
/// audio (via `MTAudioProcessingTapGetSourceAudio`) and calls `process`, which
/// pulls that source through the AU. The AU's input render callback copies the
/// stashed source into the unit; the unit writes the EQ'd result to `output`.
///
/// Threading: `process` and the render callback run on the audio render thread,
/// while band/bypass changes and `prepare`/`unprepare` come from the UI thread.
/// Parameter-setting is safe to run concurrently with rendering, but *disposing*
/// the AudioUnit is not: `unprepare()` (reached off-main from the tap's teardown
/// callback) can free the unit while `process`/`setParam` hold a raw pointer to
/// it → use-after-free. All access to `au` is therefore serialised behind
/// `lock`; the critical sections are single AudioUnit calls, short enough for an
/// unfair lock on the render thread.
final class AudioEQ {
    static let bandCount = 10

    enum EQError: Error { case componentNotFound, osstatus(OSStatus) }

    private var au: AudioUnit?
    /// Guards the lifetime of `au` so a dispose can't race a set/render call.
    private let lock = OSAllocatedUnfairLock()

    /// Source buffers for the in-flight `process` call, read by the AU's input
    /// render callback. Only touched on the render thread.
    private var pendingSource: UnsafePointer<AudioBufferList>?

    // MARK: - Lifecycle

    /// Creates and initialises the N-Band EQ for `format`, configuring each band
    /// at `frequencies[i]` with flat (0 dB) gain.
    func prepare(format: AudioStreamBasicDescription, frequencies: [Float]) throws {
        precondition(frequencies.count == Self.bandCount)

        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_NBandEQ,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw EQError.componentNotFound }

        try lock.withLockUnchecked {
            var unit: AudioUnit?
            try check(AudioComponentInstanceNew(comp, &unit))
            guard let au = unit else { throw EQError.componentNotFound }
            self.au = au

            var bands = UInt32(Self.bandCount)
            try check(AudioUnitSetProperty(au, kAUNBandEQProperty_NumberOfBands,
                                           kAudioUnitScope_Global, 0,
                                           &bands, UInt32(MemoryLayout<UInt32>.size)))

            var fmt = format
            let fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
                                           kAudioUnitScope_Input, 0, &fmt, fmtSize))
            try check(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
                                           kAudioUnitScope_Output, 0, &fmt, fmtSize))

            // Render slices can be large; raise the cap or AudioUnitRender fails
            // with kAudioUnitErr_TooManyFramesToProcess. Must be set before init.
            var maxFrames = UInt32(8192)
            try check(AudioUnitSetProperty(au, kAudioUnitProperty_MaximumFramesPerSlice,
                                           kAudioUnitScope_Global, 0,
                                           &maxFrames, UInt32(MemoryLayout<UInt32>.size)))

            // Use the lock-free helper on the local `au` — the public setParam
            // would re-acquire this (non-recursive) lock and deadlock.
            for i in 0..<Self.bandCount {
                let band = AudioUnitParameterID(i)
                applyParam(au, kAUNBandEQParam_Frequency + band, frequencies[i])
                applyParam(au, kAUNBandEQParam_Gain + band, 0)
                applyParam(au, kAUNBandEQParam_BypassBand + band, 0)  // 0 = band active
            }

            var cb = AURenderCallbackStruct(
                inputProc: audioEQRenderInput,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try check(AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback,
                                           kAudioUnitScope_Input, 0,
                                           &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))

            try check(AudioUnitInitialize(au))
        }
    }

    func unprepare() {
        lock.withLockUnchecked {
            if let au = self.au {
                AudioUnitUninitialize(au)
                AudioComponentInstanceDispose(au)
            }
            self.au = nil
            pendingSource = nil
        }
    }

    deinit { unprepare() }

    // MARK: - Control (UI thread)

    /// Sets band `index`'s gain in dB. Safe to call while rendering.
    func setBand(_ index: Int, gain: Float) {
        guard index >= 0, index < Self.bandCount else { return }
        setParam(kAUNBandEQParam_Gain + AudioUnitParameterID(index), gain)
    }

    /// Bypasses the whole EQ (audio passes through unchanged) without detaching.
    func setBypass(_ bypass: Bool) {
        lock.withLockUnchecked {
            guard let au = self.au else { return }
            var v = UInt32(bypass ? 1 : 0)
            AudioUnitSetProperty(au, kAudioUnitProperty_BypassEffect,
                                 kAudioUnitScope_Global, 0,
                                 &v, UInt32(MemoryLayout<UInt32>.size))
        }
    }

    // MARK: - Parametric (Pro)

    /// Reconfigures the AUNBandEQ from a parametric preset: per-band filter
    /// type, centre frequency, bandwidth (converted from Q), and gain, plus the
    /// preset's global preamp gain. Bands beyond the preset are bypassed. One
    /// lock acquisition for the whole batch so the render thread never sees a
    /// half-applied curve.
    func applyParametric(_ preset: ParametricEQPreset) {
        lock.withLockUnchecked {
            guard let au = self.au else { return }
            let bands = Array(preset.bands.prefix(Self.bandCount))
            for i in 0..<Self.bandCount {
                let band = AudioUnitParameterID(i)
                if i < bands.count {
                    let b = bands[i]
                    applyParam(au, kAUNBandEQParam_FilterType + band, Float(Self.filterTypeValue(b.type)))
                    applyParam(au, kAUNBandEQParam_Frequency + band, b.frequency.clamped(to: 20...20_000))
                    applyParam(au, kAUNBandEQParam_Bandwidth + band, b.bandwidthOctaves.clamped(to: 0.05...5))
                    applyParam(au, kAUNBandEQParam_Gain + band, b.gain.clamped(to: -24...24))
                    applyParam(au, kAUNBandEQParam_BypassBand + band, 0)
                } else {
                    applyParam(au, kAUNBandEQParam_Gain + band, 0)
                    applyParam(au, kAUNBandEQParam_BypassBand + band, 1)
                }
            }
            applyParam(au, kAUNBandEQParam_GlobalGain, preset.preamp.clamped(to: -24...24))
        }
    }

    /// Restores the graphic-EQ configuration after parametric mode: bell
    /// filters at the fixed band frequencies, default bandwidth, no preamp.
    func applyGraphic(frequencies: [Float], gains: [Float]) {
        lock.withLockUnchecked {
            guard let au = self.au else { return }
            for i in 0..<Self.bandCount {
                let band = AudioUnitParameterID(i)
                applyParam(au, kAUNBandEQParam_FilterType + band, Float(Self.filterTypeValue(.peak)))
                if i < frequencies.count {
                    applyParam(au, kAUNBandEQParam_Frequency + band, frequencies[i])
                }
                applyParam(au, kAUNBandEQParam_Bandwidth + band, 0.5)
                applyParam(au, kAUNBandEQParam_Gain + band, i < gains.count ? gains[i] : 0)
                applyParam(au, kAUNBandEQParam_BypassBand + band, 0)
            }
            applyParam(au, kAUNBandEQParam_GlobalGain, 0)
        }
    }

    private static func filterTypeValue(_ type: ParametricFilterType) -> Int {
        switch type {
        case .peak: return kAUNBandEQFilterType_Parametric
        case .lowShelf: return kAUNBandEQFilterType_LowShelf
        case .highShelf: return kAUNBandEQFilterType_HighShelf
        }
    }

    // MARK: - Render (audio thread)

    /// Renders `frames` of audio from `source` through the EQ into `output`.
    func process(source: UnsafePointer<AudioBufferList>,
                 output: UnsafeMutablePointer<AudioBufferList>,
                 frames: AVAudioFrameCount,
                 timeStamp: AudioTimeStamp) -> OSStatus {
        // Held across AudioUnitRender so unprepare() can't dispose `au` mid-render.
        // AudioUnitRender invokes fillInput synchronously on this same thread and
        // fillInput takes no lock, so there's no re-entrancy/deadlock.
        lock.withLockUnchecked {
            guard let au = self.au else { return kAudioUnitErr_Uninitialized }
            pendingSource = source
            defer { pendingSource = nil }
            var flags = AudioUnitRenderActionFlags()
            var ts = timeStamp
            return AudioUnitRender(au, &flags, &ts, 0, frames, output)
        }
    }

    /// Called by the AU's input render callback to fill `ioData` with the source
    /// audio stashed for the current `process` call.
    fileprivate func fillInput(_ ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let source = pendingSource, let ioData else { return noErr }
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source))
        let dst = UnsafeMutableAudioBufferListPointer(ioData)
        for i in 0..<min(src.count, dst.count) {
            dst[i].mNumberChannels = src[i].mNumberChannels
            let bytes = min(dst[i].mDataByteSize, src[i].mDataByteSize)
            if let s = src[i].mData, let d = dst[i].mData {
                memcpy(d, s, Int(bytes))
            }
            dst[i].mDataByteSize = bytes
        }
        return noErr
    }

    // MARK: - Helpers

    /// Locked public path: read `au` and set a parameter under `lock`.
    private func setParam(_ id: AudioUnitParameterID, _ value: Float) {
        lock.withLockUnchecked {
            guard let au = self.au else { return }
            applyParam(au, id, value)
        }
    }

    /// Lock-free parameter set on a caller-supplied unit. The caller must already
    /// hold `lock` (or own `au` exclusively, as `prepare` does during setup).
    private func applyParam(_ au: AudioUnit, _ id: AudioUnitParameterID, _ value: Float) {
        AudioUnitSetParameter(au, id, kAudioUnitScope_Global, 0,
                              AudioUnitParameterValue(value), 0)
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw EQError.osstatus(status) }
    }
}

/// C render callback for the hosted AU's input bus — delegates to the `AudioEQ`
/// passed as `inRefCon`.
private func audioEQRenderInput(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let eq = Unmanaged<AudioEQ>.fromOpaque(inRefCon).takeUnretainedValue()
    return eq.fillInput(ioData)
}
