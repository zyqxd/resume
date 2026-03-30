# eBay Staff Frontend Engineer — Debugging/Refactoring Prep

## 1. `this` Binding

```js
// Arrow functions inherit `this` from enclosing scope
// Regular functions get `this` from call site

const obj = {
  name: "eBay",
  // BUG: `this` is undefined/window in the callback
  fetchBad() {
    setTimeout(function () {
      console.log(this.name); // undefined
    }, 100);
  },
  // FIX 1: arrow function
  fetchGood() {
    setTimeout(() => {
      console.log(this.name); // "eBay"
    }, 100);
  },
  // FIX 2: bind
  fetchBound() {
    setTimeout(
      function () {
        console.log(this.name);
      }.bind(this),
      100
    );
  },
};

// call / apply / bind
function greet(greeting) {
  return `${greeting}, ${this.name}`;
}
greet.call({ name: "David" }, "Hello"); // "Hello, David"
greet.apply({ name: "David" }, ["Hello"]); // same
const bound = greet.bind({ name: "David" });
bound("Hello"); // same

// Class methods lose context when extracted
class Button {
  constructor(label) {
    this.label = label;
  }
  // BUG: `this` lost when passed as callback
  handleClick() {
    console.log(this.label);
  }
}
const btn = new Button("Submit");
document.addEventListener("click", btn.handleClick); // undefined!
document.addEventListener("click", btn.handleClick.bind(btn)); // fix
document.addEventListener("click", () => btn.handleClick()); // fix
```

---

## 2. Prototypal Inheritance

```js
// `class` is syntactic sugar over prototypes
function Animal(name) {
  this.name = name;
}
Animal.prototype.speak = function () {
  return `${this.name} makes a sound`;
};

function Dog(name, breed) {
  Animal.call(this, name); // super()
  this.breed = breed;
}
Dog.prototype = Object.create(Animal.prototype);
Dog.prototype.constructor = Dog;

Dog.prototype.fetch = function () {
  return `${this.name} fetches the ball`;
};

const rex = new Dog("Rex", "Lab");
rex.speak(); // "Rex makes a sound" — walks up prototype chain
rex.fetch(); // "Rex fetches the ball"

// Prototype chain inspection
rex.__proto__ === Dog.prototype; // true
Dog.prototype.__proto__ === Animal.prototype; // true

// Object.create for delegation without constructors
const base = {
  init(name) {
    this.name = name;
    return this;
  },
  greet() {
    return `Hi, ${this.name}`;
  },
};
const child = Object.create(base).init("David");
child.greet(); // "Hi, David"
```

---

## 3. Closures & Scope

```js
// Encapsulation via closures
function createCounter() {
  let count = 0; // private
  return {
    increment() {
      return ++count;
    },
    getCount() {
      return count;
    },
  };
}
const counter = createCounter();
counter.increment(); // 1
counter.count; // undefined — truly private

// CLASSIC BUG: loop variable capture
for (var i = 0; i < 3; i++) {
  setTimeout(() => console.log(i), 100);
}
// prints: 3, 3, 3 — `var` is function-scoped, single binding shared

// FIX 1: use `let` (block-scoped, new binding per iteration)
for (let i = 0; i < 3; i++) {
  setTimeout(() => console.log(i), 100);
}
// prints: 0, 1, 2

// FIX 2: IIFE (if stuck with var)
for (var i = 0; i < 3; i++) {
  (function (j) {
    setTimeout(() => console.log(j), 100);
  })(i);
}

// Closure-based memoization
function memoize(fn) {
  const cache = new Map();
  return function (...args) {
    const key = JSON.stringify(args);
    if (cache.has(key)) return cache.get(key);
    const result = fn.apply(this, args);
    cache.set(key, result);
    return result;
  };
}
```

---

## 4. Coercion & Equality

```js
// == performs type coercion, === does not
0 == false; // true
0 === false; // false
"" == false; // true
null == undefined; // true  (special case — they only equal each other)
null === undefined; // false
NaN === NaN; // false — use Number.isNaN()

// Truthy/falsy: these are ALL the falsy values
// false, 0, -0, 0n, "", null, undefined, NaN
// Everything else is truthy, including: [], {}, "0", "false"

!![];        // true  — empty array is truthy!
[] == false; // true  — coercion: [] → "" → 0 → false
"0" == false; // true — "0" → 0, false → 0

// typeof quirks
typeof null;        // "object" (historic bug)
typeof undefined;   // "undefined"
typeof NaN;         // "number"
typeof [];          // "object" — use Array.isArray()
typeof function(){}; // "function"

// instanceof walks the prototype chain
[] instanceof Array;  // true
[] instanceof Object; // true

// Safe checks
Number.isNaN(NaN);        // true (better than isNaN("hello") which is true)
Number.isFinite(Infinity); // false
Object.is(NaN, NaN);      // true
Object.is(0, -0);         // false
```

