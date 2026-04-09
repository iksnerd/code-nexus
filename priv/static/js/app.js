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

// UTC timestamps to user's local timezone
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

// D3.js Code Graph Hook
Hooks.CodeGraph = {
  mounted() {
    this.handleEvent("graph_data", ({nodes, links}) => {
      console.log("GraphData received", {nodes: nodes.length, links: links.length});
      this.renderGraph(nodes, links);
    });
  },

  renderGraph(nodes, links) {
    if (!nodes || nodes.length === 0) {
      console.log("No nodes to render");
      return;
    }

    if (this.simulation) this.simulation.stop();

    const width = this.el.clientWidth;
    const height = this.el.clientHeight;
    console.log("Rendering SVG", {width, height});

    if (width === 0 || height === 0) {
        console.warn("Container has 0 width or height, D3 simulation might fail to center.");
    }

    const svg = d3.select("#code-graph-svg");

    // Clear previous
    svg.selectAll("*").remove();

    const g = svg.append("g");

    // Zoom setup
    const zoom = d3.zoom()
      .scaleExtent([0.1, 4])
      .on("zoom", (event) => g.attr("transform", event.transform));

    svg.call(zoom);

    // Global zoom helpers
    window.zoomIn = () => svg.transition().call(zoom.scaleBy, 1.3);
    window.zoomOut = () => svg.transition().call(zoom.scaleBy, 0.7);
    window.resetZoom = () => svg.transition().call(zoom.transform, d3.zoomIdentity);

    // Build adjacency for hover highlighting
    const neighbors = new Map();
    nodes.forEach(n => neighbors.set(n.id, new Set()));
    links.forEach(l => {
      const sid = typeof l.source === 'object' ? l.source.id : l.source;
      const tid = typeof l.target === 'object' ? l.target.id : l.target;
      if (neighbors.has(sid)) neighbors.get(sid).add(tid);
      if (neighbors.has(tid)) neighbors.get(tid).add(sid);
    });

    const simulation = d3.forceSimulation(nodes)
      .force("link", d3.forceLink(links).id(d => d.id).distance(180))
      .force("charge", d3.forceManyBody().strength(-500).distanceMax(800))
      .force("center", d3.forceCenter(width / 2, height / 2))
      .force("collision", d3.forceCollide().radius(d => Math.sqrt(d.val) * 8 + 25))
      .force("x", d3.forceX(width / 2).strength(0.02))
      .force("y", d3.forceY(height / 2).strength(0.02));

    this.simulation = simulation;

    // Arrowhead markers for each link type
    const defs = svg.append("defs");
    const markerColors = {
      "calls": "#64748b",
      "imports": "#f59e0b",
      "contains": "#6366f1",
      "highlight": "#38bdf8"
    };
    Object.entries(markerColors).forEach(([name, color]) => {
      defs.append("marker")
        .attr("id", `arrowhead-${name}`)
        .attr("viewBox", "-0 -5 10 10")
        .attr("refX", 20)
        .attr("refY", 0)
        .attr("orient", "auto")
        .attr("markerWidth", 6)
        .attr("markerHeight", 6)
        .append("svg:path")
        .attr("d", "M 0,-5 L 10 ,0 L 0,5")
        .attr("fill", color)
        .style("stroke", "none");
    });

    const linkColors = { "calls": "#64748b", "imports": "#f59e0b", "contains": "#818cf8" };
    const linkDash = { "calls": "none", "imports": "8,4", "contains": "4,4" };
    const linkOpacity = { "calls": 0.5, "imports": 0.6, "contains": 0.45 };
    const linkWidth = { "calls": 1.5, "imports": 1.5, "contains": 1.2 };

    const link = g.append("g")
      .selectAll("line")
      .data(links)
      .join("line")
      .attr("stroke", d => linkColors[d.type] || "#64748b")
      .attr("stroke-opacity", d => linkOpacity[d.type] || 0.5)
      .attr("stroke-width", d => linkWidth[d.type] || 1.5)
      .attr("stroke-dasharray", d => linkDash[d.type] || "none")
      .attr("marker-end", d => `url(#arrowhead-${d.type})`);

    const node = g.append("g")
      .selectAll("g")
      .data(nodes)
      .join("g")
      .call(drag(simulation));

    const colorMap = {
      "module": "#3b82f6",
      "function": "#10b981",
      "class": "#f59e0b",
      "method": "#8b5cf6",
      "unknown": "#64748b"
    };

    const typeBadgeColors = {
      "module": "bg-blue-500/20 text-blue-400",
      "function": "bg-emerald-500/20 text-emerald-400",
      "class": "bg-amber-500/20 text-amber-400",
      "method": "bg-purple-500/20 text-purple-400",
      "unknown": "bg-slate-500/20 text-slate-400"
    };

    // Glow ring for highly-called nodes
    node.filter(d => d.callers_count >= 5)
      .append("circle")
      .attr("r", d => Math.sqrt(d.val) * 4 + 10)
      .attr("fill", "none")
      .attr("stroke", d => colorMap[d.type] || colorMap.unknown)
      .attr("stroke-opacity", d => Math.min(0.4, d.callers_count / 50))
      .attr("stroke-width", d => Math.min(4, d.callers_count / 8))
      .style("pointer-events", "none");

    node.append("circle")
      .attr("r", d => Math.sqrt(d.val) * 4 + 4)
      .attr("fill", d => colorMap[d.type] || colorMap.unknown)
      .attr("stroke", d => d.callers_count >= 10 ? "#e2e8f0" : "#1e293b")
      .attr("stroke-width", d => d.callers_count >= 10 ? 2 : 1.5)
      .on("mouseover", (event, d) => {
        const connectedIds = neighbors.get(d.id) || new Set();
        // Dim non-connected nodes
        node.select("circle")
          .attr("opacity", n => n.id === d.id || connectedIds.has(n.id) ? 1 : 0.15);
        node.select("text")
          .attr("opacity", n => n.id === d.id || connectedIds.has(n.id) ? 1 : 0.1);
        // Highlight connected links
        link
          .attr("stroke", l => {
            const sid = typeof l.source === 'object' ? l.source.id : l.source;
            const tid = typeof l.target === 'object' ? l.target.id : l.target;
            return (sid === d.id || tid === d.id) ? "#38bdf8" : "#64748b";
          })
          .attr("stroke-opacity", l => {
            const sid = typeof l.source === 'object' ? l.source.id : l.source;
            const tid = typeof l.target === 'object' ? l.target.id : l.target;
            return (sid === d.id || tid === d.id) ? 1 : 0.08;
          })
          .attr("stroke-width", l => {
            const sid = typeof l.source === 'object' ? l.source.id : l.source;
            const tid = typeof l.target === 'object' ? l.target.id : l.target;
            return (sid === d.id || tid === d.id) ? 2.5 : 1.5;
          })
          .attr("marker-end", l => {
            const sid = typeof l.source === 'object' ? l.source.id : l.source;
            const tid = typeof l.target === 'object' ? l.target.id : l.target;
            return (sid === d.id || tid === d.id) ? "url(#arrowhead-highlight)" : `url(#arrowhead-${l.type})`;
          })
          .attr("stroke-dasharray", l => {
            const sid = typeof l.source === 'object' ? l.source.id : l.source;
            const tid = typeof l.target === 'object' ? l.target.id : l.target;
            return (sid === d.id || tid === d.id) ? "none" : (linkDash[l.type] || "none");
          });
        d3.select(event.currentTarget).attr("stroke", "#f8fafc").attr("stroke-width", 2.5);
        showDetails(d);
      })
      .on("mouseout", (event) => {
        node.select("circle").attr("opacity", 1);
        node.select("text").attr("opacity", 1);
        link
          .attr("stroke", d => linkColors[d.type] || "#64748b")
          .attr("stroke-opacity", d => linkOpacity[d.type] || 0.5)
          .attr("stroke-width", d => linkWidth[d.type] || 1.5)
          .attr("stroke-dasharray", d => linkDash[d.type] || "none")
          .attr("marker-end", d => `url(#arrowhead-${d.type})`);
        d3.select(event.currentTarget).attr("stroke", "#1e293b").attr("stroke-width", 1.5);
        hideDetails();
      });

    // Only show labels on nodes with enough connections to matter
    node.append("text")
      .attr("x", d => Math.sqrt(d.val) * 4 + 8)
      .attr("y", 4)
      .text(d => d.val >= 3 ? d.name : "")
      .attr("fill", d => d.callers_count >= 10 ? "#f1f5f9" : "#cbd5e1")
      .attr("font-size", d => d.callers_count >= 10 ? "12px" : d.val >= 8 ? "11px" : "9px")
      .attr("font-weight", d => d.callers_count >= 10 ? "bold" : "normal")
      .attr("font-family", "monospace")
      .style("pointer-events", "none");

    simulation.on("tick", () => {
      link
        .attr("x1", d => d.source.x)
        .attr("y1", d => d.source.y)
        .attr("x2", d => d.target.x)
        .attr("y2", d => d.target.y);

      node.attr("transform", d => `translate(${d.x},${d.y})`);
    });

    function drag(simulation) {
      function dragstarted(event) {
        if (!event.active) simulation.alphaTarget(0.3).restart();
        event.subject.fx = event.subject.x;
        event.subject.fy = event.subject.y;
      }
      function dragged(event) {
        event.subject.fx = event.x;
        event.subject.fy = event.y;
      }
      function dragended(event) {
        if (!event.active) simulation.alphaTarget(0);
        event.subject.fx = null;
        event.subject.fy = null;
      }
      return d3.drag()
        .on("start", dragstarted)
        .on("drag", dragged)
        .on("end", dragended);
    }

    function showDetails(d) {
      const el = document.getElementById("node-details");
      document.getElementById("node-name").textContent = d.name;
      const badge = document.getElementById("node-type-badge");
      badge.textContent = d.type;
      badge.className = `px-1.5 py-0.5 rounded text-[10px] font-bold uppercase tracking-wider ${typeBadgeColors[d.type] || typeBadgeColors.unknown}`;
      document.getElementById("node-file").textContent = d.file || "unknown";
      document.getElementById("node-lines").textContent = d.lines || "?";
      document.getElementById("node-calls").textContent = d.calls_count;
      document.getElementById("node-callers").textContent = d.callers_count;
      document.getElementById("node-imports").textContent = d.imports_count;

      // Calls list
      const callsList = document.getElementById("node-calls-list");
      const callsItems = document.getElementById("node-calls-items");
      callsItems.innerHTML = "";
      if (d.calls && d.calls.length > 0) {
        callsList.classList.remove("hidden");
        d.calls.forEach(c => {
          const tag = document.createElement("span");
          tag.className = "px-1.5 py-0.5 bg-emerald-500/10 text-emerald-400 rounded text-[10px] font-mono";
          tag.textContent = c;
          callsItems.appendChild(tag);
        });
      } else {
        callsList.classList.add("hidden");
      }

      // Imports list
      const importsList = document.getElementById("node-imports-list");
      const importsItems = document.getElementById("node-imports-items");
      importsItems.innerHTML = "";
      if (d.imports && d.imports.length > 0) {
        importsList.classList.remove("hidden");
        d.imports.forEach(c => {
          const tag = document.createElement("span");
          tag.className = "px-1.5 py-0.5 bg-amber-500/10 text-amber-400 rounded text-[10px] font-mono";
          tag.textContent = c;
          importsItems.appendChild(tag);
        });
      } else {
        importsList.classList.add("hidden");
      }

      el.classList.remove("opacity-0");
      el.classList.add("opacity-100");
    }

    function hideDetails() {
      const el = document.getElementById("node-details");
      el.classList.remove("opacity-100");
      el.classList.add("opacity-0");
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
