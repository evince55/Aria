import AVFoundation
import MediaToolbox

/// Runs an `AVPlayer`'s audio through an `AudioEQ` in real time via an
/// `MTAudioProcessingTap`. Build an `AVAudioMix` with `makeAudioMix(for:)` and
/// set it on the player item to apply EQ to the live stream — no download.
///
/// One instance per player item (the `AudioEQ`/AU is prepared with that item's
/// format). The owner (`AVPlayerPath`) must retain this while the item is
/// active — the tap's callbacks reference it via `clientInfo` without retaining.
final class AudioEQTap {
    private let eq = AudioEQ()
    private let frequencies: [Float]
    private let initialBands: [Float]

    /// Read on the audio render thread; written from the UI thread. A plain Bool
    /// is fine — a torn read just applies EQ one buffer early/late.
    fileprivate var bypassed: Bool

    /// Monotonic sample clock for `AudioUnitRender`, advanced per process call.
    fileprivate var renderSampleTime: Float64 = 0

    init(frequencies: [Float], bands: [Float], bypassed: Bool) {
        self.frequencies = frequencies
        self.initialBands = bands
        self.bypassed = bypassed
    }

    // MARK: - Control (UI thread)

    func setBand(_ index: Int, gain: Float) { eq.setBand(index, gain: gain) }
    func setBands(_ gains: [Float]) {
        for (i, g) in gains.enumerated() where i < AudioEQ.bandCount { eq.setBand(i, gain: g) }
    }
    func setBypass(_ b: Bool) {
        bypassed = b
        eq.setBypass(b)
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

    fileprivate func prepare(format: AudioStreamBasicDescription) {
        try? eq.prepare(format: format, frequencies: frequencies)
        setBands(initialBands)
        eq.setBypass(bypassed)
    }

    fileprivate func unprepareEQ() { eq.unprepare() }

    fileprivate func process(tap: MTAudioProcessingTap,
                             frames: CMItemCount,
                             bufferList: UnsafeMutablePointer<AudioBufferList>,
                             framesOut: UnsafeMutablePointer<CMItemCount>,
                             flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>) {
        // Pull source audio into the supplied buffer list.
        let status = MTAudioProcessingTapGetSourceAudio(
            tap, frames, bufferList, flagsOut, nil, framesOut)
        guard status == noErr else { return }
        if bypassed { return }  // passthrough — leave source audio as-is

        var ts = AudioTimeStamp()
        ts.mSampleTime = renderSampleTime
        ts.mFlags = .sampleTimeValid
        _ = eq.process(source: bufferList, output: bufferList,
                       frames: AVAudioFrameCount(framesOut.pointee), timeStamp: ts)
        renderSampleTime += Float64(framesOut.pointee)
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

private let tapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, format in
    context(tap).prepare(format: format.pointee)
}

private let tapUnprepare: MTAudioProcessingTapUnprepareCallback = { tap in
    context(tap).unprepareEQ()
}

private let tapProcess: MTAudioProcessingTapProcessCallback = { tap, frames, _, bufferListInOut, framesOut, flagsOut in
    context(tap).process(tap: tap, frames: frames,
                         bufferList: bufferListInOut,
                         framesOut: framesOut, flagsOut: flagsOut)
}