---

## 5. Event Loop

```js
// Execution order: sync → microtasks → macrotasks

console.log("1 - sync");

setTimeout(() => console.log("2 - macrotask (setTimeout)"), 0);

Promise.resolve().then(() => console.log("3 - microtask (promise)"));

queueMicrotask(() => console.log("4 - microtask (queueMicrotask)"));

console.log("5 - sync");

// Output: 1, 5, 3, 4, 2
// Sync runs first, then ALL microtasks drain, then one macrotask

// Nested microtasks execute before any macrotask
Promise.resolve().then(() => {
  console.log("A");
  Promise.resolve().then(() => console.log("B"));
});
setTimeout(() => console.log("C"), 0);
// Output: A, B, C — nested microtask B runs before macrotask C

// requestAnimationFrame — runs before next paint, after microtasks
requestAnimationFrame(() => {
  console.log("rAF — before next paint");
  // batch DOM reads/writes here
});

// Starving the macrotask queue (anti-pattern)
function blockForever() {
  Promise.resolve().then(blockForever); // never yields to setTimeout
}
```

---

## 6. Error Handling

```js
// Async/await — try/catch works naturally
async function fetchData(url) {
  try {
    const res = await fetch(url);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return await res.json();
  } catch (err) {
    console.error("Fetch failed:", err.message);
    throw err; // re-throw if caller should handle
  }
}

// Promise chains — .catch() at the end
fetch("/api")
  .then((r) => r.json())
  .then((data) => process(data))
  .catch((err) => console.error(err)); // catches any rejection above

// BUG: swallowed error — no catch, no handler
async function leaky() {
  const data = fetch("/api").then((r) => r.json());
  // missing await AND missing catch — silent failure
}

// Global safety nets (don't rely on these — fix the root cause)
window.addEventListener("unhandledrejection", (e) => {
  console.error("Unhandled promise rejection:", e.reason);
});
window.addEventListener("error", (e) => {
  console.error("Uncaught error:", e.error);
});

// Custom error types for better debugging
class ValidationError extends Error {
  constructor(field, message) {
    super(message);
    this.name = "ValidationError";
    this.field = field;
  }
}

// Finally for cleanup
async function withCleanup() {
  const resource = acquire();
  try {
    await resource.process();
  } finally {
    resource.release(); // runs whether success or error
  }
}
```

---

## 7. Common Bug Patterns

```js
// Off-by-one
const items = [1, 2, 3];
// BUG: <= should be <
for (let i = 0; i <= items.length; i++) {
  console.log(items[i]); // last iteration: undefined
}

// Stale closure
function createButtons() {
  let count = 0;
  const button = document.createElement("button");
  const display = document.createElement("span");

  button.addEventListener("click", () => {
    count++;
    // BUG if display.textContent was captured as a variable
    // instead of reading from DOM each time
  });
}

// Memory leak: forgotten interval
function startPolling() {
  // BUG: no way to stop this
  setInterval(() => fetch("/api/status"), 5000);

  // FIX: return cleanup function
  const id = setInterval(() => fetch("/api/status"), 5000);
  return () => clearInterval(id);
}

// Memory leak: detached DOM nodes
let cache = [];
function renderItem(data) {
  const el = document.createElement("div");
  el.textContent = data;
  cache.push(el); // holds reference even after el removed from DOM
  return el;
}

// Memory leak: event listeners on removed elements
function showModal() {
  const modal = document.createElement("div");
  const handler = () => console.log("resize");
  window.addEventListener("resize", handler);
  document.body.appendChild(modal);

  return {
    destroy() {
      modal.remove();
      window.removeEventListener("resize", handler); // must clean up!
    },
  };
}
```

---

## 8. Reading Code for Side Effects

