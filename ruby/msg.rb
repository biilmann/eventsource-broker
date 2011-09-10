#!/usr/bin/env ruby
require 'json'
require 'bunny'

chan = ARGV.first || "test"

client   = Bunny.new

client.start

exchange = client.exchange("eventsource.fanout", :type => :fanout)
queue    = client.queue

#puts "Enter messages (channell message)"
loop do
  # msg = gets.strip
  # _, chan, msg = *msg.match(/(\w+) (.+)/)
  msg = Time.now.to_s
  exchange.publish({
    :channel => chan,
    :data    => msg
  }.to_json)
  sleep 1
end
