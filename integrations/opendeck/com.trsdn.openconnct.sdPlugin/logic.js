/**
 * The decisions the plugin makes without touching a socket, kept apart from
 * plugin.js so they can be tested on their own.
 */

/** Longest name that still reads on a key before the deck app wraps it. */
const NAME_LENGTH = 12;

export function shortName(name) {
    return name.length > NAME_LENGTH ? `${name.slice(0, NAME_LENGTH - 1)}…` : name;
}

/**
 * The microphone a key means.
 *
 * By name, never by index: the index is the mixer's order, which changes when a
 * microphone is plugged in or removed, and a key that silently moved to a
 * different microphone would mute the wrong one in the middle of a call.
 * A key bound to nothing means "the only one" and nothing more, for the same
 * reason — with two microphones, guessing is how the wrong one gets muted.
 */
export function findChannel(state, settings) {
    const channels = state?.channels ?? [];
    if (!settings?.name) return channels.length === 1 ? channels[0] : undefined;
    return channels.find((channel) => channel.name === settings.name);
}

const MUTE = "com.trsdn.openconnct.mute";
const GAIN = "com.trsdn.openconnct.gain";
const SOLO = "com.trsdn.openconnct.solo";
const FADER = "com.trsdn.openconnct.fader";
const EFFECT = "com.trsdn.openconnct.effect";

/**
 * The filters a key can switch, by the name the app's API uses. `read` says
 * whether one is on, from a channel of `GET /v1/state`; it returns undefined
 * when the app is too old to report it.
 */
export const EFFECTS = {
    highpass: { name: "High-pass", read: (c) => (c.highPass === undefined ? undefined : c.highPass !== "off") },
    gate: { name: "Noise gate", read: (c) => c.gate },
    compressor: { name: "Compressor", read: (c) => c.compressor },
    exciter: { name: "Exciter", read: (c) => c.exciter },
    bass: { name: "Bass", read: (c) => c.bassEnhancer },
    pad: { name: "Pad", read: (c) => c.pad },
};

/**
 * What a key is called: its own label when it has one, otherwise the
 * microphone's name cut to fit. Names like "RØDE NT-USB Mini" and
 * "RØDE VideoMic NTG" share their first twelve characters, so on a real deck the
 * shortened names are indistinguishable and a label is the only way to tell the
 * keys apart.
 */
function titleFor(settings, channel) {
    const label = typeof settings?.label === "string" ? settings.label.trim() : "";
    return label || shortName(channel.name);
}

/** The label alone, or nothing: for keys whose title is a value and a name. */
const labelOf = (settings) => (typeof settings?.label === "string" ? settings.label.trim() : "");

/** A value under the microphone's label, in the way the OpenLens keys do it. */
const withLabel = (settings, value) => (labelOf(settings) ? `${labelOf(settings)}\n${value}` : value);

/** What a key says when the app it talks to predates the field it needs. */
const TOO_OLD = { state: 2, title: "Update\nOpenConnct" };

/** The state a key should be in and the title it should carry. */
export function keyFace(action, settings, state) {
    if (!state) return { state: 2, title: "—" };

    const channel = findChannel(state, settings);
    if (!channel) return { state: 2, title: "?" };

    switch (action) {
        case MUTE:
            // Unplugged wins over muted: a muted microphone that is not there
            // is not a muted microphone anyone can un-mute.
            if (!channel.present) return { state: 2, title: titleFor(settings, channel) };
            // `active` rather than `muted`: a microphone silenced by another
            // channel's solo is not muted, but nobody can hear it, and a key
            // that says "live" over a silent microphone is the worst lie a
            // mute key can tell.
            return { state: channel.muted || !channel.active ? 1 : 0, title: titleFor(settings, channel) };

        case SOLO:
            if (channel.soloed === undefined) return TOO_OLD;
            if (!channel.present) return { state: 2, title: titleFor(settings, channel) };
            return { state: channel.soloed ? 1 : 0, title: titleFor(settings, channel) };

        case GAIN:
            return { state: 0, title: withLabel(settings, formatDB(channel.gainDB)) };

        case FADER:
            if (channel.faderDB === undefined) return TOO_OLD;
            return { state: 0, title: withLabel(settings, formatDB(channel.faderDB)) };

        case EFFECT: {
            const effect = EFFECTS[settings?.effect];
            if (!effect) return { state: 2, title: "Choose\nfilter" };
            const on = effect.read(channel);
            if (on === undefined) return TOO_OLD;
            const lines = [effect.name, labelOf(settings) || shortName(channel.name)];
            return { state: !channel.present ? 2 : on ? 1 : 0, title: lines.join("\n") };
        }

        default:
            return { state: 0, title: "" };
    }
}

function formatDB(value) {
    const rounded = Math.round(value * 10) / 10;
    const text = Number.isInteger(rounded) ? String(rounded) : rounded.toFixed(1);
    return `${rounded > 0 ? "+" : ""}${text} dB`;
}

/**
 * The gain a press asks for, or null when the key's step is unusable.
 *
 * The app clamps to the slider's range, which depends on the microphone and is
 * not known here, so this does not try to.
 */
export function nextGainDB(settings, channel) {
    const step = stepOf(settings, 1);
    return step === null ? null : channel.gainDB + step;
}

/** The fader a press asks for, or null when the key's step is unusable. */
export function nextFaderDB(settings, channel) {
    const step = stepOf(settings, 3);
    return step === null ? null : channel.faderDB + step;
}

function stepOf(settings, fallback) {
    const step = settings?.step === undefined || settings.step === "" ? fallback : Number(settings.step);
    return Number.isFinite(step) ? step : null;
}
