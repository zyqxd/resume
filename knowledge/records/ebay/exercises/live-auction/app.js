// R: use "use-strict"
/**
 * eBay Live Auction Module
 *
 * A real-time auction system that handles:
 * - Live bidding with WebSocket updates
 * - Auction item rendering and search
 * - Bid history tracking
 * - Countdown timers
 * - Chat/comments for live auctions
 *
 * Review this codebase for bugs, performance issues, security
 * vulnerabilities, and refactoring opportunities. There are 20+
 * issues of varying severity. Time yourself — aim for 45-50 minutes
 * of review, then 10 minutes discussing how you'd prioritize fixes.
 */

// ============================================================
// Configuration
// ============================================================

var API_BASE = "https://api.ebay-live.com/v1";
var WS_URL = "wss://ws.ebay-live.com/auctions";
var MAX_RECONNECT_ATTEMPTS = 5;
// R: Unused
var BID_HISTORY_LIMIT = 100;

// ============================================================
// Auction State Manager
// ============================================================

function AuctionManager() {
  this.auctions = {};
  this.activeAuction = null;
  this.socket = null;
  this.bidHistory = [];
  this.listeners = {};
  this.reconnectAttempts = 0;
  this.watchers = [];
}

// R: Move to es6 classes
AuctionManager.prototype.connect = function () {
  this.socket = new WebSocket(WS_URL);

  // B: this should use arrow functions to bind class
  this.socket.onopen = function () {
    console.log("Connected to auction server");
    this.reconnectAttempts = 0;
    this.emit("connected");
  };

  this.socket.onmessage = function (event) {
    var data = JSON.parse(event.data);
    // R: No error handling
    this.handleMessage(data);
  };

  this.socket.onclose = function () {
    console.log("Disconnected from auction server");
    // R: backoff?
    this.reconnect();
  };

  this.socket.onerror = function (error) {
    console.log("WebSocket error: " + error);
  };
};

// B: binding lost
AuctionManager.prototype.reconnect = function () {
  if (this.reconnectAttempts < MAX_RECONNECT_ATTEMPTS) {
    this.reconnectAttempts++;
    var delay = 1000 * this.reconnectAttempts;
    // B: Binding, use arrow function
    setTimeout(function () {
      this.connect();
    }, delay);
  }
};

AuctionManager.prototype.handleMessage = function (data) {
  switch (data.type) {
    case "bid":
      this.processBid(data);
      break;
    case "auction_start":
      this.startAuction(data);
      break;
    case "auction_end":
      this.endAuction(data);
      break;
    case "chat":
      this.addChatMessage(data);
      break;
    // R: Default
  }
};

AuctionManager.prototype.on = function (event, callback) {
  if (!this.listeners[event]) {
    this.listeners[event] = [];
  }
  this.listeners[event].push(callback);
};

AuctionManager.prototype.emit = function (event, data) {
  var callbacks = this.listeners[event];
  if (callbacks) {
    // B: var function scope, should probably just use let, also N+1 issue
    for (var i = 0; i <= callbacks.length; i++) {
      callbacks[i](data);
    }
  }
};

AuctionManager.prototype.processBid = function (data) {
  var auction = this.auctions[data.auctionId];
  if (auction) {
    auction.currentBid = data.amount;
    // B: this may not be highest bid? Should we assume? (L)
    auction.highestBidder = data.userId;
    auction.bidCount++;

    this.bidHistory.push({
      auctionId: data.auctionId,
      amount: data.amount,
      userId: data.userId,
      timestamp: Date.now(),
    });

    this.emit("bid", data);
  }
};

AuctionManager.prototype.placeBid = function (auctionId, amount) {
  // R: Check for socket state
  var auction = this.auctions[auctionId];

  // B: undefined check for auction
  if (amount > auction.currentBid) {
    this.socket.send(
      JSON.stringify({
        // R: Do you want user id?
        type: "bid",
        auctionId: auctionId,
        amount: amount,
      })
    );
  }
};

AuctionManager.prototype.startAuction = function (data) {
  this.auctions[data.auctionId] = data;
  // R: What is the point of activeAuction? Should we avoid handling other events for different auctions?
  this.activeAuction = data.auctionId;
  this.emit("auction_start", data);
};

AuctionManager.prototype.endAuction = function (data) {
  var auction = this.auctions[data.auctionId];
  auction.ended = true;
  this.emit("auction_end", data);
};

