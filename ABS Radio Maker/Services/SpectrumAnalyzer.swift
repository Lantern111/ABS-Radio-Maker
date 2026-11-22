import Accelerate
import Observation

/// The preview's spectrum, worked out 30 times a second from the latest stretch of sound while anything shows it.
/// Levels are per FFT bin, in dB where a full-scale sine wave reads 0.
@MainActor @Observable final class SpectrumAnalyzer {
    private(set) var levels: [Float] = []
    /// Hz between neighbouring bins.
    private(set) var binWidth: Double = 0

    /// How many views show the spectrum. Nothing is worked out while none do.
    @ObservationIgnored var watchers = 0
    @ObservationIgnored var fftSize = 4096 {
        didSet {
            guard fftSize != oldValue else { return }
            levels = []
            smoothed = []
        }
    }
    /// 0 follows every change, near 1 moves slowly.
    @ObservationIgnored var smoothing: Float = 0.75

    static let silence: Float = -140

    @ObservationIgnored private var setup: vDSP_DFT_Setup?
    @ObservationIgnored private var setupSize = 0
    @ObservationIgnored private var window: [Float] = []
    @ObservationIgnored private var samples: [Float] = []
    @ObservationIgnored private var real: [Float] = []
    @ObservationIgnored private var imaginary: [Float] = []
    @ObservationIgnored private var outReal: [Float] = []
    @ObservationIgnored private var outImaginary: [Float] = []
    @ObservationIgnored private var fresh: [Float] = []
    @ObservationIgnored private var smoothed: [Float] = []

    func update(from tap: OutputTap, sampleRate: Double) {
        guard watchers > 0 else { return }
        prepare()
        let size = setupSize
        let half = size / 2
        guard let setup else { return }

        samples.withUnsafeMutableBufferPointer { samples in
            tap.latest(size, into: samples.baseAddress!)
            window.withUnsafeBufferPointer { window in
                vDSP_vmul(samples.baseAddress!, 1, window.baseAddress!, 1, samples.baseAddress!, 1, vDSP_Length(size))
            }
        }
        // The real FFT takes the even samples as real parts and the odd ones as imaginary parts.
        real.withUnsafeMutableBufferPointer { real in
            imaginary.withUnsafeMutableBufferPointer { imaginary in
                var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imaginary.baseAddress!)
                samples.withUnsafeBufferPointer { samples in
                    samples.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(half))
                    }
                }
                outReal.withUnsafeMutableBufferPointer { outReal in
                    outImaginary.withUnsafeMutableBufferPointer { outImaginary in
                        vDSP_DFT_Execute(setup, real.baseAddress!, imaginary.baseAddress!, outReal.baseAddress!, outImaginary.baseAddress!)
                        var result = DSPSplitComplex(realp: outReal.baseAddress!, imagp: outImaginary.baseAddress!)
                        fresh.withUnsafeMutableBufferPointer { fresh in
                            vDSP_zvmags(&result, 1, fresh.baseAddress!, 1, vDSP_Length(half))
                        }
                    }
                }
            }
        }
        // The packed transform comes out twice the size of the true one, and a Hann window halves a sine, so a
        // full-scale sine's bin is N/2 here: scaled by (2/N)² it reads 0 dB.
        var scale = Float(4.0 / Double(size * size))
        var tiny: Float = 1e-14
        var reference: Float = 1
        fresh.withUnsafeMutableBufferPointer { fresh in
            let values = fresh.baseAddress!
            vDSP_vsmsa(values, 1, &scale, &tiny, values, 1, vDSP_Length(half))
            vDSP_vdbcon(values, 1, &reference, values, 1, vDSP_Length(half), 0)
        }
        // The first bin holds the steady offset and the highest frequency together, neither of which is shown.
        fresh[0] = Self.silence

        if smoothed.count != half {
            smoothed = fresh
        } else {
            // Rises come through faster than falls, as on a desk analyzer.
            let fall = 1 - min(max(smoothing, 0), 0.99)
            let rise = min(1, fall * 3)
            for index in 0..<half {
                let old = smoothed[index]
                let new = fresh[index]
                smoothed[index] = max(old + (new - old) * (new > old ? rise : fall), Self.silence)
            }
        }
        binWidth = sampleRate / Double(size)
        levels = smoothed
    }

    func clear() {
        smoothed = []
        if !levels.isEmpty { levels = [] }
    }

    private func prepare() {
        guard setupSize != fftSize || setup == nil else { return }
        if let setup { vDSP_DFT_DestroySetup(setup) }
        let size = fftSize
        setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(size), .FORWARD)
        setupSize = size
        // A periodic Hann window.
        window = (0..<size).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(size)) }
        samples = [Float](repeating: 0, count: size)
        real = [Float](repeating: 0, count: size / 2)
        imaginary = real
        outReal = real
        outImaginary = real
        fresh = real
        smoothed = []
    }
}
