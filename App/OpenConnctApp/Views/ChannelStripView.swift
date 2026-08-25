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
    /// Muted by the app on first sighting rather than by the user.
    let automatic: Bool
    let action: () -> Void

    // Colour meaning:
    //   Active mute  → accent red
    //   Silenced but not by this button → dim amber
    //   Normal        → raised (off)
    //
    // A device muted on arrival takes the amber rather than the red, which is
    // the same distinction the strip already draws for a channel silenced by
    // somebody else's solo: the channel is quiet, and the user did not do it.
    // Reusing that colour rather than inventing a third means there is one thing
    // to learn instead of two.
    private var bgColor: Color {
        if muted { return automatic ? Theme.soloDim : Theme.accent }
        if effectivelyMuted { return Theme.soloDim }
        return Theme.raised
    }

    private var fgColor: Color {
        if muted || effectivelyMuted { return .white }
        return Theme.textSecondary
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Theme.buttonIconFont)
                .foregroundColor(fgColor)
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: Theme.radiusSmall).fill(bgColor))
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(Text("Mute"))
        .accessibilityValue(Text(accessibilityValue))
        .accessibilityAddTraits(muted ? .isSelected : [])
    }

    /// The picture states the outcome, so the button is legible without the
    /// colour: a struck-through speaker when this channel is not heard, a
    /// sounding one when it is. Colour then adds the second question — *who*
    /// silenced it — which a shape cannot express.
    ///
    /// It is a speaker rather than a microphone on purpose. This same strip
    /// already uses `mic.fill`/`mic.slash.fill` a few points higher to mean
    /// connected/disconnected, and one picture meaning two different things in
    /// one window is worse than the letter it replaced. The speaker also states
    /// the truth more precisely: mute does not switch the microphone off, it
    /// takes the channel out of what everyone hears.
    private var symbol: String {
        muted || effectivelyMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
    }

    /// Says why, not just what. "Unmute" on a channel the user never muted
    /// answers the wrong question. With the letter gone the tooltip is also
    /// where the word "mute" itself now lives, so it spells out the effect
    /// rather than naming the feature.
    private var helpText: String {
        if automatic {
            return "New device — muted on arrival so it could not join the mix "
                + "unheard. Click to unmute."
        }
        if muted { return "Muted — click to let this microphone be heard again." }
        if effectivelyMuted {
            return "Already silent because another microphone is soloed. "
                + "Click to mute this one as well."
        }
        return "Mute — silence this microphone. The others keep playing."
    }

    private var accessibilityValue: String {
        if automatic { return "On, muted automatically because this device is new" }
        if muted { return "On" }
        return effectivelyMuted ? "Silenced by solo" : "Off"
    }
}

// MARK: - SoloButton

private struct SoloButton: View {
    let soloed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "headphones")
                .font(Theme.buttonIconFont)
                .foregroundColor(soloed ? .black : Theme.textSecondary)
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusSmall)
                        .fill(soloed ? Theme.solo : Theme.raised)
                )
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(Text("Solo"))
        .accessibilityValue(Text(soloed ? "On" : "Off"))
        .accessibilityAddTraits(soloed ? .isSelected : [])
    }

    /// Unlike mute, the glyph does not change with the state, and that is not an
    /// oversight. Mute has two states that both need naming — heard, not heard —
    /// whereas solo has a mode and a normal, and a lit button is the ordinary way
    /// to show a mode is on. More to the point, switching solo on visibly changes
    /// *every other strip* in the mixer: they all take the dimmed silenced
    /// treatment and their speakers strike through. The state is announced across
    /// the whole window, so this one button does not have to carry it alone.
    private var helpText: String {
        soloed
            ? "Solo is on — click to hear the other microphones again."
            : "Solo — hear only this microphone and silence all the others."
    }
}

// MARK: - MicTileButton

/// The microphone tile at the top of a strip, and the way into that mic's
/// settings.
///
/// It reads as a button because it is drawn as one — a filled tile that lights
/// up under the pointer — which the old bare 14pt glyph did not. The whole
/// strip still selects on click; this just gives the gesture an obvious target
/// instead of leaving it undiscoverable.
private struct MicTileButton: View {
    @ObservedObject var connection: ChannelConnectionSource
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        let connected = connection.connected
        Button(action: action) {
            Image(systemName: connected ? "mic.fill" : "mic.slash.fill")
                .font(.system(size: 20))
                .foregroundColor(connected ? Theme.textPrimary : Theme.textDisabled)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusMedium)
                        .fill(isSelected ? Theme.accentDim : Theme.raised)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusMedium)
                        .strokeBorder(
                            isSelected ? Theme.accent
                                : hovering ? Theme.textSecondary : Color.clear,
                            lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open this microphone's settings")
        .accessibilityLabel(Text("Open settings"))
    }
}