```js
// Implicit global (missing declaration)
function process(items) {
  // BUG: `result` leaks to global scope
  result = [];
  for (const item of items) {
    result.push(transform(item));
  }
  return result;
}
// FIX: const result = [];
// "use strict" would throw ReferenceError on implicit globals

// Unintended reference sharing / mutation
function addDefaults(options) {
  const defaults = { theme: "light", lang: "en", features: ["search"] };
  // BUG: shallow merge — nested objects shared
  const config = Object.assign({}, defaults, options);
  config.features.push("filter"); // mutates defaults.features!

  // FIX: deep clone or spread nested
  const config2 = {
    ...defaults,
    ...options,
    features: [...defaults.features, ...(options.features || [])],
  };
}

// Mutation through function arguments
function sortAndReturn(arr) {
  return arr.sort(); // BUG: .sort() mutates original array
}
const original = [3, 1, 2];
const sorted = sortAndReturn(original);
console.log(original); // [1, 2, 3] — mutated!
// FIX: return [...arr].sort(); or arr.toSorted()

// Hidden mutation via array methods
// Mutating: push, pop, shift, unshift, splice, sort, reverse, fill
// Non-mutating: map, filter, slice, concat, flat, toSorted, toReversed, toSpliced
```

---

## 9. Async Bugs

```js
// Missing await
async function loadUser(id) {
  // BUG: returns Promise, not the data
  const user = fetch(`/api/users/${id}`).then((r) => r.json());
  console.log(user.name); // undefined — user is a Promise
  // FIX: const user = await fetch(...).then(r => r.json());
}

// Sequential when it should be parallel
async function loadDashboard() {
  // BAD: sequential — each waits for the previous
  const users = await fetchUsers();
  const orders = await fetchOrders();
  const stats = await fetchStats();

  // GOOD: parallel — all fire at once
  const [users2, orders2, stats2] = await Promise.all([
    fetchUsers(),
    fetchOrders(),
    fetchStats(),
  ]);
}

// Error swallowing in .then chains
fetch("/api/data")
  .then((res) => {
    // BUG: if this throws, the error vanishes
    return res.json();
  })
  .then((data) => {
    processData(data); // if this throws, also swallowed
  });
// no .catch() — silent failure

// Race condition: response ordering
let currentQuery = "";
async function search(query) {
  currentQuery = query;
  const results = await fetch(`/api/search?q=${query}`).then((r) => r.json());
  // BUG: slow "aa" response arrives after fast "aab" response
  // overwrites newer results with stale data
  renderResults(results);

  // FIX: check if still current
  if (query === currentQuery) {
    renderResults(results);
  }
}

// Better FIX: AbortController
let controller = null;
async function searchFixed(query) {
  controller?.abort();
  controller = new AbortController();
  try {
    const res = await fetch(`/api/search?q=${query}`, {
      signal: controller.signal,
    });
    renderResults(await res.json());
  } catch (err) {
    if (err.name !== "AbortError") throw err;
  }
}
```

---

## 10. Performance

```js
// Debounce — wait until user stops, then fire once
function debounce(fn, ms) {
  let timer;
  return function (...args) {
    clearTimeout(timer);
    timer = setTimeout(() => fn.apply(this, args), ms);
  };
}
input.addEventListener("input", debounce(handleSearch, 300));

// Throttle — fire at most once per interval
function throttle(fn, ms) {
  let last = 0;
  return function (...args) {
    const now = Date.now();
    if (now - last >= ms) {
      last = now;
      fn.apply(this, args);
    }
  };
}
window.addEventListener("scroll", throttle(handleScroll, 100));

// Layout thrashing — interleaving reads and writes forces reflow
// BAD:
elements.forEach((el) => {
  const height = el.offsetHeight; // READ — forces layout
  el.style.height = height * 2 + "px"; // WRITE — invalidates layout
  // next iteration's READ forces another layout
});
// GOOD: batch reads, then batch writes
const heights = elements.map((el) => el.offsetHeight); // all reads
elements.forEach((el, i) => {
  el.style.height = heights[i] * 2 + "px"; // all writes
});

// DocumentFragment — batch DOM insertions
const fragment = document.createDocumentFragment();
for (let i = 0; i < 1000; i++) {
  const li = document.createElement("li");
  li.textContent = `Item ${i}`;
  fragment.appendChild(li); // no reflow per item
}
document.getElementById("list").appendChild(fragment); // single reflow

// Lazy loading images
const img = document.createElement("img");
img.loading = "lazy"; // native lazy loading
img.src = "photo.jpg";

// IntersectionObserver for custom lazy behavior
const observer = new IntersectionObserver((entries) => {
  entries.forEach((entry) => {
    if (entry.isIntersecting) {
      entry.target.src = entry.target.dataset.src;
      observer.unobserve(entry.target);
    }
  });
});
document.querySelectorAll("img[data-src]").forEach((img) => observer.observe(img));
```

