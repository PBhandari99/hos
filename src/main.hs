module Main where

import Foreign.Ptr
import Foreign.Storable
import Control.Monad
import Data.Word
import Data.Char
import Data.Monoid
import Data.IORef
--import qualified Data.PQueue.Prio.Min as PQ
import qualified Data.Map.Base as M
import System.IO.Unsafe

import Numeric

import Hos.CBits
import Hos.Types
import Hos.Task
import Hos.Memory
import Hos.SysCall
import Hos.Privileges
import Data.Elf

import Hos.Arch.Types
#if TARGET==x86_64
import Hos.Arch.X64
#endif

strict :: a -> a
strict !x = x

main :: IO ()
main = do
  -- Yay! We're now in Haskel(!!) land
  --
  -- There are a few steps here before we can really get into the nitty gritty of being
  -- an operating system.
  --
  -- We want to initialize the C task scheduling system. This will let us forcibly context
  -- switch between processes we manage.
  --
  -- We also will want to set up interrupts (again using C). We want interrupts for all
  -- faults and for at least the timer IRQ for now
  --
  -- Then we will want to create our resource catalog so that we can dish them out to the
  -- init process
  --
  -- Finally, we will want to load the init process, enable preemption, and enter user mode.
#if TARGET==x86_64
  initProcessPhysBase <- x64GetPhysPage 0x400000
  hosMain (x64 { archInitProcessPhysBase = initProcessPhysBase })
#endif

