import AVFoundation
import MediaToolbox

/// Runs an `AVPlayer`'s audio through an `AudioPitchShifter` and an `AudioEQ` in
/// real time via an `MTAudioProcessingTap`. Build an `AVAudioMix` with
/// `makeAudioMix(for:)` and set it on the player item to process the live stream
/// — no download. Either stage is skipped entirely while it isn't in use, so
/// audio passes through untouched when neither is.
///
/// One instance per player item (the units are prepared with that item's
/// format). The owner (`AVPlayerPath`) must retain this while the item is
/// active — the tap's callbacks reference it via `clientInfo` without retaining.
final class AudioEQTap {
    private let eq = AudioEQ()
    private let pitchShifter = AudioPitchShifter()
    private let frequencies: [Float]
    private let initialBands: [Float]
    private let initialParametric: ParametricEQPreset?

    /// Read on the audio render thread; written from the UI thread. A plain Bool
    /// is fine — a torn read just applies EQ one buffer early/late.
    fileprivate var bypassed: Bool

    /// Pitch offset in semitones; 0 skips the shifter. Same threading as `bypassed`.
    fileprivate var pitchSemitones: Float

    /// Monotonic sample clock for `AudioUnitRender`, advanced per process call.
    fileprivate var renderSampleTime: Float64 = 0

    /// The tap currently in `process`, and the flags its source pulls reported.
    /// Valid only during a shifter render; unretained because the tap already
    /// retains this object, and holding it back would be a cycle.
    private var activeTap: Unmanaged<MTAudioProcessingTap>?
    private var pulledFlags: MTAudioProcessingTapFlags = 0
    /// Per buffer, from the format `prepare` was given.
    private var sourceBytesPerFrame = 0

    init(frequencies: [Float], bands: [Float], bypassed: Bool,
         parametric: ParametricEQPreset? = nil, pitchSemitones: Float = 0) {
        self.pitchSemitones = pitchSemitones
        self.frequencies = frequencies
        self.initialBands = bands
        self.bypassed = bypassed
        self.initialParametric = parametric
    }

    // MARK: - Control (UI thread)

    func setBand(_ index: Int, gain: Float) { eq.setBand(index, gain: gain) }
    func setBands(_ gains: [Float]) {
        for (i, g) in gains.enumerated() where i < AudioEQ.bandCount { eq.setBand(i, gain: g) }
    }
    /// Switches the live tap to a parametric curve (AutoEQ profile).
    func setParametric(_ preset: ParametricEQPreset) { eq.applyParametric(preset) }
    /// Restores the graphic configuration (fixed band frequencies + gains).
    func setGraphic(gains: [Float]) { eq.applyGraphic(frequencies: frequencies, gains: gains) }
    func setBypass(_ b: Bool) {
        bypassed = b
        eq.setBypass(b)
    }

    func setPitch(semitones: Float) {
        // Re-engaging: drop what the unit held when it was last in use, or that
        // old audio plays back first.
        if pitchSemitones == 0, semitones != 0 { pitchShifter.reset() }
        pitchShifter.setPitch(semitones: semitones)
        pitchSemitones = semitones
    }

    // MARK: - Mix

    /// Builds an `AVAudioMix` that routes `track`'s audio through this tap.
    func makeAudioMix(for track: AVAssetTrack) -> AVAudioMix? {
        // RETAIN self into the tap: the tap's callbacks (process/unprepare/
        // finalize) run on the audio thread and can fire while/after the owner
        // (AVPlayerPath) has dropped its `eqTap` reference — e.g. on skip, when
        // the old item and its tap are torn down. With passUnretained that was a
        // use-after-free (crash / debugger hang). `finalize` releases the +1.
        let clientInfo = Unmanaged.passRetained(self).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: clientInfo,
            init: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: tapUnprepare,
            process: tapProcess)

