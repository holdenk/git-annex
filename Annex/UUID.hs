{- git-annex uuids
 -
 - Each git repository used by git-annex has an annex.uuid setting that
 - uniquely identifies that repository.
 -
 - UUIDs of remotes are cached in git config, using keys named
 - remote.<name>.annex-uuid
 -
 - Copyright 2010-2011 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Annex.UUID (
	getUUID,
	getRepoUUID,
	getUncachedUUID,
	prepUUID,
	genUUID
) where

import Common.Annex
import qualified Git
import qualified Build.SysConfig as SysConfig
import Config

configkey :: String
configkey = "annex.uuid"

{- Generates a UUID. There is a library for this, but it's not packaged,
 - so use the command line tool. -}
genUUID :: IO UUID
genUUID = pOpen ReadFromPipe command params hGetLine
	where
		command = SysConfig.uuid
		params = if command == "uuid"
			-- request a random uuid be generated
			then ["-m"]
			-- uuidgen generates random uuid by default
			else []

getUUID :: Annex UUID
getUUID = getRepoUUID =<< gitRepo

{- Looks up a repo's UUID. May return "" if none is known. -}
getRepoUUID :: Git.Repo -> Annex UUID
getRepoUUID r = do
	g <- gitRepo

	let c = cached g
	let u = getUncachedUUID r
	
	if c /= u && u /= ""
		then do
			updatecache g u
			return u
		else return c
	where
		cached g = Git.configGet g cachekey ""
		updatecache g u = when (g /= r) $ setConfig cachekey u
		cachekey = "remote." ++ fromMaybe "" (Git.repoRemoteName r) ++ ".annex-uuid"

getUncachedUUID :: Git.Repo -> UUID
getUncachedUUID r = Git.configGet r configkey ""

{- Make sure that the repo has an annex.uuid setting. -}
prepUUID :: Annex ()
prepUUID = whenM (null <$> getUUID) $
	setConfig configkey =<< liftIO genUUID