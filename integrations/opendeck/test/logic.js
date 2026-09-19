#!/usr/bin/env node
import assert from "node:assert/strict";
import process from "node:process";

import { EFFECTS, findChannel, keyFace, nextFaderDB, nextGainDB, shortName } from "../com.trsdn.openconnct.sdPlugin/logic.js";

/**
 * The decisions the plugin makes without touching a socket: which microphone a
 * key means, what the key should show, and what a gain press should ask for.
 * They are the part worth pinning down, because a wrong answer here is a key
 * that lies about whether you are muted.
 */

const state = (channels) => ({ driverInstalled: true, engineRunning: true, channels });
const mic = (index, name, over = {}) => ({
    index, name, active: true, muted: false, gainDB: 0, present: true,
    soloed: false, faderDB: 0, highPass: "off", gate: false, compressor: false,
    exciter: false, bassEnhancer: false, pad: false, ...over,
});
const SOLO = "com.trsdn.openconnct.solo";
const FADER = "com.trsdn.openconnct.fader";
const EFFECT = "com.trsdn.openconnct.effect";
/** What an OpenConnct from before these fields existed sends. */
const oldApp = (channel) => {
    const { soloed, faderDB, highPass, gate, compressor, exciter, bassEnhancer, pad, ...rest } = channel;
    return rest;
};

const checks = [];
const check = (name, body) => checks.push([name, body]);

// MARK: - Which microphone

check("a key finds its microphone by name, whatever index it has now", () => {
    const s = state([mic(0, "Desk"), mic(1, "Boom")]);
    assert.equal(findChannel(s, { name: "Boom" })?.index, 1);
    // Someone plugged in another microphone and the order changed.
    const reordered = state([mic(0, "Boom"), mic(1, "Desk")]);
    assert.equal(findChannel(reordered, { name: "Boom" })?.index, 0);
});

check("a key bound to nothing means the only microphone, and only then", () => {
    assert.equal(findChannel(state([mic(0, "Desk")]), {})?.name, "Desk");
    assert.equal(findChannel(state([mic(0, "Desk"), mic(1, "Boom")]), {}), undefined);
});

check("a name that is not there finds nothing rather than something else", () => {
    assert.equal(findChannel(state([mic(0, "Desk")]), { name: "Boom" }), undefined);
});

check("no state at all finds nothing", () => {
    assert.equal(findChannel(null, { name: "Desk" }), undefined);
});

// MARK: - What a mute key shows

check("a live microphone shows the live state and its name", () => {
    const face = keyFace("com.trsdn.openconnct.mute", { name: "Desk" }, state([mic(0, "Desk")]));
    assert.deepEqual(face, { state: 0, title: "Desk" });
});

check("a muted microphone shows the muted state", () => {
    const s = state([mic(0, "Desk", { muted: true, active: false })]);
    assert.equal(keyFace("com.trsdn.openconnct.mute", { name: "Desk" }, s).state, 1);
});

check("a microphone silenced by another channel's solo is not shown as live", () => {
    // Not muted itself, but nobody can hear it — the key must not say "live".
    const s = state([mic(0, "Desk", { muted: false, active: false })]);
    assert.equal(keyFace("com.trsdn.openconnct.mute", { name: "Desk" }, s).state, 1);
});

check("an unplugged microphone shows unavailable, even if it was muted", () => {
    const s = state([mic(0, "Desk", { present: false, muted: true, active: false })]);
    assert.equal(keyFace("com.trsdn.openconnct.mute", { name: "Desk" }, s).state, 2);
});

check("with OpenConnct unreachable every key shows a dash and unavailable", () => {
    assert.deepEqual(keyFace("com.trsdn.openconnct.mute", { name: "Desk" }, null), { state: 2, title: "—" });
});

check("a key whose microphone is not in the list says so instead of guessing", () => {
    const face = keyFace("com.trsdn.openconnct.mute", { name: "Boom" }, state([mic(0, "Desk")]));
    assert.deepEqual(face, { state: 2, title: "?" });
});

check("a key can carry its own label instead of the microphone's long name", () => {
    const s = state([mic(0, "RØDE NT-USB Mini")]);
    const face = keyFace("com.trsdn.openconnct.mute", { name: "RØDE NT-USB Mini", label: "NT-USB" }, s);
    assert.equal(face.title, "NT-USB");
    // A blank label is "no label", not an empty title.
    assert.equal(keyFace("com.trsdn.openconnct.mute", { name: "RØDE NT-USB Mini", label: "  " }, s).title, "RØDE NT-USB…");
});

check("a label does not hide that the microphone is unplugged", () => {
    const s = state([mic(0, "Desk", { present: false })]);
    const face = keyFace("com.trsdn.openconnct.mute", { name: "Desk", label: "Mine" }, s);
    assert.deepEqual(face, { state: 2, title: "Mine" });
});

// MARK: - What a gain key shows

check("a gain key shows the current gain with its sign", () => {
    const at = (gainDB) => keyFace("com.trsdn.openconnct.gain", {}, state([mic(0, "Desk", { gainDB })])).title;
    assert.equal(at(3), "+3 dB");
    assert.equal(at(-6.5), "-6.5 dB");
    assert.equal(at(0), "0 dB");
    assert.equal(at(12.25), "+12.3 dB");
});

check("a gain key with a label puts the microphone above the value", () => {
    const s = state([mic(0, "Desk", { gainDB: 26 })]);
    assert.equal(keyFace("com.trsdn.openconnct.gain", { label: "NT-USB" }, s).title, "NT-USB\n+26 dB");
});

