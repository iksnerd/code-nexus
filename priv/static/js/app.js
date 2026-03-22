// Phoenix LiveView client setup
// phoenix.min.js and phoenix_live_view.min.js are loaded as separate scripts
// They expose Phoenix and LiveView globals respectively

var csrfToken = document.querySelector("meta[name='csrf-token']");
var token = csrfToken ? csrfToken.getAttribute("content") : "";

var Hooks = {};

// Smooth animated counter transitions
Hooks.AnimatedCounter = {
  mounted() {
    this._current = 0;
    this._update(parseInt(this.el.dataset.value) || 0);
  },
  updated() {
    this._update(parseInt(this.el.dataset.value) || 0);
  },
  _update(target) {
    if (target === this._current) return;
    var start = this._current;
    var diff = target - start;
    var duration = 600;
    var startTime = null;
    var el = this.el;
    var self = this;

    function step(ts) {
      if (!startTime) startTime = ts;
      var progress = Math.min((ts - startTime) / duration, 1);
      // ease-out cubic
      var eased = 1 - Math.pow(1 - progress, 3);
      var val = Math.round(start + diff * eased);
      el.textContent = val.toLocaleString();
      if (progress < 1) {
        requestAnimationFrame(step);
      } else {
        self._current = target;
      }
    }
    requestAnimationFrame(step);
  }
};

// Cmd+K / Ctrl+K global shortcut to focus search
Hooks.SearchFocus = {
  mounted() {
    var input = this.el;
    this._handler = function(e) {
      if ((e.metaKey || e.ctrlKey) && e.key === "k") {
        e.preventDefault();
        input.focus();
        input.select();
      }
    };
    document.addEventListener("keydown", this._handler);
  },
  destroyed() {
    document.removeEventListener("keydown", this._handler);
  }
};

// Convert UTC timestamps to user's local timezone
Hooks.LocalTime = {
  mounted() { this._format(); },
  updated() { this._format(); },
  _format() {
    var ts = parseInt(this.el.dataset.timestamp);
    if (ts) {
      this.el.textContent = new Date(ts).toLocaleTimeString();
    }
  }
};

// Subtle fade+slide on mount for page content
Hooks.FadeIn = {
  mounted() {
    this.el.style.opacity = "0";
    this.el.style.transform = "translateY(8px)";
    requestAnimationFrame(function() {
      this.el.style.transition = "opacity 0.3s ease-out, transform 0.3s ease-out";
      this.el.style.opacity = "1";
      this.el.style.transform = "translateY(0)";
    }.bind(this));
  }
};

var liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
  params: {_csrf_token: token},
  hooks: Hooks
});

liveSocket.connect();

window.liveSocket = liveSocket;
