#!/usr/bin/env ruby
require 'json'
require 'bunny'

client   = Bunny.new

client.start

exchange = client.exchange("eventsource.fanout", :type => :fanout)
queue    = client.queue

#puts "Enter messages (channell message)"
loop do
  # msg = gets.strip
  msg = Time.now.to_s
  _, chan, msg = *msg.match(/(\w+) (.+)/)
  exchange.publish({
    :channel => chan,
    :data    => msg
  }.to_json)
  sleep 1000
end
