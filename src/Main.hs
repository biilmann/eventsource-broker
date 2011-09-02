{-# LANGUAGE OverloadedStrings #-}
module Main where

import           Control.Applicative
import           Control.Monad
import           Control.Monad.Trans
import           Control.Monad.Fix(fix)
import           Control.Concurrent.Chan
import           Snap.Types
import           Snap.Util.FileServe
import           Snap.Http.Server
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import           Blaze.ByteString.Builder
import           AMQPListener
import           EventStream

main :: IO ()
main = do
    listener <- openEventChannel "localhost" "/" "guest" "guest" "haskell.fanout" "haskell.queue-1"

    quickHttpServe $
        ifTop (serveFile "static/index.html") <|>
        dir "static" (serveDirectory "static") <|>
        route [ ("eventsource", eventHandler listener) ]

messagesFor id chan = do
    event <- readChan chan
    if amqpChannel event == id
        then return $ ServerEvent (fmap fromByteString $ amqpName event) (fmap fromByteString $ amqpId event) [fromByteString $ amqpData event]
        else messagesFor id chan

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