---

## 11. DOM API Fluency

```js
// Querying
document.querySelector(".card"); // first match
document.querySelectorAll(".card"); // NodeList (not live)
document.getElementById("app"); // by ID

// Event delegation — one listener for many children
document.getElementById("list").addEventListener("click", (e) => {
  const item = e.target.closest("li"); // find ancestor matching selector
  if (!item) return;
  console.log("Clicked item:", item.dataset.id);
});
// Why: fewer listeners, works for dynamically added items

// Creating and modifying DOM
const div = document.createElement("div");
div.className = "card";
div.dataset.id = "42"; // data-id="42"
div.textContent = "Safe from XSS"; // escapes HTML
// div.innerHTML = userInput; // DANGER — XSS vector

// MutationObserver — watch for DOM changes
const observer = new MutationObserver((mutations) => {
  for (const m of mutations) {
    if (m.type === "childList") {
      console.log("Children changed:", m.addedNodes, m.removedNodes);
    }
    if (m.type === "attributes") {
      console.log(`${m.attributeName} changed`);
    }
  }
});
observer.observe(document.getElementById("app"), {
  childList: true,
  attributes: true,
  subtree: true,
});
// Don't forget: observer.disconnect() when done

// classList API
element.classList.add("active");
element.classList.remove("hidden");
element.classList.toggle("open");
element.classList.contains("active"); // boolean
```

---

## 12. Memory Management

```js
// WeakMap — keys are weakly held, GC'd when no other references
const metadata = new WeakMap();
function trackElement(el) {
  metadata.set(el, { created: Date.now(), clicks: 0 });
  // when `el` is removed and dereferenced, entry is auto-GC'd
}
// Use cases: caching, private data, DOM-associated state

// WeakSet — track objects without preventing GC
const seen = new WeakSet();
function processOnce(obj) {
  if (seen.has(obj)) return;
  seen.add(obj);
  // process...
}

// WeakRef — hold a reference that doesn't prevent GC
const ref = new WeakRef(someLargeObject);
// later...
const obj = ref.deref(); // returns object or undefined if GC'd
if (obj) {
  // still alive, use it
}

// AbortController — cancel fetch and clean up
const controller = new AbortController();
fetch("/api/data", { signal: controller.signal })
  .then((r) => r.json())
  .catch((err) => {
    if (err.name === "AbortError") return; // expected
    throw err;
  });
// Cancel when no longer needed (component unmount, navigation, etc.)
controller.abort();

// Cleaning up subscriptions pattern
function setupWidget(element) {
  const controller = new AbortController();
  const { signal } = controller;

  element.addEventListener("click", handleClick, { signal });
  window.addEventListener("resize", handleResize, { signal });
  const interval = setInterval(poll, 5000);

  // Single cleanup call removes everything
  return () => {
    controller.abort(); // removes both event listeners
    clearInterval(interval);
  };
}
```

---

## 13. Design Patterns in JS

```js
// Observer / Pub-Sub
class EventBus {
  #listeners = new Map();

  on(event, fn) {
    if (!this.#listeners.has(event)) this.#listeners.set(event, new Set());
    this.#listeners.get(event).add(fn);
    return () => this.#listeners.get(event).delete(fn); // unsubscribe
  }

  emit(event, ...args) {
    this.#listeners.get(event)?.forEach((fn) => fn(...args));
  }
}
const bus = new EventBus();
const unsub = bus.on("update", (data) => console.log(data));
bus.emit("update", { id: 1 });
unsub(); // clean up

// Module pattern (pre-ES modules, still seen in legacy code)
const CartModule = (function () {
  const items = []; // private

  return {
    add(item) {
      items.push(item);
    },
    getTotal() {
      return items.reduce((sum, i) => sum + i.price, 0);
    },
  };
})();

// Strategy pattern
const validators = {
  email: (v) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v),
  phone: (v) => /^\+?[\d\s-]{10,}$/.test(v),
  required: (v) => v != null && v !== "",
};

function validate(value, rules) {
  return rules.every((rule) => validators[rule](value));
}
validate("test@x.com", ["required", "email"]); // true

// Factory pattern
function createLogger(transport) {
  const transports = {
    console: (msg) => console.log(msg),
    file: (msg) => fs.appendFileSync("log.txt", msg + "\n"),
    remote: (msg) => fetch("/logs", { method: "POST", body: msg }),
  };

  const log = transports[transport];
  if (!log) throw new Error(`Unknown transport: ${transport}`);

  return {
    info: (msg) => log(`[INFO] ${msg}`),
    error: (msg) => log(`[ERROR] ${msg}`),
  };
}
```