        var tapRef: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks,
            kMTAudioProcessingTapCreationFlag_PreEffects, &tapRef)
        guard status == noErr, let tap = tapRef else {
            Unmanaged<AudioEQTap>.fromOpaque(clientInfo).release()  // no tap → no finalize
            return nil
        }

        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap  // mix retains the tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }

    // MARK: - Callback hooks (audio thread)

    fileprivate func prepare(format: AudioStreamBasicDescription, maximumFrames: CMItemCount) {
        try? eq.prepare(format: format, frequencies: frequencies,
                        maximumFrames: AVAudioFrameCount(clamping: maximumFrames))
        sourceBytesPerFrame = Int(format.mBytesPerFrame)
        try? pitchShifter.prepare(format: format,
                                  maximumFrames: max(AVAudioFrameCount(clamping: maximumFrames),
                                                     AudioEQ.minimumFramesPerSlice))
        pitchShifter.setPitch(semitones: pitchSemitones)
        pitchShifter.setSourceProvider { [unowned self] frames, buffers in
            self.pullSource(frames: frames, into: buffers)
        }
        if let preset = initialParametric {
            eq.applyParametric(preset)
        } else {
            setBands(initialBands)
        }
        eq.setBypass(bypassed)
    }

    fileprivate func unprepareEQ() {
        eq.unprepare()
        pitchShifter.unprepare()
    }

    fileprivate func process(tap: MTAudioProcessingTap,
                             frames: CMItemCount,
                             bufferList: UnsafeMutablePointer<AudioBufferList>,
                             framesOut: UnsafeMutablePointer<CMItemCount>,
                             flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>) {
        // Pull source audio into the supplied buffer list, through the shifter
        // if it's in use.
        if pitchSemitones != 0 {
            renderShifted(tap: tap, frames: frames, bufferList: bufferList,
                          framesOut: framesOut, flagsOut: flagsOut)
        } else {
            let status = MTAudioProcessingTapGetSourceAudio(
                tap, frames, bufferList, flagsOut, nil, framesOut)
            guard status == noErr else { return }
        }
        if bypassed { return }  // passthrough — leave the audio as-is

        var ts = AudioTimeStamp()
        ts.mSampleTime = renderSampleTime
        ts.mFlags = .sampleTimeValid
        _ = eq.process(source: bufferList, output: bufferList,
                       frames: AVAudioFrameCount(framesOut.pointee), timeStamp: ts)
        renderSampleTime += Float64(framesOut.pointee)
    }

    private func renderShifted(tap: MTAudioProcessingTap,
                               frames: CMItemCount,
                               bufferList: UnsafeMutablePointer<AudioBufferList>,
                               framesOut: UnsafeMutablePointer<CMItemCount>,
                               flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>) {
        activeTap = Unmanaged.passUnretained(tap)
        pulledFlags = 0
        let status = pitchShifter.render(into: bufferList, frames: AVAudioFrameCount(clamping: frames))
        activeTap = nil
        if status != noErr {
            // Silence beats whatever the failed render left in the buffer.
            for buffer in UnsafeMutableAudioBufferListPointer(bufferList) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
        }
        framesOut.pointee = frames
        flagsOut.pointee = pulledFlags
    }

    /// Called by the shifter, during `renderShifted`, whenever it wants source.
    /// It asks for what its window needs, not what `process` was asked for.
    private func pullSource(frames: AVAudioFrameCount,
                            into buffers: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        guard let tap = activeTap?.takeUnretainedValue() else { return kAudioUnitErr_NoConnection }
        var flags: MTAudioProcessingTapFlags = 0
        var got: CMItemCount = 0
        let status = MTAudioProcessingTapGetSourceAudio(
            tap, CMItemCount(frames), buffers, &flags, nil, &got)
        pulledFlags |= flags
        // At the end of a track the source runs short; the unit still needs a
        // full slice, so pad it with silence.
        if status == noErr, got < CMItemCount(frames) {
            let list = UnsafeMutableAudioBufferListPointer(buffers)
            let used = Int(got) * sourceBytesPerFrame
            let total = Int(frames) * sourceBytesPerFrame
            for i in 0..<list.count {
                guard let data = list[i].mData else { continue }
                memset(data + used, 0, total - used)
                list[i].mDataByteSize = UInt32(total)
            }
        }
        return status
    }
}

// MARK: - C tap callbacks

private func context(_ tap: MTAudioProcessingTap) -> AudioEQTap {
    Unmanaged<AudioEQTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
}

private let tapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, tapStorageOut in
    // Stash clientInfo as the tap storage so the other callbacks can recover it.
    tapStorageOut.pointee = clientInfo
}

private let tapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    // Balance the passRetained(self) from makeAudioMix — the tap is done with
    // its context now, so the AudioEQTap (and its AudioUnit) can deallocate.
    Unmanaged<AudioEQTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private let tapPrepare: MTAudioProcessingTapPrepareCallback = { tap, maxFrames, format in
    // `maxFrames` is the largest slice `process` will be handed (issue #73).
    context(tap).prepare(format: format.pointee, maximumFrames: maxFrames)
}

private let tapUnprepare: MTAudioProcessingTapUnprepareCallback = { tap in
    context(tap).unprepareEQ()
}

private let tapProcess: MTAudioProcessingTapProcessCallback = { tap, frames, _, bufferListInOut, framesOut, flagsOut in
    context(tap).process(tap: tap, frames: frames,
                         bufferList: bufferListInOut,
                         framesOut: framesOut, flagsOut: flagsOut)
}
