{-# LANGUAGE OverloadedStrings #-}
module DB 
    (
      DB,
      Failure,
      withDB,
      openDB,
      closeDB,
      run,
      repsert,
      modify,
      delete,
      select,
      findOne,
      count,
      lookup,
      at,
      (=:)
    ) where

import           Prelude hiding (lookup)

import           Control.Exception (bracket)

import           System.Posix.Env(getEnvDefault)
import           Data.String.Utils(split)
import           Text.URI(URI(..), parseURI)

import           Data.UString (UString, u)
import           Data.Maybe (fromJust)

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
