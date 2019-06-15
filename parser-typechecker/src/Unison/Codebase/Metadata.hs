module Unison.Codebase.Metadata where

import Data.Map (Map)
import Data.Set (Set)
import Unison.Reference (Reference)
import qualified Data.Map as Map
import qualified Data.Set as Set

type Type = Reference

type Metadata = Map Reference (Map Type (Set Reference))

-- parallel composition - commutative and associative
merge :: Metadata -> Metadata -> Metadata
merge = Map.unionWith (Map.unionWith (<>))

-- sequential composition, right-biased
append :: Metadata -> Metadata -> Metadata
append = Map.unionWith (Map.unionWith (flip const))

includeOnly :: Set Reference -> Metadata -> Metadata
includeOnly s md =
  Map.fromList [ (r, m) | r <- Set.toList s, Just m <- [Map.lookup r md]]