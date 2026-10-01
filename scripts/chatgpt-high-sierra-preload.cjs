"use strict";

// Compatibility surface for OpenAI's real ChatGPT/Codex desktop payload when
// running on Electron 26 / Node 18 (macOS 10.13 compatible runtime).
const electron = require("electron");

if (electron && electron.app && typeof electron.app.showTaskManager !== "function") {
  Object.defineProperty(electron.app, "showTaskManager", {
    configurable: true,
    enumerable: false,
    writable: false,
    value() {
      // Owl exposes a native Chromium task-manager window. Electron 26 has no
      // equivalent public API. Keeping this callable preserves startup and the
      // menu action safely becomes a no-op on the High Sierra backport.
    },
  });
}

if (typeof URL.parse !== "function") {
  URL.parse = function parseUrlCompat(input, base) {
    try {
      return new URL(input, base);
    } catch {
      return null;
    }
  };
}

if (typeof Promise.withResolvers !== "function") {
  Promise.withResolvers = function withResolversCompat() {
    let resolve;
    let reject;
    const promise = new Promise((res, rej) => {
      resolve = res;
      reject = rej;
    });
    return { promise, resolve, reject };
  };
}

if (typeof AbortSignal.any !== "function") {
  AbortSignal.any = function anySignalCompat(signals) {
    const controller = new AbortController();
    for (const signal of signals) {
      if (signal.aborted) {
        controller.abort(signal.reason);
        break;
      }
      signal.addEventListener(
        "abort",
        () => {
          if (!controller.signal.aborted) {
            controller.abort(signal.reason);
          }
        },
        { once: true }
      );
    }
    return controller.signal;
  };
}
