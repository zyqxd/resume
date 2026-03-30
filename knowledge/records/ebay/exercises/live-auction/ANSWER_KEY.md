# Answer Key — Live Auction Code Review

## Bugs

### 1. `this` binding lost in all WebSocket callbacks (Lines 46–63)
**Severity: P0 — app won't function at all**

All `onopen`, `onmessage`, `onclose`, `onerror` handlers use `function(){}`,
so `this` refers to the WebSocket, not the AuctionManager.

```js
// BUG
this.socket.onopen = function () {
  this.reconnectAttempts = 0; // `this` = WebSocket, not AuctionManager
};

// FIX: arrow functions or .bind(this)
this.socket.onopen = () => {
  this.reconnectAttempts = 0;
};
```

### 2. `this` binding lost in `reconnect` setTimeout (Lines 68–73)
**Severity: P0 — reconnection will never work**

```js
// BUG
setTimeout(function () {
  this.connect(); // `this` = window
}, delay);

// FIX
setTimeout(() => {
  this.connect();
}, delay);
```

### 3. Off-by-one in `emit` loop (Line 96)
**Severity: P0 — crashes every event emission**

```js
// BUG: <= causes index out of bounds, callbacks[callbacks.length] is undefined
for (var i = 0; i <= callbacks.length; i++) {
  callbacks[i](data); // TypeError on last iteration
}

// FIX
for (var i = 0; i < callbacks.length; i++) {
```

### 4. `this` binding lost in card click handler (Line 175)
**Severity: P1 — clicking auction cards crashes**

```js
// BUG: `this` inside addEventListener refers to the DOM element
card.addEventListener("click", function () {
  this.showAuctionDetail(auction); // `this` = card element
});

// FIX
card.addEventListener("click", () => {
  this.showAuctionDetail(auction);
});
// or: .bind(this)
```

### 5. `getActiveBids` uses `==` with `false` (Line 129)
**Severity: P1 — returns wrong results**

```js
// BUG: == false matches 0, "", null, undefined (not just false)
// An auction with ended=undefined would NOT match == false
if (this.auctions[id].ended == false) {

// FIX: explicit check
if (this.auctions[id].ended !== true) {
// or: if (!this.auctions[id].ended) {
```

### 6. `removeWatcher` crashes if userId not found (Lines 137–139)
**Severity: P2 — crashes on invalid input**

```js
// BUG: indexOf returns -1 if not found, splice(-1, 1) removes last element
var index = this.watchers.indexOf(userId);
this.watchers.splice(index, 1); // removes wrong element!

// FIX
var index = this.watchers.indexOf(userId);
if (index !== -1) {
  this.watchers.splice(index, 1);
}
```

### 7. `getTopBidders` sorts ascending instead of descending (Line 296)
**Severity: P2 — returns bottom bidders, not top**

```js
// BUG: a[1] - b[1] is ascending
var sorted = Object.entries(bidderCounts).sort(function (a, b) {
  return a[1] - b[1];
});

// FIX: descending
return b[1] - a[1];
```

### 8. `getAverageBid` divides by zero when no bids (Line 280)
**Severity: P2 — returns NaN**

```js
// BUG: if bids.length === 0, returns 0/0 = NaN
return total / bids.length;

// FIX
if (bids.length === 0) return 0;
return total / bids.length;
```

### 9. `debounce` loses `this` context (Lines 361–369)
**Severity: P2 — `this` inside debounced function is wrong**

```js
// BUG: `this` inside setTimeout callback is window, not the caller
timer = setTimeout(function () {
  fn.apply(this, args); // `this` = window
}, delay);

// FIX: capture context
return function () {
  var context = this;
  var args = arguments;
  clearTimeout(timer);
  timer = setTimeout(function () {
    fn.apply(context, args);
  }, delay);
};
```

### 10. `placeBid` doesn't validate auction exists (Lines 113–123)
**Severity: P2 — crashes with TypeError if auction not found**

```js
// BUG: no null check on auction
var auction = this.auctions[auctionId];
if (amount > auction.currentBid) { // TypeError if auction is undefined

// FIX
if (!auction) return;
```

### 11. `parseInt` for bid amount loses decimal precision (Line 388)
**Severity: P2 — bids of $10.50 become $10**

```js
// BUG
var amount = parseInt(input.value);

// FIX
var amount = parseFloat(input.value);
// Also: validate it's a positive number
```

---

## Security Vulnerabilities

### 12. XSS via `innerHTML` with auction data (Lines 161–174)
**Severity: P0 — stored XSS**