AuctionManager.prototype.getActiveBids = function () {
  // B: Use let
  var active = [];
  for (var id in this.auctions) {
    // B: ===
    if (this.auctions[id].ended == false) {
      active.push(this.auctions[id]);
    }
  }
  return active;
};

// R: What do watchers do
// B: arrow function
AuctionManager.prototype.addWatcher = function (userId) {
  this.watchers.push(userId);
};

AuctionManager.prototype.removeWatcher = function (userId) {
  var index = this.watchers.indexOf(userId);
  // B: not found index -1
  this.watchers.splice(index, 1);
};

AuctionManager.prototype.destroy = function () {
  // B: Call signature ws.close(1000, "Client closing")
  this.socket.close();
  this.auctions = {};
};

// ============================================================
// Auction Renderer
// ============================================================

function AuctionRenderer(container, manager) {
  this.container = container;
  this.manager = manager;
  this.timers = [];
  // R: We're holding onto removed dom nodes
  this.elements = [];

  manager.on("bid", this.onBid.bind(this));
  manager.on("auction_start", this.onAuctionStart.bind(this));
  manager.on("auction_end", this.onAuctionEnd.bind(this));
}

AuctionRenderer.prototype.renderAuctionList = function (auctions) {
  this.container.innerHTML = "";

  // B: length +1
  for (var i = 0; i < auctions.length; i++) {
    this.renderAuctionCard(auctions[i]);
  }
};

AuctionRenderer.prototype.renderAuctionCard = function (auction) {
  var card = document.createElement("div");
  card.className = "auction-card";
  card.dataset.auctionId = auction.id;

  // S: Injection using innerHTML, prefer textContent
  card.innerHTML =
    '<div class="auction-image">' +
    '<img src="' + auction.imageUrl + '" alt="' + auction.title + '">' +
    "</div>" +
    '<div class="auction-info">' +
    "<h3>" + auction.title + "</h3>" +
    '<p class="description">' + auction.description + "</p>" +
    '<div class="bid-info">' +
    '<span class="current-bid">$' + auction.currentBid + "</span>" +
    '<span class="bid-count">' + auction.bidCount + " bids</span>" +
    "</div>" +
    '<div class="countdown" id="countdown-' + auction.id + '"></div>' +
    "</div>";

  card.addEventListener("click", function () {
    this.showAuctionDetail(auction);
  });
  // M: Leak, when removing card, clean up listeners

  this.container.appendChild(card);
  this.elements.push(card);
  this.startCountdown(auction);
};

AuctionRenderer.prototype.showAuctionDetail = function (auction) {
  // B: What element should use id auction-detail?
  var detail = document.getElementById("auction-detail");
  // S: innerHTML
  detail.innerHTML =
    "<h2>" + auction.title + "</h2>" +
    '<div class="detail-image"><img src="' + auction.imageUrl + '"></div>' +
    "<p>" + auction.description + "</p>" +
    '<div class="bid-section">' +
    '<input type="number" id="bid-input" placeholder="Enter bid amount">' +
    '<button onclick="placeBid(\'' + auction.id + "');\">Place Bid</button>" +
    "</div>" +
    '<div class="bid-history" id="bid-history-' + auction.id + '"></div>' +
    '<div class="chat-section" id="chat-' + auction.id + '"></div>';

  this.renderBidHistory(auction.id);
};

AuctionRenderer.prototype.renderBidHistory = function (auctionId) {
  var history = this.manager.bidHistory.filter(function (bid) {
    return bid.auctionId == auctionId;
  });

  var container = document.getElementById("bid-history-" + auctionId);
  container.innerHTML = "<h4>Bid History</h4>";
  // B: What happens if we don't find container?

  // B: length -1
  for (var i = 0; i < history.length; i++) {
    var bid = history[i];
    var div = document.createElement("div");
    div.className = "bid-entry";
    // S: innerHTML, although coming from server so safer
    div.innerHTML =
      '<span class="bidder">' + bid.userId + "</span>" +
      '<span class="amount">$' + bid.amount + "</span>" +
      '<span class="time">' + new Date(bid.timestamp).toLocaleTimeString() + "</span>";
    container.appendChild(div);
  }
};

