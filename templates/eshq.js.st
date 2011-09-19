(function() {
  var origin = "$origin$";

  var Sub = function(channel, options) {
    for (var i in options) {
      this[i] = options[i];
    };
    this.channel = channel;
  }

  var subs = {};

  var onMessage = function(event) {
    if (event.origin !== origin) { return; }

    var data = JSON.parse(event.data);
    if (!data.eshqEvent) { return; }

    var sub = subs[data.channel];
    if (!sub) { return; }

    if (sub[data.eshqEvent]) { sub[data.eshqEvent].call(null, data.originalEvent); }
  };

  window.addEventListener("message", onMessage, false);

  var openChannel = function(channel) {
      var iframe = document.createElement("iframe");
      iframe.setAttribute("style", "display: none;");
      iframe.setAttribute("src", origin + "/iframe?channel=" + channel + "&t=" + new Date().getTime());
      document.body.appendChild(iframe);
      subs[channel].frame = iframe;
  };

  window.eshq = {
    open: function(channel, options) {
      subs[channel] = new Sub(channel, options || {});
      openChannel(channel);
    },
    send: function(channel, data) {
      var sub = subs[channel];
      if (!sub) throw "You must open a channel before sending to it";

      sub.frame.contentWindow.postMessage(data, "*");
    }
  };
})();
