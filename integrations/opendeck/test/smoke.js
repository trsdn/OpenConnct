#!/usr/bin/env node
import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

import { handshake, readFrame, writeFrame } from "./websocket.js";

/**
 * Runs the plugin between a stand-in for OpenDeck and a stand-in for OpenConnct.
 *
 * The interesting part of this plugin is the join between those two, and none of
 * it is visible from reading the file: that a press arrives at the app as the
 * right request with the right key, that a change made somewhere else repaints
 * the key, and that a key never claims a state it cannot know.
 *
 * The fake OpenConnct is a real HTTP server that checks the bearer token and
 * reads the port from files, exactly as the app publishes them.
 */

const here = path.dirname(fileURLToPath(import.meta.url));
const PLUGIN_UUID = "com.trsdn.openconnct.sdPlugin";
const TOKEN = "a".repeat(64);

// Run a copy in a directory of its own, because that is what a deck app runs:
// the folder is copied out of the repository, away from any package.json above
// it, so the plugin has to declare itself a module.
const installed = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "openconnct-installed-")), PLUGIN_UUID);
fs.cpSync(path.join(here, "..", PLUGIN_UUID), installed, { recursive: true });

// MARK: - A stand-in for OpenConnct

const supportDir = fs.mkdtempSync(path.join(os.tmpdir(), "openconnct-support-"));

/** Every request the fake app received, in order. */
const requests = [];
const extras = () => ({
    soloed: false, faderDB: -6, highPass: "off", gate: false, compressor: false,
    exciter: false, bassEnhancer: false, pad: false,
});
let channels = [
    { index: 0, name: "Desk", active: true, muted: false, gainDB: 3, present: true, ...extras() },
    { index: 1, name: "Boom", active: true, muted: false, gainDB: 0, present: true, ...extras() },
    { index: 2, name: "Spare", active: false, muted: true, gainDB: 0, present: false, ...extras() },
];
let acceptedToken = TOKEN;

const snapshot = () => ({ driverInstalled: true, engineRunning: true, channels });
const answer = (response, status, body) => {
    response.writeHead(status, { "Content-Type": "application/json" });
    response.end(JSON.stringify(body));
};

function makeApp() {
    return http.createServer((request, response) => {
        let text = "";
        request.on("data", (chunk) => (text += chunk));
        request.on("end", () => {
            if (request.headers.authorization !== `Bearer ${acceptedToken}`) {
                return answer(response, 401, { error: "unauthorized" });
            }
            const body = text ? JSON.parse(text) : undefined;
            requests.push({ method: request.method, url: request.url, body, origin: request.headers.origin });

            const [, , , index, verb, sub, tail] = request.url.split("/");
            const channel = channels[Number(index)];
            if (request.method === "GET" && request.url === "/v1/state") return answer(response, 200, snapshot());
            if (!channel) return answer(response, 404, { error: "no such channel" });
            if (verb === "mute" && sub === "toggle") {
                channel.muted = !channel.muted;
                channel.active = !channel.muted;
            } else if (verb === "gain") {
                channel.gainDB = body.gainDB;
            } else if (verb === "solo" && sub === "toggle") {
                channel.soloed = !channel.soloed;
            } else if (verb === "fader") {
                channel.faderDB = body.faderDB;
            } else if (verb === "effect" && tail === "toggle") {
                const field = { highpass: "highPass", gate: "gate", compressor: "compressor", exciter: "exciter", bass: "bassEnhancer", pad: "pad" }[sub];
                if (!field) return answer(response, 404, { error: "not found" });
                channel[field] = field === "highPass" ? (channel.highPass === "off" ? "75" : "off") : !channel[field];
            }
            answer(response, 200, snapshot());
        });
    });
}

let app = makeApp();
async function startApp() {
    app = makeApp();
    await new Promise((resolve) => app.listen(0, "127.0.0.1", resolve));
    fs.writeFileSync(path.join(supportDir, "api-port"), `${app.address().port}\n`);
    fs.writeFileSync(path.join(supportDir, "api-token"), `${TOKEN}\n`);
}
async function stopApp() {
    app.closeAllConnections?.();
    await new Promise((resolve) => app.close(resolve));
    fs.rmSync(path.join(supportDir, "api-port"), { force: true });
}

// MARK: - A stand-in for OpenDeck

/** Messages the plugin sent us, in order. */
const fromPlugin = [];
const waiters = [];
let pluginSocket = null;

function deliver(message) {
    fromPlugin.push(message);
    for (const [index, waiter] of waiters.entries()) {
        if (waiter.matches(message)) {
            waiters.splice(index, 1);
            waiter.resolve(message);
            return;
        }
    }
}

