# Quick Reference — Weak Spots

## 1. Closures, `this`, bind, call, apply

### The core rule

`this` is determined by **how a function is called**, not where it's defined.
Arrow functions are the exception — they capture `this` from where they're **written**.

```js
// REGULAR FUNCTIONS: `this` = whatever is left of the dot at call time
obj.method();        // this = obj
const fn = obj.method;
fn();                // this = undefined (strict) or window (sloppy)

// ARROW FUNCTIONS: `this` = whatever `this` was in the enclosing scope
// They IGNORE the call site. You can't rebind them.
```

### Mental model: just ask "who called this?"

```js
class Auction {
  constructor(id) { this.id = id; }

  // SCENARIO 1: called as obj.method() → this = obj ✓
  log() { console.log(this.id); }

  // SCENARIO 2: passed as callback → caller decides `this`
  start() {
    setTimeout(function () {
      console.log(this.id);     // this = window (setTimeout calls it)
    }, 100);

    setTimeout(() => {
      console.log(this.id);     // this = Auction (arrow captures from start())
    }, 100);
  }

  // SCENARIO 3: extracted and called bare
  getBidHandler() {
    return function () {
      console.log(this.id);     // this = whoever calls it later
    };
    return () => {
      console.log(this.id);     // this = Auction (arrow, locked in)
    };
  }
}

const a = new Auction("x");
const log = a.log;
log();                // undefined — no dot, no `this`
a.log();              // "x"

document.addEventListener("click", a.log);       // this = document element
document.addEventListener("click", () => a.log()); // this = Auction ✓
document.addEventListener("click", a.log.bind(a)); // this = Auction ✓
```

### bind vs call vs apply

```js
function bid(amount, currency) {
  console.log(`${this.user} bids ${amount} ${currency}`);
}

const ctx = { user: "David" };

// call: invoke NOW, args listed out
bid.call(ctx, 100, "USD");           // "David bids 100 USD"

// apply: invoke NOW, args as array
bid.apply(ctx, [100, "USD"]);        // "David bids 100 USD"

// bind: return NEW function with `this` locked, invoke LATER
const davidBid = bid.bind(ctx);
davidBid(100, "USD");                // "David bids 100 USD"

// bind with partial application
const davidBidUSD = bid.bind(ctx, 100, "USD");
davidBidUSD();                       // "David bids 100 USD"
```

**When to use each:**
| | When | Example |
|---|---|---|
| **Arrow** | New code, callbacks | `setTimeout(() => this.x, 100)` |
| **bind** | Passing a method as a callback | `el.addEventListener("click", this.onClick.bind(this))` |
| **call** | Borrowing a method once | `Array.prototype.slice.call(arguments)` |
| **apply** | Spreading an array of args | `Math.max.apply(null, numbers)` — (obsolete, use `...spread`) |

### Closure traps in review

```js
// TRAP 1: function() inside prototype method
Timer.prototype.start = function () {
  setInterval(function () {
    this.tick();           // BUG — this = window
  }, 1000);
};

// TRAP 2: function() inside function() (nested)
Monitor.prototype.check = function () {
  setInterval(function () {       // outer: this = window
    setTimeout(function () {      // inner: this = ALSO window
      this.status = "stale";      // neither refers to Monitor
    }, 5000);
  }, 30000);
};

// TRAP 3: debounce/throttle wrappers
function debounce(fn, delay) {
  var timer;
  return function () {
    var context = this;               // ← must capture here
    var args = arguments;
    clearTimeout(timer);
    timer = setTimeout(function () {
      fn.apply(context, args);        // ← use captured context
    }, delay);
  };
}

// TRAP 4: event listener extraction
class View {
  constructor() {
    // BUG: this.onClick is unbound when passed
    document.addEventListener("click", this.onClick);
    // FIX options:
    document.addEventListener("click", this.onClick.bind(this));
    document.addEventListener("click", (e) => this.onClick(e));
    // or define onClick as arrow in constructor:
    this.onClick = (e) => { /* this = View */ };
  }
}
```

### Quick `this` cheat table

| Call style | `this` = |
|---|---|
| `obj.fn()` | `obj` |
| `fn()` | `window` / `undefined` (strict) |
| `new Fn()` | new instance |
| `fn.call(x)` / `fn.apply(x)` | `x` |
| `fn.bind(x)()` | `x` |
| `setTimeout(fn, t)` | `window` |
| `el.addEventListener(e, fn)` | `el` |
| `() => {}` | inherited from enclosing scope (cannot be rebound) |

---

## 2. WebSocket — Full Mental Model

### Lifecycle (memorize this sequence)

```
  new WebSocket(url)
        │
        ▼
   CONNECTING (0)
        │
   onopen fires
        │
        ▼
     OPEN (1) ◄───── ready to send/receive
        │
   onmessage fires (repeatedly)
        │
   close() called or connection drops
        │
        ▼
   CLOSING (2)
        │
   onclose fires
        │
        ▼
    CLOSED (3)

   onerror can fire at any stage → always followed by onclose
```