Auction titles, descriptions, and image URLs come from the server (potentially
user-submitted data) and are injected directly via `innerHTML`. An attacker
could set a title to `<img src=x onerror="steal(document.cookie)">`.

```js
// BUG
card.innerHTML = '...<h3>' + auction.title + '</h3>...'

// FIX: use textContent or sanitize all user-provided fields
var titleEl = document.createElement("h3");
titleEl.textContent = auction.title;
```

### 13. XSS in chat messages (Lines 259–262)
**Severity: P0 — stored XSS from any user**

Chat messages from other users rendered via `innerHTML` with no sanitization.

```js
// BUG
messageDiv.innerHTML = '<span class="chat-user">' + data.username + ':</span> '
  + '<span class="chat-text">' + data.message + '</span>';

// FIX: use textContent
```

### 14. XSS in notifications (Lines 324–325)
**Severity: P0 — XSS via bid data**

```js
// BUG: data.userId is user-controlled
notification.innerHTML = message; // where message contains data.userId

// FIX: use textContent, or sanitize before building message
```

### 15. XSS via `onclick` attribute with unsanitized auction ID (Line 190)
**Severity: P0 — XSS via crafted auction ID**

```js
// BUG: auction.id could contain: '); stealCookies(); //
'<button onclick="placeBid(\'' + auction.id + '\');">Place Bid</button>'

// FIX: use addEventListener instead of inline onclick
```

### 16. Prototype pollution in `deepMerge` (Lines 343–352)
**Severity: P1 — can pollute all object prototypes**

```js
// BUG: uses for...in which includes inherited properties,
// and doesn't guard against __proto__, constructor, prototype
deepMerge({}, JSON.parse('{"__proto__":{"isAdmin":true}}'));

// FIX: use Object.keys() and guard against dangerous keys
```

### 17. Incomplete `sanitizeInput` (Lines 354–356)
**Severity: P1 — doesn't sanitize quotes, ampersands, or other vectors**

```js
// BUG: only escapes < and >, misses " ' ` & and event handlers
return input.replace(/</g, "&lt;").replace(/>/g, "&gt;");

// FIX: also escape &, ", ' at minimum
// Better: use a proper sanitization library or textContent
```

---

## Memory Leaks

### 18. Timers never cleared in `AuctionRenderer.destroy` (Line 234)
**Severity: P1 — leaked intervals accumulate**

```js
// BUG: destroy clears DOM but doesn't clear intervals
AuctionRenderer.prototype.destroy = function () {
  this.container.innerHTML = "";
  // Missing: timer cleanup
};

// FIX
AuctionRenderer.prototype.destroy = function () {
  this.timers.forEach(clearInterval);
  this.timers = [];
  this.container.innerHTML = "";
};
```

### 19. `bidHistory` grows unbounded (Line 104)
**Severity: P1 — memory grows forever in long sessions**

`BID_HISTORY_LIMIT` is defined (line 19) but never enforced.

```js
// FIX: add after push
if (this.bidHistory.length > BID_HISTORY_LIMIT) {
  this.bidHistory.shift();
}
```

### 20. `elements` array keeps references to removed DOM nodes (Line 179)
**Severity: P2 — prevents GC of old auction cards**

Cards are pushed to `this.elements` but never removed, even after
`renderAuctionList` clears the container with `innerHTML = ""`.

```js
// FIX: clear the array when re-rendering
AuctionRenderer.prototype.renderAuctionList = function (auctions) {
  this.elements = [];
  this.container.innerHTML = "";
  // ...
};
```

### 21. Event listeners not cleaned up in `AuctionManager.destroy` (Line 143)
**Severity: P2 — listener callbacks hold references**

```js
// BUG: listeners still reference the manager
AuctionManager.prototype.destroy = function () {
  this.socket.close();
  this.auctions = {};
  // Missing: this.listeners = {}; this.bidHistory = []; this.watchers = [];
};
```

---

## Performance

### 22. Search cache is never invalidated (Lines 241–257)
**Severity: P1 — stale results after new bids/auctions**

When a new auction starts or a bid changes, cached search results are stale
but still returned.

```js
// FIX: invalidate cache on data changes
AuctionManager.prototype.processBid = function (data) {
  // ... existing logic ...
  this.searchCache = {}; // or use a more granular approach
};
```

### 23. `sortByEndTime` mutates the original array (Line 267)
**Severity: P2 — side effect in a "getter" method**

```js
// BUG: .sort() mutates in place
return auctions.sort(function (a, b) { ... });

