var output = document.getElementById("output");

if (typeof(console) == "undefined") {
  console = {log: function() {}};
}

setTimeout(function() {
  console.log("Loaded");

  var evtSrc = new EventSource( "/eventsource?channel=test" );

  evtSrc.onopen = function(e) {
    console.log("Open %o", e);
  };

  evtSrc.onerror = function(e) {
    console.log("Error %o", e);
  };

  evtSrc.onmessage = function(e) {
    console.log("Got event %o", e);
    var el = document.createElement("p")
    el.appendChild(document.createTextNode(e.data))
    output.insertBefore(el, output.firstChild);
  };
},50);