### The 5 things that go wrong (and how to spot them in code review)

**1. Sending on a non-OPEN socket**
```js
// BUG: socket might be CONNECTING, CLOSING, or CLOSED
socket.send(JSON.stringify(data));

// FIX: always guard
if (socket.readyState === WebSocket.OPEN) {
  socket.send(JSON.stringify(data));
} else {
  messageQueue.push(data); // buffer for later
}
```
Review tip: Ctrl+F `.send(` — every call needs a readyState check or
must be provably inside an `onopen` handler.

**2. Silent connection death (no heartbeat)**
```js
// Proxies/LBs can kill idle connections after 30-60s with no FIN packet.
// The client has no idea the socket is dead until it tries to send.

// FIX: ping/pong at regular intervals
startHeartbeat() {
  this.lastPong = Date.now();            // ← initialize! null = instant false positive
  this.heartbeat = setInterval(() => {   // ← arrow function for `this`
    if (Date.now() - this.lastPong > 15000) {
      this.socket.close(4000, "Heartbeat timeout");
      return;
    }
    if (this.socket.readyState === WebSocket.OPEN) {  // ← guard the send
      this.socket.send('{"type":"ping"}');
    }
  }, 10000);
}
// Don't forget: clearInterval in destroy()
```

**3. Reconnection stampede**
```js
// BAD: linear backoff, no jitter — 10k clients reconnect at same instant
var delay = 1000 * attempts;

// GOOD: exponential + jitter
var delay = Math.min(
  1000 * Math.pow(2, attempts) + Math.random() * 1000,
  30000  // cap at 30s
);
```

**4. Lost state after reconnect**
```js
// The server doesn't remember your subscriptions after disconnect.
// Track subscriptions client-side and replay on reconnect.

socket.addEventListener("open", () => {
  subscriptions.forEach(ch =>                       // resubscribe
    socket.send(JSON.stringify({ type: "sub", channel: ch }))
  );
  while (queue.length > 0 && socket.readyState === WebSocket.OPEN) {
    socket.send(queue.shift());                     // flush queued messages (FIFO!)
  }
});

// Use a Set for subscriptions to prevent duplicates:
subscriptions = new Set();  // not an array
```

**5. Duplicate / out-of-order messages**
```js
// During reconnection, the server may replay messages you already processed.
// Use sequence numbers to detect and skip duplicates.

handleMessage(data) {
  if (data.seq <= this.lastSeq) return;    // ← SKIP, don't process
  if (data.seq > this.lastSeq + 1) {
    requestReplay(this.lastSeq + 1, data.seq); // gap detected
  }
  this.lastSeq = data.seq;
  process(data);
}
```

### WebSocket code review checklist

```
For EVERY .send():
  □ readyState === OPEN checked?
  □ data could be undefined/null?
  □ called during reconnect window?

For lifecycle:
  □ Heartbeat with initialized pong time?
  □ Exponential backoff + jitter on reconnect?
  □ Max retry limit? Error state shown to user?
  □ All intervals cleared in destroy()?
  □ Subscriptions resubscribed on reconnect?
  □ Duplicates skipped (seq check)?
  □ Queue is FIFO (shift not pop)?
  □ Backpressure (bufferedAmount < threshold)?
  □ Clean close on page unload (beforeunload)?
  □ this binding correct in ALL callbacks?
```

---

## 3. Logic Bugs (you missed these entirely)

```js
// Division by zero
total / bids.length;        // NaN if length === 0
if (bids.length === 0) return 0;

// Wrong sort direction
arr.sort((a, b) => a - b);  // ascending (smallest first)
arr.sort((a, b) => b - a);  // descending (largest first)
// Ask: does the function NAME match the sort ORDER?

// LIFO vs FIFO
queue.pop();   // takes from END   — last in, first out
queue.shift(); // takes from START — first in, first out
// If it's called a "queue" or "flush", it should be FIFO → shift()

// parseInt truncates decimals
parseInt("10.50");   // 10
parseFloat("10.50"); // 10.5
// Rule: money/bids → always parseFloat

// .sort() mutates the original array
const sorted = arr.sort(compareFn);  // arr is ALSO sorted now
const sorted = [...arr].sort(compareFn); // safe copy
```

## 4. XSS — Don't Miss Any

```
Ctrl+F for:  innerHTML, outerHTML, insertAdjacentHTML, onclick=", document.write
```

- User input → P0 XSS
- Server data containing user content (usernames, chat, titles) → P0 XSS
- Fix: use `textContent`, `createElement`, or sanitize

## 5. Refactoring — Staff-Level Moves

The interview explicitly tests refactoring. Don't just find bugs — propose
structural improvements and articulate the **system-wide impact**.

### Prototype → ES6 class (the #1 refactor in this codebase)

