{- git-annex command
 -
 - Copyright 2010 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Command.Semitrust where

import Command
import qualified Remote
import UUID
import Trust
import Messages

command :: [Command]
command = [repoCommand "semitrust" (paramRepeating paramRemote) seek
	"return repository to default trust level"]

seek :: [CommandSeek]
seek = [withString start]

start :: CommandStartString
start name = notBareRepo $ do
	showStart "semitrust" name
	u <- Remote.nameToUUID name
	return $ Just $ perform u

perform :: UUID -> CommandPerform
perform uuid = do
	trustSet uuid SemiTrusted
	return $ Just $ return True