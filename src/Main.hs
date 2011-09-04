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
import           EventStream(ServerEvent(..), eventStreamPull)

main :: IO ()
main = do
    uuid <- UUID.uuid

    listener <- openEventChannel "eventsource.fanout" $ "eventsource." ++ (show uuid)

    quickHttpServe $
        ifTop (serveFile "static/index.html") <|>
        dir "static" (serveDirectory "static") <|>
        route [ ("eventsource", eventHandler listener) ]

messagesFor :: ByteString -> Chan AMQPEvent -> IO ServerEvent
messagesFor channelId chan = do
    event <- readChan chan
    if amqpChannel event == channelId
        then return $ ServerEvent (fmap fromByteString $ amqpName event) (fmap fromByteString $ amqpId event) [fromByteString $ amqpData event]
        else messagesFor channelId chan

eventHandler :: Chan AMQPEvent -> Snap ()
eventHandler chan = do
    chan'   <- liftIO $ dupChan chan
    channelParam <- getParam "channel"
    case channelParam of
        Just channelId -> eventStreamPull $ messagesFor channelId chan'
        Nothing -> do
          modifyResponse $ setResponseCode 401
          writeBS "Bad Request - no channel id"
          r <- getResponse
          finishWith r