---

## 14. Security

```js
// XSS — the #1 frontend vulnerability

// BAD: innerHTML with user input
element.innerHTML = `<h1>Welcome, ${userInput}</h1>`;
// If userInput = '<img src=x onerror="steal(document.cookie)">' → XSS

// GOOD: textContent (escapes everything)
element.textContent = userInput;

// GOOD: create elements programmatically
const h1 = document.createElement("h1");
h1.textContent = `Welcome, ${userInput}`;
element.appendChild(h1);

// If you MUST use innerHTML, sanitize
function sanitize(str) {
  const div = document.createElement("div");
  div.textContent = str;
  return div.innerHTML; // HTML-entity-encoded
}

// Prototype pollution
// BAD: recursive merge without checks
function deepMerge(target, source) {
  for (const key in source) {
    if (typeof source[key] === "object") {
      target[key] = deepMerge(target[key] || {}, source[key]);
    } else {
      target[key] = source[key];
    }
  }
  return target;
}
// Attack: deepMerge({}, JSON.parse('{"__proto__":{"isAdmin":true}}'))
// Now ({}).isAdmin === true for ALL objects

// FIX: guard against prototype keys
function safeMerge(target, source) {
  for (const key of Object.keys(source)) {
    // Object.keys skips inherited props
    if (key === "__proto__" || key === "constructor" || key === "prototype") {
      continue;
    }
    if (
      typeof source[key] === "object" &&
      source[key] !== null &&
      !Array.isArray(source[key])
    ) {
      target[key] = safeMerge(target[key] || {}, source[key]);
    } else {
      target[key] = source[key];
    }
  }
  return target;
}

// Content Security Policy (CSP) — HTTP header
// Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'
// Prevents inline scripts, eval, and loading from untrusted origins
```

---

## 15. Scalability Patterns

```js
// Dynamic import / code splitting
async function loadEditor() {
  // Only loads when needed — reduces initial bundle
  const { Editor } = await import("./editor.js");
  return new Editor();
}
button.addEventListener("click", async () => {
  const editor = await loadEditor();
  editor.mount(document.getElementById("editor"));
});

// Service Worker basics (caching)
// In sw.js:
self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open("v1").then((cache) => {
      return cache.addAll(["/", "/styles.css", "/app.js"]);
    })
  );
});

self.addEventListener("fetch", (event) => {
  event.respondWith(
    caches.match(event.request).then((cached) => {
      // Cache-first strategy
      return cached || fetch(event.request);
    })
  );
});

// Stale-while-revalidate
self.addEventListener("fetch", (event) => {
  event.respondWith(
    caches.open("v1").then(async (cache) => {
      const cached = await cache.match(event.request);
      const fetching = fetch(event.request).then((response) => {
        cache.put(event.request, response.clone());
        return response;
      });
      return cached || fetching;
    })
  );
});

// Virtual scrolling concept (render only visible items)
function renderVisibleItems(container, allItems, itemHeight) {
  const scrollTop = container.scrollTop;
  const viewHeight = container.clientHeight;
  const startIdx = Math.floor(scrollTop / itemHeight);
  const endIdx = Math.min(
    startIdx + Math.ceil(viewHeight / itemHeight) + 1,
    allItems.length
  );

  container.innerHTML = "";
  const spacer = document.createElement("div");
  spacer.style.height = `${startIdx * itemHeight}px`;
  container.appendChild(spacer);

  for (let i = startIdx; i < endIdx; i++) {
    const el = document.createElement("div");
    el.style.height = `${itemHeight}px`;
    el.textContent = allItems[i];
    container.appendChild(el);
  }

  const bottomSpacer = document.createElement("div");
  bottomSpacer.style.height = `${(allItems.length - endIdx) * itemHeight}px`;
  container.appendChild(bottomSpacer);
}
```

