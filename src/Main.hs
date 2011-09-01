{-# LANGUAGE OverloadedStrings #-}
module Main where

import           Control.Applicative
import           Network.AMQP
import           Control.Monad.Trans
import           Control.Concurrent
import           Control.Concurrent.MVar
import           Control.Concurrent.Chan
import           Snap.Types
import           Snap.Util.FileServe
import           Snap.Http.Server
import           Snap.Iteratee
import qualified Data.ByteString as B
import           Blaze.ByteString.Builder
import           EventStream

main :: IO ()
main = do
    listener <- newChan

    conn <- openConnection "127.0.0.1" "/" "guest" "guest"
    chan <- openChannel conn

    let queue = "haskell.queue-1"

    -- declare a queue, exchange and binding
    declareQueue chan newQueue {queueName = queue, queueAutoDelete = True}
    declareExchange chan newExchange {exchangeName = "haskell.fanout", exchangeType = "fanout"}
    bindQueue chan queue "haskell.fanout" queue

    consumeMsgs chan queue NoAck (sendTo listener)

    quickHttpServe $
        ifTop (serveFile "static/index.html") <|>
        dir "static" (serveDirectory "static") <|>
        route [ ("eventsource", eventHandler listener) ]

sendTo chan (msg, envelope) = do
    putStrLn "Sending message" 
    writeChan chan $ ServerEvent Nothing Nothing [fromLazyByteString $ msgBody msg] 

--eventHandler :: MVar [Chan B.ByteString] -> Snap ()
eventHandler chan = do
    chan' <- liftIO $ dupChan chan
    eventStreamPull (readChan chan')
