import Accelerate

/// The preview's spectrum, worked out on the player's clock from the latest stretch of sound, only while a spectrum is
/// on screen. Levels are per FFT bin, in dB where a full-scale sine wave reads 0. Displays read them when the player
/// asks them to refresh, so nothing else in the window redraws along with them.
@MainActor final class SpectrumAnalyzer {
    private(set) var levels: [Float] = []
    /// Hz between neighbouring bins.
    private(set) var binWidth: Double = 0

    var fftSize = 4096 {
        didSet {
            guard fftSize != oldValue else { return }
            levels = []
        }
    }
    /// 0 follows every change, near 1 moves slowly.
    var smoothing: Float = 0.75

    static let silence: Float = -140

    private var setup: vDSP_DFT_Setup?
    private var setupSize = 0
    private var window: [Float] = []
    private var samples: [Float] = []
    private var real: [Float] = []
    private var imaginary: [Float] = []
    private var outReal: [Float] = []
    private var outImaginary: [Float] = []
    private var fresh: [Float] = []

    /// `elapsed` is the time since the last update, so smoothing looks the same at any refresh rate.
    func update(from tap: OutputTap, sampleRate: Double, elapsed: Double = 1.0 / 30) {
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

        binWidth = sampleRate / Double(size)
        guard levels.count == half else {
            levels = fresh
            return
        }
        // Rises come through faster than falls, as on a desk analyzer. Smoothing is set as per 1/30 s.
        let fall = 1 - pow(min(max(smoothing, 0), 0.99), Float(elapsed * 30))
        let rise = min(1, fall * 3)
        levels.withUnsafeMutableBufferPointer { levels in
            fresh.withUnsafeBufferPointer { fresh in
                for index in 0..<half {
                    let old = levels[index]
                    let new = fresh[index]
                    levels[index] = max(old + (new - old) * (new > old ? rise : fall), Self.silence)
                }
            }
        }
    }

    func clear() {
        levels = []
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
        levels = []
    }
}
