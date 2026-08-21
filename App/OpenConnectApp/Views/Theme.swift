import SwiftUI

// MARK: - Colour palette

enum Theme {
    // Backgrounds
    static let bg         = Color(red: 0.09, green: 0.09, blue: 0.10)
    static let panel      = Color(red: 0.14, green: 0.14, blue: 0.16)
    static let raised     = Color(red: 0.18, green: 0.18, blue: 0.20)
    static let border     = Color(white: 1, opacity: 0.08)

    // Text
    static let textPrimary   = Color.white
    static let textSecondary = Color(white: 0.55)
    static let textDisabled  = Color(white: 0.30)

    // Accent (RØDE warm-red)
    static let accent        = Color(red: 0.88, green: 0.24, blue: 0.20)
    static let accentDim     = Color(red: 0.45, green: 0.12, blue: 0.10)

    // Solo colour
    static let solo          = Color(red: 0.95, green: 0.72, blue: 0.10)
    static let soloDim       = Color(red: 0.45, green: 0.34, blue: 0.05)

    // Meter segments
    static let meterGreen    = Color(red: 0.18, green: 0.80, blue: 0.35)
    static let meterAmber    = Color(red: 0.95, green: 0.72, blue: 0.10)
    static let meterRed      = Color(red: 0.95, green: 0.25, blue: 0.20)
    static let meterTrack    = Color(white: 0.12)

    // Corner radii
    static let radiusSmall:  CGFloat = 4
    static let radiusMedium: CGFloat = 8
    static let radiusLarge:  CGFloat = 12

    // Fonts
    static let labelFont  = Font.system(size: 11, weight: .medium, design: .default)
    static let valueFont  = Font.system(size: 11, weight: .semibold, design: .monospaced)
    static let captionFont = Font.system(size: 10, weight: .regular)
    static let titleFont  = Font.system(size: 12, weight: .semibold)
}

// MARK: - dB formatting

func formatDB(_ v: Float, decimals: Int = 1) -> String {
    String(format: "%+.\(decimals)f dB", v)
}

func formatMS(_ v: Float) -> String {
    String(format: "%.0f ms", v)
}

func formatRatio(_ v: Float) -> String {
    String(format: "%.1f:1", v)
}

func formatHz(_ v: Float) -> String {
    if v >= 1000 {
        return String(format: "%.1f kHz", v / 1000)
    }
    return String(format: "%.0f Hz", v)
}

// MARK: - Binding helper

/// Construct a Binding that reads from a value and writes through ParameterStore.update.
/// SwiftUI always calls Binding setters from the main thread, so assumeIsolated is correct here.
func bind<T>(
    _ value: T,
    uid: String,
    store: ParameterStore,
    keyPath: WritableKeyPath<ChannelSettings, T>
) -> Binding<T> {
    Binding(
        get: { value },
        set: { v in
            MainActor.assumeIsolated { store.update(uid) { $0[keyPath: keyPath] = v } }
        }
    )
}

// MARK: - Toggle pill style

struct PillToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
                .font(Theme.labelFont)
                .foregroundColor(configuration.isOn ? .black : Theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusSmall)
                        .fill(configuration.isOn ? Theme.accent : Theme.raised)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Labelled row

struct LabelledRow<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack {
            Text(label)
                .font(Theme.labelFont)
                .foregroundColor(Theme.textSecondary)
                .frame(width: 80, alignment: .leading)
            content
        }
    }
}

// MARK: - Parameter slider row

struct ParamSliderRow: View {
    let label: String
    let value: Binding<Float>
    let range: ClosedRange<Float>
    let format: (Float) -> String
    let enabled: Bool

    init(
        _ label: String,
        value: Binding<Float>,
        range: ClosedRange<Float>,
        format: @escaping (Float) -> String = { String(format: "%.1f", $0) },
        enabled: Bool = true
    ) {
        self.label = label
        self.value = value
        self.range = range
        self.format = format
        self.enabled = enabled
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(Theme.labelFont)
                .foregroundColor(enabled ? Theme.textSecondary : Theme.textDisabled)
                .frame(width: 72, alignment: .leading)
            Slider(value: value, in: range)
                .disabled(!enabled)
                .tint(enabled ? Theme.accent : Theme.textDisabled)
                .accessibilityLabel(Text(label))
                .accessibilityValue(Text(format(value.wrappedValue)))
            Text(format(value.wrappedValue))
                .font(Theme.valueFont)
                .foregroundColor(enabled ? Theme.textPrimary : Theme.textDisabled)
                .frame(width: 72, alignment: .trailing)
                .monospacedDigit()
        }
        .opacity(enabled ? 1 : 0.5)
    }
}

// MARK: - Section card

struct CardSection<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusMedium)
                    .fill(Theme.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radiusMedium)
                            .strokeBorder(Theme.border, lineWidth: 1)
                    )
            )
    }
}