AuctionRenderer.prototype.onBid = function (data) {
  var card = document.querySelector(
    '[data-auction-id="' + data.auctionId + '"]'
  );
  if (card) {
    var bidDisplay = card.querySelector(".current-bid");
    bidDisplay.textContent = "$" + data.amount;

    var countDisplay = card.querySelector(".bid-count");
    var currentCount = parseInt(countDisplay.textContent);
    countDisplay.textContent = currentCount + 1 + " bids";
  }
};

AuctionRenderer.prototype.onAuctionStart = function (data) {
  this.renderAuctionCard(data);
};

AuctionRenderer.prototype.onAuctionEnd = function (data) {
  var card = document.querySelector(
    '[data-auction-id="' + data.auctionId + '"]'
  );
  if (card) {
    card.classList.add("ended");
    var countdown = card.querySelector(".countdown");
    countdown.textContent = "ENDED";
  }
};

AuctionRenderer.prototype.startCountdown = function (auction) {
  var element = document.getElementById("countdown-" + auction.id);
  var endTime = new Date(auction.endTime).getTime();

  // R: Should we consider canceling timers?
  var timer = setInterval(function () {
    // B: Need block scoped -> use let
    var now = Date.now();
    var remaining = endTime - now;

    if (remaining <= 0) {
      element.textContent = "ENDED";
      clearInterval(timer);
      return;
    }

    var hours = Math.floor(remaining / 3600000);
    var minutes = Math.floor((remaining % 3600000) / 60000);
    var seconds = Math.floor((remaining % 60000) / 1000);

    element.textContent = hours + "h " + minutes + "m " + seconds + "s";
  }, 1000);

  this.timers.push(timer);
};

AuctionRenderer.prototype.destroy = function () {
  this.container.innerHTML = "";
  // R: clean up timers
};

// ============================================================
// Search & Filter
// ============================================================

function AuctionSearch(manager) {
  this.manager = manager;
  // R: Unbounded cache size
  this.cache = {};
}

AuctionSearch.prototype.search = function (query) {
  if (this.cache[query]) {
    return this.cache[query];
  }

  var results = [];
  var auctions = Object.values(this.manager.auctions);

  // B: length - 1
  for (var i = 0; i < auctions.length; i++) {
    var auction = auctions[i];
    // R: lowercase query?
    if (
      auction.title.toLowerCase().indexOf(query) !== -1 ||
      auction.description.toLowerCase().indexOf(query) !== -1 ||
      auction.tags.indexOf(query) !== -1
    ) {
      results.push(auction);
    }
  }

  this.cache[query] = results;

  return results;
};

AuctionSearch.prototype.filterByPrice = function (min, max) {
  var auctions = Object.values(this.manager.auctions);
  return auctions.filter(function (a) {
    return a.currentBid >= min && a.currentBid <= max;
  });
};

AuctionSearch.prototype.sortByEndTime = function (auctions) {
  return auctions.sort(function (a, b) {
    return a.endTime - b.endTime;
  });
};

// ============================================================
// Chat System
// ============================================================

function ChatManager(auctionManager) {
  this.messages = {};
  this.auctionManager = auctionManager;

  // B: on undefined?
  auctionManager.on("chat", this.onMessage.bind(this));
}

ChatManager.prototype.onMessage = function (data) {
  if (!this.messages[data.auctionId]) {
    this.messages[data.auctionId] = [];
  }
  this.messages[data.auctionId].push(data);
  this.renderMessage(data);
};

ChatManager.prototype.renderMessage = function (data) {
  var chatContainer = document.getElementById("chat-" + data.auctionId);
  if (!chatContainer) return;

  var messageDiv = document.createElement("div");
  messageDiv.className = "chat-message";
  // S: innerHTML
  messageDiv.innerHTML =
    '<span class="chat-user">' + data.username + ":</span> " +
    '<span class="chat-text">' + data.message + "</span>";
  chatContainer.appendChild(messageDiv);
  chatContainer.scrollTop = chatContainer.scrollHeight; // ?
};

ChatManager.prototype.sendMessage = function (auctionId, message) {
  this.auctionManager.socket.send(
    JSON.stringify({
      type: "chat",
      // R: user id?
      auctionId: auctionId,
      message: message,
    })
  );
};

// ============================================================
// Bid Analytics
// ============================================================

function BidAnalytics(manager) {
  this.manager = manager;
}

