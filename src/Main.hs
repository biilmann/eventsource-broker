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
import           Data.Digest.Pure.SHA (sha1, bytestringDigest)
import           Data.Time.Clock.POSIX (POSIXTime)
import           Blaze.ByteString.Builder(fromByteString)

import qualified System.UUID.V4 as UUID

import           AMQPEvents(AMQPEvent(..), Channel, openEventChannel, publishEvent)
import           EventStream(ServerEvent(..), eventSourceStream, eventSourceResponse)

import           DB

import qualified Models.Connection as Conn
import qualified Models.User as User

import           System.Posix.Env(getEnvDefault)
import           Data.Time.Clock.POSIX (getPOSIXTime)

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

    bracket openDB (\db -> Conn.remove db uuid >> closeDB db) $ \db -> do
        forkIO $ connectionSweeper db uuid
        quickHttpServe $
            ifTop (serveFile "static/index.html") <|>
            path "iframe" (serveFile "static/iframe.html") <|>
            path "es.js" (serveJS js) <|>
            dir "static" (serveDirectory "static") <|>
            method POST (route [ 
                ("event", postEvent db publisher queue),
                ("socket", createSocket db uuid),
                ("socket/:sid", postEventFromSocket db publisher queue)
            ]) <|>
            method GET (route [
                ("broker", brokerInfo db uuid),
                ("eventsource", eventSource db uuid listener) 
            ])


-- |Clean up disconnected connections for this broker at regular intervals
connectionSweeper :: DB -> UString -> IO ()
connectionSweeper db uuid = do
    threadDelay 15000000
    Conn.sweep db uuid
    connectionSweeper db uuid


brokerInfo :: DB -> UString -> Snap ()
brokerInfo db uuid = do
    result <- liftIO $ Conn.count db uuid
    case result of
        Right count -> do
            modifyResponse $ setContentType "application/json"
            writeBS $ BS.pack $ "{\"brokerId\": " ++ (show uuid) ++ ", \"connections\": " ++ (show count) ++ "}"
        Left e -> do
            modifyResponse $ setResponseCode 500
            writeBS $ BS.pack $ "Database Connection Problem: " ++ (show e)

-- |Create a new socket and return the ID
createSocket :: DB -> UString -> Snap ()
createSocket db uuid = do
    withAuth db $ \user -> do
      withParam "channel" $ \channel -> do
        socketId   <- liftIO $ fmap show UUID.uuid
        presenceId <- getParam "presence_id"
        result     <- liftIO $ Conn.store db Conn.Connection {
              Conn.socketId     = u socketId
            , Conn.brokerId     = uuid
            , Conn.userId       = User.apiKey user
            , Conn.channel      = channel
            , Conn.presenceId   = fmap ufrombs presenceId
            , Conn.disconnectAt = Just 10
        }
        case result of
          Left  _ -> showError 500 "Database Connection Error"
          Right _ -> do
              modifyResponse $ setContentType "application/json"
              writeBS $ BS.pack ("{\"socket\": \"" ++ socketId ++ "\"}")


postEvent :: DB -> Channel -> UString -> Snap ()
postEvent db chan queue =
    withAuth db $ \user ->
      withParam "channel" $ \channel ->
          withParam "data" $ \dataParam -> do
              liftIO $ publishEvent chan (show queue) $
                  AMQPEvent (utobs channel) (utobs $ User.apiKey user) (utobs dataParam) Nothing Nothing
              writeBS "Ok"

-- |Post a new event from a socket.
postEventFromSocket :: DB -> Channel -> UString -> Snap ()
postEventFromSocket db chan queue =
    withConnection db $ \conn ->
        withParam "data" $ \dataParam -> do
            liftIO $ publishEvent chan (show queue) $ 
                AMQPEvent (utobs $ Conn.channel conn) (utobs $ Conn.userId conn) (utobs dataParam) Nothing Nothing
            writeBS "Ok"


-- |Stream events from a channel of AMQPEvents to EventSource
eventSource :: DB -> UString -> Chan AMQPEvent -> Snap ()
eventSource db uuid chan = do
    chan'   <- liftIO $ dupChan chan
    withConnection db $ \conn -> do
      liftIO $ before conn
      transport <- getTransport
      transport (filterEvents conn chan') (after conn)
  where
    before conn = Conn.store db conn >> return ()
    after conn = Conn.mark db (conn { Conn.disconnectAt = Just 10 } ) >> return ()

serveJS :: ByteString -> Snap ()
serveJS js = do
    modifyResponse $ setContentType "text/javascript; charset=UTF-8"
    writeBS js


withParam :: UString -> (UString -> Snap ()) -> Snap ()
withParam param fn = do
    param' <- getParam (utobs param)
    case param' of
        Just value -> fn (ufrombs value)
        Nothing    -> showError 400 $ BS.concat ["Missing param: ", utobs param]


withConnection :: DB -> (Conn.Connection -> Snap ()) -> Snap ()
withConnection db fn = do
    withParam "socket" $ \sid -> do
        result <- liftIO $ Conn.get db sid
        case result of
            Just conn -> fn conn
            Nothing   -> showError 404 $ BS.concat ["No socket found with id: ", utobs sid]


withAuth :: DB -> (User.User -> Snap ()) -> Snap ()
withAuth db handler = do
  key       <- getParam "key"
  token     <- getParam "token"
  timestamp <- getParam "timestamp"

  case (key, token, timestamp) of
    (Just key', Just token', Just timestamp') -> do
      currentTime <- liftIO getPOSIXTime
      currentUser <- liftIO $ User.get db (ufrombs key')
      case currentUser of
        Just user -> 
            if validTime timestamp' currentTime && User.authenticate user token' timestamp'
              then handler user
              else showError 401 "Access Denied"
        Nothing -> showError 404 "User not found"
    _ -> showError 400 "Bad Request - Missing authentication parameters"

validTime :: ByteString -> POSIXTime -> Bool
validTime timestamp currentTime =
    let t1 = read $ BS.unpack timestamp
        t2 = floor currentTime in
        abs (t1 - t2) < 5 * 60

showError :: Int -> ByteString -> Snap ()
showError code msg = do
    modifyResponse $ setResponseCode code
    writeBS msg
    r <- getResponse
    finishWith r

-- |Returns the transport method to use for this request
getTransport :: Snap (IO ServerEvent -> IO () -> Snap ())
getTransport = withRequest $ \request ->
    case getHeader "X-Requested-With" request of
      Just "XMLHttpRequest" -> return eventSourceResponse
      _                     -> return eventSourceStream

-- |Filter AMQPEvents by channelId
filterEvents :: Conn.Connection -> Chan AMQPEvent -> IO ServerEvent
filterEvents conn chan = do
    event <- readChan chan
    if amqpUser event == userId && amqpChannel event == channel
        then return $ ServerEvent (toBS $ amqpName event) (toBS $ amqpId event) [fromByteString $ amqpData event]
        else filterEvents conn chan
  where
    toBS    = fmap fromByteString
    userId  = utobs $ Conn.userId conn
    channel = utobs $ Conn.channel conn


ufrombs :: ByteString -> UString
ufrombs = US.fromByteString_


utobs :: UString -> ByteString
utobs = US.toByteString