hosMain :: (Show regs, Show vTbl, Show e, Registers regs) => Arch regs vTbl e -> IO ()
hosMain a = do archDebugLog a ("Starting in Haskell land!")

               -- The loader will have loaded the init task at 4 megabytes, but it's an ELF file
               -- so we should parse it, unmap it from the address space, and then establish new mappings
               -- for it.
               let elfPtr = wordToPtr 0x400000 :: Ptr Elf64Hdr
               (elfHdr, progHdrs) <- elf64ProgHdrs elfPtr
               let mappings = map (\pHdr -> (ph64VAddr pHdr, ph64MemSz pHdr, initProcessPhysBase + (ph64Offset pHdr))) $
                              filter (elfShouldLoad . ph64Type) progHdrs
                   initProcessPhysBase = archInitProcessPhysBase a

               archUnmapInitTask a

               initTask <- mkInitTask a (e64Entry elfHdr)

               -- Now, add the mapping into the task
               let initTask' = foldr (\(vAddr, sz, physBase) -> taskWithMapping vAddr (vAddr + sz) (Mapped (UserSpace ReadWrite) physBase)) initTask mappings

               -- Now we want to get ready for userspace.
               archReadyForUserspace a

               -- switch tasks, using the initTask we're switching to as the faux old task...
               -- we're not going to use the result so this doesn't really matter
               archSwitchTasks a initTask' initTask'

               -- Now we will build our resource catalog
               -- archGetArchSpecificResources a

               -- Now we switch into the new task
               let initialState = HosState
                                  { hosSchedule = emptySchedule initTaskId

                                  , hosTasks = M.singleton initTaskId initTask' }
                   initTaskId = TaskId 0

               kernelize a initialState

kernelize :: (Registers regs, Show e, Show regs) => Arch regs vMemTbl e -> HosState regs vMemTbl e -> IO ()
kernelize a st =
    do rsn <- archSwitchToUserspace a
       let taskId = hscCurrentTask (hosSchedule st)
       rip <- x64GetUserRIP
       archDebugLog a ("Back(Task" ++ show taskId ++ "): " ++ show rsn ++ " at " ++ showHex rip "")
       case rsn of
         TrapInterrupt (VirtualMemoryFault vmCause vAddr) ->
             do t <- currentTask st
                res <- handleFaultAt a vmCause vAddr t
                case res of
                  Right t' ->
                    do ((), st') <- modifyCurrentTask st (\_ -> ((), t'))
                       kernelize a st'
                  Left rsn ->
                    do rip <- x64GetUserRIP
                       archDebugLog a ("Can't map " ++ showHex vAddr "" ++ " at " ++ showHex rip "")
                       t' <- archSwitchTasks a t t
                       archDebugLog a ("Regs :" ++ show (taskSavedRegisters t'))
         TrapInterrupt (ArchException archE) ->
             do res <- archHandleException a archE st
                case res of
                  Right st' -> kernelize a st'
                  Left err -> archDebugLog a ("Architectural panic: " ++ show err)
         SysCallInterrupt (DebugLog s) ->
             runSysCall (debugLog s) a st >>= kernelize a
         SysCallInterrupt (CurrentAddressSpace taskId) ->
             do runSysCall (currentAddressSpace taskId) a st >>= kernelize a
         SysCallInterrupt (AddMapping addrSpaceRef range mapping) ->
             runSysCall (addMapping addrSpaceRef range mapping) a st >>= kernelize a
         SysCallInterrupt (SwitchToAddressSpace taskId addrSpaceRef) ->
             runSysCall (switchToAddressSpace taskId addrSpaceRef) a st >>= kernelize a
         SysCallInterrupt (CloseAddressSpace addrSpaceRef) ->
             runSysCall (closeAddressSpace addrSpaceRef) a st >>= kernelize a
         SysCallInterrupt (KillTask taskId) ->
             runSysCall (killTask taskId) a st >>= kernelize a
         SysCallInterrupt CurrentTask ->
             runSysCall getCurrentTaskId a st >>= kernelize a
         SysCallInterrupt Fork ->
             runSysCall forkSc a st >>= kernelize a
         SysCallInterrupt Yield ->
             runSysCall yieldSc a st >>= kernelize a
         SysCallInterrupt ModuleCount ->
             do modCount <- archBootModuleCount a
                archReturnToUserspace a (fromSysCallReturnable modCount)
                kernelize a st
         SysCallInterrupt (GetModuleInfo i p) ->
             do archGetBootModule a i (castPtr p)
                kernelize a st
         TrapInterrupt ProtectionException -> archUserPanic a
         _ -> do rip <- x64GetUserRIP
                 archDebugLog a ("Got back from userspace because of a " ++ show rsn ++ " at " ++ showHex rip "")

runSysCall :: (SysCallReturnable a, Registers r, Show e, Show r) => SysCallM r v e a -> Arch r v e -> HosState r v e -> IO (HosState r v e)
runSysCall sc a st = do res <- runSysCallM sc a st
                        case res of
                          Error e -> archReturnToUserspace a (fromSysCallReturnable e) >>
                                     return st
                          Success (x, st') -> archReturnToUserspace a (fromSysCallReturnable x) >>
                                              return st'

debugLog :: String -> SysCallM r v e ()
debugLog s = scDebugLog ("Userspace says: " ++ show s)

currentAddressSpace :: TaskId -> SysCallM r v e ()
currentAddressSpace taskId =
    do Task { taskAddressSpace = addrSpace } <- getTask taskId
       curTask <- getCurrentTask
       let newAddressSpaceRef = nextRef AddressSpaceRef unAddressSpaceRef (taskAddressSpaces curTask)
       setCurrentTask (curTask { taskAddressSpaces = M.insert newAddressSpaceRef addrSpace (taskAddressSpaces curTask) })

addMapping :: AddressSpaceRef -> AddressRange -> Mapping -> SysCallM r v e ()
addMapping addrSpaceRef (AR start end) mapping =
    do curTask <- getCurrentTask
       addrSpace <- getAddressSpace curTask addrSpaceRef
       let addrSpace' = addrSpaceWithMapping start end mapping addrSpace
           curTask' = taskWithModifiedAddressSpace addrSpaceRef addrSpace' curTask
       setCurrentTask curTask'

switchToAddressSpace :: TaskId -> AddressSpaceRef -> SysCallM r v e ()
switchToAddressSpace taskId addrSpaceRef =
    ensuringPrivileges (canReplaceAddressSpaceP taskId) $
      do task <- getTask taskId
         curTask <- getCurrentTask
         addrSpace <- getAddressSpace curTask addrSpaceRef
         let task' = taskWithAddressSpace addrSpace curTask
         setTask taskId task'

closeAddressSpace :: AddressSpaceRef -> SysCallM r v e ()
closeAddressSpace addrSpaceRef =
    do curTask <- getCurrentTask
       let curTask' = taskWithDeletedAddressSpace addrSpaceRef curTask
       setCurrentTask curTask'

killTask :: TaskId -> SysCallM r v e ()
killTask taskId = ensuringPrivileges (canKillP taskId) $
                  do x <- switchToNextTask
                     x `seq` deleteTask taskId

yieldSc :: SysCallM r v e ()
yieldSc = do curPrio <- getCurrentTaskPriority
             curTaskId <- getCurrentTaskId
             curTask' <- switchToNextTask
             x1 <- setTask curTaskId curTask'
             x1 `seq` scheduleTask curPrio curTaskId -- make sure we run next time!

forkSc :: SysCallM r v e TaskId
forkSc = do curTask <- getCurrentTask
            a <- getArch
            (curTask'', childTask) <- liftIO $ do curTask' <- archSwitchTasks a curTask curTask
                                                  taskFork a curTask'
            childTask' <- liftIO $ do
                            t1 <- archSwitchTasks a curTask childTask
                            () <- archReturnToUserspace a (fromSysCallReturnable (TaskId 0))
                            t1 `seq` archSwitchTasks a childTask curTask''

            childId <- newTaskId

            x1 <- setTask childId childTask'
            x2 <- setCurrentTask curTask''

            x3 <- scDebugLog ("after fork, new address space is " ++ show (taskAddressSpace curTask''))

            curPrio <- getCurrentTaskPriority
            x4 <- scheduleTask curPrio childId

            -- This gets around a bug in JHC...
            return (x1 `seq` x2 `seq` x3 `seq` x4 `seq` childId)
