{- git-annex crypto
 -
 - Currently using gpg; could later be modified to support different
 - crypto backends if neccessary.
 -
 - Copyright 2011 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Crypto (
	Cipher,
	EncryptedCipher,
	genCipher,
	updateCipher,
	storeCipher,
	extractCipher,
	decryptCipher,		
	encryptKey,
	withEncryptedContentHandle,
	withEncryptedContent,
	withDecryptedContent,
) where

import qualified Data.ByteString.Lazy.Char8 as L
import qualified Data.Map as M
import qualified Codec.Binary.Base64 as B64
import Data.ByteString.Lazy.UTF8 (fromString)
import Data.Digest.Pure.SHA
import System.Cmd.Utils
import Data.String.Utils
import Data.List
import Data.Bits.Utils
import System.IO
import System.Posix.IO
import System.Posix.Types
import System.Posix.Process
import Control.Concurrent
import Control.Exception
import System.Exit

import Types
import Key
import RemoteClass
import Utility
import CryptoTypes

{- The first half of a Cipher is used for HMAC; the remainder
 - is used as the GPG symmetric encryption passphrase.
 -
 - HMAC SHA1 needs only 64 bytes. The remainder is for expansion,
 - perhaps to HMAC SHA512, which needs 128 bytes (ideally).
 -
 - 256 is enough for gpg's symetric cipher; unlike weaker public key
 - crypto, the key does not need to be too large.
 -}
cipherHalf :: Int
cipherHalf = 256

cipherSize :: Int
cipherSize = cipherHalf * 2

cipherPassphrase :: Cipher -> String
cipherPassphrase (Cipher c) = drop cipherHalf c

cipherHmac :: Cipher -> String
cipherHmac (Cipher c) = take cipherHalf c

{- Creates a new Cipher, encrypted as specified in the remote's configuration -}
genCipher :: RemoteConfig -> IO EncryptedCipher
genCipher c = do
	ks <- configKeyIds c
	random <- genrandom
	encryptCipher (Cipher random) ks
	where
		genrandom = gpgRead
			-- Armor the random data, to avoid newlines,
			-- since gpg only reads ciphers up to the first
			-- newline.
			[ Params "--gen-random --armor"
			, Param $ show randomquality
			, Param $ show cipherSize
			]
		-- 1 is /dev/urandom; 2 is /dev/random
		randomquality = 1 :: Int

{- Updates an existing Cipher, re-encrypting it to add KeyIds specified in
 - the remote's configuration. -}
updateCipher :: RemoteConfig -> EncryptedCipher -> IO EncryptedCipher
updateCipher c encipher@(EncryptedCipher _ ks) = do
	ks' <- configKeyIds c
	cipher <- decryptCipher c encipher
	encryptCipher cipher (combine ks ks')
	where
		combine (KeyIds a) (KeyIds b) = KeyIds $ a ++ b

{- Stores an EncryptedCipher in a remote's configuration. -}
storeCipher :: RemoteConfig -> EncryptedCipher -> RemoteConfig
storeCipher c (EncryptedCipher t ks) = 
	M.insert "cipher" (toB64 t) $ M.insert "cipherkeys" (show ks) c

{- Extracts an EncryptedCipher from a remote's configuration. -}
extractCipher :: RemoteConfig -> Maybe EncryptedCipher
extractCipher c = 
	case (M.lookup "cipher" c, M.lookup "cipherkeys" c) of
		(Just t, Just ks) -> Just $ EncryptedCipher (fromB64 t) (read ks)
		_ -> Nothing

{- Encrypts a Cipher to the specified KeyIds. -}
encryptCipher :: Cipher -> KeyIds -> IO EncryptedCipher
encryptCipher (Cipher c) (KeyIds ks) = do
	let ks' = nub $ sort ks -- gpg complains about duplicate recipient keyids
	encipher <- gpgPipeStrict (encrypt++recipients ks') c
	return $ EncryptedCipher encipher (KeyIds ks')
	where
		encrypt = [ Params "--encrypt" ]
		recipients l = 
			-- Force gpg to only encrypt to the specified
			-- recipients, not configured defaults.
			[ Params "--no-encrypt-to --no-default-recipient"] ++
			(concat $ map (\k -> [Param "--recipient", Param k]) l)

{- Decrypting an EncryptedCipher is expensive; the Cipher should be cached. -}
decryptCipher :: RemoteConfig -> EncryptedCipher -> IO Cipher
decryptCipher _ (EncryptedCipher encipher _) = 
	return . Cipher =<< gpgPipeStrict decrypt encipher
	where
		decrypt = [ Param "--decrypt" ]

{- Generates an encrypted form of a Key. The encryption does not need to be
 - reversable, nor does it need to be the same type of encryption used
 - on content. It does need to be repeatable. -}
encryptKey :: Cipher -> Key -> IO Key
encryptKey c k =
	return Key {
		keyName = showDigest $ hmacSha1
			(fromString $ cipherHmac c)
			(fromString $ show k),
		keyBackendName = "GPGHMACSHA1",
		keySize = Nothing, -- size and mtime omitted
		keyMtime = Nothing -- to avoid leaking data
	}

{- Runs an action passing it a handle from which it can 
 - stream encrypted content. -}
withEncryptedContentHandle :: Cipher -> L.ByteString -> (Handle -> IO a) -> IO a
withEncryptedContentHandle = gpgCipherHandle [Params "--symmetric --force-mdc"]

{- Streams encrypted content to an action. -}
withEncryptedContent :: Cipher -> L.ByteString -> (L.ByteString -> IO a) -> IO a
withEncryptedContent = gpgCipher [Params "--symmetric --force-mdc"]

{- Streams decrypted content to an action. -}
withDecryptedContent :: Cipher -> L.ByteString -> (L.ByteString -> IO a) -> IO a
withDecryptedContent = gpgCipher [Param "--decrypt"]


gpgParams :: [CommandParam] -> [String]
gpgParams params =
	-- avoid prompting, and be quiet, even about checking the trustdb
	["--batch", "--quiet", "--trust-model", "always"] ++
	toCommand params

gpgRead :: [CommandParam] -> IO String
gpgRead params = pOpen ReadFromPipe "gpg" (gpgParams params) hGetContentsStrict

gpgPipeStrict :: [CommandParam] -> String -> IO String
gpgPipeStrict params input = do
	(pid, fromh, toh) <- hPipeBoth "gpg" (gpgParams params)
	_ <- forkIO $ finally (hPutStr toh input) (hClose toh)
	output <- hGetContentsStrict fromh
	forceSuccess pid
	return output

{- Runs gpg with a cipher and some parameters, feeding it an input,
 - and passing a handle to its output to an action. -}
gpgCipherHandle :: [CommandParam] -> Cipher -> L.ByteString -> (Handle -> IO a) -> IO a
gpgCipherHandle params c input a = do
	-- pipe the passphrase into gpg on a fd
	(frompipe, topipe) <- createPipe
	_ <- forkIO $ do
		toh <- fdToHandle topipe
		hPutStrLn toh $ cipherPassphrase c
		hClose toh
	let Fd passphrasefd = frompipe
	let passphrase = [Param "--passphrase-fd", Param $ show passphrasefd]

	(pid, fromh, toh) <- hPipeBoth "gpg" $
		gpgParams $ passphrase ++ params
	_ <- forkProcess $ do
		L.hPut toh input
		hClose toh
		exitSuccess
	hClose toh
	ret <- a fromh

	-- cleanup
	forceSuccess pid
	closeFd frompipe
	return ret

{- Runs gpg with a cipher and some parameters, feeding it an input,
 - and piping its output lazily to an action. -}
gpgCipher :: [CommandParam] -> Cipher -> L.ByteString -> (L.ByteString -> IO a) -> IO a
gpgCipher params c input a = do
	gpgCipherHandle params c input $ \h -> do
		content <- L.hGetContents h
		a content

configKeyIds :: RemoteConfig -> IO KeyIds
configKeyIds c = do
	let k = configGet c "encryption"
	s <- gpgRead [Params "--with-colons --list-public-keys", Param k]
	return $ KeyIds $ parseWithColons s
	where
		parseWithColons s = map keyIdField $ filter pubKey $ lines s
		pubKey = isPrefixOf "pub:"
		keyIdField s = (split ":" s) !! 4

configGet :: RemoteConfig -> String -> String
configGet c key =
	case M.lookup key c of
		Just v -> v
		Nothing -> error $ "missing " ++ key ++ " in remote config"

toB64 :: String -> String		
toB64 = B64.encode . s2w8

fromB64 :: String -> String
fromB64 s =
	case B64.decode s of
		Nothing -> error "bad base64 encoded data"
		Just ws -> w82s ws