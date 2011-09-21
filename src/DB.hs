{-# LANGUAGE OverloadedStrings #-}
module DB 
    (
      DB,
      ESConnection(..),
      withDB,
      openDB,
      closeDB,
      storeConnection,
      markConnection,
      sweepConnections,
      disconnectBroker,
      getConnection,
      getConnectionCount
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

import          Database.MongoDB (
                    Action, Pipe, Database, Failure, runIOE, connect, auth, access, master,
                    readHostPort, close, repsert, modify, delete, (=:), select,
                    findOne, count, lookup, at
                 )

-- |A connection to a mongoDB
data DB = DB { mongoPipe :: Pipe, mongoDB :: Database }


-- |Credentials for authenticating with a mongoDB
data Credentials = NoAuth
                 | Credentials { crUser :: UString, crPass :: UString }


-- |An eventSource connection to the broker persisted in mongoDB
data ESConnection = ESConnection 
    { socketId :: UString
    , brokerId :: UString
    , channel  :: UString
    , userId   :: Maybe UString
    , disconnectAt :: Maybe Int -- Seconds from current time
    }


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
storeConnection :: DB -> ESConnection -> IO (Either Failure ())
storeConnection db conn= do
    time <- disconnectTime (disconnectAt conn)
    run db $ repsert (select s "connections") (d time)
  where
    s = ["_id" =: socketId conn, "channel" =: channel conn]
    d (Just time) = s ++ ["broker" =: brokerId conn, "disconnect_at" =: time]
    d Nothing     = s ++ ["broker" =: brokerId conn]


-- |Mark a connection. Marked connections will be removed by a later
-- sweep
markConnection :: DB -> ESConnection -> IO (Either Failure ())
markConnection db conn = do
    case disconnectAt conn of
        Just offset -> do
            time <- disconnectTime (Just offset)
            run db $ modify (select s "connections") (m time)
        Nothing -> return $ Right ()
  where
    s = ["_id" =: (socketId conn)]
    m time = ["$set" =: ["disconnect_at" =: time]]


-- |Sweep connections. All marked connections with a disconnect_at less
-- than the current time will be removed.
sweepConnections :: DB -> UString -> IO (Either Failure ())
sweepConnections db bid = do
    time <- getCurrentTime
    run db $ delete (select ["broker" =: bid, "disconnect_at" =: ["$lte" =: time]] "connections")


-- |Remove all connections from a broker from the db
disconnectBroker :: DB -> UString -> IO (Either Failure ())
disconnectBroker db bid = 
    run db $ delete (select ["broker" =: bid] "connections")


getConnection :: DB -> UString -> IO (Maybe ESConnection)
getConnection db sid = do
    result <- run db $ findOne (select ["_id" =: sid] "connections")
    case result of
        Right (Just doc) -> return $ Just ESConnection {
              brokerId     = at "broker" doc
            , socketId     = at "_id" doc
            , channel      = at "channel" doc
            , userId       = lookup "user_id" doc
            , disconnectAt = Nothing
        }
        _                -> return Nothing

getConnectionCount :: DB -> UString -> IO (Either Failure Int)
getConnectionCount db bid =
    run db $ count (select ["broker" =: bid] "connections")


disconnectTime :: Maybe Int -> IO (Maybe UTCTime)
disconnectTime (Just offset) = fmap (Just . posixSecondsToUTCTime . (+ (fromIntegral offset))) getPOSIXTime 
disconnectTime Nothing       = return Nothing


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
