#!/usr/bin/env node
import process from "node:process";

import { getState, setFaderDB, setGainDB, toggleEffect, toggleMute, toggleSolo } from "./api-client.js";
import { DeckSocket } from "./deck-socket.js";
import { EFFECTS, findChannel, keyFace, nextFaderDB, nextGainDB } from "./logic.js";

/**
 * An OpenDeck plugin for OpenConnct.
 *
 * Two connections, in opposite directions, as in the OpenLens plugin: the deck
 * app tells us which keys exist and when one is pressed, and OpenConnct tells us
 * what is true right now. The plugin is the join between them — a press becomes
 * a request, and what OpenConnct reports becomes a repaint of every key.
 *
 * OpenConnct's API is request/response, so "what is true now" is a poll, once a
 * second, and only while a key of ours is on a device. That is what makes a key
 * honest: a microphone muted in the app window, or with curl, turns its key red
 * on the next tick instead of leaving the key claiming what it last sent.
 *
 * Same file, same rules as the OpenLens plugin: no dependencies, its own
 * WebSocket client, so it runs on whatever Node the deck app provides.
 */

const args = process.argv.slice(2);
const argument = (flag) => args[args.indexOf(flag) + 1];

const port = argument("-port");
const pluginUUID = argument("-pluginUUID");
const registerEvent = argument("-registerEvent");

const POLL_MS = Number(process.env.OPENCONNCT_POLL_MS ?? 1000);

/** Every key of ours currently on a device, by context. */
const keys = new Map();

/** The last state OpenConnct sent, or null while it cannot be reached. */
let mixer = null;

/**
 * Whether OpenConnct has answered yet, with a state or with a refusal. Until it
 * has, `mixer` being null means "we do not know", not "it is unreachable", and
 * painting the second for the first would flash keys grey each time a profile
 * loads.
 */
let asked = false;
let deck;
let timer = null;

// MARK: - The deck app

function connectToDeck() {
    deck = new DeckSocket(`ws://127.0.0.1:${port}`);
    deck.addEventListener("open", () => {
        deck.send(JSON.stringify({ event: registerEvent, uuid: pluginUUID }));
    });
    deck.addEventListener("message", ({ data }) => {
        try {
            handle(JSON.parse(data));
        } catch {
            // Not ours to crash on: a malformed message is the deck app's.
        }
    });
    // The deck app kills the plugin when it unloads it, so a closed socket means
    // we are leaving, not that we should try again.
    deck.addEventListener("close", () => process.exit(0));
    deck.addEventListener("error", () => process.exit(1));
}

function toDeck(event, context, payload) {
    if (deck?.readyState !== DeckSocket.OPEN) return;
    deck.send(JSON.stringify(payload ? { event, context, payload } : { event, context }));
}

function log(message) {
    if (deck?.readyState === DeckSocket.OPEN) {
        deck.send(JSON.stringify({ event: "logMessage", payload: { message: `OpenConnct: ${message}` } }));
    }
}

function handle(message) {
    const { event, context, action, payload } = message;
    switch (event) {
        case "willAppear":
            keys.set(context, { action, settings: payload?.settings ?? {}, face: null });
            render(context);
            startPolling();
            refresh();
            break;

        case "willDisappear":
            keys.delete(context);
            if (keys.size === 0) stopPolling();
            break;

        case "didReceiveSettings":
            if (keys.has(context)) {
                keys.get(context).settings = payload?.settings ?? {};
                keys.get(context).face = null;
            }
            render(context);
            break;

        case "keyDown":
            press(context).catch((error) => {
                // On the key itself: the person pressing it is looking at the
                // device, not at a log.
                toDeck("showAlert", context);
                log(error.message);
            });
            break;

        case "propertyInspectorDidAppear":
        case "sendToPlugin":
            answerInspector(context);
            break;
    }
}

// MARK: - Inspector