---

## 16. Testability

```js
// Dependency injection without frameworks
// BAD: hard-coded dependency — can't test without hitting network
async function getUser(id) {
  const res = await fetch(`/api/users/${id}`);
  return res.json();
}

// GOOD: inject the fetcher
async function getUser(id, fetcher = fetch) {
  const res = await fetcher(`/api/users/${id}`);
  return res.json();
}
// In tests:
const mockFetcher = (url) =>
  Promise.resolve({ json: () => ({ id: 1, name: "Test" }) });
const user = await getUser(1, mockFetcher);

// Separating pure logic from side effects
// BAD: mixed concerns
function processOrder(order) {
  const total = order.items.reduce((s, i) => s + i.price * i.qty, 0);
  const tax = total * 0.13;
  fetch("/api/orders", {
    // side effect tangled in
    method: "POST",
    body: JSON.stringify({ ...order, total, tax }),
  });
  return { total, tax };
}

// GOOD: pure calculation separate from side effect
function calculateOrder(order) {
  const total = order.items.reduce((s, i) => s + i.price * i.qty, 0);
  const tax = total * 0.13;
  return { total, tax };
}
async function submitOrder(order) {
  const calc = calculateOrder(order);
  await fetch("/api/orders", {
    method: "POST",
    body: JSON.stringify({ ...order, ...calc }),
  });
  return calc;
}
// Now calculateOrder is trivially testable with no mocking

// What makes code hard to test:
// - Global state / singletons
// - new SomeClass() inside functions (can't swap)
// - Reading Date.now() or Math.random() directly
// - DOM manipulation mixed with business logic
// - Deeply nested callbacks
```

---

## 17–18. Staff-Level Framing

When identifying issues, structure your review around **impact**:

| Concern | Question to ask | Example comment |
|---|---|---|
| **Performance** | What happens at 10x data? | "This O(n²) loop is fine for 100 items but will block the main thread at 10k" |
| **Reliability** | What's the failure mode? | "If this fetch fails, we show a blank screen with no way to retry" |
| **Security** | Can a user control this input? | "This innerHTML with unsanitized input is an XSS vector" |
| **Maintainability** | Will someone understand this in 6 months? | "This implicit coupling between modules means changing A silently breaks B" |
| **Scalability** | What if 5 teams use this? | "Hardcoding this config means every consumer forks the code" |

**Mentoring frame**: Don't just say "this is wrong." Say:
- What the **current behavior** is
- What the **risk** is (with a concrete scenario)
- What the **fix** is and **why** it's better
- What **trade-off** you're making (if any)

---

## 19. Trade-off Articulation

Practice these in code reviews:

```
"I'd extract this into a shared utility, but since there's only one call site,
the indirection cost isn't worth it yet. If we see a second use, then we should."

"We could add a cache here, but the cache invalidation complexity outweighs
the performance gain for our current traffic. Worth revisiting at 10x."

"This is more verbose than a clever reduce, but the next person reading this
at 2am during an incident will thank us."

"Strict typing would catch this class of bug at compile time, but adding
TypeScript to this module right now would delay the feature. I'd add a
runtime check here and file a ticket for the migration."
```

---

## 20. Client-Side WebSocket Patterns

