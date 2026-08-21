/*
 OpenConnectDSP realtime core test shim. This Swift target is not used from audio render callbacks.
 Helpers may allocate Swift arrays for deterministic tests and analysis only.
*/
import Foundation
import OpenConnectDSP

public enum SignalGenerator {
    public static func sine(frequency: Float, sampleRate: Float = 48_000, count: Int, amplitude: Float = 1, phase: Float = 0) -> [Float] {
        (0..<count).map { amplitude * sin(2 * .pi * frequency * Float($0) / sampleRate + phase) }
    }

    public static func whiteNoise(count: Int, amplitude: Float = 1, seed: UInt64 = 0x1234_5678) -> [Float] {
        var s = seed
        return (0..<count).map { _ in
            s = 6364136223846793005 &* s &+ 1442695040888963407
            let u = Float((s >> 40) & 0x00ff_ffff) / Float(0x00ff_ffff)
            return (u * 2 - 1) * amplitude
        }
    }

    public static func impulse(count: Int, amplitude: Float = 1) -> [Float] {
        var x = Array(repeating: Float(0), count: count)
        if !x.isEmpty { x[0] = amplitude }
        return x
    }

    public static func silence(count: Int) -> [Float] { Array(repeating: 0, count: count) }
    public static func step(count: Int, amplitude: Float = 1) -> [Float] { Array(repeating: amplitude, count: count) }

    public static func sineBurst(frequency: Float, sampleRate: Float = 48_000, count: Int, start: Int, length: Int, amplitude: Float = 1) -> [Float] {
        var x = Array(repeating: Float(0), count: count)
        guard start < count else { return x }
        for i in start..<min(count, start + length) {
            x[i] = amplitude * sin(2 * .pi * frequency * Float(i - start) / sampleRate)
        }
        return x
    }
}

public enum Analysis {
    public static func rms(_ x: [Float], dropFirst: Int = 0) -> Float {
        guard dropFirst < x.count else { return 0 }
        let s = x.dropFirst(dropFirst).reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(s / Float(x.count - dropFirst))
    }

    public static func peak(_ x: [Float]) -> Float { x.map { abs($0) }.max() ?? 0 }
    public static func db(_ linear: Float) -> Float { 20 * log10(max(abs(linear), 1.0e-20)) }
    public static func linear(_ db: Float) -> Float { pow(10, db / 20) }

    public static func binMagnitude(_ x: [Float], frequency: Float, sampleRate: Float) -> Float {
        var re = Float(0), im = Float(0)
        for (n, v) in x.enumerated() {
            let a = 2 * Float.pi * frequency * Float(n) / sampleRate
            re += v * cos(a)
            im -= v * sin(a)
        }
        return 2 * sqrt(re * re + im * im) / Float(max(x.count, 1))
    }

    public static func thd(_ x: [Float], fundamental: Float, sampleRate: Float, harmonics: Int = 5) -> Float {
        let f = max(binMagnitude(x, frequency: fundamental, sampleRate: sampleRate), 1.0e-12)
        var sum = Float(0)
        if harmonics >= 2 {
            for h in 2...harmonics where fundamental * Float(h) < sampleRate * 0.5 {
                let m = binMagnitude(x, frequency: fundamental * Float(h), sampleRate: sampleRate)
                sum += m * m
            }
        }
        return sqrt(sum) / f
    }

    public static func envelope(_ x: [Float], attackMs: Float, releaseMs: Float, sampleRate: Float) -> [Float] {
        let ac = exp(-1 / (attackMs * 0.001 * sampleRate))
        let rc = exp(-1 / (releaseMs * 0.001 * sampleRate))
        var e = Float(0)
        return x.map { sample in
            let a = abs(sample)
            e = a + (a > e ? ac : rc) * (e - a)
            return e
        }
    }

    public static func magnitudeResponse(frequency: Float, sampleRate: Float = 48_000, seconds: Float = 1, amplitude: Float = 0.25, process: (inout [Float]) -> Void) -> Float {
        var x = SignalGenerator.sine(frequency: frequency, sampleRate: sampleRate, count: Int(sampleRate * seconds), amplitude: amplitude)
        process(&x)
        return rms(x, dropFirst: x.count / 2) / max(amplitude / sqrt(2), 1.0e-12)
    }
}
