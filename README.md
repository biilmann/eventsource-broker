EvenSource Broker
=================

A simple bridge between EventSource and an AMQP fanout exchange.

EventSource is a new browser standard released as part of the HTML5
spec.

It lets the browser send a never-ending HTTP request to a server and
provides a javascript API for binding to events pushed from the server.

EventSource is very handy when you don't need the full bidirectional
communication that Websockets offers. it plays well with load-balancers,
intermediary proxies and HTTPS termination.

This library sets up an EventSource that clients can connect to
specifying a channel to listen to in the query string. The server
connects to a fanout AMQP exchange and routes AMQP messages as events to
the javascript clients.

The server expects the AMQP messages to be JSON following the format:

    {
        "channel": "some-channel", // Required
        "data": "{/"msg/": /"data/"}", // Required
        "id": "event-id", // optional
        "name": "event-name" // optional
    }

Installation
============

Clone the repository, cd to the root of it and execute

    cabal install

Run as:

    eventsource-broker -p <port>

The broker will look for an AMQP_URL environment variable for a broker
to connect to.

The repository includes a small ruby script to send data to channels and
the server will by default serve up a simple index page subscribing to
the channel "test".

License
=======

Copyright (c)2011, Mathias Biilmann <info@mathias-biilmann.net>

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.

    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.

    * Neither the name of Mathias Biilman <info@mathias-biilmann.net>
      nor the names of other contributors may be used to endorse or
      promote products derived from this software without specific prior
      written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE
