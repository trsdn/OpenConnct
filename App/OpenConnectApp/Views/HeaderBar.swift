import SwiftUI

// MARK: - HeaderBar
//
// The full-width bar across the top of the window.
//
// It exists because the summed output level is the one reading that is true for
// the whole application rather than for one microphone, and it was previously
// living in the mixer column as a vertical bar beside the strips. That was the
// wrong home twice over: it competed with the strips for width in the one place
// where width is scarce, and it implied — by sitting among them — that it was
// another channel.
//
// Up here it spans the window, it cannot be scrolled away, and it costs the
// strips nothing. The horizontal shape also has room for the dB figure, the
// scale and the plain-language verdict side by side, which the 52pt column did
// not.
//
// The bar carries the three things that belong to the app as a whole: is it
// working, what is going out, and the two ways in.

struct HeaderBar: View {
    @ObservedObject var store: ParameterStore
    @ObservedObject var diagnosticsSource: DiagnosticsSource
    @ObservedObject var masterSource: ChannelMeterSource

    @State private var showDetails = false
    @State private var showDevices = false

    private var diagnostics: EngineDiagnostics { diagnosticsSource.value }

    var body: some View {
        HStack(spacing: 16) {
            statusView
            MasterMeterBar(source: masterSource)
            actions
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
        .background(Theme.panel)
        .sheet(isPresented: $showDevices) {
            DeviceSelectionView(store: store)
        }
    }

    // MARK: Status
    //
    // Two audiences, two levels. Day to day the user only needs to know whether
    // the thing is working, so this shows one plain-language status and nothing
    // else. The counters behind it (dropouts, drift in ppm) are engineering
    // telemetry: useful when diagnosing a fault, meaningless otherwise, and
    // actively harmful in the default view because they change several times a
    // second and shift the layout around them.

    private enum Status {
        case ready, noDriver, stopped, glitching

        var text: String {
            switch self {
            case .ready:     return "Bereit"
            case .noDriver:  return "Kein Gerät"
            case .stopped:   return "Gestoppt"
            case .glitching: return "Aussetzer"
            }
        }

        var colour: Color {
            switch self {
            case .ready: return Theme.meterGreen
            case .noDriver, .glitching: return Theme.meterAmber
            case .stopped: return Theme.meterRed
            }
        }
    }

    private var status: Status {
        if !diagnostics.running { return .stopped }
        if !diagnostics.sinkAvailable { return .noDriver }
        // Recent, not ever. Binding and priming the microphones costs a handful
        // of dropouts on every launch; testing the lifetime total lights this
        // warning at startup and never clears it.
        if diagnostics.hasRecentDropout { return .glitching }
        return .ready
    }

    private var statusView: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(status.colour)
                .frame(width: 7, height: 7)
            Text(status.text)
                .font(Theme.labelFont)
                .foregroundColor(status == .ready ? Theme.textSecondary : status.colour)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 6) {
            headerButton(
                systemImage: "mic.badge.plus",
                help: "Mikrofone auswählen"
            ) { showDevices = true }

            headerButton(
                systemImage: "waveform.badge.magnifyingglass",
                help: "Technische Details"
            ) { showDetails.toggle() }
            .popover(isPresented: $showDetails, arrowEdge: .bottom) {
                DiagnosticsDetail(diagnostics: diagnostics)
            }
        }
    }

    @ViewBuilder
    private func headerButton(
        systemImage: String, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusMedium)
                        .fill(Theme.raised)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

// MARK: - MasterMeterBar

/// The summed output level, horizontally, at the top of the window.
///
/// The channel meters answer "is this microphone set right?". This one answers
/// "is what leaves the app set right?" — the question the person at the other
/// end of the call cares about, and the one no channel meter can answer once
/// there is more than one microphone open.
struct MasterMeterBar: View {
    @ObservedObject var source: ChannelMeterSource

    var body: some View {
        let peak = source.meters.postFaderPeakDB
        let verdict = meterVerdict(peakDB: peak)

        HStack(spacing: 10) {
            Text("SUMME")
                .font(Theme.captionFont)
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: true, vertical: false)

            LiveLevelMeter(
                source: source, tap: .postFader, orientation: .horizontal,
                showsScale: true)
                .frame(height: 16)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)

            // Fixed widths on both readouts: they change several times a second
            // and anything that reflows the bar beside them would make the bar
            // itself twitch.
            Text(peak > -120 ? String(format: "%.0f", peak) : "—")
                .font(Theme.valueFont)
                .monospacedDigit()
                .foregroundColor(Theme.textPrimary)
                .frame(width: 30, alignment: .trailing)

            Text(verdict.text)
                .font(Theme.captionFont)
                .foregroundColor(verdictColour(verdict))
                .lineLimit(1)
                .frame(width: 46, alignment: .leading)
        }
        .help("Der Pegel, den OpenConnect an Teams, Zoom oder OBS weitergibt. "
              + "Der grün hinterlegte Bereich ist das Ziel: dort sollten die "
              + "lautesten Stellen beim Sprechen landen.")
    }
}

// MARK: - DiagnosticsDetail

struct DiagnosticsDetail: View {
    let diagnostics: EngineDiagnostics

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Diagnose")
                .font(Theme.titleFont)
                .foregroundColor(Theme.textPrimary)

            row("Aussetzer",
                value: "\(diagnostics.underruns + diagnostics.overruns)",
                help: "Wie oft Ton zu spät oder zu früh ankam, gezählt seit dem "
                    + "Start. Ein paar beim Verbinden der Mikrofone sind normal; "
                    + "danach sollte die Zahl stehen bleiben. Klettert sie weiter, "
                    + "während du sprichst, ist etwas kaputt.")

            row("Verworfene Änderungen",
                value: "\(diagnostics.droppedParameters)",
                help: "Einstellungen, die der Tonprozess nicht rechtzeitig "
                    + "annehmen konnte. Sollte 0 bleiben.")

            if !diagnostics.perChannelRatioPPM.isEmpty {
                Divider().background(Theme.border)
                Text("Taktkorrektur je Mikrofon")
                    .font(Theme.labelFont)
                    .foregroundColor(Theme.textSecondary)
                Text("Jedes USB-Mikrofon läuft auf seinem eigenen Quarz, minimal "
                     + "neben 48 kHz. So stark dehnt OpenConnect dieses Mikrofon, "
                     + "damit es im Takt bleibt, in millionstel Anteilen. Unter 100 "
                     + "ist normal, sobald es sich eingependelt hat. Direkt nach dem "
                     + "Anstecken schwankt der Wert bis zu einer Minute stark; das "
                     + "ist so gewollt.")
                    .font(Theme.captionFont)
                    .foregroundColor(Theme.textDisabled)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(diagnostics.perChannelRatioPPM.sorted(by: { $0.key < $1.key }), id: \.key) { uid, ppm in
                    HStack(spacing: 8) {
                        Text(diagnostics.perChannelName[uid] ?? uid)
                            .font(Theme.labelFont)
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 12)
                        Text(String(format: "%+.0f ppm", ppm))
                            .font(Theme.valueFont)
                            .monospacedDigit()
                            .foregroundColor(abs(ppm) > 100 ? Theme.meterAmber : Theme.textPrimary)
                            .frame(width: 74, alignment: .trailing)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }

    @ViewBuilder
    private func row(_ label: String, value: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(label)
                    .font(Theme.labelFont)
                    .foregroundColor(Theme.textSecondary)
                Spacer(minLength: 12)
                Text(value)
                    .font(Theme.valueFont)
                    .monospacedDigit()
                    .foregroundColor(value == "0" ? Theme.textPrimary : Theme.meterAmber)
                    .frame(width: 74, alignment: .trailing)
            }
            Text(help)
                .font(Theme.captionFont)
                .foregroundColor(Theme.textDisabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