/** Resolves with the next message matching `matches`, seen or yet to come. */
function nextMessage(matches, description, since = 0) {
    const found = fromPlugin.slice(since).find(matches);
    if (found) return Promise.resolve(found);
    return new Promise((resolve, reject) => {
        const waiter = { matches: (m) => fromPlugin.indexOf(m) >= since && matches(m), resolve };
        waiters.push(waiter);
        setTimeout(() => {
            const index = waiters.indexOf(waiter);
            if (index < 0) return;
            waiters.splice(index, 1);
            reject(new Error(`timed out waiting for ${description}`));
        }, 4000);
    });
}

const deck = http.createServer();
deck.on("upgrade", (request, socket) => {
    handshake(request, socket);
    pluginSocket = socket;
    let buffer = Buffer.alloc(0);
    socket.on("data", (chunk) => {
        buffer = Buffer.concat([buffer, chunk]);
        let frame;
        while ((frame = readFrame(buffer))) {
            buffer = buffer.subarray(frame.length);
            if (frame.opcode === 0x1) deliver(JSON.parse(frame.payload.toString("utf8")));
        }
    });
});
const toPlugin = (message) => pluginSocket.write(writeFrame(JSON.stringify(message)));

// MARK: - Checks

const checks = [];
const check = (name, body) => checks.push([name, body]);

const ctx = (name) => `DEVICE.Profile.Keypad.${name}.0`;
const MUTE = "com.trsdn.openconnct.mute";
const GAIN = "com.trsdn.openconnct.gain";
const settle = (ms = 400) => new Promise((resolve) => setTimeout(resolve, ms));
const appear = (action, name, settings = {}) =>
    toPlugin({ event: "willAppear", action, context: ctx(name), payload: { settings, state: 0 } });
const stateOf = (name, value) => (m) =>
    m.event === "setState" && m.context === ctx(name) && (value === undefined || m.payload.state === value);
const press = (action, name, settings = {}) =>
    toPlugin({ event: "keyDown", action, context: ctx(name), payload: { settings, state: 0 } });

check("the plugin registers itself with the uuid it was given", async () => {
    const message = await nextMessage((m) => m.event === "registerPlugin", "registerPlugin");
    assert.equal(message.uuid, PLUGIN_UUID);
});

check("a mute key is painted from the app's state, never from a guess", async () => {
    // A profile loading brings its keys in a burst, while the very first request
    // to the app is still out. Every one of them has to wait for that answer, so
    // this is the first thing the plugin is asked, on purpose: it only goes wrong
    // before the plugin has heard from the app once.
    appear(MUTE, "desk", { name: "Desk" });
    appear(MUTE, "extra", { name: "Boom" });
    appear(GAIN, "extra-gain", { name: "Desk", step: "1" });
    await nextMessage(stateOf("extra-gain"), "the last key of the burst");
    await settle(200);
    for (const name of ["desk", "extra", "extra-gain"]) {
        const first = fromPlugin.find((m) => m.event === "setState" && m.context === ctx(name));
        assert.notEqual(first.payload.state, 2, `${name} was painted as unavailable before it had asked`);
        const title = fromPlugin.find((m) => m.event === "setTitle" && m.context === ctx(name));
        assert.notEqual(title.payload.title, "—", `${name} was painted as unreachable before it had asked`);
    }
    assert.equal(fromPlugin.find(stateOf("desk")).payload.state, 0);
    assert.equal(fromPlugin.find((m) => m.event === "setTitle" && m.context === ctx("desk")).payload.title, "Desk");
    for (const name of ["extra", "extra-gain"]) {
        toPlugin({ event: "willDisappear", action: MUTE, context: ctx(name), payload: {} });
    }
});

check("a change nobody asked for repaints the key", async () => {
    // The whole reason the plugin polls: someone muted it in the app window.
    const since = fromPlugin.length;
    channels[0].muted = true;
    channels[0].active = false;
    const message = await nextMessage(stateOf("desk", 1), "the key to follow the app", since);
    assert.equal(message.payload.state, 1);
    channels[0].muted = false;
    channels[0].active = true;
    await nextMessage(stateOf("desk", 0), "the key to come back", since);
});

check("a key that is not changing is not repainted", async () => {
    await settle(300);
    const before = fromPlugin.filter(stateOf("desk")).length;
    await settle(600);
    assert.equal(fromPlugin.filter(stateOf("desk")).length, before, "polling alone must not repaint");
});