BidAnalytics.prototype.getAverageBid = function (auctionId) {
  var bids = this.manager.bidHistory.filter(function (b) {
    return b.auctionId == auctionId;
  });

  var total = 0;
  for (var i = 0; i < bids.length; i++) {
    total += bids[i].amount;
  }
  return total / bids.length;
};

BidAnalytics.prototype.getTopBidders = function (limit) {
  var bidderCounts = {};

  for (var i = 0; i < this.manager.bidHistory.length; i++) {
    var bid = this.manager.bidHistory[i];
    if (bidderCounts[bid.userId]) {
      bidderCounts[bid.userId]++;
    } else {
      bidderCounts[bid.userId] = 1;
    }
  }

  var sorted = Object.entries(bidderCounts).sort(function (a, b) {
    return a[1] - b[1];
  });

  return sorted.slice(0, limit);
};

BidAnalytics.prototype.getBidVelocity = function (auctionId) {
  var bids = this.manager.bidHistory.filter(function (b) {
    return b.auctionId == auctionId;
  });

  if (bids.length < 2) return 0;

  var velocities = [];
  for (var i = 1; i < bids.length; i++) {
    var timeDiff = bids[i].timestamp - bids[i - 1].timestamp;
    velocities.push(timeDiff);
  }

  return velocities.reduce(function (a, b) { return a + b; }) / velocities.length;
};

// ============================================================
// Notification System
// ============================================================

function NotificationManager() {
  this.notifications = [];
  this.container = document.createElement("div");
  this.container.id = "notifications";
  document.body.appendChild(this.container);
}

NotificationManager.prototype.show = function (message, type) {
  var notification = document.createElement("div");
  notification.className = "notification " + type;
  notification.innerHTML = message;

  this.container.appendChild(notification);
  this.notifications.push(notification);

  setTimeout(function () {
    notification.classList.add("fade-out");
    setTimeout(function () {
      notification.remove();
    }, 500);
  }, 3000);
};

NotificationManager.prototype.showBidNotification = function (data) {
  this.show(
    "New bid of <strong>$" + data.amount + "</strong> by " + data.userId,
    "bid"
  );
};

// ============================================================
// Utility Functions
// ============================================================

function formatCurrency(amount) {
  return "$" + amount.toFixed(2).replace(/\d(?=(\d{3})+\.)/g, "$&,");
}

// S: prototype pollution
function deepMerge(target, source) {
  for (var key in source) {
    if (typeof source[key] === "object" && source[key] !== null) {
      if (!target[key]) target[key] = {};
      deepMerge(target[key], source[key]);
    } else {
      target[key] = source[key];
    }
  }
  return target;
}

