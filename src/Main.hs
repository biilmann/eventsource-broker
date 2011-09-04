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

import           AMQPListener(AMQPEvent(..), openEventChannel)
import           EventStream(ServerEvent(..), eventStreamPull)

main :: IO ()
main = do
    listener <- openEventChannel "eventsource.fanout" "eventsource.queue"

    quickHttpServe $
        ifTop (serveFile "static/index.html") <|>
        dir "static" (serveDirectory "static") <|>
        route [ ("eventsource", eventHandler listener) ]

messagesFor :: ByteString -> Chan AMQPEvent -> IO ServerEvent
messagesFor handlerId chan = do
    event <- readChan chan
    if amqpChannel event == handlerId
        then return $ ServerEvent (fmap fromByteString $ amqpName event) (fmap fromByteString $ amqpId event) [fromByteString $ amqpData event]
        else messagesFor handlerId chan

eventHandler :: Chan AMQPEvent -> Snap ()
eventHandler chan = do
    chan'   <- liftIO $ dupChan chan
    idParam <- getParam "id"
    case idParam of
        Just handlerId -> eventStreamPull $ messagesFor handlerId chan'
        Nothing -> do
          modifyResponse $ setResponseCode 401
          writeBS "Bad Request - no channel id"
          r <- getResponse
          finishWith r