check("pressing a mute key reaches the app as the right request, with the key", async () => {
    requests.length = 0;
    const since = fromPlugin.length;
    press(MUTE, "desk", { name: "Desk" });
    await nextMessage(stateOf("desk", 1), "the key to change on the press itself", since);
    const post = requests.find((r) => r.method === "POST");
    assert.equal(post.url, "/v1/channel/0/mute/toggle");
    assert.equal(post.origin, undefined, "a browser-style Origin header would be refused by the app");
    press(MUTE, "desk", { name: "Desk" });
    await settle();
    assert.equal(channels[0].muted, false, "a second press unmutes");
});

check("a key follows its microphone by name when the order changes", async () => {
    appear(MUTE, "boom", { name: "Boom" });
    await nextMessage(stateOf("boom", 0), "the boom key");
    // Another microphone was plugged in and Boom is no longer index 1.
    channels = [
        { index: 0, name: "Boom", active: true, muted: false, gainDB: 0, present: true, ...extras() },
        { index: 1, name: "Desk", active: true, muted: false, gainDB: 3, present: true, ...extras() },
        channels[2],
    ];
    channels[2].index = 2;
    requests.length = 0;
    press(MUTE, "boom", { name: "Boom" });
    await settle();
    assert.equal(requests.find((r) => r.method === "POST").url, "/v1/channel/0/mute/toggle");
    channels[0].muted = false;
    channels[0].active = true;
});

check("an unplugged microphone shows unavailable", async () => {
    appear(MUTE, "spare", { name: "Spare" });
    const message = await nextMessage(stateOf("spare"), "the spare key");
    assert.equal(message.payload.state, 2);
});

check("a gain key shows the current gain and adds its step on a press", async () => {
    appear(GAIN, "gain", { name: "Desk", step: "3" });
    const title = await nextMessage((m) => m.event === "setTitle" && m.context === ctx("gain"), "the gain title");
    assert.equal(title.payload.title, "+3 dB");
    requests.length = 0;
    press(GAIN, "gain", { name: "Desk", step: "3" });
    await settle();
    const post = requests.find((r) => r.method === "POST");
    assert.equal(post.url, `/v1/channel/${channels.findIndex((c) => c.name === "Desk")}/gain`);
    assert.equal(post.body.gainDB, 6);
});

const SOLO = "com.trsdn.openconnct.solo";
const FADER = "com.trsdn.openconnct.fader";
const EFFECT = "com.trsdn.openconnct.effect";
const titleOf = (name) => (m) => m.event === "setTitle" && m.context === ctx(name);
const lastTitle = (name) => fromPlugin.filter(titleOf(name)).at(-1)?.payload.title;

check("a solo key lights up when its microphone is soloed, and a press reaches the app", async () => {
    appear(SOLO, "solo", { name: "Desk" });
    await nextMessage(stateOf("solo", 0), "the solo key");
    requests.length = 0;
    const since = fromPlugin.length;
    press(SOLO, "solo", { name: "Desk" });
    await nextMessage(stateOf("solo", 1), "the key to light", since);
    const post = requests.find((r) => r.method === "POST");
    assert.equal(post.url, `/v1/channel/${channels.findIndex((c) => c.name === "Desk")}/solo/toggle`);
    press(SOLO, "solo", { name: "Desk" });
    await settle();
    assert.equal(channels.find((c) => c.name === "Desk").soloed, false, "a second press un-solos");
});

check("a level key shows the fader with the label above it, and a press moves the fader", async () => {
    appear(FADER, "fader", { name: "Desk", step: "3", label: "Desk" });
    await nextMessage((m) => titleOf("fader")(m) && m.payload.title === "Desk\n-6 dB", "the fader title");
    requests.length = 0;
    press(FADER, "fader", { name: "Desk", step: "3", label: "Desk" });
    await settle();
    const post = requests.find((r) => r.method === "POST");
    assert.match(post.url, /\/fader$/);
    assert.equal(post.body.faderDB, -3);
    assert.equal(lastTitle("fader"), "Desk\n-3 dB");
});

check("a filter key names its filter, lights when it is on, and a press switches it", async () => {
    appear(EFFECT, "gate", { name: "Desk", effect: "gate", label: "Desk" });
    await nextMessage((m) => titleOf("gate")(m) && m.payload.title === "Noise gate\nDesk", "the filter title");
    requests.length = 0;
    const since = fromPlugin.length;
    press(EFFECT, "gate", { name: "Desk", effect: "gate", label: "Desk" });
    await nextMessage(stateOf("gate", 1), "the filter key to light", since);
    assert.match(requests.find((r) => r.method === "POST").url, /\/effect\/gate\/toggle$/);
});

