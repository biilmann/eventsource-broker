{-# LANGUAGE OverloadedStrings #-}
module Main where

import           Control.Applicative
import           Network.AMQP
import           Control.Monad
import           Control.Monad.Trans
import           Control.Monad.Fix(fix)
import           Control.Concurrent
import           Control.Concurrent.MVar
import           Control.Concurrent.Chan
import           Snap.Types
import           Snap.Util.FileServe
import           Snap.Http.Server
--import           Snap.Iteratee
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import           Blaze.ByteString.Builder
import           Data.Aeson
import           Data.Attoparsec(parse, maybeResult)
import           EventStream

data AMQPEvent = AMQPEvent { amqpChannel :: B.ByteString, amqpData :: B.ByteString }

instance FromJSON AMQPEvent where
    parseJSON (Object v) = AMQPEvent <$>
                           v .: "channel" <*>
                           v .: "data"
    parseJSON _           = mzero

main :: IO ()
main = do
    listener <- getExchangeListener

    quickHttpServe $
        ifTop (serveFile "static/index.html") <|>
        dir "static" (serveDirectory "static") <|>
        route [ ("eventsource", eventHandler listener) ]

getExchangeListener = do
    listener <- newChan

    forkIO $ fix $ \loop -> do
        _ <- readChan listener
        loop

    conn <- openConnection "127.0.0.1" "/" "guest" "guest"
    chan <- openChannel conn

    let queue = "haskell.queue-1"

    -- declare a queue, exchange and binding
    declareQueue chan newQueue {queueName = queue, queueAutoDelete = True}
    declareExchange chan newExchange {exchangeName = "haskell.fanout", exchangeType = "fanout"}
    bindQueue chan queue "haskell.fanout" queue

    consumeMsgs chan queue NoAck (sendTo listener)

    return listener

sendTo chan (msg, envelope) =
    case maybeResult $ parse json (B.concat $ LB.toChunks (msgBody msg)) of
        Just value -> case fromJSON value of
            Success event -> do
                putStrLn "Sending message"
                writeChan chan (amqpChannel event, ServerEvent Nothing Nothing [fromByteString $ amqpData event])
            Error _       -> return ()
        Nothing    -> return ()

messagesFor id chan = do
    (msgId, event) <- readChan chan
    if msgId == id then return event else messagesFor id chan

eventHandler chan = do
    chan'   <- liftIO $ dupChan chan
    idParam <- getParam "id"
    case idParam of
        Just id -> eventStreamPull $ messagesFor id chan'
        Nothing -> do
          modifyResponse $ setResponseCode 401
          writeBS "Bad Request - no channel id"
          r <- getResponse
          finishWith r
