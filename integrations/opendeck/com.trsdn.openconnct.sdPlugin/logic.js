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

/** The state a key should be in and the title it should carry. */
export function keyFace(action, settings, state) {
    if (!state) return { state: 2, title: "—" };

    const channel = findChannel(state, settings);
    if (!channel) return { state: 2, title: "?" };

    switch (action) {
        case MUTE:
            // Unplugged wins over muted: a muted microphone that is not there
            // is not a muted microphone anyone can un-mute.
            if (!channel.present) return { state: 2, title: shortName(channel.name) };
            // `active` rather than `muted`: a microphone silenced by another
            // channel's solo is not muted, but nobody can hear it, and a key
            // that says "live" over a silent microphone is the worst lie a
            // mute key can tell.
            return { state: channel.muted || !channel.active ? 1 : 0, title: shortName(channel.name) };

        case GAIN:
            return { state: 0, title: formatGain(channel.gainDB) };

        default:
            return { state: 0, title: "" };
    }
}

function formatGain(gainDB) {
    const rounded = Math.round(gainDB * 10) / 10;
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
    const step = settings?.step === undefined || settings.step === "" ? 1 : Number(settings.step);
    if (!Number.isFinite(step)) return null;
    return channel.gainDB + step;
}
