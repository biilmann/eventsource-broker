{-# LANGUAGE OverloadedStrings #-}
module DB 
    (
      DB,
      withDB,
      openDB,
      closeDB,
      storeConnection,
      markConnection,
      sweepConnections,
      disconnectBroker,
      getChannel
    ) where

import           Prelude hiding (lookup)

import           Control.Exception (bracket)

import           System.Posix.Env(getEnvDefault)
import           Data.String.Utils(split)
import           Text.URI(URI(..), parseURI)

import           Data.UString (UString, u)
import           Data.Maybe (fromJust)
import           Data.Time.Clock (UTCTime, getCurrentTime)
import           Data.Time.Clock.POSIX (getPOSIXTime, posixSecondsToUTCTime)

import					 Database.MongoDB (
                    Action, Pipe, Database, Failure, runIOE, connect, auth, access, master,
                    readHostPort, close, repsert, modify, delete, (=:), select,
                    findOne, lookup
                 )

data DB = DB { mongoPipe :: Pipe, mongoDB :: Database }


data Credentials = NoAuth
                 | Credentials { crUser :: UString, crPass :: UString }

-- |Opens a connection to the database speficied in the MONGO_URL
-- environment variable
openDB :: IO DB
openDB = do
    mongoURI <- getEnvDefault "MONGO_URL" "mongodb://127.0.0.1:27017/eventsourcehq"
    openConn mongoURI

-- |Close the connection to the database
closeDB :: DB -> IO ()
closeDB = do
    closeConn

-- |Bracket around opening and closing the DB connection
withDB :: (DB -> IO ()) -> IO ()
withDB f = do
    mongoURI <- getEnvDefault "MONGO_URL" "mongodb://127.0.0.1:27017/eventsourcehq"

    bracket (openConn mongoURI) closeConn f	


-- |Store a "connection" to the broker in the database
-- If the disconnect is set, the connection will be marked for
-- disconnection during a coming sweep
storeConnection :: DB -> UString -> UString -> UString -> Bool -> IO (Either Failure ())
storeConnection db brokerId socketId channel disconnect = do
    time <- disconnectTime
    run db $ repsert (select s "connections") (d disconnect time)
  where
    s = ["_id" =: socketId, "channel" =: channel]
    d True time = s ++ ["broker" =: brokerId, "disconnect_at" =: time]
    d False _   = s ++ ["broker" =: brokerId]


-- |Mark a connection. Marked connections will be removed by a later
-- sweep
markConnection :: DB -> UString -> IO (Either Failure ())
markConnection db socketId = do
    time <- disconnectTime
    run db $ modify (select s "connections") (m time)
  where
    s = ["_id" =: socketId]
    m time = ["$set" =: ["disconnect_at" =: time]]


-- |Sweep connections. All marked connections with a disconnect_at less
-- than the current time will be removed.
sweepConnections :: DB -> UString -> IO (Either Failure ())
sweepConnections db brokerId = do
    time <- getCurrentTime
    run db $ delete (select ["broker" =: brokerId, "disconnect_at" =: ["$lte" =: time]] "connections")


-- |Remove all connections from a broker from the db
disconnectBroker :: DB -> UString -> IO (Either Failure ())
disconnectBroker db brokerId = 
    run db $ delete (select ["broker" =: brokerId] "connections")


-- |Get the "channel" for a specific connection
getChannel :: DB -> UString -> IO (Maybe UString)
getChannel db socketId = do
    result <- run db $ findOne (select ["_id" =: socketId] "connections")
    case result of
      Right (Just doc) -> return $ lookup "channel" doc
      Right Nothing    -> return Nothing
      Left _           -> return Nothing


disconnectTime :: IO UTCTime
disconnectTime = fmap (posixSecondsToUTCTime . (+ 15)) getPOSIXTime


openConn :: String -> IO DB
openConn mongoURI = do
    let uri       = fromJust $ parseURI mongoURI
    let creds     = case fmap (split ":") (uriUserInfo uri) of
                        Nothing     -> NoAuth
                        Just [us, pw] -> Credentials (u us) (u pw)
    let hostname  = fromJust $ uriRegName uri
    let port      = case uriPort uri of
                        Just p  -> show p
                        Nothing -> "27017"

    let dbName    = u $ drop 1 (uriPath uri)

    pipe <- runIOE $ connect (readHostPort (hostname ++ ":" ++ port))

    let db = DB pipe dbName

    authenticate db creds

    return db


authenticate :: DB -> Credentials -> IO (Either Failure Bool)
authenticate db NoAuth                  = return (Right True)
authenticate db (Credentials user pass) = run db (auth user pass)


run :: DB -> Action IO a -> IO (Either Failure a)
run (DB pipe db) action = 
    access pipe master db action


closeConn :: DB -> IO ()
closeConn db = close (mongoPipe db)
