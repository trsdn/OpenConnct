import fs from "node:fs/promises";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import process from "node:process";

/**
 * A client for OpenConnct's local control API.
 *
 * The port and the key are read from the two files the app writes when
 * "Control from other apps" is switched on, on every request rather than once.
 * That is what lets the plugin start before the app, and keep working when the
 * app is restarted onto a different port — nothing here is remembered that the
 * app could have changed since.
 */

export class ApiUnavailableError extends Error {
    name = "ApiUnavailableError";
}

export class ApiError extends Error {
    name = "ApiError";
    constructor(status, message) {
        super(message);
        this.status = status;
    }
}

const supportDirectory = () =>
    process.env.OPENCONNCT_SUPPORT_DIR ??
    path.join(os.homedir(), "Library", "Application Support", "OpenConnct");

async function credentials() {
    const directory = supportDirectory();
    try {
        const port = Number((await fs.readFile(path.join(directory, "api-port"), "utf8")).trim());
        const token = (await fs.readFile(path.join(directory, "api-token"), "utf8")).trim();
        if (!Number.isInteger(port) || port < 1 || port > 65535 || !token) throw new Error("unusable");
        return { port, token };
    } catch {
        // No port file means the API is off (the app removes it when switched
        // off) or the app has never run: the same answer for the person at the
        // deck, and the same fix.
        throw new ApiUnavailableError(
            "OpenConnct's control API is off. Switch on “Control from other apps” in its Technical details."
        );
    }
}

export async function request(method, pathname, body) {
    const { port, token } = await credentials();
    const payload = body === undefined ? undefined : JSON.stringify(body);

    return new Promise((resolve, reject) => {
        const req = http.request(
            {
                host: "127.0.0.1",
                port,
                method,
                path: pathname,
                timeout: 3000,
                headers: {
                    Authorization: `Bearer ${token}`,
                    ...(payload === undefined
                        ? {}
                        : { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(payload) }),
                },
            },
            (response) => {
                let text = "";
                response.setEncoding("utf8");
                response.on("data", (chunk) => (text += chunk));
                response.on("end", () => {
                    let json;
                    try {
                        json = JSON.parse(text);
                    } catch {
                        json = undefined;
                    }
                    if (response.statusCode === 200 && json) return resolve(json);
                    if (response.statusCode === 401) {
                        return reject(new ApiError(401, "OpenConnct did not accept the key. Restart the app's API."));
                    }
                    reject(new ApiError(response.statusCode, json?.error ?? `HTTP ${response.statusCode}`));
                });
            }
        );

        // A port file left behind by an app that quit without switching the API
        // off points at nothing; that is "not running", not a bug.
        req.on("error", (error) =>
            reject(
                error.code === "ECONNREFUSED" || error.code === "ECONNRESET"
                    ? new ApiUnavailableError("OpenConnct is not running.")
                    : error
            )
        );
        req.on("timeout", () => req.destroy(new ApiUnavailableError("OpenConnct did not answer.")));
        if (payload !== undefined) req.write(payload);
        req.end();
    });
}

export const getState = () => request("GET", "/v1/state");
export const toggleMute = (index) => request("POST", `/v1/channel/${index}/mute/toggle`);
export const setGainDB = (index, gainDB) => request("POST", `/v1/channel/${index}/gain`, { gainDB });
