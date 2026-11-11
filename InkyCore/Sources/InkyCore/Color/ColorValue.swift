import Foundation

/// A color, as a screen shows it.
///
/// It is kept in sRGB, the colors of the web. A color written in one of the
/// wider notations may lie outside of what sRGB can show; its parts are then
/// below 0 or above 1, and nothing is lost by turning it back.
public struct ColorValue: Sendable, Equatable {
    /// The ways a color is written.
    public enum Notation: String, Sendable, CaseIterable {
        case hex, rgb, hsl, hwb, lab, lch, oklab, oklch
    }

    public var red: Double
    public var green: Double
    public var blue: Double
    /// From 0, which is see-through, to 1.
    public var alpha: Double
    /// How it was written.
    public var notation: Notation

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1, notation: Notation = .rgb) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
        self.notation = notation
    }

    /// Whether a screen that shows sRGB shows it as it is.
    public var isInGamut: Bool {
        [red, green, blue].allSatisfy { $0 >= -Self.tolerance && $0 <= 1 + Self.tolerance }
    }

    /// The nearest color sRGB can show: the same lightness and hue, with as
    /// much of its strength as fits. Cutting the parts off at 0 and 1 instead
    /// would change the hue.
    public var displayed: ColorValue {
        guard !isInGamut else { return clipped }
        let (lightness, chroma, hue) = oklch
        if lightness >= 1 { return ColorValue(red: 1, green: 1, blue: 1, alpha: alpha, notation: notation) }
        if lightness <= 0 { return ColorValue(red: 0, green: 0, blue: 0, alpha: alpha, notation: notation) }
        var fits = 0.0
        var tooStrong = chroma
        for _ in 0..<24 {
            let middle = (fits + tooStrong) / 2
            if ColorValue(oklch: (lightness, middle, hue)).isInGamut {
                fits = middle
            } else {
                tooStrong = middle
            }
        }
        var color = ColorValue(oklch: (lightness, fits, hue)).clipped
        color.alpha = alpha
        color.notation = notation
        return color
    }

    private var clipped: ColorValue {
        ColorValue(
            red: min(1, max(0, red)), green: min(1, max(0, green)), blue: min(1, max(0, blue)),
            alpha: alpha, notation: notation
        )
    }

    private static let tolerance = 1e-5
}

// MARK: - The other ways to say it

extension ColorValue {
    /// Hue in degrees, saturation and lightness from 0 to 1.
    var hsl: (hue: Double, saturation: Double, lightness: Double) {
        let color = displayed
        let most = max(color.red, color.green, color.blue)
        let least = min(color.red, color.green, color.blue)
        let lightness = (most + least) / 2
        let spread = most - least
        // A gray has no hue. A part that differs by less than shows is
        // what is left of reckoning, not a hue.
        guard spread > 1e-9 else { return (0, 0, lightness) }
        let saturation = spread / (1 - abs(2 * lightness - 1))
        var hue: Double
        if most == color.red {
            hue = (color.green - color.blue) / spread
        } else if most == color.green {
            hue = (color.blue - color.red) / spread + 2
        } else {
            hue = (color.red - color.green) / spread + 4
        }
        hue = (hue * 60).truncatingRemainder(dividingBy: 360)
        return (hue < 0 ? hue + 360 : hue, saturation, lightness)
    }

    init(hsl: (hue: Double, saturation: Double, lightness: Double)) {
        let saturation = min(1, max(0, hsl.saturation))
        let lightness = min(1, max(0, hsl.lightness))
        let hue = Self.turn(hsl.hue)
        func part(_ n: Double) -> Double {
            let k = (n + hue / 30).truncatingRemainder(dividingBy: 12)
            let a = saturation * min(lightness, 1 - lightness)
            return lightness - a * max(-1, min(k - 3, 9 - k, 1))
        }
        self.init(red: part(0), green: part(8), blue: part(4))
    }

    /// Hue in degrees, how much white and how much black from 0 to 1.
    var hwb: (hue: Double, whiteness: Double, blackness: Double) {
        let color = displayed
        return (hsl.hue, min(color.red, color.green, color.blue), 1 - max(color.red, color.green, color.blue))
    }

