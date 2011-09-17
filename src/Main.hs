{-# LANGUAGE OverloadedStrings #-}
module Main where

import           Control.Applicative((<|>))
import           Control.Monad.Trans(liftIO)
import           Control.Concurrent.Chan(Chan, readChan, dupChan)

import           Snap.Types
import           Snap.Util.FileServe(serveFile, serveDirectory)
import           Snap.Http.Server(quickHttpServe)

import           Data.Maybe (isJust, fromJust)
import           Data.ByteString(ByteString)
import           Blaze.ByteString.Builder(fromByteString)

import qualified System.UUID.V4 as UUID

import           AMQPEvents(AMQPEvent(..), openEventChannel, publishEvent)
import           EventStream(ServerEvent(..), eventSourceStream, eventSourceResponse)

import           System.Posix.Env(getEnvDefault)

import					 Text.StringTemplate


-- |Setup a channel listening to an AMQP exchange and start Snap
main :: IO ()
main = do
    uuid			<- UUID.uuid
    origin 		<- getEnvDefault "ORIGIN" "http://127.0.0.1"
    templates <- directoryGroup "templates" :: IO (STGroup ByteString)

    let queue = "eventsource." ++ (show uuid)

    (publisher, listener) <- openEventChannel queue

    let Just js = fmap (render . (setAttribute "origin" origin)) (getStringTemplate "eshq.js" templates)

    quickHttpServe $
        ifTop (serveFile "static/index.html") <|>
        path "iframe" (serveFile "static/iframe.html") <|>
        path "es.js" (writeBS js) <|>
        dir "static" (serveDirectory "static") <|>
        method POST (route [ ("event", postEvent publisher queue) ]) <|>
        route [ ("eventsource", eventSource listener) ]


postEvent chan queue = do
    channelParam <- getParam "channel"
    dataParam    <- getParam "data"
    if (isJust channelParam) && (isJust dataParam)
        then do
            liftIO $ publishEvent chan queue $ AMQPEvent (fromJust channelParam) (fromJust dataParam) Nothing Nothing
            writeBS "OK"
        else
            badRequest


-- |Stream events from a channel of AMQPEvents to EventSource
eventSource :: Chan AMQPEvent -> Snap ()
eventSource chan = do
    chan'   <- liftIO $ dupChan chan
    channelParam <- getParam "channel"
    case channelParam of
        Just channelId -> do
          transport <- getTransport
          transport $ filterEvents channelId chan'
        Nothing -> badRequest


badRequest = do
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