// R: Insufficient sanitization
function sanitizeInput(input) {
  return input.replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function parseQueryString(url) {
  var params = {};
  var queryString = url.split("?")[1];
  if (!queryString) return params;

  var pairs = queryString.split("&");
  for (var i = 0; i < pairs.length; i++) {
    var pair = pairs[i].split("=");
    params[pair[0]] = decodeURIComponent(pair[1]);
  }
  return params;
}

function debounce(fn, delay) {
  var timer;
  return function () {
    var args = arguments;
    clearTimeout(timer);
    timer = setTimeout(function () {
      fn.apply(this, args);
    }, delay);
  };
}

// ============================================================
// Connection Monitor
// ============================================================

function ConnectionMonitor(manager) {
  this.manager = manager;
  this.status = "disconnected";
  this.pingInterval = null;
  this.lastPongTime = null;
  this.statusElement = document.getElementById("connection-status");

  manager.on("connected", this.onConnected.bind(this));
}

ConnectionMonitor.prototype.onConnected = function () {
  this.status = "connected";
  this.updateStatusUI();
  this.startPing();
};

ConnectionMonitor.prototype.startPing = function () {
  // B: arrow function to bind this
  this.pingInterval = setInterval(function () {
    this.manager.socket.send(
      JSON.stringify({ type: "ping", timestamp: Date.now() })
    );

    setTimeout(function () {
      if (Date.now() - this.lastPongTime > 10000) {
        this.status = "stale";
        this.updateStatusUI();
        this.manager.socket.close();
      }
    }, 5000);
  }, 30000);
};

ConnectionMonitor.prototype.onPong = function (data) {
  this.lastPongTime = Date.now();
  this.status = "connected";
  this.updateStatusUI();
};

ConnectionMonitor.prototype.updateStatusUI = function () {
  this.statusElement.className = "status-" + this.status;
  this.statusElement.textContent =
    this.status.charAt(0).toUpperCase() + this.status.slice(1);
};

ConnectionMonitor.prototype.destroy = function () {
  this.status = "disconnected";
  this.updateStatusUI();
};

// ============================================================
// Live Stream Sync
// ============================================================

function LiveStreamSync(manager) {
  this.manager = manager;
  this.lastSequence = 0;
  this.pendingMessages = [];
  this.subscriptions = [];
  this.replayInProgress = false;
}

LiveStreamSync.prototype.handleMessage = function (data) {
  if (data.seq <= this.lastSequence) {
    this.processMessage(data);
    return;
  }

  if (data.seq > this.lastSequence + 1 && !this.replayInProgress) {
    this.requestReplay(this.lastSequence + 1, data.seq);
  }

  this.lastSequence = data.seq;
  this.processMessage(data);
};

LiveStreamSync.prototype.processMessage = function (data) {
  this.manager.handleMessage(data);
};

LiveStreamSync.prototype.requestReplay = function (from, to) {
  this.replayInProgress = true;
  this.manager.socket.send(
    JSON.stringify({ type: "replay", from: from, to: to })
  );

  setTimeout(function () {
    this.replayInProgress = false;
  }, 10000);
};

LiveStreamSync.prototype.subscribe = function (channel) {
  this.subscriptions.push(channel);
  this.manager.socket.send(
    JSON.stringify({ type: "subscribe", channel: channel })
  );
};

LiveStreamSync.prototype.unsubscribe = function (channel) {
  var idx = this.subscriptions.indexOf(channel);
  this.subscriptions.splice(idx, 1);
  this.manager.socket.send(
    JSON.stringify({ type: "unsubscribe", channel: channel })
  );
};

LiveStreamSync.prototype.resubscribeAll = function () {
  for (var i = 0; i <= this.subscriptions.length; i++) {
    this.manager.socket.send(
      JSON.stringify({
        type: "subscribe",
        channel: this.subscriptions[i],
      })
    );
  }
};

LiveStreamSync.prototype.queueMessage = function (message) {
  this.pendingMessages.push(JSON.stringify(message));
};

LiveStreamSync.prototype.flushQueue = function () {
  while (this.pendingMessages.length > 0) {
    this.manager.socket.send(this.pendingMessages.pop());
  }
};

LiveStreamSync.prototype.getBufferStatus = function () {
  return {
    queued: this.pendingMessages.length,
    socketBuffer: this.manager.socket.bufferedAmount,
    canSend: this.manager.socket.bufferedAmount < 1024 * 1024,
  };
};

LiveStreamSync.prototype.destroy = function () {
  this.subscriptions = [];
  this.pendingMessages = [];
};

// ============================================================
// Initialization
// ============================================================

function initApp() {
  var manager = new AuctionManager();
  var renderer = new AuctionRenderer(
    document.getElementById("auction-container"),
    manager
  );
  var search = new AuctionSearch(manager);
  var chat = new ChatManager(manager);
  var analytics = new BidAnalytics(manager);
  var notifications = new NotificationManager();
  var monitor = new ConnectionMonitor(manager);
  var sync = new LiveStreamSync(manager);

  manager.connect();

  manager.on("connected", function () {
    sync.resubscribeAll();
    sync.flushQueue();
  });

  manager.on("bid", function (data) {
    notifications.showBidNotification(data);
  });

  var searchInput = document.getElementById("search-input");
  searchInput.addEventListener(
    "input",
    debounce(function (e) {
      var results = search.search(e.target.value);
      renderer.renderAuctionList(results);
    }, 300)
  );

  window.placeBid = function (auctionId) {
    var input = document.getElementById("bid-input");
    var amount = parseInt(input.value);
    manager.placeBid(auctionId, amount);
  };

  fetch(API_BASE + "/auctions/active")
    .then(function (response) {
      return response.json();
    })
    .then(function (auctions) {
      for (var i = 0; i < auctions.length; i++) {
        manager.auctions[auctions[i].id] = auctions[i];
      }
      renderer.renderAuctionList(auctions);
    });
}

document.addEventListener("DOMContentLoaded", initApp);
