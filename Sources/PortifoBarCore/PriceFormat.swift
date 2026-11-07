import Foundation

// Prices to the decimals Yahoo quotes them to, and moves with an explicit
// sign: a true minus (−), which lines up with the plus in a monospaced-digit
// font where a hyphen wouldn't.
public enum PriceFormat {
    public static func price(_ value: Double, decimals: Int, locale: Locale = .current) -> String {
        number(value, decimals: decimals, locale: locale)
    }

    public static func change(_ value: Double, decimals: Int, locale: Locale = .current) -> String {
        signed(value, decimals: decimals, locale: locale)
    }

    public static func percent(_ value: Double, decimals: Int = 2, locale: Locale = .current) -> String {
        signed(value, decimals: decimals, locale: locale) + "%"
    }

    private static func signed(_ value: Double, decimals: Int, locale: Locale) -> String {
        let places = clamp(decimals)
        let magnitude = number(abs(value), decimals: places, locale: locale)
        // A move that rounds to nothing carries no sign.
        if (abs(value) * pow(10, Double(places))).rounded() == 0 { return magnitude }
        return (value > 0 ? "+" : "\u{2212}") + magnitude
    }

    private static func number(_ value: Double, decimals: Int, locale: Locale) -> String {
        value.formatted(.number.precision(.fractionLength(clamp(decimals))).locale(locale))
    }

    private static func clamp(_ decimals: Int) -> Int {
        min(max(decimals, 0), 8)
    }
}
