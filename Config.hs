{- Git configuration
 -
 - Copyright 2011 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Config where

import Common.Annex
import qualified Git
import qualified Git.Config
import qualified Git.Command
import qualified Annex
import Utility.DataUnits

type ConfigKey = String

{- Changes a git config setting in both internal state and .git/config -}
setConfig :: ConfigKey -> String -> Annex ()
setConfig k value = do
	inRepo $ Git.Command.run "config" [Param k, Param value]
	-- re-read git config and update the repo's state
	newg <- inRepo Git.Config.read
	Annex.changeState $ \s -> s { Annex.repo = newg }

{- Looks up a git config setting in git config. -}
getConfig :: ConfigKey -> String -> Annex String
getConfig key def = fromRepo $ Git.Config.get key def

{- Looks up a per-remote config setting in git config.
 - Failing that, tries looking for a global config option. -}
getRemoteConfig :: Git.Repo -> ConfigKey -> String -> Annex String
getRemoteConfig r key def =
	getConfig (remoteConfig r key) =<< getConfig key def

{- A per-remote config setting in git config. -}
remoteConfig :: Git.Repo -> ConfigKey -> String
remoteConfig r key = "remote." ++ fromMaybe "" (Git.remoteName r) ++ ".annex-" ++ key

{- Calculates cost for a remote. Either the default, or as configured 
 - by remote.<name>.annex-cost, or if remote.<name>.annex-cost-command
 - is set and prints a number, that is used. -}
remoteCost :: Git.Repo -> Int -> Annex Int
remoteCost r def = do
	cmd <- getRemoteConfig r "cost-command" ""
	(fromMaybe def . readish) <$>
		if not $ null cmd
			then liftIO $ snd <$> pipeFrom "sh" ["-c", cmd]
			else getRemoteConfig r "cost" ""

cheapRemoteCost :: Int
cheapRemoteCost = 100
semiCheapRemoteCost :: Int
semiCheapRemoteCost = 110
expensiveRemoteCost :: Int
expensiveRemoteCost = 200

{- Adjusts a remote's cost to reflect it being encrypted. -}
encryptedRemoteCostAdj :: Int
encryptedRemoteCostAdj = 50

{- Make sure the remote cost numbers work out. -}
prop_cost_sane :: Bool
prop_cost_sane = False `notElem`
	[ expensiveRemoteCost > 0
	, cheapRemoteCost < semiCheapRemoteCost
	, semiCheapRemoteCost < expensiveRemoteCost
	, cheapRemoteCost + encryptedRemoteCostAdj > semiCheapRemoteCost
	, cheapRemoteCost + encryptedRemoteCostAdj < expensiveRemoteCost
	, semiCheapRemoteCost + encryptedRemoteCostAdj < expensiveRemoteCost
	]

{- Checks if a repo should be ignored. -}
repoNotIgnored :: Git.Repo -> Annex Bool
repoNotIgnored r = not . fromMaybe False . Git.configTrue
	<$> getRemoteConfig r "ignore" ""

{- If a value is specified, it is used; otherwise the default is looked up
 - in git config. forcenumcopies overrides everything. -}
getNumCopies :: Maybe Int -> Annex Int
getNumCopies v = perhaps (use v) =<< Annex.getState Annex.forcenumcopies
	where
		use (Just n) = return n
		use Nothing = perhaps (return 1) =<< 
			readish <$> getConfig "annex.numcopies" "1"
		perhaps fallback = maybe fallback (return . id)

{- Gets the trust level set for a remote in git config. -}
getTrustLevel :: Git.Repo -> Annex (Maybe String)
getTrustLevel r = fromRepo $ Git.Config.getMaybe $ remoteConfig r "trustlevel"

{- Gets annex.diskreserve setting. -}
getDiskReserve :: Annex Integer
getDiskReserve = fromMaybe megabyte . readSize dataUnits
	<$> getConfig "diskreserve" ""
	where
		megabyte = 1000000
