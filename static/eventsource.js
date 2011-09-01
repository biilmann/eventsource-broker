setTimeout(function() {
  console.log("Loaded");

  var evtSrc = new EventSource( "/eventsource" );

  evtSrc.onopen = function(e) {
    console.log("Open %o", e);
  };

  evtSrc.onerror = function(e) {
    console.log("Error %o", e);
  };

  evtSrc.onmessage = function(e) {
    console.log("Got event %o", e);
  };
},50);
