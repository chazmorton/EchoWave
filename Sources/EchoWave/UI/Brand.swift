import SwiftUI

/// EchoWave's colors.
enum Brand {
    static let violet = Color(red: 0.55, green: 0.42, blue: 1.00)
    static let blue = Color(red: 0.26, green: 0.55, blue: 1.00)
    static let cyan = Color(red: 0.18, green: 0.86, blue: 0.96)
    static let recording = Color(red: 1.00, green: 0.27, blue: 0.29)
    static let success = Color(red: 0.20, green: 0.78, blue: 0.45)
    static let warning = Color(red: 1.00, green: 0.62, blue: 0.16)
    /// The floating button's dark glass.
    static let surface = Color(red: 0.07, green: 0.07, blue: 0.09)

    static let gradient = LinearGradient(colors: [violet, blue, cyan], startPoint: .bottomLeading, endPoint: .topTrailing)
    static let waveGradient = LinearGradient(colors: [violet, blue, cyan], startPoint: .leading, endPoint: .trailing)
}
