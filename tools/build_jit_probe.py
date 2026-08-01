#!/usr/bin/env python3
"""Generate the WKWebView JIT probe page.

Open item 1 in docs/scope-v0.1.md asks whether WASM gets a real JIT inside
WKWebView's WebContent process. This builds a self contained HTML page that
answers it empirically: a tight integer loop compiled to WASM, timed, with a
JS implementation of the same loop timed alongside it as a control.

The WASM module is hand assembled here rather than compiled, so the project
needs no WASM toolchain and the page needs no network access. Output is a
single HTML file with the module inlined as base64.

Usage:
    python3 tools/build_jit_probe.py spikes/JITProbe/JITProbe/Resources/bench.html

How to read the result. Run the page in the app and in mobile Safari on the
same device. Safari's WebContent always has JIT, so it is the reference. If
the app scores within roughly 20 percent of Safari, WASM is being jitted and
the architecture in the scope doc holds. If the app is several times slower,
the module is running interpreted and the webview player needs rethinking
before anything else gets built on it.
"""

import base64
import sys


def uleb(n):
    out = bytearray()
    while True:
        byte = n & 0x7F
        n >>= 7
        if n:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def sleb(n):
    out = bytearray()
    while True:
        byte = n & 0x7F
        n >>= 7
        done = (n == 0 and not byte & 0x40) or (n == -1 and byte & 0x40)
        out.append(byte if done else byte | 0x80)
        if done:
            return bytes(out)


def section(sid, body):
    return bytes([sid]) + uleb(len(body)) + body


def vec(items):
    return uleb(len(items)) + b"".join(items)


# Opcodes used below.
BLOCK, LOOP, END, BR, BR_IF = 0x02, 0x03, 0x0B, 0x0C, 0x0D
LOCAL_GET, LOCAL_SET, I32_CONST = 0x20, 0x21, 0x41
I32_GE_S, I32_ADD, I32_MUL, I32_XOR, I32_SHR_U = 0x4E, 0x6A, 0x6C, 0x73, 0x76
I32, VOID = 0x7F, 0x40

# Locals: 0 = n (param), 1 = i, 2 = acc.
N, I, ACC = 0, 1, 2

# acc starts at 1, then a dependent chain of multiply, add, shift, xor per
# iteration. The dependency chain is the point: it defeats vectorisation and
# leaves a result an interpreter cannot fake cheaply.
body = bytes([
    I32_CONST, 0x01, LOCAL_SET, ACC,
    BLOCK, VOID,
    LOOP, VOID,
    # if (i >= n) break
    LOCAL_GET, I, LOCAL_GET, N, I32_GE_S, BR_IF, 0x01,
]) + bytes([
    # acc = acc * 1664525 + 1013904223
    LOCAL_GET, ACC, I32_CONST,
]) + sleb(1664525) + bytes([I32_MUL, I32_CONST]) + sleb(1013904223) + bytes([
    I32_ADD, LOCAL_SET, ACC,
    # acc ^= acc >>> 13
    LOCAL_GET, ACC, LOCAL_GET, ACC, I32_CONST, 0x0D, I32_SHR_U, I32_XOR,
    LOCAL_SET, ACC,
    # i += 1
    LOCAL_GET, I, I32_CONST, 0x01, I32_ADD, LOCAL_SET, I,
    BR, 0x00,
    END,   # loop
    END,   # block
    LOCAL_GET, ACC,
    END,   # function
])

# One local group: two i32 locals beyond the parameter.
code_entry = uleb(1) + bytes([2, I32]) + body
module = (
    b"\x00asm\x01\x00\x00\x00"
    # type: (i32) -> i32
    + section(1, vec([bytes([0x60]) + vec([bytes([I32])]) + vec([bytes([I32])])]))
    # function: one function, type 0
    + section(3, vec([bytes([0x00])]))
    # export: "bench" -> func 0
    + section(7, vec([uleb(5) + b"bench" + bytes([0x00, 0x00])]))
    + section(10, vec([uleb(len(code_entry)) + code_entry]))
)

WASM_B64 = base64.b64encode(module).decode()

