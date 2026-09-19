#!/usr/bin/env node
import assert from "node:assert/strict";
import process from "node:process";

import { findChannel, keyFace, nextGainDB, shortName } from "../com.trsdn.openconnct.sdPlugin/logic.js";

/**
 * The decisions the plugin makes without touching a socket: which microphone a
 * key means, what the key should show, and what a gain press should ask for.
 * They are the part worth pinning down, because a wrong answer here is a key
 * that lies about whether you are muted.
 */

const state = (channels) => ({ driverInstalled: true, engineRunning: true, channels });
const mic = (index, name, over = {}) => ({
    index, name, active: true, muted: false, gainDB: 0, present: true, ...over,
});

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

// MARK: - What a gain key shows

check("a gain key shows the current gain with its sign", () => {
    const at = (gainDB) => keyFace("com.trsdn.openconnct.gain", {}, state([mic(0, "Desk", { gainDB })])).title;
    assert.equal(at(3), "+3 dB");
    assert.equal(at(-6.5), "-6.5 dB");
    assert.equal(at(0), "0 dB");
    assert.equal(at(12.25), "+12.3 dB");
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
