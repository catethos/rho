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

      Markdown: {
        mounted() {
          this.render();
        },
        updated() {
          this.render();
        },
        render() {
          var raw = this.el.getAttribute("data-md");
          if (raw && window.marked) {
            var html = window.marked.parse(raw, { breaks: true });
            this.el.innerHTML = window.DOMPurify ? DOMPurify.sanitize(html) : html;
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
      }
    };
    """
  end
end
