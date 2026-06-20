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

    // Cluster by package: lay out each group's center on a grid, then pull its
    // nodes toward it. This mirrors the codebase's package structure instead of
    // hairballing 150+ flat nodes into the middle.
    const groups = Array.from(new Set(nodes.map(n => n.group || "?")));
    const cols = Math.max(1, Math.ceil(Math.sqrt(groups.length)));
    // Lay clusters out over a virtual area larger than the viewport so packages
    // sit well apart; a one-time zoom-to-fit (below) frames the whole spread.
    const spread = 1.6;
    const vw = width * spread, vh = height * spread;
    const ox = (width - vw) / 2, oy = (height - vh) / 2;
    const cellW = vw / cols;
    const cellH = vh / Math.max(1, Math.ceil(groups.length / cols));
    const groupCenter = {};
    groups.forEach((gname, i) => {
      groupCenter[gname] = {
        x: ox + (i % cols + 0.5) * cellW,
        y: oy + (Math.floor(i / cols) + 0.5) * cellH,
        name: gname
      };
    });
    this.groupCenter = groupCenter;
    const centerOf = d => groupCenter[d.group || "?"] || {x: width / 2, y: height / 2};

    // Base cluster-center positions, so the boxes-separation control can rescale the spread
    // between packages live (forceX/forceY read groupCenter, so mutating it moves clusters).
    const baseGroupCenter = {};
    groups.forEach(gname => {
      baseGroupCenter[gname] = {x: groupCenter[gname].x, y: groupCenter[gname].y};
    });

    // Per-package color + a tinted container box drawn behind the graph, so each
    // cluster reads as a visible package region. Repositioned each tick to wrap
    // that package's nodes.
    const groupPalette = ["#3b82f6", "#10b981", "#f59e0b", "#8b5cf6", "#ec4899", "#06b6d4", "#eab308", "#f43f5e", "#14b8a6", "#a855f7"];
    const groupColor = {};
    groups.forEach((gname, i) => { groupColor[gname] = groupPalette[i % groupPalette.length]; });
    const nodesByGroup = {};
    groups.forEach(gname => { nodesByGroup[gname] = nodes.filter(n => (n.group || "?") === gname); });

    const hullBox = g.append("g").attr("class", "cluster-hulls")
      .selectAll("g").data(groups).join("g");
    // The box rect is clickable in "boxes" select mode (click to isolate the package).
    // It starts inert — default mode is "nodes" — and setMode() toggles pointer-events.
    hullBox.append("rect")
      .attr("rx", 16)
      .attr("fill", d => groupColor[d]).attr("fill-opacity", 0.06)
      .attr("stroke", d => groupColor[d]).attr("stroke-opacity", 0.3).attr("stroke-width", 1)
      .style("cursor", "pointer")
      .style("pointer-events", "none")
      .on("mouseover", function(event, d) {
        if (isolatedGroup) return;
        d3.select(this).attr("fill-opacity", 0.12).attr("stroke-opacity", 0.6);
      })
      .on("mouseout", function(event, d) {
        if (isolatedGroup) return;
        d3.select(this).attr("fill-opacity", 0.06).attr("stroke-opacity", 0.3);
      })
      .on("click", (event, d) => {
        event.stopPropagation();
        setIsolation(isolatedGroup === d ? null : d);
      });
    hullBox.append("text")
      .text(d => d)
      .attr("fill", d => groupColor[d]).attr("fill-opacity", 0.75)
      .attr("font-size", "12px").attr("font-weight", "bold").attr("font-family", "monospace")
      .style("pointer-events", "none");

    // Click-to-isolate a package: highlight its box + nodes, dim everything else. Click the
    // same box again (or empty canvas) to clear. `setIsolation` is defined after node/link.
    let isolatedGroup = null;
    // Select mode: "nodes" (hover/drag/inspect nodes) or "boxes" (click packages to isolate).
    let selectMode = "nodes";

    // Type-aware link distance: contained methods tight to their struct, call/
    // import edges longer so the graph breathes.
    const linkDistance = { "contains": 55, "calls": 175, "imports": 215 };
    const simulation = d3.forceSimulation(nodes)
      .force("link", d3.forceLink(links).id(d => d.id).distance(d => linkDistance[d.type] || 175).strength(0.35))
      .force("charge", d3.forceManyBody().strength(-520).distanceMax(900))
      .force("collision", d3.forceCollide().radius(d => Math.sqrt(d.val) * 8 + 30).strength(0.9))
      .force("x", d3.forceX(d => centerOf(d).x).strength(0.45))
      .force("y", d3.forceY(d => centerOf(d).y).strength(0.45));

    this.simulation = simulation;

    // Live force controls — exposed to the settings panel in the graph template. Each
    // re-tunes a force and gently reheats the simulation so the layout re-settles.
    const reheat = () => simulation.alpha(0.5).restart();
    window.graphControls = {
      // Multiplier on the per-type base distances (contains/calls/imports).
      linkDistance: (mult) => {
        const m = +mult || 1;
        simulation.force("link").distance(d => (linkDistance[d.type] || 175) * m);
        reheat();
      },
      // Repulsion between nodes (more negative = more spread).
      charge: (v) => { simulation.force("charge").strength(+v); reheat(); },
      // Extra collision padding (node spacing).
      spacing: (v) => { simulation.force("collision").radius(d => Math.sqrt(d.val) * 8 + (+v)); reheat(); },
      // How tightly packages pull toward their cluster center (0 = free, 1 = rigid grid).
      cluster: (v) => { simulation.force("x").strength(+v); simulation.force("y").strength(+v); reheat(); },
      // Spread package clusters apart (scales each cluster center out from the viewport
      // middle). Gives intra-cluster links room, which is what makes "link distance" visible.
      boxesSeparation: (mult) => {
        const m = +mult || 1;
        const cx = width / 2, cy = height / 2;
        groups.forEach(g => {
          groupCenter[g].x = cx + (baseGroupCenter[g].x - cx) * m;
          groupCenter[g].y = cy + (baseGroupCenter[g].y - cy) * m;
        });
        reheat();
      }
    };

    // Segmented-button active-state helper for the template toggles.
    window.segActivate = (btn) => {
      Array.from(btn.parentNode.querySelectorAll("button")).forEach(b => {
        b.classList.remove("bg-blue-600", "text-white");
        b.classList.add("text-slate-400");
      });
      btn.classList.add("bg-blue-600", "text-white");
      btn.classList.remove("text-slate-400");
    };

    // Frame the whole (wider-than-viewport) layout once it settles.
    simulation.on("end", () => {
      const xs = nodes.map(n => n.x), ys = nodes.map(n => n.y);
      const minX = Math.min(...xs), maxX = Math.max(...xs);
      const minY = Math.min(...ys), maxY = Math.max(...ys);
      const bw = maxX - minX, bh = maxY - minY;
      if (!isFinite(bw) || !isFinite(bh) || bw === 0 || bh === 0) return;
      const scale = Math.min(width / (bw + 160), height / (bh + 160), 1.1);
      const tx = width / 2 - scale * (minX + maxX) / 2;
      const ty = height / 2 - scale * (minY + maxY) / 2;
      svg.transition().duration(600).call(zoom.transform, d3.zoomIdentity.translate(tx, ty).scale(scale));
    });

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

    // Cross-package edges are calmed (much fainter) so intra-package structure
    // reads first and inter-package coupling reads as secondary.
    const linkOpacityFor = d => {
      const base = linkOpacity[d.type] || 0.5;
      const sg = d.source && d.source.group, tg = d.target && d.target.group;
      return (sg != null && tg != null && sg !== tg) ? base * 0.22 : base;
    };

    const link = g.append("g")
      .selectAll("line")
      .data(links)
      .join("line")
      .attr("stroke", d => linkColors[d.type] || "#64748b")
      .attr("stroke-opacity", linkOpacityFor)
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
      "struct": "#f59e0b",
      "interface": "#eab308",
      "method": "#8b5cf6",
      "variable": "#22d3ee",
      "constant": "#22d3ee",
      "unknown": "#64748b"
    };

    const typeBadgeColors = {
      "module": "bg-blue-500/20 text-blue-400",
      "function": "bg-emerald-500/20 text-emerald-400",
      "class": "bg-amber-500/20 text-amber-400",
      "struct": "bg-amber-500/20 text-amber-400",
      "interface": "bg-yellow-500/20 text-yellow-400",
      "method": "bg-purple-500/20 text-purple-400",
      "variable": "bg-cyan-500/20 text-cyan-400",
      "constant": "bg-cyan-500/20 text-cyan-400",
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
        // In "boxes" mode the package boxes are the focus — skip node hover-highlighting.
        if (selectMode === "boxes") return;
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
          .attr("stroke-opacity", linkOpacityFor)
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
      .text(d => (d.val >= 3 || d.type === "struct" || d.type === "module") ? d.name : "")
      .attr("fill", d => d.callers_count >= 10 ? "#f1f5f9" : "#cbd5e1")
      .attr("font-size", d => d.callers_count >= 10 ? "12px" : d.val >= 8 ? "11px" : "9px")
      .attr("font-weight", d => d.callers_count >= 10 ? "bold" : "normal")
      .attr("font-family", "monospace")
      .style("pointer-events", "none");

    // Isolate one package: full opacity for its nodes/box, heavy dim for the rest. Links
    // touching the isolated package stay readable so cross-package coupling is still visible.
    function setIsolation(group) {
      isolatedGroup = group;
      const inGroup = d => (d.group || "?") === group;

      if (!group) {
        node.style("opacity", 1);
        link.style("opacity", null);
        hullBox.select("rect").attr("fill-opacity", 0.06).attr("stroke-opacity", 0.3).attr("stroke-width", 1);
        hullBox.select("text").attr("fill-opacity", 0.75);
        return;
      }

      node.style("opacity", d => inGroup(d) ? 1 : 0.07);
      link.style("opacity", d => {
        const sg = d.source.group, tg = d.target.group;
        return (sg === group || tg === group) ? 0.65 : 0.025;
      });
      hullBox.select("rect")
        .attr("fill-opacity", d => d === group ? 0.14 : 0.02)
        .attr("stroke-opacity", d => d === group ? 0.9 : 0.1)
        .attr("stroke-width", d => d === group ? 2 : 1);
      hullBox.select("text").attr("fill-opacity", d => d === group ? 1 : 0.2);
    }

    // Click empty canvas to clear isolation.
    svg.on("click.isolate", () => setIsolation(null));

    // Composed graph filters: edge-type + minimum connections + hidden node types all apply
    // together (a node must clear every active filter to show; a link shows only when its
    // type passes AND both endpoints are visible). One recompute keeps them consistent.
    let edgeFilter = "all";
    let minConnections = 0;
    const hiddenTypes = new Set();
    const degreeOf = d => (d.callers_count || 0) + (d.calls_count || 0);

    function applyGraphFilters() {
      const visible = new Set();
      node.style("display", d => {
        const show = degreeOf(d) >= minConnections && !hiddenTypes.has(d.type);
        if (show) visible.add(d.id);
        return show ? null : "none";
      });
      link.style("display", d => {
        const s = typeof d.source === "object" ? d.source.id : d.source;
        const t = typeof d.target === "object" ? d.target.id : d.target;
        const typeOk = edgeFilter === "all" || d.type === edgeFilter;
        return typeOk && visible.has(s) && visible.has(t) ? null : "none";
      });
    }

    window.graphControls.linkFilter = (type) => { edgeFilter = type; applyGraphFilters(); };
    // Hide nodes with fewer than n connections (callers + calls) — declutter low-signal leaves.
    window.graphControls.minConnections = (n) => { minConnections = +n || 0; applyGraphFilters(); };
    // Toggle a whole entity type on/off (e.g. hide all `variable` nodes).
    window.graphControls.toggleType = (type, hidden) => {
      if (hidden) hiddenTypes.add(type); else hiddenTypes.delete(type);
      applyGraphFilters();
    };
    // Label density: "auto" (degree-gated, default), "all", or "none".
    window.graphControls.labels = (mode) => {
      node.select("text").style("display", d => {
        if (mode === "none") return "none";
        if (mode === "all") return null;
        return d.val >= 3 || d.type === "struct" || d.type === "module" ? null : "none";
      });
    };

    // Toggle select mode: "nodes" (default) vs "boxes" (clickable package isolation).
    window.graphControls.setMode = (mode) => {
      selectMode = mode;
      hullBox.select("rect").style("pointer-events", mode === "boxes" ? "all" : "none");
      // Leaving box mode clears any active isolation so node mode starts clean.
      if (mode !== "boxes") setIsolation(null);
    };

    simulation.on("tick", () => {
      link
        .attr("x1", d => d.source.x)
        .attr("y1", d => d.source.y)
        .attr("x2", d => d.target.x)
        .attr("y2", d => d.target.y);

      node.attr("transform", d => `translate(${d.x},${d.y})`);

      // Wrap each package's nodes in its container box.
      const pad = 30;
      hullBox.each(function(gname) {
        const members = nodesByGroup[gname];
        if (!members || members.length === 0) return;
        let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
        members.forEach(m => {
          if (m.x < minX) minX = m.x;
          if (m.y < minY) minY = m.y;
          if (m.x > maxX) maxX = m.x;
          if (m.y > maxY) maxY = m.y;
        });
        const sel = d3.select(this);
        sel.select("rect")
          .attr("x", minX - pad).attr("y", minY - pad)
          .attr("width", maxX - minX + pad * 2).attr("height", maxY - minY + pad * 2);
        sel.select("text").attr("x", minX - pad + 12).attr("y", minY - pad + 18);
      });
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