check("the high-pass key reads on for any setting and switches between off and on", async () => {
    appear(EFFECT, "hpf", { name: "Boom", effect: "highpass" });
    await nextMessage(stateOf("hpf", 0), "the high-pass key");
    const since = fromPlugin.length;
    press(EFFECT, "hpf", { name: "Boom", effect: "highpass" });
    await nextMessage(stateOf("hpf", 1), "the key to light", since);
    assert.equal(channels.find((c) => c.name === "Boom").highPass, "75");
});

check("a filter key that has not been told which filter refuses and switches nothing", async () => {
    appear(EFFECT, "nofilter", { name: "Desk" });
    await nextMessage(stateOf("nofilter", 2), "the unconfigured key");
    // The title is its own message, sent just after the state: wait for it.
    const title = await nextMessage(titleOf("nofilter"), "the unconfigured key's title");
    assert.equal(title.payload.title, "Choose\nfilter");
    requests.length = 0;
    const since = fromPlugin.length;
    press(EFFECT, "nofilter", { name: "Desk" });
    await nextMessage((m) => m.event === "showAlert" && m.context === ctx("nofilter"), "an alert", since);
    assert.equal(requests.filter((r) => r.method === "POST").length, 0);
});

check("a key bound to nothing refuses to guess when there are several microphones", async () => {
    appear(MUTE, "unbound", {});
    await nextMessage(stateOf("unbound"), "the unbound key");
    requests.length = 0;
    const since = fromPlugin.length;
    press(MUTE, "unbound", {});
    await nextMessage((m) => m.event === "showAlert" && m.context === ctx("unbound"), "an alert", since);
    assert.equal(requests.filter((r) => r.method === "POST").length, 0, "nothing may be muted on a guess");
});

check("the inspector is handed the live list of microphones", async () => {
    const since = fromPlugin.length;
    toPlugin({ event: "propertyInspectorDidAppear", action: MUTE, context: ctx("desk") });
    const message = await nextMessage((m) => m.event === "sendToPropertyInspector", "the list", since);
    const labels = message.payload.channels.map((c) => c.label);
    assert.deepEqual(labels, ["Boom", "Desk", "Spare (unplugged)"]);
    assert.equal(message.payload.running, true);
});

check("with the app unreachable every key shows a dash, and recovers on its own", async () => {
    await stopApp();
    const since = fromPlugin.length;
    const dash = await nextMessage(
        (m) => m.event === "setTitle" && m.context === ctx("desk") && m.payload.title === "—",
        "the dash",
        since
    );
    assert.equal(dash.payload.title, "—");
    // The app comes back on a different port: the plugin reads the file again.
    await startApp();
    const back = await nextMessage(
        (m) => m.event === "setTitle" && m.context === ctx("desk") && m.payload.title === "Desk",
        "the key to recover",
        since
    );
    assert.equal(back.payload.title, "Desk");
});

check("a press the app refuses flashes the alert marker instead of failing quietly", async () => {
    acceptedToken = "b".repeat(64);
    const since = fromPlugin.length;
    press(MUTE, "desk", { name: "Desk" });
    await nextMessage((m) => m.event === "showAlert" && m.context === ctx("desk"), "an alert", since);
    acceptedToken = TOKEN;
});

// MARK: - Running

const port = await new Promise((resolve) => deck.listen(0, "127.0.0.1", () => resolve(deck.address().port)));
await startApp();

// `--no-experimental-*` makes this Node behave like Stream Deck's older one: no
// global WebSocket and no module-syntax guessing. Both are easy to depend on by
// accident and would only fail on somebody else's machine.
const plugin = spawn(
    process.execPath,
    [
        "--no-experimental-websocket",
        "--no-experimental-detect-module",
        path.join(installed, "plugin.js"),
        "-port", String(port),
        "-pluginUUID", PLUGIN_UUID,
        "-registerEvent", "registerPlugin",
        "-info", "{}",
    ],
    {
        stdio: ["ignore", "inherit", "inherit"],
        env: { ...process.env, OPENCONNCT_SUPPORT_DIR: supportDir, OPENCONNCT_POLL_MS: "100" },
    }
);
plugin.on("exit", (code) => {
    if (code) console.log(`  (plugin exited with ${code})`);
});

const failures = [];
for (const [name, body] of checks) {
    try {
        await body();
        console.log(`  ok  ${name}`);
    } catch (error) {
        failures.push(name);
        console.log(`  FAIL ${name}`);
        console.log(`       ${error.message}`);
    }
}

plugin.kill();
deck.close();
app.close();
console.log(
    failures.length
        ? `\n${failures.length} of ${checks.length} checks failed`
        : `\n${checks.length}/${checks.length} checks passed`
);
process.exit(failures.length ? 1 : 0);
