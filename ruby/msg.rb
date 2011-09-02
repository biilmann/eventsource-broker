#!/usr/bin/env ruby
require 'json'
require 'bunny'

client   = Bunny.new

client.start

exchange = client.exchange("haskell.fanout", :type => :fanout)
queue    = client.queue

puts "Enter messages (channell message)"
loop do
  msg = gets.strip
  _, chan, msg = *msg.match(/(\w+) (.+)/)
  exchange.publish({
    :channel => chan,
    :data    => msg
  }.to_json)
end