    init(hwb: (hue: Double, whiteness: Double, blackness: Double)) {
        let whiteness = min(1, max(0, hwb.whiteness))
        let blackness = min(1, max(0, hwb.blackness))
        // More white and black than there is room for makes a gray.
        guard whiteness + blackness < 1 else {
            let gray = whiteness / (whiteness + blackness)
            self.init(red: gray, green: gray, blue: gray)
            return
        }
        let pure = ColorValue(hsl: (hwb.hue, 1, 0.5))
        func part(_ value: Double) -> Double {
            value * (1 - whiteness - blackness) + whiteness
        }
        self.init(red: part(pure.red), green: part(pure.green), blue: part(pure.blue))
    }

    /// Lightness from 0 to 100, and where it lies between green and red and
    /// between blue and yellow.
    var lab: (lightness: Double, a: Double, b: Double) {
        let xyz = Matrix.d65ToD50 * xyz
        let f = zip(xyz, Self.d50).map { value, white -> Double in
            let ratio = value / white
            return ratio > Self.epsilon ? cbrt(ratio) : (Self.kappa * ratio + 16) / 116
        }
        return (116 * f[1] - 16, 500 * (f[0] - f[1]), 200 * (f[1] - f[2]))
    }

    init(lab: (lightness: Double, a: Double, b: Double)) {
        let f1 = (lab.lightness + 16) / 116
        let f0 = lab.a / 500 + f1
        let f2 = f1 - lab.b / 200
        let ratios = [
            pow(f0, 3) > Self.epsilon ? pow(f0, 3) : (116 * f0 - 16) / Self.kappa,
            lab.lightness > Self.kappa * Self.epsilon ? pow(f1, 3) : lab.lightness / Self.kappa,
            pow(f2, 3) > Self.epsilon ? pow(f2, 3) : (116 * f2 - 16) / Self.kappa,
        ]
        self.init(xyz: Matrix.d50ToD65 * zip(ratios, Self.d50).map { $0 * $1 })
    }

    /// Lightness from 0 to 100, strength, and hue in degrees.
    var lch: (lightness: Double, chroma: Double, hue: Double) {
        let lab = lab
        return Self.polar(lab.lightness, lab.a, lab.b, least: 1e-3)
    }

    init(lch: (lightness: Double, chroma: Double, hue: Double)) {
        let hue = lch.hue * .pi / 180
        self.init(lab: (lch.lightness, lch.chroma * cos(hue), lch.chroma * sin(hue)))
    }

    /// Lightness from 0 to 1, and where it lies between green and red and
    /// between blue and yellow.
    var oklab: (lightness: Double, a: Double, b: Double) {
        let lms = (Matrix.xyzToLMS * xyz).map { cbrt($0) }
        let lab = Matrix.lmsToOklab * lms
        return (lab[0], lab[1], lab[2])
    }

    init(oklab: (lightness: Double, a: Double, b: Double)) {
        let lms = (Matrix.oklabToLMS * [oklab.lightness, oklab.a, oklab.b]).map { $0 * $0 * $0 }
        self.init(xyz: Matrix.lmsToXYZ * lms)
    }

    /// Lightness from 0 to 1, strength, and hue in degrees.
    var oklch: (lightness: Double, chroma: Double, hue: Double) {
        let lab = oklab
        return Self.polar(lab.lightness, lab.a, lab.b, least: 1e-5)
    }

    init(oklch: (lightness: Double, chroma: Double, hue: Double)) {
        let hue = oklch.hue * .pi / 180
        self.init(oklab: (oklch.lightness, oklch.chroma * cos(hue), oklch.chroma * sin(hue)))
    }

    // MARK: - Light itself

    /// How much light of each kind it is, with the white of daylight (D65).
    private var xyz: [Double] {
        Matrix.rgbToXYZ * [red, green, blue].map(Self.linear)
    }

    private init(xyz: [Double]) {
        let parts = (Matrix.xyzToRGB * xyz).map(Self.encoded)
        self.init(red: parts[0], green: parts[1], blue: parts[2])
    }

    /// sRGB counts in steps that look even. Light is reckoned with in steps
    /// that are even.
    private static func linear(_ value: Double) -> Double {
        let size = abs(value)
        let linear = size <= 0.04045 ? size / 12.92 : pow((size + 0.055) / 1.055, 2.4)
        return value < 0 ? -linear : linear
    }

    private static func encoded(_ value: Double) -> Double {
        let size = abs(value)
        let encoded = size <= 0.0031308 ? size * 12.92 : 1.055 * pow(size, 1 / 2.4) - 0.055
        return value < 0 ? -encoded : encoded
    }