HTML = """<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>WASM JIT probe</title>
<style>
  :root { color-scheme: light dark; }
  body {
    font: 16px/1.5 -apple-system, system-ui, sans-serif;
    margin: 0; padding: max(20px, env(safe-area-inset-top)) 20px 20px;
    -webkit-text-size-adjust: 100%%;
  }
  h1 { font-size: 19px; margin: 0 0 4px; }
  .sub { opacity: .6; font-size: 13px; margin-bottom: 20px; }
  .row {
    display: flex; justify-content: space-between; align-items: baseline;
    padding: 10px 0; border-bottom: 1px solid rgba(128,128,128,.25);
  }
  .k { opacity: .7; font-size: 14px; }
  .v { font-variant-numeric: tabular-nums; font-weight: 600; }
  .big { font-size: 30px; font-weight: 700; margin: 18px 0 2px;
         font-variant-numeric: tabular-nums; }
  button {
    font: inherit; font-weight: 600; width: 100%%; padding: 13px;
    margin-top: 22px; border: 0; border-radius: 11px;
    background: #0a7; color: #fff;
  }
  button:disabled { opacity: .45; }
  #ua { opacity: .45; font-size: 11px; margin-top: 22px; word-break: break-all; }
  .note { font-size: 13px; opacity: .75; margin-top: 14px; }
</style>

<h1>WASM JIT probe</h1>
<div class="sub">scope doc open item 1</div>

<div class="big" id="score">not run</div>
<div class="k" id="scoreLabel">WASM million iterations per second</div>

<div class="row"><span class="k">WASM</span><span class="v" id="wasm">&mdash;</span></div>
<div class="row"><span class="k">JavaScript, same loop</span><span class="v" id="js">&mdash;</span></div>
<div class="row"><span class="k">WASM vs JS</span><span class="v" id="ratio">&mdash;</span></div>
<div class="row"><span class="k">Checksum agrees</span><span class="v" id="ok">&mdash;</span></div>

<button id="run">Run probe</button>

<div class="note">
  Run this in the app and in Safari on the same device, then compare the WASM
  number. Safari is the jitted reference. Close means jitted, several times
  slower means interpreted.
</div>

<div id="ua"></div>

<script>
const WASM_B64 = "%(wasm)s";
const ITERS = 30000000;

function bytes(b64) {
  const s = atob(b64), a = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) a[i] = s.charCodeAt(i);
  return a;
}

// Same loop as the WASM module, as a control. Both must return the same value.
function jsBench(n) {
  let acc = 1;
  for (let i = 0; i < n; i++) {
    acc = (Math.imul(acc, 1664525) + 1013904223) | 0;
    acc = acc ^ (acc >>> 13);
  }
  return acc | 0;
}

const fmt = n => n.toFixed(1);

async function run() {
  const btn = document.getElementById("run");
  btn.disabled = true;
  btn.textContent = "Running";
  await new Promise(r => setTimeout(r, 50));

  const mod = await WebAssembly.instantiate(bytes(WASM_B64), {});
  const bench = mod.instance.exports.bench;

  // Warm both paths so we measure steady state, not first-call overhead.
  const wWarm = bench(2000000);
  const jWarm = jsBench(2000000);

  let t = performance.now();
  const wRes = bench(ITERS);
  const wMs = performance.now() - t;

  t = performance.now();
  const jRes = jsBench(ITERS);
  const jMs = performance.now() - t;

  const wRate = ITERS / wMs / 1000;
  const jRate = ITERS / jMs / 1000;
  const agree = (wRes | 0) === (jRes | 0) && (wWarm | 0) === (jWarm | 0);

  document.getElementById("score").textContent = fmt(wRate);
  document.getElementById("wasm").textContent =
    fmt(wRate) + " M/s  (" + wMs.toFixed(0) + " ms)";
  document.getElementById("js").textContent =
    fmt(jRate) + " M/s  (" + jMs.toFixed(0) + " ms)";
  document.getElementById("ratio").textContent =
    (wRate / jRate).toFixed(2) + "x";
  document.getElementById("ok").textContent = agree ? "yes" : "NO, results differ";

  btn.disabled = false;
  btn.textContent = "Run again";

  // Let the native host read the numbers without scraping the DOM.
  if (window.webkit && window.webkit.messageHandlers &&
      window.webkit.messageHandlers.probe) {
    window.webkit.messageHandlers.probe.postMessage({
      wasmMillionPerSec: wRate, jsMillionPerSec: jRate,
      wasmMs: wMs, jsMs: jMs, checksumAgrees: agree, iterations: ITERS,
      checksum: (wRes | 0)
    });
  }
}

document.getElementById("run").addEventListener("click", run);
document.getElementById("ua").textContent = navigator.userAgent;

// Run once unattended on load so a host can collect the numbers without
// anyone touching the screen. The button re-runs it by hand.
window.addEventListener("load", () => setTimeout(run, 300));
</script>
""" % {"wasm": WASM_B64}

if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "bench.html"
    with open(out, "w") as f:
        f.write(HTML)
    print("wrote %s (wasm module %d bytes)" % (out, len(module)))