// MARK: - Solo

check("a solo key is lit only while its microphone is soloed", () => {
    assert.equal(keyFace(SOLO, { name: "Desk" }, state([mic(0, "Desk")])).state, 0);
    assert.equal(keyFace(SOLO, { name: "Desk" }, state([mic(0, "Desk", { soloed: true })])).state, 1);
});

check("a solo key on an unplugged microphone is unavailable", () => {
    assert.equal(keyFace(SOLO, { name: "Desk" }, state([mic(0, "Desk", { present: false })])).state, 2);
});

// MARK: - Fader

check("a fader key shows the level in the mix, not the microphone's gain", () => {
    const s = state([mic(0, "Desk", { gainDB: 26, faderDB: -12 })]);
    assert.equal(keyFace(FADER, { name: "Desk" }, s).title, "-12 dB");
    assert.equal(keyFace(FADER, { name: "Desk", label: "Desk" }, s).title, "Desk\n-12 dB");
});

check("a press moves the fader by the key's step", () => {
    assert.equal(nextFaderDB({ step: "-3" }, mic(0, "Desk", { faderDB: -6 })), -9);
    assert.equal(nextFaderDB({}, mic(0, "Desk", { faderDB: -6 })), -3, "a fresh key steps up by three");
    assert.equal(nextFaderDB({ step: "loud" }, mic(0, "Desk", { faderDB: -6 })), null);
});

// MARK: - Filters

check("a filter key is lit while its filter is on, and names both filter and microphone", () => {
    const off = state([mic(0, "Desk")]);
    const on = state([mic(0, "Desk", { gate: true })]);
    assert.deepEqual(keyFace(EFFECT, { name: "Desk", effect: "gate", label: "NT-USB" }, off), { state: 0, title: "Noise gate\nNT-USB" });
    assert.equal(keyFace(EFFECT, { name: "Desk", effect: "gate" }, on).state, 1);
});

check("every filter reads the right field of the microphone", () => {
    const cases = { highpass: { highPass: "75" }, gate: { gate: true }, compressor: { compressor: true },
        exciter: { exciter: true }, bass: { bassEnhancer: true }, pad: { pad: true } };
    for (const [effect, over] of Object.entries(cases)) {
        assert.equal(keyFace(EFFECT, { name: "Desk", effect }, state([mic(0, "Desk", over)])).state, 1, effect);
        assert.equal(keyFace(EFFECT, { name: "Desk", effect }, state([mic(0, "Desk")])).state, 0, effect);
    }
    assert.deepEqual(Object.keys(EFFECTS).sort(), Object.keys(cases).sort());
});

check("any high-pass setting counts as the filter being on", () => {
    for (const highPass of ["75", "150", "variable"]) {
        assert.equal(keyFace(EFFECT, { name: "Desk", effect: "highpass" }, state([mic(0, "Desk", { highPass })])).state, 1, highPass);
    }
});

check("a filter key that has not been told which filter says so", () => {
    assert.deepEqual(keyFace(EFFECT, { name: "Desk" }, state([mic(0, "Desk")])), { state: 2, title: "Choose\nfilter" });
    assert.equal(keyFace(EFFECT, { name: "Desk", effect: "reverb" }, state([mic(0, "Desk")])).state, 2);
});

check("a filter key on an unplugged microphone is unavailable", () => {
    assert.equal(keyFace(EFFECT, { name: "Desk", effect: "gate" }, state([mic(0, "Desk", { present: false })])).state, 2);
});

check("an OpenConnct too old to know these fields says so instead of showing a guess", () => {
    const s = state([oldApp(mic(0, "Desk"))]);
    for (const [action, settings] of [[SOLO, {}], [FADER, {}], [EFFECT, { effect: "gate" }]]) {
        assert.deepEqual(keyFace(action, { name: "Desk", ...settings }, s), { state: 2, title: "Update\nOpenConnct" }, action);
    }
    // The keys that always worked keep working.
    assert.equal(keyFace("com.trsdn.openconnct.mute", { name: "Desk" }, s).state, 0);
});

// MARK: - What a gain press asks for

check("a press adds the step to where the gain is now", () => {
    assert.equal(nextGainDB({ step: "3" }, mic(0, "Desk", { gainDB: 2 })), 5);
    assert.equal(nextGainDB({ step: "-1" }, mic(0, "Desk", { gainDB: 2 })), 1);
});

check("a fresh key with no step set nudges up by one decibel", () => {
    assert.equal(nextGainDB({}, mic(0, "Desk", { gainDB: 0 })), 1);
});

check("a step that is not a number does nothing instead of sending NaN", () => {
    assert.equal(nextGainDB({ step: "loud" }, mic(0, "Desk", { gainDB: 2 })), null);
});

// MARK: - Names

check("long names are shortened so they fit a key", () => {
    assert.equal(shortName("Desk"), "Desk");
    assert.equal(shortName("VideoMic NTG Wireless"), "VideoMic NT…");
});

// MARK: - Running

const failures = [];
for (const [name, body] of checks) {
    try {
        body();
        console.log(`  ok  ${name}`);
    } catch (error) {
        failures.push(name);
        console.log(`  FAIL ${name}`);
        console.log(`       ${error.message}`);
    }
}
console.log(
    failures.length
        ? `\n${failures.length} of ${checks.length} checks failed`
        : `\n${checks.length}/${checks.length} checks passed`,
);
process.exit(failures.length ? 1 : 0);