```js
// ============================================================
// Basic WebSocket lifecycle
// ============================================================

const ws = new WebSocket("wss://example.com/feed");

ws.addEventListener("open", () => {
  console.log("connected");
  ws.send(JSON.stringify({ type: "subscribe", channel: "auctions" }));
});

ws.addEventListener("message", (event) => {
  const data = JSON.parse(event.data); // can throw if not valid JSON
  handleMessage(data);
});

ws.addEventListener("close", (event) => {
  // event.code: 1000 = normal, 1006 = abnormal, 1001 = going away
  // event.reason: server-provided string
  console.log(`Closed: ${event.code} ${event.reason}`);
  // event.wasClean: true if server initiated clean close
});

ws.addEventListener("error", (event) => {
  // The error event has almost no info — always followed by close
  // Don't put retry logic here; put it in onclose
  console.error("WebSocket error");
});

// readyState constants
WebSocket.CONNECTING; // 0 — connection not yet open
WebSocket.OPEN;       // 1 — ready to send
WebSocket.CLOSING;    // 2 — close() called, not yet closed
WebSocket.CLOSED;     // 3 — connection is closed

// ALWAYS check readyState before sending
if (ws.readyState === WebSocket.OPEN) {
  ws.send(JSON.stringify(payload));
}

// ============================================================
// Reconnection with exponential backoff + jitter
// ============================================================

function createReconnectingSocket(url, options = {}) {
  const {
    maxRetries = 10,
    baseDelay = 1000,
    maxDelay = 30000,
    onMessage,
    onStatusChange,
  } = options;

  let ws = null;
  let retries = 0;
  let intentionallyClosed = false;
  let messageQueue = []; // buffer messages during reconnect

  function connect() {
    ws = new WebSocket(url);
    onStatusChange?.("connecting");

    ws.addEventListener("open", () => {
      retries = 0;
      onStatusChange?.("connected");

      // Flush queued messages
      while (messageQueue.length > 0) {
        ws.send(messageQueue.shift());
      }
    });

    ws.addEventListener("message", (event) => {
      try {
        const data = JSON.parse(event.data);
        onMessage?.(data);
      } catch (err) {
        console.error("Failed to parse WebSocket message:", err);
      }
    });

    ws.addEventListener("close", (event) => {
      onStatusChange?.("disconnected");

      if (intentionallyClosed) return;

      if (retries < maxRetries) {
        retries++;
        // Exponential backoff with jitter to prevent thundering herd
        const delay = Math.min(
          baseDelay * Math.pow(2, retries - 1) + Math.random() * 1000,
          maxDelay
        );
        console.log(`Reconnecting in ${Math.round(delay)}ms (attempt ${retries})`);
        setTimeout(connect, delay);
      } else {
        onStatusChange?.("failed");
        console.error("Max reconnection attempts reached");
      }
    });

    ws.addEventListener("error", () => {
      // error is always followed by close — reconnect logic lives there
    });
  }

  function send(data) {
    const msg = JSON.stringify(data);
    if (ws?.readyState === WebSocket.OPEN) {
      ws.send(msg);
    } else {
      // Queue for delivery after reconnect
      messageQueue.push(msg);
    }
  }

  function close() {
    intentionallyClosed = true;
    ws?.close(1000, "Client closing"); // 1000 = normal closure
  }

  connect();
  return { send, close };
}

// Usage
const socket = createReconnectingSocket("wss://api.example.com/live", {
  onMessage: (data) => console.log("Received:", data),
  onStatusChange: (status) => updateUI(status),
});
socket.send({ type: "bid", amount: 100 });

// ============================================================
// Heartbeat / keep-alive
// ============================================================

// Problem: some proxies/load balancers silently drop idle connections
// after 30-60s. Without heartbeat, the client doesn't know it's dead
// until it tries to send.

function createSocketWithHeartbeat(url) {
  let ws;
  let heartbeatTimer;
  let missedPongs = 0;
  const HEARTBEAT_INTERVAL = 30000; // 30s
  const MAX_MISSED_PONGS = 3;

  function connect() {
    ws = new WebSocket(url);

    ws.addEventListener("open", () => {
      startHeartbeat();
    });

    ws.addEventListener("message", (event) => {
      const data = JSON.parse(event.data);

      // Server responds to our ping with a pong
      if (data.type === "pong") {
        missedPongs = 0;
        return;
      }

      handleMessage(data);
    });

    ws.addEventListener("close", () => {
      stopHeartbeat();
      // reconnect logic...
    });
  }

  function startHeartbeat() {
    heartbeatTimer = setInterval(() => {
      if (ws.readyState !== WebSocket.OPEN) return;

      missedPongs++;
      if (missedPongs >= MAX_MISSED_PONGS) {
        console.warn("Server unresponsive — forcing reconnect");
        ws.close(4000, "Heartbeat timeout"); // custom close code
        return;
      }

      ws.send(JSON.stringify({ type: "ping", timestamp: Date.now() }));
    }, HEARTBEAT_INTERVAL);
  }

  function stopHeartbeat() {
    clearInterval(heartbeatTimer);
    missedPongs = 0;
  }

  connect();
}

// ============================================================
// Message ordering and idempotency
// ============================================================

// Problem: messages can arrive out of order or be duplicated
// (especially during reconnection). Always design for this.

let lastSeqNum = 0;

function handleOrderedMessage(data) {
  // Server includes a sequence number with each message
  if (data.seq <= lastSeqNum) {
    return; // duplicate or out-of-order — skip
  }

  if (data.seq > lastSeqNum + 1) {
    // Gap detected — we missed messages
    // Request a replay from the server
    ws.send(JSON.stringify({
      type: "replay",
      from: lastSeqNum + 1,
      to: data.seq,
    }));
  }

  lastSeqNum = data.seq;
  processMessage(data);
}

// ============================================================
// Subscription management
// ============================================================

// Resubscribe after reconnect — the server doesn't remember you

class SubscriptionManager {
  #subscriptions = new Set();
  #socket;

  constructor(socket) {
    this.#socket = socket;
  }

  subscribe(channel) {
    this.#subscriptions.add(channel);
    this.#socket.send(JSON.stringify({ type: "subscribe", channel }));
  }

  unsubscribe(channel) {
    this.#subscriptions.delete(channel);
    this.#socket.send(JSON.stringify({ type: "unsubscribe", channel }));
  }

  // Call this after every reconnect
  resubscribeAll() {
    for (const channel of this.#subscriptions) {
      this.#socket.send(JSON.stringify({ type: "subscribe", channel }));
    }
  }
}

// ============================================================
// Binary data and large payloads
// ============================================================

// WebSocket can send text (strings) or binary (Blob/ArrayBuffer)
ws.binaryType = "arraybuffer"; // or "blob" (default)

ws.addEventListener("message", (event) => {
  if (event.data instanceof ArrayBuffer) {
    // Binary frame
    const view = new DataView(event.data);
    const messageType = view.getUint8(0);
    // ... parse binary protocol
  } else {
    // Text frame
    const data = JSON.parse(event.data);
  }
});

// Backpressure: check bufferedAmount before flooding the socket
function sendWithBackpressure(ws, data) {
  const MAX_BUFFER = 1024 * 1024; // 1MB
  if (ws.bufferedAmount > MAX_BUFFER) {
    console.warn("Socket buffer full, dropping message");
    return false;
  }
  ws.send(data);
  return true;
}

// ============================================================
// Cleanup
// ============================================================

// Always clean up on page unload to avoid dangling connections
window.addEventListener("beforeunload", () => {
  if (ws?.readyState === WebSocket.OPEN) {
    ws.close(1000, "Page unloading");
  }
});

// For SPAs: clean up when navigating away from a view
function destroyLiveView() {
  socket.close();
  // Also clear: intervals, subscriptions, message handlers
}
```