```js
// BEFORE: verbose, error-prone this binding everywhere
function Timer(el) {
  this.el = el;
  this.id = null;
}
Timer.prototype.start = function () {
  this.id = setInterval(function () {
    this.el.textContent = Date.now();  // BUG: this = window
  }, 1000);
};

// AFTER: class + arrow method = no binding bugs
class Timer {
  constructor(el) {
    this.el = el;
    this.id = null;
  }
  start() {
    this.id = setInterval(() => {       // arrow inherits this
      this.el.textContent = Date.now(); // works
    }, 1000);
  }
  stop() { clearInterval(this.id); }
}
```
**Why it matters at scale:** eliminates an entire category of bugs. Every
`function(){}` callback in a prototype method is a potential `this` bug.
Classes + arrows make it structural rather than requiring developer vigilance.

### Separate concerns (data vs rendering)

```js
// BEFORE: ChatManager owns data AND renders to DOM
ChatManager.prototype.onMessage = function (data) {
  this.messages[data.auctionId].push(data);  // data
  this.renderMessage(data);                   // rendering
};

// AFTER: split into store + view
class ChatStore {
  #messages = new Map();
  #bus;
  constructor(bus) { this.#bus = bus; }
  add(auctionId, msg) {
    if (!this.#messages.has(auctionId)) this.#messages.set(auctionId, []);
    this.#messages.get(auctionId).push(msg);
    this.#bus.emit("chat:new", msg);         // notify, don't render
  }
}
class ChatView {
  constructor(bus) {
    bus.on("chat:new", (msg) => this.render(msg));
  }
  render(msg) { /* DOM only */ }
}
```
**Why:** testable without DOM, replaceable views, multiple views can
listen to the same data (e.g., chat panel + notification badge).

### Event system: add unsubscribe

```js
// BEFORE: no way to remove listeners → memory leaks
manager.on("bid", callback);

// AFTER: on() returns an unsubscribe function
on(event, fn) {
  if (!this.listeners.has(event)) this.listeners.set(event, new Set());
  this.listeners.get(event).add(fn);
  return () => this.listeners.get(event).delete(fn);  // cleanup handle
}

// Usage
const unsub = manager.on("bid", handleBid);
// later, on destroy:
unsub();
```

### Cleanup pattern: centralize with AbortController

```js
// BEFORE: scattered cleanup, easy to forget one
destroy() {
  clearInterval(this.timer1);
  clearInterval(this.timer2);
  window.removeEventListener("resize", this.onResize);
  this.el.removeEventListener("click", this.onClick);
  this.socket.close();
}

// AFTER: one controller rules them all
init() {
  this.ac = new AbortController();
  const { signal } = this.ac;
  window.addEventListener("resize", this.onResize, { signal });
  this.el.addEventListener("click", this.onClick, { signal });
}
destroy() {
  this.ac.abort();   // removes ALL listeners at once
  this.socket.close(1000, "Destroyed");
}
```

### Replace global functions with module scope

```js
// BEFORE: pollutes global, XSS-injectable via onclick=""
window.placeBid = function (id) { ... };
'<button onclick="placeBid(\'' + id + '\')">Bid</button>';

// AFTER: event delegation, no globals
bidSection.addEventListener("click", (e) => {
  const btn = e.target.closest("[data-action='bid']");
  if (!btn) return;
  const id = btn.dataset.auctionId;
  const amount = parseFloat(bidInput.value);
  manager.placeBid(id, amount);
});
```

### How to talk about refactoring in the interview

Frame every suggestion as: **current state → risk → proposed change → impact**

> "Right now the event system has no unsubscribe mechanism. In a long-running
> session, listeners from destroyed views accumulate, leaking memory. If we
> return an unsub handle from `on()`, each component can clean up on destroy.
> The change is backward-compatible — existing callers just ignore the return
> value."

> "The prototype methods use `function(){}` callbacks throughout, which has
> already caused 5+ `this` binding bugs in this file. Migrating to ES6 classes
> with arrow functions eliminates this category structurally rather than
> relying on every developer to remember `.bind(this)`. I'd prioritize this
> refactor because it fixes multiple bugs simultaneously."

Don't propose refactors in isolation. Tie them to bugs you already found.

---

## 6. Other Repeat Patterns

```js
// splice(-1) — check EVERY indexOf + splice pair
var idx = arr.indexOf(val);
arr.splice(idx, 1);  // if not found: splice(-1,1) removes LAST element
// Fix: if (idx !== -1) arr.splice(idx, 1);

// Off-by-one — check EVERY for loop
for (var i = 0; i <= arr.length; i++)  // BUG: reads arr[arr.length] = undefined
for (var i = 0; i < arr.length; i++)   // correct
// DON'T flag correct loops as buggy — verify before calling it out
```

## 6. Review Strategy (50 minutes)

**Pass 1 — Full scan (20 min):** Read top to bottom. Flag everything.

**Pass 2 — Pattern sweep (15 min):** Ctrl+F for each:
`innerHTML`, `function ()` in methods, `indexOf`+`splice`, `<= *.length`,
`.sort(`, `/ ` (division), `setInterval`/`setTimeout`, `.send(`, `for...in`

**Pass 3 — Narrate (15 min):** For each finding:
1. The bug (one sentence)
2. What breaks (concrete scenario)
3. The fix (one sentence)
4. Severity (P0/P1/P2)
