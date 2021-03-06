{-# LANGUAGE TemplateHaskell		#-}
{-# LANGUAGE DeriveDataTypeable		#-}
{-# LANGUAGE DeriveGeneric		#-}
{-# LANGUAGE GeneralizedNewtypeDeriving	#-}
{-# LANGUAGE ForeignFunctionInterface #-}

module Main where

import GHC.Generics (Generic)
import Data.Typeable
import Control.Monad
import System.Posix.Files
import System.Environment (getArgs)
import Control.Concurrent (threadDelay)
import Control.Distributed.Process hiding (say)
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Backend.SimpleLocalnet
import Control.Distributed.Process.Node (initRemoteTable)
import Control.Distributed.Process.Platform (resolve)
import qualified Data.Vector.Storable as S
import Text.Printf
import Control.Distributed.Process.Debug
import qualified Control.Distributed.Process.Platform.Service.SystemLog as Log
import qualified Control.Distributed.Process.Platform.Time as Time
import qualified Control.Distributed.Process.Platform.Timer as Timer
import Data.Binary

import DNA.Channel.File
import DNA.Message

import Common (startLogger, say)
import Cfg (executableName, event)

data PartialSum = PartialSum ProcessId Double deriving (Show,Typeable,Generic)
instance Binary PartialSum
newtype Result = Result Double deriving (Show,Typeable,Generic)
instance Binary Result
data ProcessType = Crash ProcessId | Norm ProcessId deriving (Show,Typeable,Generic)
instance Binary ProcessType
--newtype Message = WhomToCrash ProcessId deriving (Eq, Ord, Show, Binary, Typeable)
--newtype MessageC = CrashMe ProcessId deriving (Eq, Ord, Show, Binary, Typeable)

--filePath :: FilePath
--filePath="float_file.txt"

-- |Collects data from compute processes, looking for
-- either partial sum result or monitoring messages.
--
-- Partial sums are get accumulated.
--
-- Monitoring notifications are checked whether process computed
-- partial sum or not. If process died before any partial sum computation
-- this process also terminate.
dpSum :: [ProcessId] -> Double -> Process(Double)
dpSum [ ] sum = do
      return sum
dpSum pids sum = do
	-- here we wait either for message with PartialSum or for message regarding process status.
	receiveWait
		[ match $ \(PartialSum pid s) -> dpSum (filter (/= pid) pids) (s+sum)
		, match $ \(ProcessMonitorNotification _ pid _) ->
			if pid `elem` pids
				then do
					say "process terminated before its contribution to sum."
					terminate
				else dpSum pids sum
		]

spawnCollector :: ProcessId -> Process ()
spawnCollector pid = do
  	collectorPID <- getSelfPid
        masterPID <- dnaSlaveHandleStart "collector" collectorPID

        (DnaPidList computePids) <- expect

	-- install monitors for compute processes.
	forM_ computePids $ \pid -> monitor pid
        sum <- dpSum computePids 0
        send masterPID (Result sum)
	traceMessage "trace message from collector."

data FileVec = FileVec ProcessId (S.Vector Double) deriving (Eq, Show, Typeable, Generic)

instance Binary FileVec where
	put (FileVec pid vec) = put pid >> put vec
	get = do { pid <- get; vec <- get; return (FileVec pid vec)}

-- XXX how do we make an S.Vector binary?
spawnFChan :: String -> Int -> Int -> ProcessId -> Process()
spawnFChan path cO cS pid = do
        mypid <- getSelfPid
	iov <- event "reading file" $ liftIO $ readData cS cO path
-- XXX must be an unsafe send to avoid copying
        send pid (FileVec mypid iov)

instance (S.Storable e, Binary e) => Binary (S.Vector e) where
	put vec = put (S.toList vec)
	get = get >>= (return . S.fromList)


data CompVec = CompVec ProcessId (S.Vector Double) deriving (Eq, Show, Typeable, Generic)
-- XXX how do we make an S.Vector binary?

instance Binary CompVec where
	put (CompVec pid vec) = put pid >> put vec
	get = do { pid <- get; vec <- get; return (CompVec pid vec)}

spawnCChan :: Int -> (Int -> Double) -> ProcessId -> Process()
spawnCChan n f pid = do
        myPid <- getSelfPid 
        let vec = S.generate n f
-- XXX must be an unsafe send to avoid copying
        send pid (CompVec myPid vec)


spawnCompute :: (FilePath, Int, Int, Int, ProcessId, String) -> Process ()
spawnCompute (file, chOffset, chSize, itemCount, collectorPID, opert) = do
	getSelfPid >>= enableTrace
	computePID <- getSelfPid
	sayDebug $ printf "[Compute %s] : f:%s iC:%s cS:%s cO:%s coll:%s" (show computePID) file (show itemCount) (show chSize) (show chOffset) (show collectorPID)
        masterPID <- dnaSlaveHandleStart "compute" computePID

	-- To check operation (normal/crash)
	send masterPID (Norm computePID)
	(Norm masterPID) <- expect

        fChanPid <- spawnLocal  (spawnFChan file chOffset chSize computePID)
        cChanPid <- spawnLocal  (spawnCChan chSize (\n -> 1.0) computePID)
        (FileVec fChanPid iov) <- expect
        (CompVec cChanPid cv) <- expect

	--sayDebug $ printf "[Compute %s] : Value of iov: %s" (show computePID) (show iov) 

	let sumOnComputeNode = S.sum $ S.zipWith (*) iov cv
	sayDebug $ printf "[Compute] : sumOnComputeNode : %s at %s send to %s" (show sumOnComputeNode) (show computePID) (show collectorPID)
	event "compute sends sum" $ do
		send collectorPID (PartialSum computePID sumOnComputeNode)
        send masterPID (DnaFinished computePID)
	traceMessage "trace message from compute."

remotable [ 'spawnCompute, 'spawnCollector]

master :: FilePath -> String -> Backend -> [NodeId] -> Process ()
master filePath opert backend peers = do
	startLogger peers
  --systemLog :: (String -> Process ()) -- ^ This expression does the actual logging
  --        -> (Process ())  -- ^ An expression used to clean up any residual state
  --        -> LogLevel      -- ^ The initial 'LogLevel' to use
  --        -> LogFormat     -- ^ An expression used to format logging messages/text
  --        -> Process ProcessId
        logPID <- Log.systemLog (liftIO . putStrLn) (return ()) Log.Debug return

	--startTracer $ \ev -> say $ "event: "++show ev

--	startTracer $ \ev -> do
--		sayDebug $ "evant in tracer: "++show ev

	Timer.sleep (Time.milliSeconds 100)

	masterPID <- getSelfPid
 	say $ printf "[Master %s]" (show masterPID)

	-- enable tracing after all is set up.
--	forM_ peers $ \peer -> do
--		startTraceRelay peer
--		setTraceFlags $ TraceFlags {
--			  traceSpawned = Nothing
--			, traceDied = Nothing
--			, traceRegistered = Nothing
--			, traceUnregistered = Nothing
--			, traceSend = Just TraceAll
--			, traceRecv = Just TraceAll
--			, traceNodes = True
--			, traceConnections = True
--			}

--	enableTrace masterPID

--	traceMessage "trace message from master"

-- Set up scheduling variables
  	let allComputeNids = tail peers
	let chunkCount = length allComputeNids 
	fileStatus <- liftIO $ getFileStatus filePath 
	let itemCount = div (read $ show (fileSize fileStatus)) itemSize
	liftIO . putStrLn $ "itemcount:  " ++  (show itemCount)

	let chunkOffsets = map (chunkOffset chunkCount itemCount) [1..chunkCount]
	liftIO . putStrLn $ "Offsets : " ++ show chunkOffsets
  	let chunkSizes = map (chunkSize chunkCount itemCount) [1..chunkCount]
  	liftIO . putStrLn $ "chunkSizes : " ++  show chunkSizes


	-- Start collector process
 	let collectorNid = head peers
        collectorPid <- dnaMasterStartSlave "collector" masterPID collectorNid ($(mkClosure 'spawnCollector) (masterPID))

--	enableTrace collectorPid

        -- Start compute processes
  	computePids <- forM (zip3 allComputeNids chunkOffsets chunkSizes)  $ \(computeNid,chO,chS) -> do
  		pid <- dnaMasterStartSlave "compute" masterPID computeNid ( $(mkClosure 'spawnCompute) (filePath, chO, chS, itemCount, collectorPid, opert)) 
		enableTrace pid
                return pid

	let computeToCrash = head computePids
	let computePidsNew = tail computePids

	case opert of
		"crash" -> do
			forM_ computePids $ \computePid -> do
				if computePid == computeToCrash
				then do 
					(Norm computeToCrash) <- expect
					send computeToCrash (Crash masterPID)
					sayDebug $ printf "Compute [%s] has to crash!!"  (show computeToCrash)
				else do (Norm computePid) <- expect
					send computePid (Norm masterPID)
					sayDebug $ printf "Compute [%s] continuing the computation!!"  (show computePid)
		"norm" -> do
			forM_ computePids $ \computePid -> do
				(Norm computePid) <- expect
				send computePid (Norm masterPID)
				sayDebug $ printf "Continue with computation[%s]!!" (show computePid)
	
	sum <- event "master waits for result" $ do
        	-- Send collector computePid's
        	case opert of
			"crash" -> do	
       				send collectorPid (DnaPidList computePidsNew)
			"norm" -> do 
				send collectorPid (DnaPidList computePids)

       		sayDebug "--------------------------------------------------------------------------------------"	
       		(Result sum) <- expect
		return sum
        sayDebug $ printf "Result %s" (show sum)
  	terminateAllSlaves backend	

main :: IO ()
main = do
	args <- getArgs

	case args of
 		["master", host, port, fwFloat, opert] -> do
    			backend <- initializeBackend host port rtable
      			startMaster backend (master fwFloat opert backend)
      			liftIO (threadDelay 200)

		["slave", host, port] -> do
    			backend <- initializeBackend host port rtable
      			startSlave backend
		["write-tests"] -> do
			writeFile "start-ddp" $ unlines [
				  "#!/bin/sh"
				, executableName++" slave localhost 60001 &"
				, executableName++" slave localhost 60002 &"
				, executableName++" slave localhost 60003 &"
				, "sleep 1"
				, executableName++" master localhost 44440"
				]
		["test-crash"] -> do
                        writeFile "start-ddp-crash" $ unlines [
                                  "#!/bin/sh"
				, executableName++" slave localhost 60001 &"
                                , executableName++" slave localhost 60002 &"
                                , executableName++" slave localhost 60003 &"
                                , executableName++" slave localhost 60004 &"
                                , "sleep 1"
                                , executableName++" master localhost 44440 float_file.txt crash"
                                ]

		["write-data", count] -> do
			return ()
                _ -> do putStrLn $ unlines [
				  "usage: '"++executableName++" (master|slave) host port"
				, "   or: '"++executableName++" write-tests"
				, "   or: '"++executableName++" test-crash"
				, ""
				, "'"++executableName++" write-tests' will write file 'start-ddp' into current directory."
				, "make it executable and run to test the program."
				]
  where
  	rtable :: RemoteTable
  	rtable = __remoteTable initRemoteTable
