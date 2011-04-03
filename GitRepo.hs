{- git repository handling 
 -
 - This is written to be completely independant of git-annex and should be
 - suitable for other uses.
 -
 - Copyright 2010 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module GitRepo (
	Repo,
	repoFromCwd,
	repoFromAbsPath,
	repoFromUnknown,
	repoFromUrl,
	localToUrl,
	repoIsUrl,
	repoIsSsh,
	repoIsLocalBare,
	repoDescribe,
	repoLocation,
	workTree,
	gitDir,
	relative,
	urlPath,
	urlHost,
	urlPort,
	urlHostUser,
	urlAuthority,
	urlScheme,
	configGet,
	configMap,
	configRead,
	hConfigRead,
	configStore,
	configTrue,
	gitCommandLine,
	run,
	pipeRead,
	attributes,
	remotes,
	remotesAdd,
	repoRemoteName,
	repoRemoteNameSet,
	inRepo,
	notInRepo,
	stagedFiles,
	stagedFilesNotDeleted,
	changedUnstagedFiles,
	checkAttr,
	decodeGitFile,
	encodeGitFile,
	typeChangedFiles,
	typeChangedStagedFiles,
	repoAbsPath,
	reap,

	prop_idempotent_deencode
) where

import Control.Monad (unless)
import System.Directory
import System.FilePath
import System.Posix.Directory
import System.Posix.User
import System.Posix.Process
import System.Path
import System.Cmd.Utils
import IO (bracket_)
import Data.String.Utils
import System.IO
import qualified Data.Map as Map hiding (map, split)
import Network.URI
import Data.Maybe
import Data.Char
import Data.Word (Word8)
import Codec.Binary.UTF8.String (encode)
import Text.Printf
import Data.List (isInfixOf, isPrefixOf)

import Utility

{- There are two types of repositories; those on local disk and those
 - accessed via an URL. -}
data RepoLocation = Dir FilePath | Url URI | Unknown
	deriving (Show, Eq)

data Repo = Repo {
	location :: RepoLocation,
	config :: Map.Map String String,
	remotes :: [Repo],
	-- remoteName holds the name used for this repo in remotes
	remoteName :: Maybe String 
} deriving (Show, Eq)

newFrom :: RepoLocation -> Repo
newFrom l = 
	Repo {
		location = l,
		config = Map.empty,
		remotes = [],
		remoteName = Nothing
	}

{- Local Repo constructor, requires an absolute path to the repo be
 - specified. -}
repoFromAbsPath :: FilePath -> IO Repo
repoFromAbsPath dir
	| "/" `isPrefixOf` dir = do
 		-- Git always looks for "dir.git" in preference to
		-- to "dir", even if dir ends in a "/".
		let dir' = (dropTrailingPathSeparator dir) ++ ".git"
		e <- doesDirectoryExist dir'
		return $ newFrom $ Dir $ if e then dir' else dir
	| otherwise = error $ "internal error, " ++ dir ++ " is not absolute"

{- Remote Repo constructor. Throws exception on invalid url. -}
repoFromUrl :: String -> IO Repo
repoFromUrl url
	| startswith "file://" url = repoFromAbsPath $ uriPath u
	| otherwise = return $ newFrom $ Url u
		where
			u = case (parseURI url) of
				Just v -> v
				Nothing -> error $ "bad url " ++ url

{- Creates a repo that has an unknown location. -}
repoFromUnknown :: Repo
repoFromUnknown = newFrom Unknown

{- Converts a Local Repo into a remote repo, using the reference repo
 - which is assumed to be on the same host. -}
localToUrl :: Repo -> Repo -> Repo
localToUrl reference r
	| not $ repoIsUrl reference = error "internal error; reference repo not url"
	| repoIsUrl r = r
	| otherwise = r { location = Url $ fromJust $ parseURI absurl }
	where
		absurl =
			urlScheme reference ++ "//" ++
			urlAuthority reference ++
			workTree r

{- User-visible description of a git repo. -}
repoDescribe :: Repo -> String
repoDescribe Repo { remoteName = Just name } = name
repoDescribe Repo { location = Url url } = show url
repoDescribe Repo { location = Dir dir } = dir
repoDescribe Repo { location = Unknown } = "UNKNOWN"

{- Location of the repo, either as a path or url. -}
repoLocation :: Repo -> String
repoLocation Repo { location = Url url } = show url
repoLocation Repo { location = Dir dir } = dir
repoLocation Repo { location = Unknown } = undefined

{- Constructs and returns an updated version of a repo with
 - different remotes list. -}
remotesAdd :: Repo -> [Repo] -> Repo
remotesAdd repo rs = repo { remotes = rs }

{- Returns the name of the remote that corresponds to the repo, if
 - it is a remote. -}
repoRemoteName :: Repo -> Maybe String
repoRemoteName Repo { remoteName = Just name } = Just name
repoRemoteName _ = Nothing

{- Sets the name of a remote based on the git config key, such as
   "remote.foo.url". -}
repoRemoteNameSet :: Repo -> String -> Repo
repoRemoteNameSet r k = r { remoteName = Just basename }
	where
		basename = join "." $ reverse $ drop 1 $
				reverse $ drop 1 $ split "." k

{- Some code needs to vary between URL and normal repos,
 - or bare and non-bare, these functions help with that. -}
repoIsUrl :: Repo -> Bool
repoIsUrl Repo { location = Url _ } = True
repoIsUrl _ = False

repoIsSsh :: Repo -> Bool
repoIsSsh Repo { location = Url url } 
	| uriScheme url == "ssh:" = True
	-- git treats these the same as ssh
	| uriScheme url == "git+ssh:" = True
	| uriScheme url == "ssh+git:" = True
	| otherwise = False
repoIsSsh _ = False

configAvail ::Repo -> Bool
configAvail Repo { config = c } = c /= Map.empty

repoIsLocalBare :: Repo -> Bool
repoIsLocalBare r@(Repo { location = Dir _ }) = configAvail r && configBare r
repoIsLocalBare _ = False

assertLocal :: Repo -> a -> a
assertLocal repo action = 
	if not $ repoIsUrl repo
		then action
		else error $ "acting on URL git repo " ++  repoDescribe repo ++ 
				" not supported"
assertUrl :: Repo -> a -> a
assertUrl repo action = 
	if repoIsUrl repo
		then action
		else error $ "acting on local git repo " ++  repoDescribe repo ++ 
				" not supported"

configBare :: Repo -> Bool
configBare repo = case Map.lookup "core.bare" $ config repo of
	Just v -> configTrue v
	Nothing -> error $ "it is not known if git repo " ++
			repoDescribe repo ++
			" is a bare repository; config not read"

{- Path to a repository's gitattributes file. -}
attributes :: Repo -> String
attributes repo
	| configBare repo = workTree repo ++ "/info/.gitattributes"
	| otherwise = workTree repo ++ "/.gitattributes"

{- Path to a repository's .git directory, relative to its workTree. -}
gitDir :: Repo -> String
gitDir repo
	| configBare repo = ""
	| otherwise = ".git"

{- Path to a repository's --work-tree, that is, its top.
 -
 - Note that for URL repositories, this is the path on the remote host. -}
workTree :: Repo -> FilePath
workTree r@(Repo { location = Url _ }) = urlPath r
workTree (Repo { location = Dir d }) = d
workTree Repo { location = Unknown } = undefined

{- Given a relative or absolute filename in a repository, calculates the
 - name to use to refer to the file relative to a git repository's top.
 - This is the same form displayed and used by git. -}
relative :: Repo -> FilePath -> IO FilePath
relative repo@(Repo { location = Dir d }) file = do
	cwd <- getCurrentDirectory
	return $ drop (length absrepo) (absfile cwd)
	where
		-- normalize both repo and file, so that repo
		-- will be substring of file
		absrepo = case (absNormPath "/" d) of
			Just f -> f ++ "/"
			Nothing -> error $ "bad repo" ++ repoDescribe repo
		absfile c = case (secureAbsNormPath c file) of
			Just f -> f
			Nothing -> error $ file ++ " is not located inside git repository " ++ absrepo
relative repo _ = assertLocal repo $ error "internal"

{- Path of an URL repo. -}
urlPath :: Repo -> String
urlPath Repo { location = Url u } = uriPath u
urlPath repo = assertUrl repo $ error "internal"

{- Scheme of an URL repo. -}
urlScheme :: Repo -> String
urlScheme Repo { location = Url u } = uriScheme u
urlScheme repo = assertUrl repo $ error "internal"

{- Hostname of an URL repo. -}
urlHost :: Repo -> String
urlHost = urlAuthPart uriRegName

{- Port of an URL repo, if it has a nonstandard one. -}
urlPort :: Repo -> Maybe Integer
urlPort r = 
	case urlAuthPart uriPort r of
		":" -> Nothing
		(':':p) -> Just (read p)
		_ -> Nothing

{- Hostname of an URL repo, including any username (ie, "user@host") -}
urlHostUser :: Repo -> String
urlHostUser r = urlAuthPart uriUserInfo r ++ urlAuthPart uriRegName r

{- The full authority portion an URL repo. (ie, "user@host:port") -}
urlAuthority :: Repo -> String
urlAuthority Repo { location = Url u } = uriUserInfo a ++ uriRegName a ++ uriPort a
	where
		a = fromMaybe (error $ "bad url " ++ show u) (uriAuthority u)
urlAuthority repo = assertUrl repo $ error "internal"

{- Applies a function to extract part of the uriAuthority of an URL repo. -}
urlAuthPart :: (URIAuth -> a) -> Repo -> a
urlAuthPart a Repo { location = Url u } = a auth
	where
		auth = fromMaybe (error $ "bad url " ++ show u) (uriAuthority u)
urlAuthPart _ repo = assertUrl repo $ error "internal"

{- Constructs a git command line operating on the specified repo. -}
gitCommandLine :: Repo -> [CommandParam] -> [CommandParam]
gitCommandLine repo@(Repo { location = Dir d} ) params =
	-- force use of specified repo via --git-dir and --work-tree
	[ Param ("--git-dir=" ++ d ++ "/" ++ gitDir repo)
	, Param ("--work-tree=" ++ d)
	] ++ params
gitCommandLine repo _ = assertLocal repo $ error "internal"

{- Runs git in the specified repo, throwing an error if it fails. -}
run :: Repo -> String -> [CommandParam] -> IO ()
run repo subcommand params = assertLocal repo $ do
	ok <- boolSystem "git" (gitCommandLine repo ((Param subcommand):params))
	unless ok $ error $ "git " ++ show params ++ " failed"

{- Runs a git subcommand and returns it output, lazily. 
 -
 - Note that this leaves the git process running, and so zombies will
 - result unless reap is called.
 -}
pipeRead :: Repo -> [CommandParam] -> IO String
pipeRead repo params = assertLocal repo $ do
	(_, s) <- pipeFrom "git" $ toCommand $ gitCommandLine repo params
	return s

{- Reaps any zombie git processes. -}
reap :: IO ()
reap = do
	-- throws an exception when there are no child processes
	r <- catch (getAnyProcessStatus False True) (\_ -> return Nothing)
	case r of
		Nothing -> return ()
		Just _ -> reap

{- Scans for files that are checked into git at the specified locations. -}
inRepo :: Repo -> [FilePath] -> IO [FilePath]
inRepo repo l = pipeNullSplit repo $
	[Params "ls-files --cached --exclude-standard -z --"] ++ map File l

{- Scans for files at the specified locations that are not checked into git,
 - and not gitignored. -}
notInRepo :: Repo -> [FilePath] -> IO [FilePath]
notInRepo repo l = pipeNullSplit repo $
	[Params "ls-files --others --exclude-standard -z --"] ++ map File l

{- Returns a list of all files that are staged for commit. -}
stagedFiles :: Repo -> [FilePath] -> IO [FilePath]
stagedFiles repo l = stagedFiles' repo l []

{- Returns a list of the files, staged for commit, that are being added,
 - moved, or changed (but not deleted), from the specified locations. -}
stagedFilesNotDeleted :: Repo -> [FilePath] -> IO [FilePath]
stagedFilesNotDeleted repo l = stagedFiles' repo l [Param "--diff-filter=ACMRT"]

stagedFiles' :: Repo -> [FilePath] -> [CommandParam] -> IO [FilePath]
stagedFiles' repo l middle = pipeNullSplit repo $ start ++ middle ++ end
	where
		start = [Params "diff --cached --name-only -z"]
		end = [Param "--"] ++ map File l

{- Returns a list of files that have unstaged changes. -}
changedUnstagedFiles :: Repo -> [FilePath] -> IO [FilePath]
changedUnstagedFiles repo l = pipeNullSplit repo $
	[Params "diff --name-only -z --"] ++ map File l

{- Returns a list of the files in the specified locations that are staged
 - for commit, and whose type has changed. -}
typeChangedStagedFiles :: Repo -> [FilePath] -> IO [FilePath]
typeChangedStagedFiles repo l = typeChangedFiles' repo l [Param "--cached"]

{- Returns a list of the files in the specified locations whose type has
 - changed.  Files only staged for commit will not be included. -}
typeChangedFiles :: Repo -> [FilePath] -> IO [FilePath]
typeChangedFiles repo l = typeChangedFiles' repo l []

typeChangedFiles' :: Repo -> [FilePath] -> [CommandParam] -> IO [FilePath]
typeChangedFiles' repo l middle = pipeNullSplit repo $ start ++ middle ++ end
	where
		start = [Params "diff --name-only --diff-filter=T -z"]
		end = [Param "--"] ++ map File l

{- Reads null terminated output of a git command (as enabled by the -z 
 - parameter), and splits it into a list of files. -}
pipeNullSplit :: Repo -> [CommandParam] -> IO [FilePath]
pipeNullSplit repo params = do
	fs0 <- pipeRead repo params
	return $ split0 fs0
	where
		split0 s = filter (not . null) $ split "\0" s

{- Runs git config and populates a repo with its config. -}
configRead :: Repo -> IO Repo
configRead repo@(Repo { location = Dir d }) = do
	{- Cannot use pipeRead because it relies on the config having
	   been already read. Instead, chdir to the repo. -}
	cwd <- getCurrentDirectory
	bracket_ (changeWorkingDirectory d)
		(\_ -> changeWorkingDirectory cwd) $
			pOpen ReadFromPipe "git" ["config", "--list"] $
				hConfigRead repo
configRead r = assertLocal r $ error "internal"

{- Reads git config from a handle and populates a repo with it. -}
hConfigRead :: Repo -> Handle -> IO Repo
hConfigRead repo h = do
	val <- hGetContentsStrict h
	configStore repo val

{- Parses a git config and returns a version of the repo using it. -}
configStore :: Repo -> String -> IO Repo
configStore repo s = do
	rs <- configRemotes r
	return $ r { remotes = rs }
	where
		r = repo { config = configParse s }

{- Calculates a list of a repo's configured remotes, by parsing its config. -}
configRemotes :: Repo -> IO [Repo]
configRemotes repo = mapM construct remotepairs
	where
		remotepairs = Map.toList $ filterremotes $ config repo
		filterremotes = Map.filterWithKey (\k _ -> isremote k)
		isremote k = startswith "remote." k && endswith ".url" k
		construct (k,v) = do
			r <- gen v
			return $ repoRemoteNameSet r k
		gen v	| scpstyle v = repoFromUrl $ scptourl v
			| isURI v = repoFromUrl v
			| otherwise = repoFromRemotePath v repo
		-- git remotes can be written scp style -- [user@]host:dir
		scpstyle v = ":" `isInfixOf` v && (not $ "//" `isInfixOf` v)
		scptourl v = "ssh://" ++ host ++ slash dir
			where
				bits = split ":" v
				host = bits !! 0
				dir = join ":" $ drop 1 bits
				slash d	| d == "" = "/~/" ++ dir
					| d !! 0 == '/' = dir
					| d !! 0 == '~' = '/':dir
					| otherwise = "/~/" ++ dir

{- Checks if a string from git config is a true value. -}
configTrue :: String -> Bool
configTrue s = map toLower s == "true"

{- Parses git config --list output into a config map. -}
configParse :: String -> Map.Map String String
configParse s = Map.fromList $ map pair $ lines s
	where
		pair l = (key l, val l)
		key l = head $ keyval l
		val l = join sep $ drop 1 $ keyval l
		keyval l = split sep l :: [String]
		sep = "="

{- Returns a single git config setting, or a default value if not set. -}
configGet :: Repo -> String -> String -> String
configGet repo key defaultValue = 
	Map.findWithDefault defaultValue key (config repo)

{- Access to raw config Map -}
configMap :: Repo -> Map.Map String String
configMap repo = config repo

{- Efficiently looks up a gitattributes value for each file in a list. -}
checkAttr :: Repo -> String -> [FilePath] -> IO [(FilePath, String)]
checkAttr repo attr files = do
	-- git check-attr wants files that are absolute (or relative to the
	-- top of the repo). But we're passed files relative to the current
	-- directory. Convert to absolute, and then convert the filenames
	-- in its output back to relative.
	cwd <- getCurrentDirectory
	let absfiles = map (absPathFrom cwd) files
	(_, s) <- pipeBoth "git" (toCommand params) $ join "\0" absfiles
	return $ map (topair $ cwd++"/") $ lines s
	where
		params = gitCommandLine repo [Param "check-attr", Param attr, Params "-z --stdin"]
		topair cwd l = (relfile, value)
			where 
				relfile 
					| startswith cwd file = drop (length cwd) file
					| otherwise = file
				file = decodeGitFile $ join sep $ take end bits
				value = bits !! end
				end = length bits - 1
				bits = split sep l
				sep = ": " ++ attr ++ ": "

{- Some git commands output encoded filenames. Decode that (annoyingly
 - complex) encoding. -}
decodeGitFile :: String -> FilePath
decodeGitFile [] = []
decodeGitFile f@(c:s)
	-- encoded strings will be inside double quotes
	| c == '"' = unescape ("", middle)
	| otherwise = f
	where
		e = '\\'
		middle = take (length s - 1) s
		unescape (b, []) = b
		-- look for escapes starting with '\'
		unescape (b, v) = b ++ beginning ++ unescape (decode rest)
			where
				pair = span (/= e) v
				beginning = fst pair
				rest = snd pair
		isescape x = x == e
		-- \NNN is an octal encoded character
		decode (x:n1:n2:n3:rest)
			| isescape x && alloctal = (fromoctal, rest)
				where
					alloctal = isOctDigit n1 &&
						isOctDigit n2 &&
						isOctDigit n3
					fromoctal = [chr $ readoctal [n1, n2, n3]]
					readoctal o = read $ "0o" ++ o :: Int
		-- \C is used for a few special characters
		decode (x:nc:rest)
			| isescape x = ([echar nc], rest)
			where
				echar 'a' = '\a'
				echar 'b' = '\b'
				echar 'f' = '\f'
				echar 'n' = '\n'
				echar 'r' = '\r'
				echar 't' = '\t'
				echar 'v' = '\v'
				echar a = a
		decode n = ("", n)

{- Should not need to use this, except for testing decodeGitFile. -}
encodeGitFile :: FilePath -> String
encodeGitFile s = foldl (++) "\"" (map echar s) ++ "\""
	where
		e c = '\\' : [c]
		echar '\a' = e 'a'
		echar '\b' = e 'b'
		echar '\f' = e 'f'
		echar '\n' = e 'n'
		echar '\r' = e 'r'
		echar '\t' = e 't'
		echar '\v' = e 'v'
		echar '\\' = e '\\'
		echar '"'  = e '"'
		echar x
			| ord x < 0x20 = e_num x -- low ascii
			| ord x >= 256 = e_utf x
			| ord x > 0x7E = e_num x -- high ascii
			| otherwise = [x]        -- printable ascii
			where 
				showoctal i = '\\' : printf "%03o" i
				e_num c = showoctal $ ord c
				-- unicode character is decomposed to
				-- Word8s and each is shown in octal
				e_utf c = concat $ map showoctal $
						(encode [c] :: [Word8])

{- for quickcheck -}
prop_idempotent_deencode :: String -> Bool
prop_idempotent_deencode s = s == decodeGitFile (encodeGitFile s)

{- Constructs a Repo from the path specified in the git remotes of
 - another Repo. -}
repoFromRemotePath :: FilePath -> Repo -> IO Repo
repoFromRemotePath dir repo = do
	dir' <- expandTilde dir
	repoFromAbsPath $ workTree repo </> dir'

{- Git remotes can have a directory that is specified relative
 - to the user's home directory, or that contains tilde expansions.
 - This converts such a directory to an absolute path.
 - Note that it has to run on the system where the remote is.
 -}
repoAbsPath :: FilePath -> IO FilePath
repoAbsPath d = do
	d' <- expandTilde d
	h <- myHomeDir
	return $ h </> d'

myHomeDir :: IO FilePath
myHomeDir = do
	uid <- getEffectiveUserID
	u <- getUserEntryForID uid
	return $ homeDirectory u

expandTilde :: FilePath -> IO FilePath
expandTilde = expandt True
	where
		expandt _ [] = return ""
		expandt _ ('/':cs) = do
			v <- expandt True cs
			return ('/':v)
		expandt True ('~':'/':cs) = do
			h <- myHomeDir
			return $ h </> cs
		expandt True ('~':cs) = do
			let (name, rest) = findname "" cs
			u <- getUserEntryForName name
			return $ homeDirectory u </> rest
		expandt _ (c:cs) = do
			v <- expandt False cs
			return (c:v)
		findname n [] = (n, "")
		findname n (c:cs)
			| c == '/' = (n, cs)
			| otherwise = findname (n++[c]) cs

{- Finds the current git repository, which may be in a parent directory. -}
repoFromCwd :: IO Repo
repoFromCwd = do
	cwd <- getCurrentDirectory
	top <- seekUp cwd isRepoTop
	case top of
		-- repoFromAbsPath is not used to avoid looking for
		-- "dir.git" directories.
		(Just dir) -> return $ newFrom $ Dir dir
		Nothing -> error "Not in a git repository."

seekUp :: FilePath -> (FilePath -> IO Bool) -> IO (Maybe FilePath)
seekUp dir want = do
	ok <- want dir
	if ok
		then return (Just dir)
		else case (parentDir dir) of
			"" -> return Nothing
			d -> seekUp d want

isRepoTop :: FilePath -> IO Bool
isRepoTop dir = do
	r <- isRepo
	b <- isBareRepo
	return (r || b)
	where
		isRepo = gitSignature ".git" ".git/config"
		isBareRepo = gitSignature "objects" "config"
		gitSignature subdir file = do
			s <- (doesDirectoryExist (dir ++ "/" ++ subdir))
			f <- (doesFileExist (dir ++ "/" ++ file))
			return (s && f)