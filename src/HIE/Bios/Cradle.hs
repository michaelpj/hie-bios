{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE BangPatterns #-}
module HIE.Bios.Cradle (
      findCradle
    , loadCradle
    , loadCustomCradle
    , loadImplicitCradle
    , defaultCradle
    , isCabalCradle
    , isStackCradle
    , isDirectCradle
    , isBiosCradle
    , isNoneCradle
    , isMultiCradle
    , isDefaultCradle
    , isOtherCradle
  ) where

import Control.Exception (handleJust)
import qualified Data.Yaml as Yaml
import Data.Void
import System.Process
import System.Exit
import HIE.Bios.Types hiding (ActionName(..))
import qualified HIE.Bios.Types as Types
import HIE.Bios.Config
import HIE.Bios.Environment (getCacheDir)
import System.Directory hiding (findFile)
import Control.Monad.Trans.Maybe
import System.FilePath
import Control.Monad
import System.Info.Extra
import Control.Monad.IO.Class
import System.Environment
import Control.Applicative ((<|>))
import System.IO.Temp
import System.IO.Error (isPermissionError)
import Data.List
import Data.Ord (Down(..))

import System.PosixCompat.Files
import HIE.Bios.Wrappers
import System.IO
import Control.DeepSeq

import Data.Conduit.Process
import qualified Data.Conduit.Combinators as C
import qualified Data.Conduit as C
import qualified Data.Conduit.Text as C
import qualified Data.Text as T
import           Data.Maybe (fromMaybe)
import           GHC.Fingerprint (fingerprintString)
----------------------------------------------------------------

-- | Given root\/foo\/bar.hs, return root\/hie.yaml, or wherever the yaml file was found.
findCradle :: FilePath -> IO (Maybe FilePath)
findCradle wfile = do
    let wdir = takeDirectory wfile
    runMaybeT (yamlConfig wdir)

-- | Given root\/hie.yaml load the Cradle.
loadCradle :: FilePath -> IO (Cradle Void)
loadCradle = loadCradleWithOpts Types.defaultCradleOpts absurd

loadCustomCradle :: Yaml.FromJSON b => (b -> Cradle a) -> FilePath -> IO (Cradle a)
loadCustomCradle = loadCradleWithOpts Types.defaultCradleOpts

-- | Given root\/foo\/bar.hs, load an implicit cradle
loadImplicitCradle :: Show a => FilePath -> IO (Cradle a)
loadImplicitCradle wfile = do
  let wdir = takeDirectory wfile
  cfg <- runMaybeT (implicitConfig wdir)
  return $ case cfg of
    Just bc -> getCradle absurd bc
    Nothing -> defaultCradle wdir

-- | Finding 'Cradle'.
--   Find a cabal file by tracing ancestor directories.
--   Find a sandbox according to a cabal sandbox config
--   in a cabal directory.
loadCradleWithOpts :: (Yaml.FromJSON b) => CradleOpts -> (b -> Cradle a) -> FilePath -> IO (Cradle a)
loadCradleWithOpts _copts buildCustomCradle wfile = do
    cradleConfig <- readCradleConfig wfile
    return $ getCradle buildCustomCradle (cradleConfig, takeDirectory wfile)

getCradle :: (b -> Cradle a) -> (CradleConfig b, FilePath) -> Cradle a
getCradle buildCustomCradle (cc, wdir) = addCradleDeps cradleDeps $ case cradleType cc of
    Cabal mc -> cabalCradle wdir mc
    CabalMulti ms ->
      getCradle buildCustomCradle $
        (CradleConfig cradleDeps
          (Multi [(p, CradleConfig [] (Cabal (Just c))) | (p, c) <- ms])
        , wdir)
    Stack mc -> stackCradle wdir mc
    StackMulti ms ->
      getCradle buildCustomCradle $
        (CradleConfig cradleDeps
          (Multi [(p, CradleConfig [] (Stack (Just c))) | (p, c) <- ms])
        , wdir)
 --   Bazel -> rulesHaskellCradle wdir
 --   Obelisk -> obeliskCradle wdir
    Bios bios deps  -> biosCradle wdir bios deps
    Direct xs -> directCradle wdir xs
    None      -> noneCradle wdir
    Multi ms  -> multiCradle buildCustomCradle wdir ms
    Other a _ -> buildCustomCradle a
    where
      cradleDeps = cradleDependencies cc

addCradleDeps :: [FilePath] -> Cradle a -> Cradle a
addCradleDeps deps c =
  c { cradleOptsProg = addActionDeps (cradleOptsProg c) }
  where
    addActionDeps :: CradleAction a -> CradleAction a
    addActionDeps ca =
      ca { runCradle = \l fp ->
            (fmap (\(ComponentOptions os' dir ds) -> ComponentOptions os' dir (ds `union` deps)))
              <$> runCradle ca l fp }

implicitConfig :: FilePath -> MaybeT IO (CradleConfig a, FilePath)
implicitConfig fp = do
  (crdType, wdir) <- implicitConfig' fp
  return (CradleConfig [] crdType, wdir)

implicitConfig' :: FilePath -> MaybeT IO (CradleType a, FilePath)
implicitConfig' fp = (\wdir ->
         (Bios (wdir </> ".hie-bios") Nothing, wdir)) <$> biosWorkDir fp
  --   <|> (Obelisk,) <$> obeliskWorkDir fp
  --   <|> (Bazel,) <$> rulesHaskellWorkDir fp
     <|> (stackExecutable >> (Stack Nothing,) <$> stackWorkDir fp)
     <|> ((Cabal Nothing,) <$> cabalWorkDir fp)


yamlConfig :: FilePath ->  MaybeT IO FilePath
yamlConfig fp = do
  configDir <- yamlConfigDirectory fp
  return (configDir </> configFileName)

yamlConfigDirectory :: FilePath -> MaybeT IO FilePath
yamlConfigDirectory = findFileUpwards (configFileName ==)

readCradleConfig :: Yaml.FromJSON b => FilePath -> IO (CradleConfig b)
readCradleConfig yamlHie = do
  cfg  <- liftIO $ readConfig yamlHie
  return (cradle cfg)

configFileName :: FilePath
configFileName = "hie.yaml"

---------------------------------------------------------------

isCabalCradle :: Cradle a -> Bool
isCabalCradle crdl = case actionName (cradleOptsProg crdl) of
  Types.Cabal -> True
  _ -> False

isStackCradle :: Cradle a -> Bool
isStackCradle crdl = case actionName (cradleOptsProg crdl) of
  Types.Stack -> True
  _ -> False

isDirectCradle :: Cradle a -> Bool
isDirectCradle crdl = case actionName (cradleOptsProg crdl) of
  Types.Direct -> True
  _ -> False

isBiosCradle :: Cradle a -> Bool
isBiosCradle crdl = case actionName (cradleOptsProg crdl) of
  Types.Bios -> True
  _ -> False

isMultiCradle :: Cradle a -> Bool
isMultiCradle crdl = case actionName (cradleOptsProg crdl) of
  Types.Multi -> True
  _ -> False

isNoneCradle :: Cradle a -> Bool
isNoneCradle crdl = case actionName (cradleOptsProg crdl) of
  Types.None -> True
  _ -> False

isDefaultCradle :: Cradle a -> Bool
isDefaultCradle crdl = case actionName (cradleOptsProg crdl) of
  Types.Default -> True
  _ -> False

isOtherCradle :: Cradle a -> Bool
isOtherCradle crdl = case actionName (cradleOptsProg crdl) of
  Types.Other _ -> True
  _ -> False

---------------------------------------------------------------

-- | Default cradle has no special options, not very useful for loading
-- modules.
defaultCradle :: FilePath -> Cradle a
defaultCradle cur_dir =
  Cradle
    { cradleRootDir = cur_dir
    , cradleOptsProg = CradleAction
        { actionName = Types.Default
        , runCradle = \_ _ -> return (CradleSuccess (ComponentOptions [] cur_dir []))
        }
    }

---------------------------------------------------------------
-- The none cradle tells us not to even attempt to load a certain directory

noneCradle :: FilePath -> Cradle a
noneCradle cur_dir =
  Cradle
    { cradleRootDir = cur_dir
    , cradleOptsProg = CradleAction
        { actionName = Types.None
        , runCradle = \_ _ -> return CradleNone
        }
    }

---------------------------------------------------------------
-- The multi cradle selects a cradle based on the filepath

multiCradle :: (b -> Cradle a) -> FilePath -> [(FilePath, CradleConfig b)] -> Cradle a
multiCradle buildCustomCradle cur_dir cs =
  Cradle
    { cradleRootDir  = cur_dir
    , cradleOptsProg = CradleAction
        { actionName = multiActionName
        , runCradle  = \l fp -> canonicalizePath fp >>= multiAction buildCustomCradle cur_dir cs l
        }
    }
  where
    cfgs = map snd cs

    multiActionName
      | all (\c -> isStackCradleConfig c || isNoneCradleConfig c) cfgs
      = Types.Stack
      | all (\c -> isCabalCradleConfig c || isNoneCradleConfig c) cfgs
      = Types.Cabal
      | otherwise
      = Types.Multi

    isStackCradleConfig cfg = case cradleType cfg of
      Stack{}      -> True
      StackMulti{} -> True
      _            -> False

    isCabalCradleConfig cfg = case cradleType cfg of
      Cabal{}      -> True
      CabalMulti{} -> True
      _            -> False

    isNoneCradleConfig cfg = case cradleType cfg of
      None -> True
      _    -> False

multiAction ::  forall b a
            . (b -> Cradle a)
            -> FilePath
            -> [(FilePath, CradleConfig b)]
            -> LoggingFunction
            -> FilePath
            -> IO (CradleLoadResult ComponentOptions)
multiAction buildCustomCradle cur_dir cs l cur_fp =
    selectCradle =<< canonicalizeCradles

  where
    err_msg = ["Multi Cradle: No prefixes matched"
              , "pwd: " ++ cur_dir
              , "filepath: " ++ cur_fp
              , "prefixes:"
              ] ++ [show (pf, cradleType cc) | (pf, cc) <- cs]

    -- Canonicalize the relative paths present in the multi-cradle and
    -- also order the paths by most specific first. In the cradle selection
    -- function we want to choose the most specific cradle possible.
    canonicalizeCradles :: IO [(FilePath, CradleConfig b)]
    canonicalizeCradles =
      sortOn (Down . fst)
        <$> mapM (\(p, c) -> (,c) <$> (canonicalizePath (cur_dir </> p))) cs

    selectCradle [] =
      return (CradleFail (CradleError ExitSuccess err_msg))
    selectCradle ((p, c): css) =
        if p `isPrefixOf` cur_fp
          then runCradle
                  (cradleOptsProg (getCradle buildCustomCradle (c, cur_dir)))
                  l
                  cur_fp
          else selectCradle css


-------------------------------------------------------------------------

directCradle :: FilePath -> [String] -> Cradle a
directCradle wdir args  =
  Cradle
    { cradleRootDir = wdir
    , cradleOptsProg = CradleAction
        { actionName = Types.Direct
        , runCradle = \_ _ -> return (CradleSuccess (ComponentOptions args wdir []))
        }
    }

-------------------------------------------------------------------------


-- | Find a cradle by finding an executable `hie-bios` file which will
-- be executed to find the correct GHC options to use.
biosCradle :: FilePath -> FilePath -> Maybe FilePath -> Cradle a
biosCradle wdir biosProg biosDepsProg =
  Cradle
    { cradleRootDir    = wdir
    , cradleOptsProg   = CradleAction
        { actionName = Types.Bios
        , runCradle = biosAction wdir biosProg biosDepsProg
        }
    }

biosWorkDir :: FilePath -> MaybeT IO FilePath
biosWorkDir = findFileUpwards (".hie-bios" ==)

biosDepsAction :: LoggingFunction -> FilePath -> Maybe FilePath -> IO [FilePath]
biosDepsAction l wdir (Just biosDepsProg) = do
  biosDeps' <- canonicalizePath biosDepsProg
  (ex, sout, serr, args) <- readProcessWithOutputFile l Nothing wdir biosDeps' []
  case ex of
    ExitFailure _ ->  error $ show (ex, sout, serr)
    ExitSuccess -> return args
biosDepsAction _ _ Nothing = return []

biosAction :: FilePath
           -> FilePath
           -> Maybe FilePath
           -> LoggingFunction
           -> FilePath
           -> IO (CradleLoadResult ComponentOptions)
biosAction wdir bios bios_deps l fp = do
  bios' <- canonicalizePath bios
  (ex, _stdo, std, res) <- readProcessWithOutputFile l Nothing wdir bios' [fp]
  deps <- biosDepsAction l wdir bios_deps
        -- Output from the program should be written to the output file and
        -- delimited by newlines.
        -- Execute the bios action and add dependencies of the cradle.
        -- Removes all duplicates.
  return $ makeCradleResult (ex, std, wdir, res) deps

------------------------------------------------------------------------
-- Cabal Cradle
-- Works for new-build by invoking `v2-repl` does not support components
-- yet.
cabalCradle :: FilePath -> Maybe String -> Cradle a
cabalCradle wdir mc =
  Cradle
    { cradleRootDir    = wdir
    , cradleOptsProg   = CradleAction
        { actionName = Types.Cabal
        , runCradle = cabalAction wdir mc
        }
    }

cabalCradleDependencies :: FilePath -> IO [FilePath]
cabalCradleDependencies rootDir = do
    cabalFiles <- findCabalFiles rootDir
    return $ cabalFiles ++ ["cabal.project"]

findCabalFiles :: FilePath -> IO [FilePath]
findCabalFiles wdir = do
  dirContent <- listDirectory wdir
  return $ filter ((== ".cabal") . takeExtension) dirContent


processCabalWrapperArgs :: [String] -> Maybe (FilePath, [String])
processCabalWrapperArgs args =
    case args of
        (dir: ghc_args) ->
            let final_args =
                    removeVerbosityOpts
                    $ removeRTS
                    $ removeInteractive
                    $ ghc_args
            in Just (dir, final_args)
        _ -> Nothing

-- | GHC process information.
-- Consists of the filepath to the ghc executable and
-- arguments to the executable.
type GhcProc = (FilePath, [String])

-- generate a fake GHC that can be passed to cabal
-- when run with --interactive, it will print out its
-- command-line arguments and exit
getCabalWrapperTool :: GhcProc -> FilePath -> IO FilePath
getCabalWrapperTool (ghcPath, ghcArgs) wdir = do
  wrapper_fp <-
    if isWindows
      then do
        cacheDir <- getCacheDir ""
        let srcHash = show (fingerprintString cabalWrapperHs)
        let wrapper_name = "wrapper-" ++ srcHash
        let wrapper_fp = cacheDir </> wrapper_name <.> "exe"
        exists <- doesFileExist wrapper_fp
        unless exists $ withSystemTempDirectory "hie-bios" $ \ tmpDir -> do
            createDirectoryIfMissing True cacheDir
            let wrapper_hs = cacheDir </> wrapper_name <.> "hs"
            writeFile wrapper_hs cabalWrapperHs
            let ghc = (proc ghcPath $
                        ghcArgs ++ ["-rtsopts=ignore", "-outputdir", tmpDir, "-o", wrapper_fp, wrapper_hs])
                        { cwd = Just wdir }
            readCreateProcess ghc "" >>= putStr
        return wrapper_fp
      else writeSystemTempFile "bios-wrapper" cabalWrapper

  setFileMode wrapper_fp accessModes
  _check <- readFile wrapper_fp
  return wrapper_fp

cabalAction :: FilePath -> Maybe String -> LoggingFunction -> FilePath -> IO (CradleLoadResult ComponentOptions)
cabalAction work_dir mc l fp = do
  wrapper_fp <- getCabalWrapperTool ("ghc", []) work_dir
  let cab_args = ["v2-repl", "--with-compiler", wrapper_fp, fromMaybe (fixTargetPath fp) mc]
  (ex, output, stde, args) <-
    readProcessWithOutputFile l Nothing work_dir "cabal" cab_args
  deps <- cabalCradleDependencies work_dir
  case processCabalWrapperArgs args of
      Nothing -> pure $ CradleFail (CradleError ex
                  ["Failed to parse result of calling cabal"
                   , unlines output
                   , unlines stde
                   , unlines args])
      Just (componentDir, final_args) -> pure $ makeCradleResult (ex, stde, componentDir, final_args) deps
  where
    -- Need to make relative on Windows, due to a Cabal bug with how it
    -- parses file targets with a C: drive in it
    fixTargetPath x
      | isWindows && hasDrive x = makeRelative work_dir x
      | otherwise = x

removeInteractive :: [String] -> [String]
removeInteractive = filter (/= "--interactive")

-- Strip out any ["+RTS", ..., "-RTS"] sequences in the command string list.
removeRTS :: [String] -> [String]
removeRTS ("+RTS" : xs)  =
  case dropWhile (/= "-RTS") xs of
    [] -> []
    (_ : ys) -> removeRTS ys
removeRTS (y:ys)         = y : removeRTS ys
removeRTS []             = []

removeVerbosityOpts :: [String] -> [String]
removeVerbosityOpts = filter ((&&) <$> (/= "-v0") <*> (/= "-w"))


cabalWorkDir :: FilePath -> MaybeT IO FilePath
cabalWorkDir = findFileUpwards isCabal
  where
    isCabal name = name == "cabal.project"

------------------------------------------------------------------------
-- Stack Cradle
-- Works for by invoking `stack repl` with a wrapper script

stackCradle :: FilePath -> Maybe String -> Cradle a
stackCradle wdir mc =
  Cradle
    { cradleRootDir    = wdir
    , cradleOptsProg   = CradleAction
        { actionName = Types.Stack
        , runCradle = stackAction wdir mc
        }
    }

stackCradleDependencies :: FilePath-> IO [FilePath]
stackCradleDependencies wdir = do
  cabalFiles <- findCabalFiles wdir
  return $ cabalFiles ++ ["package.yaml", "stack.yaml"]

stackAction :: FilePath -> Maybe String -> LoggingFunction -> FilePath -> IO (CradleLoadResult ComponentOptions)
stackAction work_dir mc l _fp = do
  let ghcProcArgs = ("stack", ["exec", "ghc", "--"])
  -- Same wrapper works as with cabal
  wrapper_fp <- getCabalWrapperTool ghcProcArgs work_dir

  (ex1, _stdo, stde, args) <-
    readProcessWithOutputFile l Nothing work_dir
            "stack" $ ["repl", "--no-nix-pure", "--with-ghc", wrapper_fp]
                      ++ [ comp | Just comp <- [mc] ]
  (ex2, pkg_args, stdr, _) <-
    readProcessWithOutputFile l Nothing work_dir "stack" ["path", "--ghc-package-path"]
  let split_pkgs = concatMap splitSearchPath pkg_args
      pkg_ghc_args = concatMap (\p -> ["-package-db", p] ) split_pkgs
  deps <- stackCradleDependencies work_dir
  return $ case processCabalWrapperArgs args of
      Nothing -> CradleFail (CradleError ex1 $
                  ("Failed to parse result of calling stack":
                    stde)
                   ++ args)

      Just (componentDir, ghc_args) ->
        makeCradleResult (combineExitCodes [ex1, ex2], stde ++ stdr, componentDir, ghc_args ++ pkg_ghc_args) deps

combineExitCodes :: [ExitCode] -> ExitCode
combineExitCodes = foldr go ExitSuccess
  where
    go ExitSuccess b = b
    go a _ = a

stackExecutable :: MaybeT IO FilePath
stackExecutable = MaybeT $ findExecutable "stack"

stackWorkDir :: FilePath -> MaybeT IO FilePath
stackWorkDir = findFileUpwards isStack
  where
    isStack name = name == "stack.yaml"

{-
-- Support removed for 0.3 but should be added back in the future
----------------------------------------------------------------------------
-- rules_haskell - Thanks for David Smith for helping with this one.
-- Looks for the directory containing a WORKSPACE file
--
rulesHaskellWorkDir :: FilePath -> MaybeT IO FilePath
rulesHaskellWorkDir fp =
  findFileUpwards (== "WORKSPACE") fp

rulesHaskellCradle :: FilePath -> Cradle
rulesHaskellCradle wdir =
  Cradle
    { cradleRootDir  = wdir
    , cradleOptsProg   = CradleAction
        { actionName = "bazel"
        , runCradle = rulesHaskellAction wdir
        }
    }

rulesHaskellCradleDependencies :: FilePath -> IO [FilePath]
rulesHaskellCradleDependencies _wdir = return ["BUILD.bazel", "WORKSPACE"]

bazelCommand :: String
bazelCommand = $(embedStringFile "wrappers/bazel")

rulesHaskellAction :: FilePath -> FilePath -> IO (CradleLoadResult ComponentOptions)
rulesHaskellAction work_dir fp = do
  wrapper_fp <- writeSystemTempFile "wrapper" bazelCommand
  setFileMode wrapper_fp accessModes
  let rel_path = makeRelative work_dir fp
  (ex, args, stde) <-
      readProcessWithOutputFile work_dir wrapper_fp [rel_path] []
  let args'  = filter (/= '\'') args
  let args'' = filter (/= "\"$GHCI_LOCATION\"") (words args')
  deps <- rulesHaskellCradleDependencies work_dir
  return $ makeCradleResult (ex, stde, args'') deps


------------------------------------------------------------------------------
-- Obelisk Cradle
-- Searches for the directory which contains `.obelisk`.

obeliskWorkDir :: FilePath -> MaybeT IO FilePath
obeliskWorkDir fp = do
  -- Find a possible root which will contain the cabal.project
  wdir <- findFileUpwards (== "cabal.project") fp
  -- Check for the ".obelisk" folder in this directory
  check <- liftIO $ doesDirectoryExist (wdir </> ".obelisk")
  unless check (fail "Not obelisk dir")
  return wdir

obeliskCradleDependencies :: FilePath -> IO [FilePath]
obeliskCradleDependencies _wdir = return []

obeliskCradle :: FilePath -> Cradle
obeliskCradle wdir =
  Cradle
    { cradleRootDir  = wdir
    , cradleOptsProg = CradleAction
        { actionName = "obelisk"
        , runCradle = obeliskAction wdir
        }
    }

obeliskAction :: FilePath -> FilePath -> IO (CradleLoadResult ComponentOptions)
obeliskAction work_dir _fp = do
  (ex, args, stde) <-
      readProcessWithOutputFile work_dir "ob" ["ide-args"] []

  o_deps <- obeliskCradleDependencies work_dir
  return (makeCradleResult (ex, stde, words args) o_deps )

-}
------------------------------------------------------------------------------
-- Utilities


-- | Searches upwards for the first directory containing a file to match
-- the predicate.
findFileUpwards :: (FilePath -> Bool) -> FilePath -> MaybeT IO FilePath
findFileUpwards p dir = do
  cnts <-
    liftIO
    $ handleJust
        -- Catch permission errors
        (\(e :: IOError) -> if isPermissionError e then Just [] else Nothing)
        pure
        (findFile p dir)

  case cnts of
    [] | dir' == dir -> fail "No cabal files"
            | otherwise   -> findFileUpwards p dir'
    _ : _ -> return dir
  where dir' = takeDirectory dir

-- | Sees if any file in the directory matches the predicate
findFile :: (FilePath -> Bool) -> FilePath -> IO [FilePath]
findFile p dir = do
  b <- doesDirectoryExist dir
  if b then getFiles >>= filterM doesPredFileExist else return []
  where
    getFiles = filter p <$> getDirectoryContents dir
    doesPredFileExist file = doesFileExist $ dir </> file

-- | Call a process with the given arguments.
-- * A special file is created for the process to write to, the process can discover the name of
-- the file by reading the @HIE_BIOS_OUTPUT@ environment variable. The contents of this file is
-- returned by the function.
-- * The logging function is called every time the process emits anything to stdout or stderr.
-- it can be used to report progress of the process to a user.
-- * The process is executed in the given directory.
-- * The path to the GHC version to use is supplied in the environment variable @HIE_BIOS_GHC@.
--   Additionally, arguments to ghc are supplied via @HIE_BIOS_GHC_ARGS@
readProcessWithOutputFile
  :: LoggingFunction -- ^ Output of the process is streamed into this function.
  -> Maybe GhcProc -- ^ Optional FilePath to GHC and arguments that should
                   -- be passed to ghc.
                   -- In the process to call, filepath and arguments
  -> FilePath -- ^ Working directory. Process is executed in this directory.
  -> FilePath -- ^ Process to call.
  -> [String] -- ^ Arguments to the process.
  -> IO (ExitCode, [String], [String], [String])
readProcessWithOutputFile l ghcProc work_dir fp args =
  withSystemTempFile "bios-output" $ \output_file h -> do
    hSetBuffering h LineBuffering
    old_env <- getEnvironment
    let (ghcPath, ghcArgs) = case ghcProc of
            Just (p, a) -> (p, unwords a)
            Nothing ->
              ( fromMaybe "ghc" (lookup hieBiosGhc old_env)
              , fromMaybe "" (lookup hieBiosGhcArgs old_env)
              )
    -- Pipe stdout directly into the logger
    let process = (readProcessInDirectory work_dir fp args)
                      { env = Just
                              $ (hieBiosGhc, ghcPath)
                              : (hieBiosGhcArgs, ghcArgs)
                              : ("HIE_BIOS_OUTPUT", output_file)
                              : old_env
                      }
        -- Windows line endings are not converted so you have to filter out `'r` characters
        loggingConduit = (C.decodeUtf8  C..| C.lines C..| C.filterE (/= '\r')  C..| C.map T.unpack C..| C.iterM l C..| C.sinkList)
    (ex, stdo, stde) <- sourceProcessWithStreams process mempty loggingConduit loggingConduit
    !res <- force <$> hGetContents h
    return (ex, stdo, stde, lines (filter (/= '\r') res))

    where
      hieBiosGhc = "HIE_BIOS_GHC"
      hieBiosGhcArgs = "HIE_BIOS_GHC_ARGS"

readProcessInDirectory :: FilePath -> FilePath -> [String] -> CreateProcess
readProcessInDirectory wdir p args = (proc p args) { cwd = Just wdir }

makeCradleResult :: (ExitCode, [String], FilePath, [String]) -> [FilePath] -> CradleLoadResult ComponentOptions
makeCradleResult (ex, err, componentDir, gopts) deps =
  case ex of
    ExitFailure _ -> CradleFail (CradleError ex err)
    _ ->
        let compOpts = ComponentOptions gopts componentDir deps
        in CradleSuccess compOpts
