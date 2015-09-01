{-
Copyright 2015 SlamData, Inc.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
-}

module Test.Selenium.Common
  ( assertBoolean
  , getElementByCss
  , getHashFromURL
  , dropHash
  , fileComponentLoaded
  , notebookLoaded
  , modalShown
  , modalDismissed
  , sendSelectAll
  , sendCopy
  , sendPaste
  , sendUndo
  , sendDelete
  , sendEnter
  , sendKeyCombo
  , parseToInt
  , filterByContent
  , filterByPairs
  , waiter
  , waitExistentCss
  , checkNotExists
  , waitNotExistentCss
  , await'
  , await
  , waitTime
  )
  where

import Prelude
import Data.Either (either, isRight, Either(..))
import Data.Maybe (Maybe(..), maybe)
import Data.Foldable (traverse_)
import Data.Traversable (traverse)
import Data.List (List(), filter)
import Data.Tuple (Tuple(..), fst, snd)
import qualified Data.String.Regex as R
import qualified Data.StrMap as SM
import qualified Data.String as Str
import qualified Data.Char as Ch

import Driver.File.Routing (Routes(..), routing)
import Routing (matchHash)

import Selenium.ActionSequence hiding (sequence)
import Selenium.Key
import Selenium.Types
import Selenium.Monad 
import qualified Selenium.Combinators as Sc 

import Test.Platform
import Test.Selenium.Log
import Test.Selenium.Monad 

import Utils (s2i)

-- | `waiter'` with timeout setted to `config.selenium.waitTime`
waiter :: forall a. Check a -> Check a
waiter getter = getConfig >>= _.selenium >>> _.waitTime >>> Sc.waiter getter

-- | Assert the truth of a boolean, providing an error message
assertBoolean :: String -> Boolean -> Check Unit
assertBoolean _ true = pure unit
assertBoolean err false = errorMsg err

-- | Get element by css-selector or throw error
getElementByCss :: String -> String -> Check Element
getElementByCss cls errorMessage =
  (attempt $ Sc.getElementByCss cls)
    >>= either (const $ errorMsg errorMessage) pure 

checkNotExists :: String -> String -> Check Unit
checkNotExists css msg =
  (attempt $ Sc.checkNotExistsByCss css)
    >>= either (const $ errorMsg msg) pure 

-- | Same as `waitExistentCss'` but wait time is setted to `config.selenium.waitTime`
waitExistentCss :: String -> String -> Check Element
waitExistentCss css msg =
  waiter (getElementByCss css msg)

-- | same as `waitNotExistentCss'`, wait time is setted to `config.selenium.waitTime`
waitNotExistentCss :: String -> String -> Check Unit
waitNotExistentCss  msg css =
  waiter (checkNotExists css msg)

await' :: Int -> String -> Check Boolean -> Check Unit
await' timeout msg check = do
  attempt (Sc.await timeout check)
    >>= either (const $ errorMsg msg) (const $ pure unit)
    
-- | Same as `await'` but max wait time is setted to `config.selenium.waitTime`
await :: String -> Check Boolean -> Check Unit
await msg check = do
  config <- getConfig
  await' config.selenium.waitTime msg check 

getHashFromURL :: String -> Check Routes
getHashFromURL =
  dropHash
    >>> matchHash routing
    >>> either (const $ errorMsg "incorrect hash") pure

dropHash :: String -> String
dropHash h = R.replace (R.regex "^[^#]*#" R.noFlags) "" h

checkElements :: SM.StrMap String -> Check Unit
checkElements m = do
  config <- getConfig
  traverse_ traverseFn $ SM.toList m
  successMsg "all elements here, page is loaded"
  where
  traverseFn :: Tuple String String -> Check Unit
  traverseFn (Tuple key selector) = do
    driver <- getDriver
    byCss selector >>= findElement >>= checkMsg key

  checkMsg :: String -> Maybe _ -> Check Unit
  checkMsg msg Nothing = errorMsg $ msg <> " not found"
  checkMsg _ _ = pure unit

loaded :: Check Unit -> Check Unit
loaded elCheck = do
  driver <- getDriver
  config <- getConfig
  wait checkEls config.selenium.waitTime
  where
  checkEls = Sc.checker $ isRight <$> attempt elCheck

checkFileElements :: Check Unit
checkFileElements = getConfig >>= _.locators >>> checkElements

checkNotebookElements :: Check Unit
checkNotebookElements = getConfig >>= _.notebookLocators >>> checkElements

fileComponentLoaded :: Check Unit
fileComponentLoaded = loaded checkFileElements

notebookLoaded :: Check Unit
notebookLoaded = loaded checkNotebookElements

-- | Is a modal dialog shown?
modalShown :: Check Boolean
modalShown = do
  config <- getConfig
  Sc.checker $
    byCss config.modal
      >>= findElement
      >>= maybe (pure false) isDisplayed

modalDismissed :: Check Boolean
modalDismissed = do
  config <- getConfig
  Sc.checker $
    byCss config.modal
      >>= findElement
      >>= maybe (pure true) (map not <<< isDisplayed)

sendSelectAll :: Platform -> Sequence Unit
sendSelectAll p = case p of
  Mac -> sendKeyCombo [commandKey] "a"
  _ -> sendKeyCombo [controlKey] "a"

sendCopy :: Platform -> Sequence Unit
sendCopy p = case p of
  Mac -> sendKeyCombo [commandKey] "c"
  _ -> sendKeyCombo [controlKey] "c"

sendPaste :: Platform -> Sequence Unit
sendPaste p = case p of
  Mac -> sendKeyCombo [commandKey] "v"
  _ -> sendKeyCombo [controlKey] "v"

sendDelete :: Sequence Unit
sendDelete =
  sendKeys $ Str.fromChar $ Ch.fromCharCode 57367

sendEnter :: Sequence Unit
sendEnter =
  sendKeys $ Str.fromChar $ Ch.fromCharCode 13

sendUndo :: Platform -> Sequence Unit
sendUndo p = case p of
  Mac -> sendKeyCombo [commandKey] "z"
  _ -> sendKeyCombo [controlKey] "z"

sendKeyCombo :: Array ControlKey -> String -> Sequence Unit
sendKeyCombo ctrlKeys str = do
  traverse_ keyDown ctrlKeys
  sendKeys str
  traverse_ keyUp ctrlKeys

parseToInt :: String -> Check Int
parseToInt str =
  maybe (errorMsg "can't parse string to int") pure $ s2i str


filterByPairs :: List Element -> (Tuple Element String -> Boolean) ->
                   Check (List (Tuple Element String))
filterByPairs els filterFn = 
  filter filterFn <$> traverse (\el -> Tuple el <$> getInnerHtml el) els

 
filterByContent :: List Element -> (String -> Boolean) -> Check (List Element)
filterByContent els filterFn =
  (fst <$>) <$> (filterByPairs els (filterFn <<< snd))

waitTime :: Int -> Check Unit
waitTime t = do
  warnMsg "waitTime is used"
  later t $ pure unit 