async function answerInspector(context) {
    // Fetched fresh: the inspector may be opened before the first poll lands,
    // and a list of microphones that is empty for want of asking is confusing.
    await refresh();
    toDeck("sendToPropertyInspector", context, {
        channels: (mixer?.channels ?? []).map((channel) => ({
            value: channel.name,
            label: channel.present ? channel.name : `${channel.name} (unplugged)`,
        })),
        running: mixer !== null,
    });
}

// MARK: - Presses

async function press(context) {
    const key = keys.get(context);
    if (!key) return;

    // Asked fresh, every press. The last poll is up to a second old, and the
    // mixer's order changes whenever a microphone is plugged in or removed: a
    // name resolved against stale state can land on a different microphone, and
    // muting the wrong one in the middle of a call is the failure that matters.
    // Not the shared poll either — a request already in flight was sent before
    // this press. It costs one loopback round trip.
    apply(await getState());

    const channel = findChannel(mixer, key.settings);
    if (!channel) {
        throw new Error(
            key.settings.name
                ? `No microphone named ${key.settings.name}`
                : "There is more than one microphone, so this key needs to say which one"
        );
    }

    let next;
    switch (key.action) {
        case "com.trsdn.openconnct.mute":
            next = await toggleMute(channel.index);
            break;
        case "com.trsdn.openconnct.gain": {
            const gain = nextGainDB(key.settings, channel);
            if (gain === null) throw new Error("This key's step is not a number");
            next = await setGainDB(channel.index, gain);
            break;
        }
        case "com.trsdn.openconnct.solo":
            next = await toggleSolo(channel.index);
            break;
        case "com.trsdn.openconnct.fader": {
            const fader = nextFaderDB(key.settings, channel);
            if (fader === null) throw new Error("This key's step is not a number");
            next = await setFaderDB(channel.index, fader);
            break;
        }
        case "com.trsdn.openconnct.effect":
            if (!EFFECTS[key.settings.effect]) throw new Error("Choose which filter this key switches");
            next = await toggleEffect(channel.index, key.settings.effect);
            break;
        default:
            return;
    }
    // Every call answers with the resulting state, so the key changes on the
    // press and not a second later.
    apply(next);
}

// MARK: - Painting

function render(context) {
    const key = keys.get(context);
    if (!key || !asked) return;
    const face = keyFace(key.action, key.settings, mixer);
    // Only what changed. The poll runs every second and almost never finds
    // anything new; repainting every key each time would make the deck app
    // redraw images for nothing.
    const same = key.face && key.face.state === face.state && key.face.title === face.title;
    if (same) return;
    key.face = face;
    toDeck("setState", context, { state: face.state });
    toDeck("setTitle", context, { title: face.title });
}

const renderAll = () => {
    for (const context of keys.keys()) render(context);
};

// MARK: - OpenConnct

function apply(state) {
    mixer = state;
    renderAll();
}

let lastError = null;
let inFlight = null;

/**
 * One request at a time, shared. A slow app must not stack requests behind each
 * other, and a caller that arrives while one is already out — the inspector
 * asking for its list — should wait for that answer, not be handed nothing.
 */
function refresh() {
    inFlight ??= fetchState().finally(() => {
        inFlight = null;
    });
    return inFlight;
}

async function fetchState() {
    try {
        const state = await getState();
        // Only now: `asked` means "we have an answer", and one still in flight
        // is not one. Keys that appear meanwhile stay unpainted until it lands.
        asked = true;
        apply(state);
        lastError = null;
    } catch (error) {
        asked = true;
        mixer = null;
        renderAll();
        // Unreachable is the normal state whenever the app is closed; say it
        // once, not every second.
        const text = error.message;
        if (text !== lastError) log(text);
        lastError = text;
    }
}

function startPolling() {
    if (!timer) timer = setInterval(refresh, POLL_MS);
}

function stopPolling() {
    clearInterval(timer);
    timer = null;
}

connectToDeck();
