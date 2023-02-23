module Main where

import qualified TastyDiscover
import Test.Tasty

------------------------------------------------------------------------

main :: IO ()
main = defaultMain =<< TastyDiscover.tests
