module HEyefi.UploadPhoto where

import           Codec.Archive.Tar (extract)
import           Control.Monad.IO.Class (liftIO)
import           Control.Monad.State.Lazy (get)
import qualified Data.ByteString.Lazy as BL
import           HEyefi.Constant (multipartBodyBoundary)
import           HEyefi.Log (logDebug, logInfo)
import           HEyefi.Prelude
import           HEyefi.Soap (mkResponse)
import           HEyefi.SoapResponse (soapResponse, uploadPhotoResponse)
import           HEyefi.Types (uploadDirectory, HEyefiM, HEyefiApplication)
import           Network.Multipart (
    parseMultipartBody
  , MultiPart (..)
  , BodyPart (..) )
import           System.Directory (copyFile, getDirectoryContents)
import           System.FilePath.Posix ((</>))
import           System.IO (hClose)
import           System.IO.Temp (withSystemTempFile, withSystemTempDirectory)
import           System.Posix.Files (
    setOwnerAndGroup
  , fileOwner
  , fileGroup
  , getFileStatus
  , FileStatus )



copyMatchingOwnership :: FileStatus -> FilePath -> FilePath -> IO FilePath
copyMatchingOwnership fs from to = do
  copyFile from to
  setOwnerAndGroup to (fileOwner fs) (fileGroup fs)
  return to

changeOwnershipAndCopy :: FilePath -> FilePath -> IO FilePath
changeOwnershipAndCopy uploadDir extractionDir = do
  s <- getFileStatus uploadDir
  names <- getDirectoryContents extractionDir
  paths <- mapM (processName s) (properNames names)
  return (head paths)
  where
    properNames = filter (`notElem` [".", ".."])
    processName s n =
      copyMatchingOwnership s (extractionDir </> n) (uploadDir </> n)

-- TODO: handle case where uploaded file has a bad format
-- TODO: handle case where temp file is not created
writeTarFile :: BL.ByteString -> HEyefiM FilePath
writeTarFile file = do
  config <- get
  let uploadDir = uploadDirectory config
  liftIO (withSystemTempFile "heyefi.tar" (handleFile uploadDir))
  where
    handleFile uploadDir filePath handle =
      withSystemTempDirectory "heyefi_extracted" (handleDir uploadDir filePath handle)
    handleDir uploadDir tempFile tempFileHandle extractionDir = do
      BL.hPut tempFileHandle file
      hClose tempFileHandle
      extract extractionDir tempFile
      changeOwnershipAndCopy uploadDir extractionDir

handleUpload :: BL.ByteString -> HEyefiApplication
handleUpload body _ f = do
  logDebug gotUploadRequest
  let MultiPart bodyParts = parseMultipartBody (unpack multipartBodyBoundary) body
  logDebug (tshow (length bodyParts))
  lBP bodyParts

  let [  BodyPart _ soapEnvelope
       , BodyPart _ file
       , BodyPart _ digest
       ] = bodyParts

  outputPath <- writeTarFile file
  logInfo (uploadedTo (pack outputPath))

  logDebug (tshow soapEnvelope)
  logDebug (tshow digest)
  let responseBody = soapResponse uploadPhotoResponse
  logDebug responseBody
  r <- mkResponse responseBody
  liftIO (f r)

  where
    lBP [] = return ()
    lBP (BodyPart headers _ : xs) = do
      logDebug (tshow headers)
      lBP xs
      return ()
