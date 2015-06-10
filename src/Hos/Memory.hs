module Hos.Memory where

import Hos.Types
import Hos.CBits

import Control.Monad
import Control.Exception

import Data.Word
import Data.Char
import qualified Data.IntervalMap as IntervalMap

import Foreign.Ptr
import Foreign.Storable

import System.IO.Unsafe

withMapping :: Arch r m e -> MemoryPermissions ->
               Word64 -> Word64 -> (Ptr a -> IO b) -> IO b
withMapping a perms v p f =
    bracket (archMapPage a v p perms)
            (\_ -> archUnmapPage a v)
            (\_ -> f (wordToPtr v))

memset :: Ptr a -> Word8 -> Word64 -> IO ()
memset !p !c 0 = return ()
memset !p !c sz = poke (castPtr p) c >> memset (p `plusPtr` 1) c (sz - 1)

memcpy :: Ptr a -> Ptr a -> Word64 -> IO ()
memcpy !dst !src 0 = return ()
memcpy !dst !src sz = peek (castPtr src :: Ptr Word8) >>= poke (castPtr dst) >>
                      memcpy (dst `plusPtr` 1) (src `plusPtr` 1) (sz - 1)

addrSpaceWithMapping :: Word64 -> Word64 -> Mapping -> AddressSpace -> AddressSpace
addrSpaceWithMapping start end mapping (AddressSpace aSpace) = AddressSpace $ IntervalMap.insert (start, end) mapping aSpace

releaseAddressSpace :: Arch r v e -> AddressSpace -> v -> IO ()
releaseAddressSpace arch aSpace virtMemTbl =
    do let regions = addrSpaceRegions aSpace
       forM_ regions $ \((start, end), mapping) ->
           case mapping of
             Mapped _ physBase ->
                 -- We need to subtract 1 from end because the mappings in the address space are closed-open, and archWalkVirtMemTbl assumes a closed interval
                 archWalkVirtMemTbl arch virtMemTbl start (end - 1) $ \_ phys ->
                     cPageAlignedPhysFree phys (alignToPage arch (end - start + fromIntegral (archPageSize arch) - 1))
             CopyOnWrite {} -> return () -- TODO: Skipping COW region at " ++ showHex start "")

             -- The other memory types either cannot be freed, or we don't need to
             _ -> return ()
       archReleaseVirtMemTbl arch virtMemTbl