// FIX: copy first
return [...auctions].sort(function (a, b) { ... });
// or: auctions.slice().sort(...)
```

### 24. `renderBidHistory` re-renders everything on each call (Lines 195–211)
**Severity: P2 — O(n) DOM operations on every bid**

With 100+ bids, this rebuilds the entire list each time. Should append
only the new bid.

---

## Missing Error Handling

### 25. No error handling on fetch or WebSocket send (Lines 113, 375)
**Severity: P1 — silent failures**

- `placeBid` calls `socket.send` without checking socket state (OPEN)
- Initial fetch has no `.catch()` handler
- No validation on bid amount (NaN, negative, non-numeric)

```js
// FIX: check socket state
AuctionManager.prototype.placeBid = function (auctionId, amount) {
  if (this.socket.readyState !== WebSocket.OPEN) {
    throw new Error("Not connected");
  }
  // ... validate amount ...
};

// FIX: add catch to fetch
fetch(API_BASE + "/auctions/active")
  .then(function (response) {
    if (!response.ok) throw new Error("HTTP " + response.status);
    return response.json();
  })
  .then(...)
  .catch(function (err) {
    console.error("Failed to load auctions:", err);
    // Show error state to user
  });
```

---

## WebSocket Bugs (ConnectionMonitor & LiveStreamSync)

### 26. `this` binding lost in `startPing` setInterval and nested setTimeout
**Severity: P0 — heartbeat never works**

Both the `setInterval` callback and the nested `setTimeout` use `function(){}`,
so `this` is `window`, not the ConnectionMonitor.

```js
// BUG
this.pingInterval = setInterval(function () {
  this.manager.socket.send(...); // this = window
  setTimeout(function () {
    if (Date.now() - this.lastPongTime > 10000) { // this = window
      ...
    }
  }, 5000);
}, 30000);

// FIX: use arrow functions
this.pingInterval = setInterval(() => {
  this.manager.socket.send(...);
  setTimeout(() => {
    if (Date.now() - this.lastPongTime > 10000) {
      ...
    }
  }, 5000);
}, 30000);
```

### 27. No readyState check before sending ping
**Severity: P1 — crashes if socket is closed/closing**

`startPing` calls `socket.send()` without checking that the socket is open.
During reconnection, the socket may be in CONNECTING or CLOSED state.

```js
// FIX
if (this.manager.socket.readyState === WebSocket.OPEN) {
  this.manager.socket.send(...);
}
```

### 28. `lastPongTime` is null on first check
**Severity: P1 — false positive stale detection**

`lastPongTime` starts as `null`. After 30s, the setTimeout fires and
`Date.now() - null` evaluates to `Date.now()` (coercion: `null → 0`),
which is always > 10000. The connection will be killed even if it's healthy.

```js
// FIX: initialize lastPongTime on connect
ConnectionMonitor.prototype.onConnected = function () {
  this.lastPongTime = Date.now(); // set baseline
  this.status = "connected";
  ...
};
```

### 29. `destroy` doesn't clear the ping interval
**Severity: P1 — leaked interval, pings sent on dead connection**

```js
// BUG
ConnectionMonitor.prototype.destroy = function () {
  this.status = "disconnected";
  this.updateStatusUI();
  // Missing: clearInterval(this.pingInterval);
};

// FIX
ConnectionMonitor.prototype.destroy = function () {
  clearInterval(this.pingInterval);
  this.status = "disconnected";
  this.updateStatusUI();
};
```

### 30. `handleMessage` processes duplicates instead of skipping them
**Severity: P1 — duplicate bids/events processed**

When `data.seq <= this.lastSequence`, the message is a duplicate or
out-of-order, but it's still passed to `processMessage`.

```js
// BUG: should skip duplicates
if (data.seq <= this.lastSequence) {
  this.processMessage(data); // processes duplicate!
  return;
}