// MARK: - RemoveChannelButton

/// The small × in the strip's top corner.
///
/// Only visible while the pointer is over the strip. It removes a microphone
/// from the mixer, which is a rare and mildly destructive action, and a row of
/// permanent × buttons would draw the eye to exactly the control the user wants
/// least often. Nothing is lost by using it: the mic's settings stay on disk
/// under its UID and come back with it.
private struct RemoveChannelButton: View {
    let visible: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(Theme.textPrimary)
                .frame(width: 15, height: 15)
                // Sits on the corner of the mic tile, so it needs its own
                // ground to stay legible against it.
                .background(Circle().fill(Theme.bg))
                .overlay(Circle().strokeBorder(Theme.border, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .help("Remove this microphone from the mixer")
        .accessibilityLabel(Text("Remove microphone"))
        .accessibilityHidden(!visible)
    }
}

// MARK: - ChannelStripView

struct ChannelStripView: View {
    let settings: ChannelSettings
    /// The name as shortened for this row — see `ChannelLabels.shorten`. Not
    /// derived here, because it depends on what the neighbouring strips say.
    let label: String
    let connection: ChannelConnectionSource
    @ObservedObject var meterSource: ChannelMeterSource
    @ObservedObject var store: ParameterStore
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var hovering = false

    private var effectivelyMuted: Bool { store.isEffectivelyMuted(settings) }
    private var uid: String { settings.deviceUID }

    var body: some View {
        VStack(spacing: 6) {
            // Name gets the strip's full width back: the remove button is an
            // overlay on the tile below, not a sibling here. Sharing the row
            // with it cost 18 of 64 points and turned every name into an
            // ellipsis.
            //
            // 64 points is about nine characters and device names run to twenty,
            // so three things buy the difference, none of which widens the strip:
            //
            // `label` has already had the words it shares with other strips
            // removed — a manufacturer repeated on every strip spends five of the
            // nine characters and distinguishes nothing.
            //
            // Two lines cost 16 points of height and roughly double what fits.
            // 32 rather than 28, because two lines of a 12 pt semibold face need
            // just over 30 and SwiftUI silently falls back to one line rather
            // than overflow a frame it was given. Height is the axis with room
            // to spare here; width is the one that does not.
            //
            // What is left truncates from the *head*, because the tail is where
            // the model is. `.middle` kept the first characters, and the first
            // characters are the least informative part of a device name.
            //
            // The full name is a hover away, and the detail sheet shows it in
            // full, so nothing is actually hidden.
            Text(label)
                .font(Theme.titleFont)
                .foregroundColor(isSelected ? Theme.accent : Theme.textPrimary)
                .lineLimit(2)
                .truncationMode(.head)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .help(settings.deviceName)
                // Shortening is a concession to 64 points of width. A screen
                // reader has no such limit, so it gets the whole name.
                .accessibilityLabel(settings.deviceName)

            ZStack(alignment: .topTrailing) {
                MicTileButton(
                    connection: connection,
                    isSelected: isSelected,
                    action: onSelect)
                    .frame(maxWidth: .infinity)

                RemoveChannelButton(visible: hovering) {
                    store.setDevice(uid, enabled: false)
                }
            }

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
                    effectivelyMuted: effectivelyMuted,
                    automatic: settings.arrivedMuted
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
        .onHover { hovering = $0 }
    }
}

// MARK: - AddChannelTile

/// The "+" slot at the end of the strip row.
///
/// The device picker was previously reachable only from a small text button in
/// the status bar, which is a poor place for the one action a new user needs
/// first. An empty slot sitting where the next microphone would go says what it
/// does without a label.
struct AddChannelTile: View {
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .light))
                    .foregroundColor(hovering ? Theme.textPrimary : Theme.textDisabled)
                Text("Mic")
                    .font(Theme.captionFont)
                    .foregroundColor(Theme.textDisabled)
            }
            .frame(width: 56)
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusMedium)
                    .fill(hovering ? Theme.panel : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radiusMedium)
                            .strokeBorder(
                                Theme.border,
                                style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Add more microphones, or switch some off")
        .accessibilityLabel(Text("Add microphone"))
    }
}