### Common WebSocket bugs to watch for

| Bug | Why it happens | Fix |
|---|---|---|
| Send on closed socket | No readyState check | Check `=== WebSocket.OPEN` before send |
| Stale connection | Proxy killed idle socket silently | Implement heartbeat/ping |
| Thundering herd on reconnect | All clients reconnect at same time | Add jitter to backoff delay |
| Missed messages during reconnect | Gap between disconnect and reconnect | Queue messages + request replay |
| Memory leak | Listeners on old socket not cleaned up | Remove listeners before creating new socket |
| Infinite reconnect loop | No max retry limit | Cap retries, show error state to user |
| `JSON.parse` crash | Server sends malformed data | Wrap in try/catch |
| No resubscription | Server doesn't remember subscriptions | Track and replay subscriptions on reconnect |
| `onclose` vs `onerror` confusion | Putting retry logic in onerror | `onerror` always fires before `onclose` — retry in `onclose` only |
| Close code ignored | Not distinguishing clean vs abnormal close | Check `event.code` and `event.wasClean` |

---

## Quick Reference: Array Methods Cheat Sheet

```
MUTATING               NON-MUTATING
push / pop             concat
shift / unshift        slice
splice                 map / filter / reduce
sort                   flat / flatMap
reverse                toSorted (ES2023)
fill                   toReversed (ES2023)
copyWithin             toSpliced (ES2023)
                       with (ES2023)
```

## Quick Reference: Promise Combinators

```js
// All must succeed — fails fast on first rejection
Promise.all([p1, p2, p3]);

// All settle — never rejects, gives status of each
Promise.allSettled([p1, p2, p3]);
// → [{status: "fulfilled", value: ...}, {status: "rejected", reason: ...}]

// First to settle (fulfill OR reject) wins
Promise.race([p1, p2, p3]);

// First to FULFILL wins — ignores rejections unless all reject
Promise.any([p1, p2, p3]);
```
