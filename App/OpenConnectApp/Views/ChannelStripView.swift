import SwiftUI

// MARK: - Fader taper helpers
//
// Piecewise-linear taper with unity (0 dB) at 80 % of travel:
//   0.0…0.80 ↔ -60…0 dB  (coarse end)
//   0.80…1.0 ↔ 0…+12 dB  (fine boost above unity)
//
// This gives comfortable resolution around typical speech levels
// while still allowing up to +12 dB boost.

private let faderMin: Float = -60
private let faderMax: Float = 12
private let faderUnityNorm: Float = 0.80

private func faderNorm(_ db: Float) -> Float {
    let c = max(faderMin, min(faderMax, db))
    if c <= 0 {
        return (c - faderMin) / -faderMin * faderUnityNorm
    } else {
        return faderUnityNorm + c / faderMax * (1 - faderUnityNorm)
    }
}

private func normToFader(_ n: Float) -> Float {
    let c = max(0, min(1, n))
    if c <= faderUnityNorm {
        return c / faderUnityNorm * -faderMin + faderMin
    } else {
        return (c - faderUnityNorm) / (1 - faderUnityNorm) * faderMax
    }
}

// MARK: - VerticalFader

struct VerticalFader: View {
    let db: Float
    let onChange: (Float) -> Void

    private let thumbH: CGFloat = 24
    private let trackW: CGFloat = 4

    @State private var dragStartNorm: Float? = nil
    @State private var dragStartY: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let trackH = geo.size.height - thumbH
            let normVal = CGFloat(faderNorm(db))
            // thumb position from bottom: normVal * trackH
            let thumbY = geo.size.height - thumbH - normVal * trackH

            ZStack(alignment: .top) {
                // Track
                RoundedRectangle(cornerRadius: trackW / 2)
                    .fill(Theme.raised)
                    .frame(width: trackW)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, thumbH / 2)
                // Filled portion below thumb
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: trackW / 2)
                        .fill(Theme.accent.opacity(0.5))
                        .frame(width: trackW)
                        .frame(height: normVal * trackH)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, thumbH / 2)
                // Unity mark
                let unityY = geo.size.height - thumbH - CGFloat(faderUnityNorm) * trackH + thumbH / 2
                Rectangle()
                    .fill(Theme.textSecondary.opacity(0.4))
                    .frame(width: 14, height: 1)
                    .offset(y: unityY - 0.5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                // Thumb — double-click resets to unity (0 dB); drag adjusts level
                RoundedRectangle(cornerRadius: Theme.radiusSmall)
                    .fill(Theme.raised)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radiusSmall)
                            .strokeBorder(Theme.accent, lineWidth: 1.5)
                    )
                    .frame(width: 28, height: thumbH)
                    .offset(y: thumbY)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .onTapGesture(count: 2) {
                        onChange(0)
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if dragStartNorm == nil {
                                    dragStartNorm = faderNorm(db)
                                    dragStartY = value.startLocation.y
                                }
                                let delta = value.location.y - dragStartY
                                let deltaNorm = Float(-delta / trackH)
                                let newNorm = (dragStartNorm ?? faderNorm(db)) + deltaNorm
                                onChange(normToFader(newNorm))
                            }
                            .onEnded { _ in dragStartNorm = nil }
                    )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Fader")
        .accessibilityValue(Text(formatDB(db, decimals: 1)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(min(faderMax, db + 1))
            case .decrement: onChange(max(faderMin, db - 1))
            @unknown default: break
            }
        }
    }
}

// MARK: - MuteButton

private struct MuteButton: View {
    let muted: Bool         // user-set mute
    let effectivelyMuted: Bool  // includes solo-induced silence
    let action: () -> Void

    // Colour meaning:
    //   Active mute  → accent red
    //   Solo-silenced (not muted) → dim amber
    //   Normal        → raised (off)
    private var bgColor: Color {
        if muted { return Theme.accent }
        if effectivelyMuted { return Theme.soloDim }
        return Theme.raised
    }

    private var fgColor: Color {
        if muted || effectivelyMuted { return .white }
        return Theme.textSecondary
    }

    var body: some View {
        Button(action: action) {
            Text("M")
                .font(Theme.labelFont)
                .foregroundColor(fgColor)
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: Theme.radiusSmall).fill(bgColor))
        }
        .buttonStyle(.plain)
        .help(muted ? "Unmute" : "Mute")
        .accessibilityLabel(Text("Mute"))
        .accessibilityValue(Text(muted ? "On" : effectivelyMuted ? "Silenced by solo" : "Off"))
        .accessibilityAddTraits(muted ? .isSelected : [])
    }
}

// MARK: - SoloButton

private struct SoloButton: View {
    let soloed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("S")
                .font(Theme.labelFont)
                .foregroundColor(soloed ? .black : Theme.textSecondary)
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusSmall)
                        .fill(soloed ? Theme.solo : Theme.raised)
                )
        }
        .buttonStyle(.plain)
        .help(soloed ? "Un-solo" : "Solo")
        .accessibilityLabel(Text("Solo"))
        .accessibilityValue(Text(soloed ? "On" : "Off"))
        .accessibilityAddTraits(soloed ? .isSelected : [])
    }
}

// MARK: - ChannelStripView

struct ChannelStripView: View {
    let settings: ChannelSettings
    let connection: ChannelConnectionSource
    @ObservedObject var meterSource: ChannelMeterSource
    @ObservedObject var store: ParameterStore
    let isSelected: Bool
    let onSelect: () -> Void

    private var effectivelyMuted: Bool { store.isEffectivelyMuted(settings) }
    private var uid: String { settings.deviceUID }

    var body: some View {
        VStack(spacing: 6) {
            // Channel name
            Button(action: onSelect) {
                Text(settings.deviceName)
                    .font(Theme.titleFont)
                    .foregroundColor(isSelected ? Theme.accent : Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)

            // Mic icon
            ConnectionIcon(source: connection)

            // dB readout for fader
            ValueText(
                text: formatDB(settings.faderDB, decimals: 1),
                width: 64,
                colour: effectivelyMuted ? Theme.textDisabled : Theme.textPrimary,
                alignment: .center)

            // Fader + meter side by side
            HStack(spacing: 4) {
                VerticalFader(db: settings.faderDB) { v in
                    store.update(uid) { $0.faderDB = v }
                }
                .frame(width: 28)
                .opacity(effectivelyMuted ? 0.4 : 1)

                StripLevelMeter(source: meterSource, muted: effectivelyMuted)
            }
            .frame(maxHeight: .infinity)

            // Mute / Solo
            HStack(spacing: 4) {
                MuteButton(
                    muted: settings.muted,
                    effectivelyMuted: effectivelyMuted
                ) {
                    store.update(uid) { $0.muted.toggle() }
                }
                SoloButton(soloed: settings.soloed) {
                    store.update(uid) { $0.soloed.toggle() }
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusMedium)
                .fill(Theme.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusMedium)
                        .strokeBorder(
                            isSelected ? Theme.accent : Theme.border,
                            lineWidth: isSelected ? 1.5 : 1
                        )
                )
        )
        .frame(width: 80)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}