    /// A gray has no hue, and reckoning leaves it a little strength that
    /// points anywhere: below `least` it is none.
    private static func polar(_ lightness: Double, _ a: Double, _ b: Double, least: Double) -> (Double, Double, Double) {
        let chroma = (a * a + b * b).squareRoot()
        guard chroma > least else { return (lightness, 0, 0) }
        return (lightness, chroma, turn(atan2(b, a) * 180 / .pi))
    }

    /// An angle within one turn.
    private static func turn(_ degrees: Double) -> Double {
        let rest = degrees.truncatingRemainder(dividingBy: 360)
        return rest < 0 ? rest + 360 : rest
    }

    private static let epsilon = 216.0 / 24389
    private static let kappa = 24389.0 / 27
    /// The whites of daylight and of print, from where they lie in the
    /// diagram of all colors.
    fileprivate static let d65 = white(x: 0.3127, y: 0.3290)
    fileprivate static let d50 = white(x: 0.3457, y: 0.3585)

    private static func white(x: Double, y: Double) -> [Double] {
        [x / y, 1, (1 - x - y) / y]
    }
}

/// Three by three, which is all that turning one kind of color into another
/// takes.
private struct Matrix {
    var rows: [[Double]]

    init(_ rows: [[Double]]) {
        self.rows = rows
    }

    static func * (matrix: Matrix, vector: [Double]) -> [Double] {
        matrix.rows.map { row in zip(row, vector).reduce(0) { $0 + $1.0 * $1.1 } }
    }

    static func * (left: Matrix, right: Matrix) -> Matrix {
        Matrix((0..<3).map { row in
            (0..<3).map { column in
                (0..<3).reduce(0) { $0 + left.rows[row][$1] * right.rows[$1][column] }
            }
        })
    }

    /// The matrix that undoes this one.
    var inverse: Matrix {
        let m = rows
        func cofactor(_ row: Int, _ column: Int) -> Double {
            let r = [(row + 1) % 3, (row + 2) % 3]
            let c = [(column + 1) % 3, (column + 2) % 3]
            return m[r[0]][c[0]] * m[r[1]][c[1]] - m[r[0]][c[1]] * m[r[1]][c[0]]
        }
        let determinant = (0..<3).reduce(0) { $0 + m[0][$1] * cofactor(0, $1) }
        return Matrix((0..<3).map { row in
            (0..<3).map { column in cofactor(column, row) / determinant }
        })
    }

    /// sRGB without its curve, to light.
    static let rgbToXYZ = Matrix([
        [506_752.0 / 1_228_815, 87881.0 / 245_763, 12673.0 / 70218],
        [87098.0 / 409_605, 175_762.0 / 245_763, 12673.0 / 175_545],
        [7918.0 / 409_605, 87881.0 / 737_289, 1_001_167.0 / 1_053_270],
    ])
    static let xyzToRGB = rgbToXYZ.inverse

    /// From the white of daylight to the white of print, which Lab is
    /// measured against, the way Bradford worked out that the eye adapts.
    static let d65ToD50: Matrix = {
        let cones = Matrix([
            [0.8951, 0.2664, -0.1614],
            [-0.7502, 1.7135, 0.0367],
            [0.0389, -0.0685, 1.0296],
        ])
        let from = cones * ColorValue.d65
        let to = cones * ColorValue.d50
        let scale = Matrix((0..<3).map { row in
            (0..<3).map { column in row == column ? to[row] / from[row] : 0 }
        })
        return cones.inverse * scale * cones
    }()
    static let d50ToD65 = d65ToD50.inverse

    /// To what the three kinds of cones in the eye take in, and from the
    /// cube roots of that to Oklab.
    static let xyzToLMS = Matrix([
        [0.8190224379967030, 0.3619062600528904, -0.1288737815209879],
        [0.0329836539323885, 0.9292868615863434, 0.0361446663506424],
        [0.0481771893596242, 0.2642395317527308, 0.6335478284694309],
    ])
    static let lmsToXYZ = xyzToLMS.inverse
    static let lmsToOklab = Matrix([
        [0.2104542683093140, 0.7936177747023054, -0.0040720430116193],
        [1.9779985324311684, -2.4285922420485799, 0.4505937096174110],
        [0.0259040424655478, 0.7827717124575296, -0.8086757549230774],
    ])
    static let oklabToLMS = lmsToOklab.inverse
}
