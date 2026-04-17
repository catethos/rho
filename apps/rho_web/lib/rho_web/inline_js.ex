defmodule RhoWeb.InlineJS do
  @moduledoc """
  Inline JavaScript for the Rho LiveView UI.
  Hooks are defined inline. The Phoenix/LiveView client JS is loaded
  from the endpoint's static paths (copied at boot from deps).
  """

  def js do
    ~S"""
    function syntaxHighlight(json) {
      return json.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
        .replace(/("(\\u[a-fA-F0-9]{4}|\\[^u]|[^\\"])*"(\s*:)?|\b(true|false|null)\b|-?\d+(?:\.\d*)?(?:[eE][+\-]?\d+)?)/g,
          function(match) {
            var cls = 'json-number';
            if (/^"/.test(match)) {
              cls = /:$/.test(match) ? 'json-key' : 'json-string';
            } else if (/true|false/.test(match)) {
              cls = 'json-bool';
            } else if (/null/.test(match)) {
              cls = 'json-null';
            }
            return '<span class="' + cls + '">' + match + '</span>';
          });
    }

    window.RhoHooks = {
      StreamingText: {
        mounted() {
          this.handleEvent("text-chunk", ({agent_id, text}) => {
            if (this.el.id === "stream-body-" + agent_id) {
              this.el.insertAdjacentText("beforeend", text);
              var feed = this.el.closest(".chat-feed");
              if (feed) feed.scrollTop = feed.scrollHeight;
            }
          });
          this.handleEvent("stream-end", ({agent_id}) => {});
        }
      },

      AutoScroll: {
        mounted() {
          var self = this;
          this.isUserScrolled = false;
          this.el.addEventListener("scroll", function() {
            var el = self.el;
            self.isUserScrolled = el.scrollHeight - el.scrollTop - el.clientHeight > 50;
          });
          this.observer = new MutationObserver(function() {
            if (!self.isUserScrolled) {
              self.el.scrollTop = self.el.scrollHeight;
            }
          });
          this.observer.observe(this.el, { childList: true, subtree: true });
          this.el.scrollTop = this.el.scrollHeight;
        },
        destroyed() {
          if (this.observer) this.observer.disconnect();
        }
      },

      AutoResize: {
        mounted() {
          var el = this.el;
          el.addEventListener("input", function() {
            el.style.height = "auto";
            el.style.height = Math.min(el.scrollHeight, 200) + "px";
          });
          el.addEventListener("keydown", function(e) {
            if (e.key === "Enter" && !e.shiftKey) {
              e.preventDefault();
              el.closest("form").dispatchEvent(new Event("submit", {bubbles: true, cancelable: true}));
              el.value = "";
              el.style.height = "auto";
            }
          });
        }
      },

      ParentPicker: {
        mounted() {
          this.el.addEventListener("rho:select-parent", function(e) {
            var parentId = e.detail.parent_id;
            var input = document.getElementById("new-agent-parent-input");
            if (input) input.value = parentId;
            var btns = e.currentTarget.querySelectorAll(".agent-parent-btn");
            btns.forEach(function(btn) {
              if (btn.getAttribute("data-parent-id") === parentId) {
                btn.classList.add("active");
              } else {
                btn.classList.remove("active");
              }
            });
          });
        }
      },

      Markdown: {
        mounted() {
          this._lastMd = null;
          this._raf = null;
          this.render();
        },
        updated() {
          var raw = this.el.getAttribute("data-md");
          if (raw === this._lastMd) return;
          if (this._raf) cancelAnimationFrame(this._raf);
          var self = this;
          this._raf = requestAnimationFrame(function() {
            self._raf = null;
            self.render();
          });
        },
        destroyed() {
          if (this._raf) cancelAnimationFrame(this._raf);
        },
        render() {
          var raw = this.el.getAttribute("data-md");
          if (!raw || !window.marked || raw === this._lastMd) return;
          this._lastMd = raw;
          var html = window.marked.parse(raw, { breaks: true });
          html = window.DOMPurify ? DOMPurify.sanitize(html) : html;
          var tmp = document.createElement("div");
          tmp.innerHTML = html;
          this._patchChildren(this.el, tmp);
        },
        _patchChildren(target, source) {
          var tNodes = target.childNodes;
          var sNodes = source.childNodes;
          var i = 0;
          while (i < sNodes.length) {
            var s = sNodes[i];
            var t = tNodes[i];
            if (!t) {
              target.appendChild(s.cloneNode(true));
            } else if (t.nodeType !== s.nodeType || t.nodeName !== s.nodeName) {
              target.replaceChild(s.cloneNode(true), t);
            } else if (s.nodeType === 3) {
              if (t.textContent !== s.textContent) t.textContent = s.textContent;
            } else if (s.nodeType === 1) {
              if (t.innerHTML !== s.innerHTML) {
                this._patchChildren(t, s);
              }
            }
            i++;
          }
          while (tNodes.length > sNodes.length) {
            target.removeChild(target.lastChild);
          }
        }
      },

      JsonPretty: {
        mounted() {
          this.render();
        },
        updated() {
          this.render();
        },
        render() {
          var raw = this.el.getAttribute("data-json");
          if (!raw) return;
          try {
            var obj = JSON.parse(raw);
            this.el.innerHTML = syntaxHighlight(JSON.stringify(obj, null, 2));
          } catch(e) {
            this.el.textContent = raw;
          }
        }
      },

      InteractionGraph: {
        mounted() {
          // Re-trigger particle animations on updates by resetting SVG animation elements
          this.handleEvent("new-edge", function() {});
        },
        updated() {
          // Force restart animations on SVG animateMotion elements
          var motions = this.el.querySelectorAll("animateMotion");
          motions.forEach(function(m) {
            if (m.beginElement) m.beginElement();
          });
        }
      },

      AutoFocus: {
        mounted() {
          this.el.focus();
          if (this.el.select) this.el.select();
        }
      },

      ExportDownload: {
        mounted() {
          var self = this;
          this.handleEvent("csv-download", ({csv, filename}) => {
            var blob = new Blob([csv], {type: "text/csv;charset=utf-8;"});
            this._download(blob, filename);
          });
          this.handleEvent("xlsx-download", ({data, filename}) => {
            var byteString = atob(data);
            var ab = new ArrayBuffer(byteString.length);
            var ia = new Uint8Array(ab);
            for (var i = 0; i < byteString.length; i++) {
              ia[i] = byteString.charCodeAt(i);
            }
            var blob = new Blob([ab], {type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"});
            this._download(blob, filename);
          });
          // Close dropdown when clicking outside
          this._onClickOutside = function(e) {
            if (!self.el.contains(e.target)) {
              self.pushEventTo(self.el, "close_export_menu", {});
            }
          };
          document.addEventListener("mousedown", this._onClickOutside);
        },
        destroyed() {
          document.removeEventListener("mousedown", this._onClickOutside);
        },
        _download(blob, filename) {
          var url = URL.createObjectURL(blob);
          var a = document.createElement("a");
          a.href = url;
          a.download = filename;
          document.body.appendChild(a);
          a.click();
          document.body.removeChild(a);
          URL.revokeObjectURL(url);
        }
      },

      SignalTimeline: {
        mounted() {
          var self = this;
          this.handleEvent("signal", function(signal) {
            var dot = document.createElement("span");
            var color = "gray";
            var t = signal.type || "";
            if (t.indexOf("task.requested") >= 0) color = "blue";
            else if (t.indexOf("task.completed") >= 0) color = "green";
            else if (t.indexOf("error") >= 0 || t.indexOf("task.failed") >= 0) color = "red";
            else if (t.indexOf("message.sent") >= 0) color = "yellow";

            dot.className = "signal-chip signal-" + color;
            dot.title = t;
            dot.addEventListener("click", function() {
              if (signal.agent_id) {
                self.pushEvent("select_agent", {"agent-id": signal.agent_id});
              }
            });
            self.el.appendChild(dot);
            while (self.el.children.length > 500) self.el.removeChild(self.el.firstChild);
            self.el.scrollLeft = self.el.scrollWidth;
          });
        }
      },
      PanelResizer: {
        mounted() {
          var self = this;
          var panels = this.el.closest(".main-panels");
          var dragging = false;

          this.el.addEventListener("mousedown", function(e) {
            e.preventDefault();
            dragging = true;
            document.body.style.cursor = "col-resize";
            document.body.style.userSelect = "none";
          });

          document.addEventListener("mousemove", function(e) {
            if (!dragging || !panels) return;
            var rect = panels.getBoundingClientRect();
            var pct = ((e.clientX - rect.left) / rect.width) * 100;
            pct = Math.max(20, Math.min(80, pct));
            panels.style.gridTemplateColumns = pct + "% 6px 1fr";
          });

          document.addEventListener("mouseup", function() {
            if (dragging) {
              dragging = false;
              document.body.style.cursor = "";
              document.body.style.userSelect = "";
            }
          });
        }
      },
      CommandPalette: {
        mounted() {
          var self = this;
          this._handleKey = function(e) {
            if ((e.metaKey || e.ctrlKey) && e.key === "k") {
              e.preventDefault();
              self.pushEvent("toggle_command_palette", {});
            } else if (e.key === "Escape") {
              var palette = document.getElementById("command-palette");
              if (palette) {
                self.pushEvent("toggle_command_palette", {});
              } else {
                self.pushEvent("escape_pressed", {});
              }
            }
          };
          document.addEventListener("keydown", this._handleKey);
        },
        destroyed() {
          document.removeEventListener("keydown", this._handleKey);
        }
      }
    };

    window.addEventListener("phx:scroll_to_skill", function(e) {
      var id = e.detail.skill_id;
      var el = document.getElementById("skill-" + id);
      if (!el) return;

      // Open all parent <details> elements so the row is visible
      var node = el.parentElement;
      while (node) {
        if (node.tagName === "DETAILS") node.open = true;
        node = node.parentElement;
      }

      // Scroll and flash highlight
      setTimeout(function() {
        el.scrollIntoView({behavior: "smooth", block: "center"});
        el.classList.add("skill-highlight");
        setTimeout(function() { el.classList.remove("skill-highlight"); }, 2000);
      }, 100);
    });
    """
  end
end
