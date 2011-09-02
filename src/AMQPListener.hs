{-# LANGUAGE OverloadedStrings #-}
module AMQPListener (AMQPEvent, amqpChannel, amqpData, amqpId, amqpName, openEventChannel) where

import           Network.AMQP
import           Data.Aeson
import           Data.Attoparsec(parse, maybeResult)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import           Control.Applicative
import           Control.Monad
import           Control.Monad.Trans
import           Control.Monad.Fix(fix)
import           Control.Concurrent
import           Control.Concurrent.Chan

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
