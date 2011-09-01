#!/usr/bin/env ruby
require 'bunny'

client   = Bunny.new

client.start

exchange = client.exchange("haskell.fanout", :durable => true, :type => :fanout)
queue    = client.queue

loop do
  exchange.publish gets.strip
end