// FIX: skip
if (data.seq <= this.lastSequence) {
  return; // already processed
}
```

### 31. Off-by-one in `resubscribeAll` loop
**Severity: P1 — crashes on resubscription after reconnect**

Same off-by-one as the `emit` loop: `<=` instead of `<`.
On the last iteration, `this.subscriptions[length]` is `undefined`,
and `JSON.stringify` will send `"channel":null` to the server.

```js
// BUG
for (var i = 0; i <= this.subscriptions.length; i++) {

// FIX
for (var i = 0; i < this.subscriptions.length; i++) {
```

### 32. `unsubscribe` has same splice(-1) bug as `removeWatcher`
**Severity: P2 — removes wrong subscription if channel not found**

```js
// BUG: indexOf returns -1, splice(-1, 1) removes last element
var idx = this.subscriptions.indexOf(channel);
this.subscriptions.splice(idx, 1);

// FIX
if (idx !== -1) {
  this.subscriptions.splice(idx, 1);
}
```

### 33. `flushQueue` uses pop() — sends messages in reverse order
**Severity: P2 — message ordering violated**

```js
// BUG: pop() takes from the end — LIFO instead of FIFO
while (this.pendingMessages.length > 0) {
  this.manager.socket.send(this.pendingMessages.pop());
}

// FIX: use shift() for FIFO ordering
this.manager.socket.send(this.pendingMessages.shift());
```

### 34. `flushQueue` doesn't check socket readyState
**Severity: P1 — crashes if called while socket is not open**

Called on "connected" event, but if multiple listeners race or the
socket closes mid-flush, `send()` will throw.

```js
// FIX
LiveStreamSync.prototype.flushQueue = function () {
  while (
    this.pendingMessages.length > 0 &&
    this.manager.socket.readyState === WebSocket.OPEN
  ) {
    this.manager.socket.send(this.pendingMessages.shift());
  }
};
```

### 35. `requestReplay` timeout has `this` binding bug
**Severity: P2 — replayInProgress flag never resets**

```js
// BUG
setTimeout(function () {
  this.replayInProgress = false; // this = window
}, 10000);

// FIX
setTimeout(() => {
  this.replayInProgress = false;
}, 10000);
```

### 36. No backpressure check before sending in `flushQueue`
**Severity: P2 — can flood the socket buffer**

After reconnect, all queued messages are flushed at once without checking
`bufferedAmount`. Ironic since `getBufferStatus` exists but is never used.

```js
// FIX: check buffer before each send
if (this.manager.socket.bufferedAmount > 1024 * 1024) {
  break; // retry remaining messages later
}
```

### 37. Subscriptions use array — duplicate subscriptions possible
**Severity: P2 — subscribe("auction-1") twice = resubscribed twice on reconnect**

```js
// BUG: push allows duplicates
this.subscriptions.push(channel);

// FIX: use a Set, or check before push
if (this.subscriptions.indexOf(channel) === -1) {
  this.subscriptions.push(channel);
}
// Better: this.subscriptions = new Set();
```

---

## Architectural / Refactoring Suggestions

1. **Use `const`/`let` everywhere** — all `var` declarations risk hoisting bugs
   and implicit sharing

2. **Use ES6 classes** — the prototype-based code is harder to read and
   error-prone (especially `this` binding); classes + arrow methods solve many
   bugs above

3. **Separate concerns** — rendering logic is mixed with data management
   (e.g., `ChatManager.renderMessage`). Extract a view layer

4. **Add an unsubscribe mechanism to `on()`** — currently no way to remove
   event listeners, leading to leaks

5. **Replace the global `placeBid` function** — `window.placeBid` is a code
   smell; use proper event delegation or module-scoped handlers

6. **Fix the heartbeat implementation** — the current ConnectionMonitor has
   the right idea but the wrong execution. Needs proper `this` binding,
   readyState checks, and initial pong time

7. **Add exponential backoff with jitter** — the linear backoff
   (`1000 * attempts`) causes thundering herd when many clients reconnect
   simultaneously

8. **Use `AbortController`** for fetch requests to support cancellation

9. **Consider a virtual scrolling approach** for bid history and auction lists
   at scale

10. **Add TypeScript** — most `this` binding and null-reference bugs would be
    caught at compile time

11. **Use a Set for subscriptions** — prevents duplicates and gives O(1)
    has/delete instead of indexOf

12. **Add message deduplication with an ID-based set** instead of relying
    purely on sequence numbers, which break across reconnections

13. **Handle `beforeunload`** — close the WebSocket cleanly when the user
    navigates away to avoid server-side resource leaks

---

## Summary by Category

| Category | Count | P0 | P1 | P2 |
|---|---|---|---|---|
| Bugs | 11 | 3 | 2 | 6 |
| Security | 6 | 4 | 2 | 0 |
| Memory Leaks | 4 | 0 | 2 | 2 |
| Performance | 3 | 0 | 1 | 2 |
| Error Handling | 1 | 0 | 1 | 0 |
| WebSocket | 12 | 1 | 5 | 5 |
| **Total** | **37** | **8** | **13** | **15** |
