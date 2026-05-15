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

      CloseDetailsOnOutsideClick: {
        mounted() {
          var self = this;

          this._closeOnOutsideClick = function(e) {
            if (self.el.open && !self.el.contains(e.target)) {
              self.el.open = false;
            }
          };

          this._closeOnEscape = function(e) {
            if (e.key === "Escape" && self.el.open) {
              self.el.open = false;
            }
          };

          document.addEventListener("click", this._closeOnOutsideClick);
          document.addEventListener("keydown", this._closeOnEscape);
        },
        destroyed() {
          document.removeEventListener("click", this._closeOnOutsideClick);
          document.removeEventListener("keydown", this._closeOnEscape);
        }
      },

      ChatReorder: {
        mounted() {
          var self = this;
          this.draggedRow = null;
          this.startOrder = "";

          this.onDragStart = function(e) {
            var handle = e.target.closest(".chat-drag-handle");
            if (!handle || !self.el.contains(handle)) return;

            var row = handle.closest(".chat-row");
            if (!row) return;

            self.draggedRow = row;
            self.startOrder = self.orderKey();
            row.classList.add("is-dragging");

            if (e.dataTransfer) {
              e.dataTransfer.effectAllowed = "move";
              e.dataTransfer.setData("text/plain", row.dataset.chatId || "");
            }
          };

          this.onDragOver = function(e) {
            if (!self.draggedRow) return;
            e.preventDefault();

            var target = e.target.closest(".chat-row");
            if (!target || target === self.draggedRow || !self.el.contains(target)) return;

            var rect = target.getBoundingClientRect();
            var after = e.clientY > rect.top + rect.height / 2;
            self.el.insertBefore(self.draggedRow, after ? target.nextSibling : target);
          };

          this.onDrop = function(e) {
            if (!self.draggedRow) return;
            e.preventDefault();
            self.finishDrag();
          };

          this.onDragEnd = function() {
            self.finishDrag();
          };

          this.el.addEventListener("dragstart", this.onDragStart);
          this.el.addEventListener("dragover", this.onDragOver);
          this.el.addEventListener("drop", this.onDrop);
          this.el.addEventListener("dragend", this.onDragEnd);
        },
        destroyed() {
          this.el.removeEventListener("dragstart", this.onDragStart);
          this.el.removeEventListener("dragover", this.onDragOver);
          this.el.removeEventListener("drop", this.onDrop);
          this.el.removeEventListener("dragend", this.onDragEnd);
        },
        orderKey() {
          return Array.from(this.el.querySelectorAll(".chat-row"))
            .map(function(row) { return row.dataset.conversationId || ""; })
            .filter(Boolean)
            .filter(function(id, idx, ids) { return ids.indexOf(id) === idx; })
            .join("|");
        },
        finishDrag() {
          if (!this.draggedRow) return;

          this.draggedRow.classList.remove("is-dragging");
          this.draggedRow = null;

          var nextOrder = this.orderKey();
          if (!nextOrder || nextOrder === this.startOrder) return;

          this.pushEvent("reorder_chats", {
            conversation_ids: nextOrder.split("|")
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

      WelcomeTypewriter: {
        mounted() {
          window.__rhoWelcomeShown = window.__rhoWelcomeShown || {};
          var key = this.el.getAttribute("data-welcome-key") || this.el.id;
          var raw = this.el.getAttribute("data-md") || "";
          var html;
          if (window.marked) {
            html = window.marked.parse(raw, { breaks: true });
            html = window.DOMPurify ? DOMPurify.sanitize(html) : html;
          } else {
            html = raw.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
          }

          // Already played in this tab — render finished state and bail.
          var storageKey = "rho:" + key + ":shown";
          var storedShown = false;
          try {
            storedShown = window.sessionStorage && window.sessionStorage.getItem(storageKey) === "1";
          } catch (_e) {
            storedShown = false;
          }

          if (window.__rhoWelcomeShown[key] || storedShown) {
            this.el.innerHTML = html;
            var card0 = this.el.closest(".welcome-card");
            if (card0) card0.classList.add("welcome-already-shown");
            return;
          }

          window.__rhoWelcomeShown[key] = true;
          try {
            if (window.sessionStorage) window.sessionStorage.setItem(storageKey, "1");
          } catch (_e) {}

          var src = document.createElement("div");
          src.innerHTML = html;

          this._timer = null;
          this.el.innerHTML = "";

          // Build an action queue. Element opens are queued but not emitted
          // until the first character inside them is reached, so list bullets
          // (and any other element-rendered chrome) appear in sync with their
          // first letter rather than popping in upfront as empty shells.
          var actions = [];
          var pending = [];

          function attrsOf(el) {
            var out = [];
            for (var i = 0; i < el.attributes.length; i++) {
              out.push([el.attributes[i].name, el.attributes[i].value]);
            }
            return out;
          }

          (function walk(srcNode) {
            for (var i = 0; i < srcNode.childNodes.length; i++) {
              var s = srcNode.childNodes[i];
              if (s.nodeType === 3) {
                var text = s.textContent;
                if (!text || !/\S/.test(text)) continue;
                while (pending.length) {
                  var p = pending.shift();
                  p.emitted = true;
                  actions.push(p);
                }
                var textRef = { node: null };
                actions.push({ kind: "text-init", ref: textRef });
                for (var j = 0; j < text.length; j++) {
                  actions.push({ kind: "char", ref: textRef, ch: text[j] });
                }
              } else if (s.nodeType === 1) {
                var openAction = {
                  kind: "open",
                  tag: s.nodeName,
                  attrs: attrsOf(s),
                  emitted: false
                };
                pending.push(openAction);
                walk(s);
                var stillPending = pending.indexOf(openAction);
                if (stillPending !== -1) {
                  pending.splice(stillPending, 1);
                } else if (openAction.emitted) {
                  actions.push({ kind: "close" });
                }
              }
            }
          })(src);

          this._actions = actions;
          this._idx = 0;
          this._stack = [this.el];

          this._caret = document.createElement("span");
          this._caret.className = "welcome-caret";
          this.el.appendChild(this._caret);

          this._tick();
        },
        _consume(a) {
          var top = this._stack[this._stack.length - 1];
          if (a.kind === "open") {
            var el = document.createElement(a.tag);
            for (var i = 0; i < a.attrs.length; i++) {
              el.setAttribute(a.attrs[i][0], a.attrs[i][1]);
            }
            // Insert before caret so caret stays at the visible tail
            if (this._caret && this._caret.parentNode === top) {
              top.insertBefore(el, this._caret);
            } else {
              top.appendChild(el);
            }
            this._stack.push(el);
          } else if (a.kind === "close") {
            this._stack.pop();
            // Move caret back up into the now-current parent
            var parent = this._stack[this._stack.length - 1];
            if (this._caret && parent) parent.appendChild(this._caret);
          } else if (a.kind === "text-init") {
            var t = document.createTextNode("");
            if (this._caret && this._caret.parentNode === top) {
              top.insertBefore(t, this._caret);
            } else {
              top.appendChild(t);
            }
            a.ref.node = t;
          }
        },
        _tick() {
          var self = this;
          while (this._idx < this._actions.length && this._actions[this._idx].kind !== "char") {
            this._consume(this._actions[this._idx++]);
          }
          if (this._idx >= this._actions.length) {
            if (this._caret && this._caret.parentNode) {
              this._caret.parentNode.removeChild(this._caret);
            }
            var card = this.el.closest(".welcome-card");
            if (card) card.classList.add("welcome-typed");
            window.__rhoWelcomeShown = window.__rhoWelcomeShown || {};
            window.__rhoWelcomeShown[this.el.getAttribute("data-welcome-key") || this.el.id] = true;
            return;
          }
          var entry = this._actions[this._idx++];
          var node = entry.ref.node;
          if (node.appendData) node.appendData(entry.ch);
          else node.textContent += entry.ch;
          var feed = this.el.closest(".chat-feed");
          if (feed) feed.scrollTop = feed.scrollHeight;
          var ch = entry.ch;
          var delay;
          if (ch === " ") delay = 2;
          else if (ch === "\n") delay = 20;
          else if (".,;:!?".indexOf(ch) >= 0) delay = 30;
          else delay = 3 + Math.random() * 5;
          this._timer = setTimeout(function() { self._tick(); }, delay);
        },
        destroyed() {
          if (this._timer) clearTimeout(this._timer);
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

      Autosize: {
        mounted() {
          var el = this.el;
          el.focus();
          var len = el.value ? el.value.length : 0;
          if (el.setSelectionRange) el.setSelectionRange(len, len);
          var resize = function() {
            el.style.height = "auto";
            el.style.height = el.scrollHeight + "px";
          };
          this._resize = resize;
          el.addEventListener("input", resize);
          resize();
        },
        destroyed() {
          if (this._resize) this.el.removeEventListener("input", this._resize);
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
