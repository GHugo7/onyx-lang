// Onyx runtime for the JavaScript target. Embedded at the top of every compiled program.
const $rt = (() => {
  "use strict";

  /** An error raised with `fail`; travels up until handled by `?`, `or` or `catch`. */
  class OnyxError {
    constructor(message) {
      this.message = message;
    }
  }
  /** A bug in the program (index out of bounds, division by zero...). Not catchable. */
  class Panic extends Error {}
  class ExpectFail extends Error {}

  const CLOSED = Symbol("closed");
  const isNode = typeof process !== "undefined" && !!(process.versions && process.versions.node);
  const node = (name) => {
    if (!isNode || typeof require === "undefined") throw new OnyxError("not available outside Node.js");
    return require(name);
  };

  const panic = (msg) => {
    throw new Panic(msg);
  };
  const fail = (v) => {
    throw v instanceof OnyxError ? v : new OnyxError(v);
  };

  // ---- formatting ----
  const repr = (v) => {
    if (typeof v === "string") return JSON.stringify(v);
    if (typeof v === "number" || typeof v === "boolean") return String(v);
    if (Array.isArray(v)) return "[" + v.map(repr).join(", ") + "]";
    if (v instanceof Map) return "{" + Array.from(v, ([k, x]) => repr(k) + ": " + repr(x)).join(", ") + "}";
    if (v instanceof OnyxError) return v.message;
    if (v instanceof Chan) return "chan";
    if (typeof v === "function") return "fn";
    if (v === undefined) return "void";
    const fields = Object.keys(v).map((k) => k + ": " + repr(v[k]));
    return (v.constructor.$name || v.constructor.name) + "{" + fields.join(", ") + "}";
  };
  const str = (v) => (typeof v === "string" ? v : repr(v));
  const fstr = (x) => (Number.isInteger(x) ? x.toFixed(1) : String(x));

  let write = (line) => console.log(line);
  const print = (...parts) => write(parts.join(" "));

  // ---- operators ----
  const idiv = (a, b) => (b === 0 ? panic("division by zero") : Math.trunc(a / b));
  const imod = (a, b) => (b === 0 ? panic("division by zero") : a % b);
  const bounds = (len, i) => {
    if (i < 0 || i >= len) panic("index out of bounds: index " + i + ", length " + len);
  };
  const idx = (list, i) => (bounds(list.length, i), list[i]);
  const setIdx = (list, i, v) => (bounds(list.length, i), (list[i] = v));
  const mapGet = (m, k) => (m.has(k) ? m.get(k) : panic("key not found in map: " + repr(k)));

  const eq = (a, b) => {
    if (a === b) return true;
    if (typeof a !== "object" || typeof b !== "object" || a === null || b === null) return false;
    if (Array.isArray(a)) return a.length === b.length && a.every((x, i) => eq(x, b[i]));
    if (a instanceof Map) {
      if (a.size !== b.size) return false;
      for (const [k, v] of a) if (!b.has(k) || !eq(v, b.get(k))) return false;
      return true;
    }
    if (a instanceof Chan || a.constructor !== b.constructor) return false;
    return Object.keys(a).every((k) => eq(a[k], b[k]));
  };

  // ---- error handling ----
  /**
   * An error on its way out of a function because of a `?` written inside the
   * subject of `depth` enclosing `or`/`catch` handlers, which must not stop it.
   */
  class Passed {
    constructor(error, depth) {
      this.error = error;
      this.depth = depth;
    }
  }
  /** What a handler does with something it does not handle. */
  const through = (e) => {
    if (e instanceof Passed && --e.depth === 0) throw e.error;
    throw e;
  };
  const pass = (depth, f) => {
    try {
      return f();
    } catch (e) {
      throw e instanceof OnyxError ? new Passed(e, depth) : e;
    }
  };
  const passAsync = async (depth, f) => {
    try {
      return await f();
    } catch (e) {
      throw e instanceof OnyxError ? new Passed(e, depth) : e;
    }
  };
  const or = (f, d) => {
    try {
      return f();
    } catch (e) {
      if (e instanceof OnyxError) return d();
      through(e);
    }
  };
  const orAsync = async (f, d) => {
    try {
      return await f();
    } catch (e) {
      if (e instanceof OnyxError) return d();
      through(e);
    }
  };
  /** Used by generated `catch` blocks: lets anything that is not an Onyx error through. */
  const caught = (e) => {
    if (e instanceof OnyxError) return e;
    through(e);
  };

  // ---- concurrency ----
  class Chan {
    constructor(cap) {
      this.cap = cap || 0;
      this.buffer = [];
      this.receivers = [];
      this.senders = [];
      this.closed = false;
    }
    send(v) {
      if (this.closed) panic("send on a closed channel");
      if (this.receivers.length > 0) {
        this.receivers.shift()(v);
        return Promise.resolve();
      }
      if (this.buffer.length < this.cap) {
        this.buffer.push(v);
        return Promise.resolve();
      }
      return new Promise((resolve) => this.senders.push({ v, resolve }));
    }
    /** Resolves to the next value, or CLOSED once the channel is closed and drained. */
    recvOpt() {
      if (this.buffer.length > 0) {
        const v = this.buffer.shift();
        if (this.senders.length > 0) {
          const s = this.senders.shift();
          this.buffer.push(s.v);
          s.resolve();
        }
        return Promise.resolve(v);
      }
      if (this.senders.length > 0) {
        const s = this.senders.shift();
        s.resolve();
        return Promise.resolve(s.v);
      }
      if (this.closed) return Promise.resolve(CLOSED);
      return new Promise((resolve) => this.receivers.push(resolve));
    }
    async recv() {
      const v = await this.recvOpt();
      return v === CLOSED ? panic("receive from a closed channel") : v;
    }
    close() {
      this.closed = true;
      for (const r of this.receivers.splice(0)) r(CLOSED);
    }
  }

  let finished = false;
  const crash = (e) => {
    finished = true;
    let msg;
    let code = 2;
    if (e instanceof OnyxError) {
      msg = "error: " + e.message;
      code = 1;
    } else if (e instanceof Panic) msg = "panic: " + e.message;
    else if (e instanceof ExpectFail) msg = "panic: expectation failed at " + e.message;
    else if (e instanceof RangeError && /call stack/i.test(e.message)) msg = "panic: stack overflow (infinite recursion?)";
    else msg = "panic: internal error: " + (e && e.stack ? e.stack : e);
    console.error(msg);
    if (isNode) process.exit(code);
  };
  const fork = (task) => {
    task().catch(crash);
  };
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  if (isNode) {
    // The reader went away (e.g. `onyx run app.ox | head`): stop quietly.
    process.stdout.on("error", (e) => {
      if (e.code === "EPIPE") process.exit(0);
    });
    process.on("beforeExit", () => {
      if (!finished) {
        console.error("fatal: deadlock: the program is waiting on a channel that nobody will ever use");
        process.exit(2);
      }
    });
  }

  const run = async (main) => {
    try {
      await main();
      finished = true;
    } catch (e) {
      crash(e);
    }
  };

  const runTests = async (tests) => {
    let failed = 0;
    print("running " + tests.length + " check" + (tests.length === 1 ? "" : "s"));
    for (const [name, body] of tests) {
      try {
        await body();
        print("  ok    " + name);
      } catch (e) {
        failed++;
        let why;
        if (e instanceof ExpectFail) why = "expectation failed at " + e.message;
        else if (e instanceof OnyxError) why = "error: " + e.message;
        else if (e instanceof Panic) why = "panic: " + e.message;
        else why = String(e);
        print("  FAIL  " + name + " (" + why + ")");
      }
    }
    finished = true;
    print("");
    print(tests.length - failed + " passed, " + failed + " failed");
    if (failed > 0 && isNode) process.exit(1);
  };

  // ---- built-in functions ----
  const expect = (cond, where) => {
    if (!cond) throw new ExpectFail(where);
  };
  const parseInt_ = (s) => (/^\s*[+-]?\d+\s*$/.test(s) ? Number(s) : fail("cannot convert " + repr(s) + " to int"));
  const parseFloat_ = (s) =>
    /^\s*[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?\s*$/.test(s) ? Number(s) : fail("cannot convert " + repr(s) + " to float");
  const fsCall = (what, path, f) => {
    const fs = node("node:fs");
    try {
      return f(fs);
    } catch (e) {
      fail("cannot " + what + " " + repr(path) + ": " + (e.code === "ENOENT" ? "no such file or directory" : e.message));
    }
  };
  const readFile = (path) => fsCall("read", path, (fs) => fs.readFileSync(path, "utf8"));
  const writeFile = (path, text) => fsCall("write", path, (fs) => void fs.writeFileSync(path, text));
  const appendFile = (path, text) => fsCall("write", path, (fs) => void fs.appendFileSync(path, text));
  const fileExists = (path) => isNode && require("node:fs").existsSync(path);
  const args = () => (isNode ? process.argv.slice(2) : []);
  const env = (name) => {
    const v = isNode ? process.env[name] : undefined;
    return v === undefined ? fail("environment variable " + repr(name) + " is not set") : v;
  };
  const exit = (code) => {
    finished = true;
    if (isNode) process.exit(code);
    throw new Panic("exit(" + code + ")");
  };
  const input = (prompt) => {
    if (!isNode) return typeof globalThis.prompt === "function" ? globalThis.prompt(prompt) || "" : "";
    const fs = require("node:fs");
    if (prompt) process.stdout.write(prompt);
    const bytes = [];
    const buf = Buffer.alloc(1);
    for (;;) {
      let n = 0;
      try {
        n = fs.readSync(0, buf, 0, 1, null);
      } catch (e) {
        if (e.code === "EAGAIN") continue;
        break;
      }
      if (n === 0 || buf[0] === 10) break;
      bytes.push(buf[0]);
    }
    return Buffer.from(bytes).toString("utf8").replace(/\r$/, "");
  };
  const fetch_ = async (url) => {
    let res;
    try {
      res = await fetch(url);
    } catch (e) {
      fail("cannot fetch " + repr(url) + ": " + ((e.cause && e.cause.message) || e.message));
    }
    if (!res.ok) fail("cannot fetch " + repr(url) + ": HTTP " + res.status);
    return await res.text();
  };
  const randomInt = (lo, hi) => lo + Math.floor(Math.random() * (hi - lo + 1));

  // ---- methods on built-in types ----
  const nonEmpty = (list) => (list.length === 0 ? fail("the list is empty") : list);
  const list = {
    pop: (l) => nonEmpty(l).pop(),
    first: (l) => nonEmpty(l)[0],
    last: (l) => nonEmpty(l)[l.length - 1],
    contains: (l, v) => l.some((x) => eq(x, v)),
    indexOf: (l, v) => l.findIndex((x) => eq(x, v)),
    join: (l, sep) => l.map(str).join(sep),
    insert: (l, i, v) => {
      if (i < 0 || i > l.length) panic("index out of bounds: index " + i + ", length " + l.length);
      l.splice(i, 0, v);
    },
    remove: (l, i) => (bounds(l.length, i), l.splice(i, 1)[0]),
    sort: (l) => l.slice().sort((a, b) => (a < b ? -1 : a > b ? 1 : 0)),
    map: async (l, f) => {
      const out = [];
      for (const x of l) out.push(await f(x));
      return out;
    },
    filter: async (l, f) => {
      const out = [];
      for (const x of l) if (await f(x)) out.push(x);
      return out;
    },
    sortBy: async (l, f) => {
      const keyed = [];
      for (const x of l) keyed.push([await f(x), x]);
      keyed.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
      return keyed.map((p) => p[1]);
    },
  };
  const strIdx = (s, i) => (bounds(s.length, i), s[i]);
  const repeat = (s, n) => (n < 0 ? panic("repeat count cannot be negative") : s.repeat(n));
  const mapTryGet = (m, k) => (m.has(k) ? m.get(k) : fail("key not found: " + repr(k)));

  return {
    OnyxError, Chan, CLOSED, panic, fail, str, fstr, print, idiv, imod, idx, setIdx, mapGet, eq,
    or, orAsync, pass, passAsync, caught, fork, sleep, run, runTests, expect, parseInt_, parseFloat_, readFile,
    writeFile, appendFile, fileExists, args, env, exit, input, fetch_, randomInt, list, strIdx,
    repeat, mapTryGet,
    setWriter: (w) => (write = w),
  };
})();
