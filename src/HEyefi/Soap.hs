{-# LANGUAGE OverloadedStrings #-}

module HEyefi.Soap
       ( handleSoapAction
       , soapAction
       , mkResponse )
       where

import           HEyefi.Config (getUploadKeyForMacaddress)
import           HEyefi.Hex (unhex)
import           HEyefi.Log (logInfo, logDebug)
import           HEyefi.SoapResponse (
    markLastPhotoInRollResponse
  , getPhotoStatusResponse)
import           HEyefi.StartSession (startSessionResponse)
import           HEyefi.Strings
import           HEyefi.Types (HEyefiM, HEyefiApplication, lastSNonce)


import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL

import           Control.Arrow ((>>>))
import           Control.Monad.IO.Class (liftIO, MonadIO)
import           Control.Monad.State.Lazy (get)
import           Data.ByteString.Lazy (fromStrict)
import           Data.ByteString.Lazy.UTF8 (toString)
import           Data.ByteString.UTF8 (fromString)
import qualified Data.CaseInsensitive as CI
import           Data.Hash.MD5 (md5s, Str (..))
import           Data.List (find)
import           Data.Maybe (fromJust)
import           Data.Time.Clock (getCurrentTime, UTCTime)
import           Data.Time.Format (
    formatTime
  , rfc822DateFormat
  , defaultTimeLocale)
import           Network.HTTP.Types (status200, unauthorized401)
import           Network.HTTP.Types.Header (
  hContentType,
  hServer,
  hContentLength,
  hDate,
  Header,
  HeaderName )
import           Network.Wai (
    responseLBS
  , Request
  , Response
  , requestHeaders )
import           Text.HandsomeSoup (css)
import           Text.XML.HXT.Core (
    runX
  , readString
  , getText
  , (/>)
  , runLA
  , root
  , writeDocumentToString
  , XmlTree
  , LA
  , mkelem
  , spi
  , sattr
  , t_xml
  , ArrowXml)


data SoapAction = StartSession
                | GetPhotoStatus
                | MarkLastPhotoInRoll
                deriving (Show, Eq)

headerIsSoapAction :: Header -> Bool
headerIsSoapAction ("SOAPAction",_) = True
headerIsSoapAction _ = False

soapAction :: Request -> Maybe SoapAction
soapAction req =
  case find headerIsSoapAction (requestHeaders req) of
   Just (_,"\"urn:StartSession\"") -> Just StartSession
   Just (_,"\"urn:GetPhotoStatus\"") -> Just GetPhotoStatus
   Just (_,"\"urn:MarkLastPhotoInRoll\"") -> Just MarkLastPhotoInRoll
   Just (_,sa) -> error (notADefinedSoapAction (show sa))
   _ -> Nothing

mkResponse :: String -> HEyefiM Response
mkResponse responseBody = do
  t <- liftIO getCurrentTime
  return (responseLBS
          status200
          (defaultResponseHeaders t (length responseBody))
          (fromStrict (fromString responseBody)))

mkUnauthorizedResponse :: Response
mkUnauthorizedResponse = responseLBS unauthorized401 [] ""

defaultResponseHeaders :: UTCTime ->
                          Int ->
                          [(HeaderName, B.ByteString)]
defaultResponseHeaders time size =
  [ (hContentType, "text/xml; charset=\"utf-8\"")
  , (hDate, fromString (formatTime defaultTimeLocale rfc822DateFormat time))
  , (CI.mk "Pragma", "no-cache")
  , (hServer, "Eye-Fi Agent/2.0.4.0 (Windows XP SP2)")
  , (hContentLength, fromString (show size))]

firstTag :: Control.Monad.IO.Class.MonadIO m =>
            BL.ByteString ->
            String ->
            m String
firstTag body tagName = do
  let xmlDocument = readString [] (toString body)
  fmap head (liftIO (runX (xmlDocument >>> css tagName /> getText)))

handleSoapAction :: SoapAction -> BL.ByteString -> HEyefiApplication
handleSoapAction StartSession body _ f = do
  logDebug gotStartSessionRequest
  let tag = firstTag body
  macaddress <- tag "macaddress"
  cnonce <- tag "cnonce"
  transfermode <- tag "transfermode"
  transfermodetimestamp <- tag "transfermodetimestamp"
  logDebug (show macaddress)
  logDebug (show transfermodetimestamp)
  responseBody <- startSessionResponse
                   macaddress
                   cnonce
                   transfermode
                   transfermodetimestamp
  logDebug (show responseBody)
  response <- mkResponse responseBody
  liftIO (f response)
handleSoapAction GetPhotoStatus body _ f = do
  logDebug gotGetPhotoStatusRequest
  credentialGood <- checkCredential body
  if credentialGood then do
    response <- mkResponse (soapResponse getPhotoStatusResponse)
    liftIO (f response)
  else
    liftIO (f mkUnauthorizedResponse)
handleSoapAction MarkLastPhotoInRoll _ _ f = do
  logDebug gotMarkLastPhotoInRollRequest
  response <- mkResponse (soapResponse markLastPhotoInRollResponse)
  liftIO (f response)

checkCredential :: BL.ByteString -> HEyefiM Bool
checkCredential body = do
  let tag = firstTag body
  macaddress <- tag "macaddress"
  credential <- tag "credential"
  state <- get
  let snonce = lastSNonce state
  upload_key_0 <- getUploadKeyForMacaddress macaddress
  case upload_key_0 of
   Nothing -> do
     logInfo (noUploadKeyInConfiguration macaddress)
     return False
   Just upload_key_0' -> do
     let credentialString = macaddress ++ upload_key_0' ++ snonce
     let binaryCredentialString = unhex credentialString
     let expectedCredential = md5s (Str (fromJust binaryCredentialString))
     if credential /= expectedCredential then do
       logInfo (invalidCredential expectedCredential credential)
       return False
     else
       return True

soapMessage :: ArrowXml a => [a n XmlTree] -> [a n XmlTree]
soapMessage body =
  [ spi t_xml "version=\"1.0\" encoding=\"UTF-8\""
  , mkelem "SOAP-ENV:Envelope"
    [ sattr "xmlns:SOAP-ENV" "http://schemas.xmlsoap.org/soap/envelope/" ]
    [ mkelem "SOAP-ENV:Body" [] body ]]

soapResponse :: [LA n XmlTree] -> String
soapResponse body =
  head (runLA (document >>> writeDocumentToString []) undefined)
  where
    document = root [] (soapMessage body)
