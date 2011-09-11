{-# LANGUAGE OverloadedStrings #-}
module Main where

import           Control.Applicative((<|>))
import           Control.Monad.Trans(liftIO)
import           Control.Concurrent.Chan(Chan, readChan, dupChan)

import           Snap.Types
import           Snap.Util.FileServe(serveFile, serveDirectory)
import           Snap.Http.Server(quickHttpServe)

import           Data.ByteString(ByteString)
import           Blaze.ByteString.Builder(fromByteString)

import qualified System.UUID.V4 as UUID

import           AMQPListener(AMQPEvent(..), openEventChannel)
import           EventStream(ServerEvent(..), eventSourceStream, eventSourceResponse)

-- |Setup a channel listening to an AMQP exchange and start Snap
main :: IO ()
main = do
    uuid <- UUID.uuid

    listener <- openEventChannel "eventsource.fanout" $ "eventsource." ++ (show uuid)

    quickHttpServe $
        ifTop (serveFile "static/index.html") <|>
        dir "static" (serveDirectory "static") <|>
        route [ ("eventsource", eventSource listener) ]


-- |Stream events from a channel of AMQPEvents to EventSource
eventSource :: Chan AMQPEvent -> Snap ()
eventSource chan = do
    chan'   <- liftIO $ dupChan chan
    channelParam <- getParam "channel"
    case channelParam of
        Just channelId -> do
          transport <- getTransport
          transport $ filterEvents channelId chan'
        Nothing -> do
          modifyResponse $ setResponseCode 401
          writeBS "Bad Request - no channel id"
          r <- getResponse
          finishWith r

-- |Returns the transport method to use for this request
getTransport :: Snap (IO ServerEvent -> Snap ())
getTransport = withRequest $ \request ->
    case getHeader "X-Requested-With" request of
      Just "XMLHttpRequest" -> return eventSourceResponse
      _                     -> return eventSourceStream

-- |Filter AMQPEvents by channelId
filterEvents :: ByteString -> Chan AMQPEvent -> IO ServerEvent
filterEvents channelId chan = do
    event <- readChan chan
    if amqpChannel event == channelId
        then return $ ServerEvent (toBS $ amqpName event) (toBS $ amqpId event) [fromByteString $ amqpData event]
        else filterEvents channelId chan
  where
    toBS = fmap fromByteString
