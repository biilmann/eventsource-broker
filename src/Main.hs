{-# LANGUAGE OverloadedStrings #-}
module Main where

import           Control.Applicative ((<|>))
import           Control.Monad.Trans (liftIO)
import           Control.Concurrent (forkIO, threadDelay)
import           Control.Concurrent.Chan (Chan, readChan, dupChan)
import           Control.Exception (bracket)

import           Snap.Types
import           Snap.Util.FileServe (serveFile, serveDirectory)
import           Snap.Http.Server( quickHttpServe)

import           Data.ByteString(ByteString)
import qualified Data.ByteString.Char8 as BS
import           Data.UString (UString, u)
import qualified Data.UString as US
import           Blaze.ByteString.Builder(fromByteString)

import qualified System.UUID.V4 as UUID

import           AMQPEvents(AMQPEvent(..), Channel, openEventChannel, publishEvent)
import           EventStream(ServerEvent(..), eventSourceStream, eventSourceResponse)
import           DB

import           System.Posix.Env(getEnvDefault)

import           Text.StringTemplate


-- |Setup a channel listening to an AMQP exchange and start Snap
main :: IO ()
main = do
    uuid      <- fmap (u . show) UUID.uuid
    origin    <- getEnvDefault "ORIGIN" "http://127.0.0.1"
    templates <- directoryGroup "templates" :: IO (STGroup ByteString)

    let queue = US.append "eventsource." uuid
    let Just js = fmap (render . (setAttribute "origin" origin)) (getStringTemplate "eshq.js" templates)

    (publisher, listener) <- openEventChannel (show queue)

    bracket openDB (\db -> disconnectBroker db uuid >> closeDB db) $ \db -> do
        forkIO $ connectionSweeper db uuid
        quickHttpServe $
            ifTop (serveFile "static/index.html") <|>
            path "iframe" (serveFile "static/iframe.html") <|>
            path "es.js" (serveJS js) <|>
            dir "static" (serveDirectory "static") <|>
            method POST (route [ 
                ("event", postEvent db publisher queue),
                ("socket", createSocket db uuid)
            ]) <|>
            method GET (route [
                ("broker", brokerInfo db uuid),
                ("eventsource", eventSource db uuid listener) 
            ])


-- |Clean up disconnected connections for this broker at regular intervals
connectionSweeper :: DB -> UString -> IO ()
connectionSweeper db uuid = do
    threadDelay 15000000
    sweepConnections db uuid
    connectionSweeper db uuid


brokerInfo :: DB -> UString -> Snap ()
brokerInfo db uuid = do
    result <- liftIO $ getConnectionCount db uuid
    case result of
        Right count -> do
            modifyResponse $ setContentType "application/json"
            writeBS $ BS.pack $ "{\"brokerId\": \"" ++ (show uuid) ++ "\", \"connections\": " ++ (show count) ++ "}"
        Left e -> do
            modifyResponse $ setResponseCode 500
            writeBS $ BS.pack $ "Database Connection Problem: " ++ (show e)

-- |Create a new socket and return the ID
createSocket :: DB -> UString -> Snap ()
createSocket db uuid = do
    withParam "channel" $ \cid -> do
      sid <- liftIO $ fmap show UUID.uuid
      uid <- getParam "user_id"
      result   <- liftIO $ storeConnection db ESConnection {
            socketId     = u sid
          , brokerId     = uuid
          , channel      = cid
          , userId       = fmap US.fromByteString_ uid
          , disconnectAt = Just 10
      }
      case result of
        Left  _ -> badRequest
        Right _ -> do
            modifyResponse $ setContentType "application/json"
            writeBS $ BS.pack ("{\"socket\": \"" ++ sid ++ "\"}")


-- |Post a new event.
postEvent :: DB -> Channel -> UString -> Snap ()
postEvent db chan queue = do
    withConnection db $ \conn -> do
        withParam "data" (\dataParam -> do
            liftIO $ publishEvent chan (show queue) $ 
                AMQPEvent (US.toByteString $ channel conn) (US.toByteString dataParam) Nothing Nothing
            writeBS "OK")


-- |Stream events from a channel of AMQPEvents to EventSource
eventSource :: DB -> UString -> Chan AMQPEvent -> Snap ()
eventSource db uuid chan = do
    chan'   <- liftIO $ dupChan chan
    withConnection db $ \conn -> do
      liftIO $ before conn
      transport <- getTransport
      transport (filterEvents (US.toByteString $ channel conn) chan') (after conn)
  where
    before conn = storeConnection db conn >> return ()
    after conn = markConnection db (conn { disconnectAt = Just 10 } ) >> return ()

serveJS :: ByteString -> Snap ()
serveJS js = do
    modifyResponse $ setContentType "text/javascript; charset=UTF-8"
    writeBS js


withParam :: UString -> (UString -> Snap ()) -> Snap ()
withParam param fn = do
    param' <- getParam (US.toByteString param)
    case param' of
        Just value -> fn (US.fromByteString_ value)
        Nothing    -> badRequest


withConnection :: DB -> (ESConnection -> Snap ()) -> Snap ()
withConnection db fn = do
    withParam "socket" $ \sid -> do
        result <- liftIO $ getConnection db sid
        case result of
            Just conn -> fn conn
            Nothing   -> badRequest


badRequest :: Snap ()
badRequest = do
    modifyResponse $ setResponseCode 401
    writeBS "Bad Request - no channel id"
    r <- getResponse
    finishWith r


-- |Returns the transport method to use for this request
getTransport :: Snap (IO ServerEvent -> IO () -> Snap ())
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
