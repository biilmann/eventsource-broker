{-# LANGUAGE OverloadedStrings #-}
module Models.User where

import           Prelude hiding (lookup)
import           Data.UString (UString)
import qualified Data.UString as US
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy as LBS
import           Data.Digest.Pure.SHA (sha1, bytestringDigest)
import           DB

data User = User { apiKey :: UString, apiSecret :: UString }

get db key = do
    result <- run db $ findOne (select ["key" =: key] "users")
    case result of
        Right (Just doc) -> return $ Just $ User (at "key" doc) (at "secret" doc)
        _                -> return Nothing

authenticate :: User -> ByteString -> ByteString -> Bool 
authenticate user token timestamp =
    let key    = US.toByteString $ apiKey user
        secret = US.toByteString $ apiSecret user
        digest = sha1 $ LBS.fromChunks [key, ":", secret, ":", timestamp] in
    show digest == BS.unpack token
