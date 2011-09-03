{-# LANGUAGE OverloadedStrings #-}
module AMQPListener (
        AMQPEvent(..),
        openEventChannel
    ) where

import           Control.Applicative((<$>), (<*>))
import           Control.Monad(mzero)
import           Control.Monad.Fix(fix)
import           Control.Concurrent(forkIO)
import           Control.Concurrent.Chan(newChan, readChan, writeChan)

import           Data.Aeson(FromJSON(..), Value(..), Result(..), fromJSON, json, (.:), (.:?))
import           Data.Attoparsec(parse, maybeResult)

import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB

import           Network.AMQP

data AMQPEvent = AMQPEvent {
                    amqpChannel :: B.ByteString,
                    amqpData :: B.ByteString,
                    amqpId :: Maybe B.ByteString,
                    amqpName :: Maybe B.ByteString 
                 }

instance FromJSON AMQPEvent where
    parseJSON (Object v) = AMQPEvent <$>
                           v .: "channel" <*>
                           v .: "data" <*>
                           v .:? "id" <*>
                           v .:? "name"
    parseJSON _           = mzero

openEventChannel host vhost user password exchange queue = do
    listener <- newChan

    forkIO $ fix $ \loop -> readChan listener >> loop

    conn <- openConnection host vhost user password
    chan <- openChannel conn

    declareQueue chan newQueue {queueName = queue, queueAutoDelete = True, queueDurable = False}
    declareExchange chan newExchange {exchangeName = exchange, exchangeType = "fanout", exchangeDurable = False}
    bindQueue chan queue exchange queue

    consumeMsgs chan queue NoAck (sendTo listener)

    return listener

sendTo chan (msg, envelope) =
    case maybeResult $ parse json (B.concat $ LB.toChunks (msgBody msg)) of
        Just value -> case fromJSON value of
            Success event -> do
                writeChan chan event
            Error e       -> do
                return ()
        Nothing    -> return ()
