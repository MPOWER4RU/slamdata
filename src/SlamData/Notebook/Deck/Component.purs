{-
Copyright 2016 SlamData, Inc.

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

module SlamData.Notebook.Deck.Component
  ( comp
  , initialState
  , module SlamData.Notebook.Deck.Component.Query
  , module DCS
  ) where

import SlamData.Prelude

import Control.Monad.Aff.Console (log)
import Control.Monad.Eff.Exception as Exn
import Control.Monad.Except.Trans (ExceptT(..), runExceptT)
import Control.UI.Browser (newTab, locationObject)
import Control.Monad.Aff.Free (fromEff)

import CSS.Geometry (width)
import CSS.Size (pct, Size(..), Rel, nil)
import CSS.String (fromString)
import CSS.Transform (transform, translate)

import Data.Argonaut (Json)
import Data.Array (catMaybes, nub)
import Data.BrowserFeatures (BrowserFeatures)
import Data.Int (toNumber)
import Data.Lens as Lens
import Data.Lens (LensP(), view, (.~), (%~), (?~), (^?))
import Data.Lens.Prism.Coproduct (_Right)
import Data.List as List
import Data.Map as Map
import Data.Ord (max)
import Data.Path.Pathy ((</>))
import Data.Path.Pathy as Pathy
import Data.Set as S
import Data.String as Str
import Data.Time (Milliseconds(..))

import Ace.Halogen.Component as Ace

import DOM.HTML.Location as Location

import Halogen as H
import Halogen.Component.ChildPath (ChildPath, injSlot, injState)
import Halogen.Component.Utils (forceRerender')
import Halogen.Component.Utils.Debounced (fireDebouncedQuery')
import Halogen.HTML.CSS.Indexed (style)
import Halogen.HTML.Events.Indexed as HE
import Halogen.HTML.Events.Handler as HEH
import Halogen.HTML.Indexed as HH
import Halogen.Component.ChildPath (injSlot, injState)
import Halogen.HTML.Properties.Indexed as HP
import Halogen.Themes.Bootstrap3 as B
import Halogen.HTML.Properties.Indexed.ARIA as ARIA
import Quasar.Aff as Quasar
import Quasar.Auth as Auth

import SlamData.Config as Config
import SlamData.Effects (Slam)
import SlamData.FileSystem.Resource as R
import SlamData.Notebook.AccessType (AccessType(..), isEditable)
import SlamData.Notebook.Action as NA
import SlamData.Notebook.Card.CardId (CardId(), runCardId, cardIdToString)
import SlamData.Notebook.Card.CardType
  (CardType(..), AceMode(..), cardName, cardGlyph, autorun, nextCardTypes)
import SlamData.Notebook.Card.Common.EvalQuery (CardEvalQuery(..))
import SlamData.Notebook.Card.Component (CardQueryP, CardQuery(..), InnerCardQuery, AnyCardQuery(..), _NextQuery, initialCardState)
import SlamData.Notebook.Card.Next.Component as Next
import SlamData.Notebook.Card.OpenResource.Component as Open
import SlamData.Notebook.Card.Port (Port(..))
import SlamData.Notebook.Deck.BackSide.Component as Back
import SlamData.Notebook.Deck.Component.ChildSlot (cpBackSide, cpCard, ChildQuery, ChildState, ChildSlot, CardSlot(..))
import SlamData.Notebook.Deck.Component.Query (QueryP, Query(..))

import SlamData.Notebook.Deck.Component.State as DCS
import SlamData.Notebook.Deck.DeckId (DeckId(..), deckIdToString)
import SlamData.Notebook.Deck.Model as Model
import SlamData.Notebook.Model as NB
import SlamData.Notebook.Routing (mkNotebookHash, mkNotebookCardHash, mkNotebookURL)
import SlamData.Quasar.Data (save, load) as Quasar
import SlamData.Quasar.FS (move, getNewName) as Quasar
import SlamData.Render.CSS as CSS
import Utils.Debounced (debouncedEventSource)
import Utils.Path (DirPath, FilePath)
import Utils.DOM (getBoundingClientRect, offsetLeft)
import Utils.CSS (transition)

type NotebookHTML = H.ParentHTML ChildState Query ChildQuery Slam ChildSlot
type NotebookDSL = H.ParentDSL DCS.State ChildState Query ChildQuery Slam ChildSlot

initialState ∷ BrowserFeatures → DCS.StateP
initialState fs = H.parentState $ DCS.initialDeck fs

comp ∷ H.Component DCS.StateP QueryP Slam
comp =
  H.parentComponent
    { render: render ∘ DCS.virtualState
    , eval
    , peek: Just peek
    }

render ∷ DCS.State → NotebookHTML
render state =
  case state.stateMode of
    DCS.Loading →
      HH.div
        [ HP.classes [ B.alert, B.alertInfo ] ]
        [ HH.h1
          [ HP.class_ B.textCenter ]
          [ HH.text "Loading..." ]
          -- We need to render the cards but have them invisible during loading
          -- otherwise the various nested components won't initialise correctly.
          -- This div is required, along with the key, so that structurally it
          -- is in the same place in both `Loading` and `Ready` states.
        , HH.div
            [ HP.key "deck-container" ]
            [ renderCards false ]
        ]
    DCS.Ready →
      -- WARNING: Very strange things happen when this is not in a div; see SD-1326.
      HH.div
        ([ HP.class_ CSS.board ]
           ⊕ (guard (isJust state.initialSliderX)
                $> (HE.onMouseUp \e -> HEH.preventDefault $> H.action (StopSlidingAndSnap e)))
           ⊕ (guard (isJust state.initialSliderX)
                $> (HE.onMouseLeave \e -> HEH.stopPropagation $> HEH.preventDefault $> H.action (StopSlidingAndSnap e)))
           ⊕ (guard (isJust state.initialSliderX)
                $> (HE.onMouseMove $ HE.input UpdateSliderPosition)))
        [ HH.div
            [ HP.class_ CSS.deck
            , HP.key "deck-container"
            ]
            [ renderCards $ not state.backsided
            , renderBackside state.backsided
              -- Commented until one card representation
--            , HH.button [ HP.classes [ B.btn, B.btnPrimary ]
--                        , HE.onClick (HE.input_ FlipDeck)
--                        , ARIA.label "Flip deck"
--                        ]
--              [ HH.text "Flip" ]
            ]
        ]

    DCS.Error err →
      HH.div
        [ HP.classes [ B.alert, B.alertDanger ] ]
        [ HH.h1
            [ HP.class_ B.textCenter ]
            [ HH.text err ]
        ]

  where
  renderBackside visible =
    HH.div
      ( [ ARIA.hidden $ show $ not visible ]
        ⊕ ((guard $ not visible) $> (HP.class_ CSS.invisible)))

      [ HH.slot' cpBackSide unit \_ →
         { component: Back.comp
         , initialState: Back.initialState
         }
      ]


  renderCards visible =
    -- The key here helps out virtual-dom: the entire subtree will be moved
    -- when the loading message disappears, rather than being reconstructed in
    -- the parent element
    HH.div
      ([ HP.key "notebook-cards"
       , HP.classes [ CSS.cardSlider ]
       , HE.onTransitionEnd $ HE.input_ StopSliderTransition
       , style
           $ (cardSliderWidth $ List.length state.cards + 1)
           *> (cardSliderTransform (List.length state.cards + 1) (activeCardIndex state) state.sliderTranslateX)
           *> (cardSliderTransition state.sliderTransition)
       ]
       ⊕ (guard (not visible) $> (HP.class_ CSS.invisible)))
      ( List.fromList (map (renderCard $ List.length state.cards + 1) state.cards)
        ⊕ (pure $ newCardMenu (List.length state.cards + 1) state))


  renderCard cardsCount cardDef =
    HH.div
    ([ HP.key ("card" ⊕ cardIdToString cardDef.id)
     , HP.classes [ CSS.card ]
     , style $ cardWidth cardsCount
    ]
     ⊕ foldMap (viewingStyle cardDef) state.viewingCard)
    [ cardGripper
    , HH.Slot $ transformCardConstructor cardDef.ctor
    ]

  cardGripper =
    HH.div
      [ HP.classes [ CSS.cardGripper ]
      , HE.onMouseDown \e -> HEH.preventDefault $> H.action (StartSliding e)
      ]
      []

  transformCardConstructor (H.SlotConstructor p l) =
    H.SlotConstructor
      (injSlot cpCard p)
      (l <#> \def →
        { component: H.transformChild cpCard def.component
        , initialState: injState cpCard def.initialState
        }
      )

  viewingStyle cardDef cid =
    guard (not (cardDef.id ≡ cid))
    $> (HP.class_ CSS.invisible)

  shouldHideNextAction =
    isJust state.viewingCard ∨ state.accessType ≡ ReadOnly

  newCardMenu cardsCount state =
    HH.div
      ([ HP.key ("next-action-card")
       , HP.classes [ CSS.card ]
       , HP.ref (H.action <<< SetNextActionCardElement)
       , style $ cardWidth cardsCount
       ]
       ⊕ (guard shouldHideNextAction $> (HP.class_ CSS.invisible)))

    [ cardGripper
    , HH.slot' cpCard (CardSlot top) \_ →
       { component: Next.nextCardComponent
       , initialState: H.parentState initialCardState
       }
    ]

  cardWidthPct cardsCount =
    100.0 / toNumber cardsCount

  cardWidth cardsCount =
    width $ calc $ (show $ cardWidthPct cardsCount) ++ "% - 1.5rem"

  cardSliderWidth cardsCount =
    width $ pct $ 100.0 * toNumber cardsCount

  cardSliderTransform cardCount activeCardIndex translateX =
    transform $ translate (cardSliderTranslateX cardCount activeCardIndex translateX) nil

  cardSliderTransition false = transition "none"
  cardSliderTransition true = transition "all 0.33s"

  cardSliderTranslateX cardCount activeCardIndex translateX =
    calc
      $ "(((-100% / " ++ show cardCount ++ ") + 1.5rem)"
      ++ " * " ++ show activeCardIndex ++ ")"
      ++ " + (" ++ show translateX ++ "px)"

  calc s = Size $ fromString $ "calc(" ++ s ++ ")"

eval ∷ Natural Query NotebookDSL
eval (AddCard cardType next) = createCard cardType $> next
eval (RunActiveCard next) = do
  (maybe (pure unit) runCard =<< H.gets (_.activeCardId)) $> next
eval (LoadNotebook fs dir deckId next) = do
  state ← H.get
  H.modify (DCS._stateMode .~ DCS.Loading)
  json ← Quasar.load $ deckIndex dir deckId
  case Model.decode =<< json of
    Left err → do
      H.fromAff $ log err
      H.modify $ DCS._stateMode .~ DCS.Error "There was a problem decoding the saved notebook"
    Right model →
      case DCS.fromModel fs (Just dir) (Just deckId) model of
        Tuple cards st → do
          H.set st
          forceRerender'
          ranCards ← catMaybes <$> for cards \card → do
            H.query' cpCard  (CardSlot card.cardId)
              $ left
              $ H.action
              $ LoadCard card
            pure if card.hasRun then Just card.cardId else Nothing
          -- We only need to run the root node in each subgraph, as doing so
          -- will result in all child nodes being run also as the outputs
          -- propagate down each subgraph.
          traverse_ runCard $ nub $ flip DCS.findRoot st <$> ranCards
          H.modify $ DCS._stateMode .~ DCS.Ready
  updateNextActionCard
  forceRerender'
  pure next

eval (ExploreFile fs res next) = do
  H.set $ DCS.initialDeck fs
  H.modify
    $ (DCS._path .~ Pathy.parentDir res)
    ∘ (DCS.addCard OpenResource Nothing)
  forceRerender'
  H.query' cpCard (CardSlot zero)
    $ right
    $ H.ChildF unit
    $ right
    $ OpenResourceQuery
    $ right
    $ H.action
    $ Open.ResourceSelected
    $ R.File res
  forceRerender'
  runCard zero
  -- Flush the eval queue
  saveNotebook
  updateNextActionCard
  pure next
eval (Publish next) = do
  H.gets DCS.deckPath >>= \mpath →
    for_ mpath $ H.fromEff ∘ newTab ∘ flip mkNotebookURL (NA.Load ReadOnly)
  pure next
eval (Reset fs dir deckId next) = do
  let nb = DCS.initialDeck fs
  H.set $ nb { id = deckId, path = Just dir }
  pure next
eval (SetName name next) =
  H.modify (DCS._name .~ Just name) $> next
eval (SetAccessType aType next) = do
  cids ← map Map.keys $ H.gets _.cardTypes
  for_ cids \cardId →
    void
      $ H.query' cpCard (CardSlot cardId)
      $ left
      $ H.action
      $ SetCardAccessType aType
  H.modify $ DCS._accessType .~ aType
  unless (isEditable aType)
    $ H.modify (DCS._backsided .~ false)
  pure next
eval (GetNotebookPath k) = k <$> H.gets DCS.deckPath
eval (SetViewingCard mbcid next) = H.modify (DCS._viewingCard .~ mbcid) $> next
eval (SaveNotebook next) = saveNotebook $> next
eval (RunPendingCards next) = do
  -- Only run pending cards if we have a deckPath. Some cards run with the
  -- assumption that the deck is saved to disk.
  H.gets DCS.deckPath >>= traverse_ \_ → runPendingCards
  pure next
eval (GetGlobalVarMap k) = k <$> H.gets _.globalVarMap
eval (SetGlobalVarMap m next) = do
  st ← H.get
  when (m ≠ st.globalVarMap) do
    H.modify $ DCS._globalVarMap .~ m
    traverse_ runCard $ DCS.cardsOfType API st
  pure next
eval (FindCardParent cid k) = k <$> H.gets (DCS.findParent cid)
eval (GetCardType cid k) = k <$> H.gets (DCS.getCardType cid)
eval (FlipDeck next) = H.modify (DCS._backsided %~ not) $> next
eval (GetActiveCardId k) = map k $ H.gets DCS.findLast
eval (StartSliding mouseEvent next) =
  setInitialSliderX (Just mouseEvent.screenX) $> next
  where
  setInitialSliderX =
    H.modify <<< (DCS._initialSliderX .~)
eval (StopSlidingAndSnap mouseEvent next) =
  startTransition *> snap *> stopSliding $> next
  where
  stopSliding =
    setInitialX Nothing *> setTranslateX 0.0
  setInitialX =
    H.modify <<< (DCS._initialSliderX .~)
  getBoundingClientWidth =
    fromEff <<< map _.width <<< getBoundingClientRect
  getNextActionCardElement =
    H.gets _.nextActionCardElement
  getCardWidth =
    traverse getBoundingClientWidth
      =<< getNextActionCardElement
  setActiveCardId =
    H.modify <<< (DCS._activeCardId .~)
  setTranslateX =
    H.modify <<< (DCS._sliderTranslateX .~)
  snapActiveCardIndex translateX (Just cardWidth) | translateX < (-(cardWidth / 2.0)) =
    add 1
  snapActiveCardIndex translateX (Just cardWidth) | translateX > (cardWidth / 2.0) =
    max 0 <<< flip sub 1
  snapActiveCardIndex translateX _ =
    id
  getCardIdByIndex cards =
    map _.id <<< List.index cards
  snapActiveCardId st cardWidth =
    getCardIdByIndex st.cards
      $ snapActiveCardIndex st.sliderTranslateX cardWidth
      $ activeCardIndex st
  snap =
    setActiveCardId =<< (snapActiveCardId <$> H.get <*> getCardWidth)
  setSliderTransition =
    H.modify <<< (DCS._sliderTransition .~)
  startTransition =
    setSliderTransition true
eval (UpdateSliderPosition mouseEvent next) =
  (maybe (pure unit) (setTranslateX <<< translateXCalc) =<< getInitialX) $> next
  where
  getInitialX =
    H.gets _.initialSliderX
  translateXCalc initialX =
    mouseEvent.screenX - initialX
  setTranslateX =
    H.modify <<< (DCS._sliderTranslateX .~)
eval (SetNextActionCardElement element next) =
  setNextActionCardElement element $> next
  where
  setNextActionCardElement =
    H.modify <<< (DCS._nextActionCardElement .~)
eval (StopSliderTransition next) =
  setSliderTransition false $> next
  where
  setSliderTransition =
    H.modify <<< (DCS._sliderTransition .~)

peek ∷ ∀ a. H.ChildF ChildSlot ChildQuery a → NotebookDSL Unit
peek (H.ChildF s q) =
  coproduct
    (either peekCards (\_ _ → pure unit) s)
    peekBackSide
    q

peekBackSide ∷ ∀ a. Back.Query a → NotebookDSL Unit
peekBackSide (Back.UpdateFilter _ _) = pure unit
peekBackSide (Back.DoAction action _) = case action of
  Back.Trash → do
    activeId ← H.gets _.activeCardId
    lastId ← H.gets DCS.findLast
    for_ (activeId <|> lastId) \trashId → do
      descendants ← H.gets $ DCS.findDescendants trashId
      H.modify ∘ DCS.removeCards $ S.insert trashId descendants
      triggerSave
      updateNextActionCard
      H.modify $ DCS._backsided .~ false
  Back.Share → pure unit
  Back.Embed → pure unit
  Back.Publish →
    H.gets DCS.deckPath >>= \mpath →
      for_ mpath $ H.fromEff ∘ newTab ∘ flip mkNotebookURL (NA.Load ReadOnly)
  Back.Mirror → pure unit
  Back.Wrap → pure unit

peekCards ∷ ∀ a. CardSlot → CardQueryP a → NotebookDSL Unit
peekCards (CardSlot cardId) q =
  coproduct (peekCard cardId) (peekCardInner cardId) q


-- | Peek on the card component to observe actions from the card control
-- | buttons.
peekCard ∷ ∀ a. CardId → CardQuery a → NotebookDSL Unit
peekCard cardId q = case q of
  RunCard _ → runCard cardId
  RefreshCard _ → runCard ∘ DCS.findRoot cardId =<< H.get
  TrashCard _ → do
    descendants ← H.gets $ DCS.findDescendants cardId
    H.modify ∘ DCS.removeCards $ S.insert cardId descendants
    triggerSave
    updateNextActionCard
  ToggleCaching _ →
    triggerSave
  ShareCard _ → pure unit
  StopCard _ → do
    H.modify $ DCS._runTrigger .~ Nothing
    H.modify $ DCS._pendingCards %~ S.delete cardId
    runPendingCards
  _ → pure unit


updateNextActionCard ∷ NotebookDSL Unit
updateNextActionCard = do
  cid ← H.gets DCS.findLast
  mbMessage ← case cid of
    Just cardId → do
      out ←
        map join
          $ H.query' cpCard (CardSlot cardId)
          $ left (H.request GetOutput)
      pure $ case out of
        Nothing →
          Just "Next actions will be made available once the last card has been run"
        Just Blocked →
          Just "There are no available next actions"
        Just (CardError _) →
          Just "There are no available next actions (parent cards have errors)"
        _ → Nothing
    Nothing → pure Nothing
  queryNextActionCard
    $ H.action
    $ Next.SetMessage mbMessage

  lastCardType ← H.gets DCS.findLastCardType
  queryNextActionCard
    $ H.action
    $ Next.SetAvailableTypes
    $ nextCardTypes lastCardType
  pure unit
  where
  queryNextActionCard q =
    H.query' cpCard (CardSlot top)
      $ right
      $ H.ChildF unit
      $ right
      $ NextQuery
      $ right q


createCard ∷ CardType → NotebookDSL Unit
createCard cardType = do
  cid ← H.gets DCS.findLast
  s ← H.get
  case cid of
    Nothing →
      H.modify $ DCS.addCard cardType Nothing
    Just cardId → do
      Tuple st newCardId ← H.gets $ DCS.addCard' cardType (Just cardId)
      H.set st
      forceRerender'
      input ←
        map join $ H.query' cpCard (CardSlot cardId) $ left (H.request GetOutput)

      for_ input \input' → do
        path ← H.gets DCS.deckPath
        let setupInfo = { notebookPath: path, inputPort: input', cardId: newCardId }
        void
          $ H.query' cpCard  (CardSlot newCardId)
          $ right
          $ H.ChildF unit
          $ left
          $ H.action (SetupCard setupInfo)
      runCard newCardId
  updateNextActionCard
  triggerSave

-- | Peek on the inner card components to observe `NotifyRunCard`, which is
-- | raised by actions within a card that should cause the card to run.
peekCardInner
  ∷ ∀ a. CardId → H.ChildF Unit InnerCardQuery a → NotebookDSL Unit
peekCardInner cardId (H.ChildF _ q) =
  coproduct (peekEvalCard cardId) (peekAnyCard cardId) q

peekEvalCard ∷ ∀ a. CardId → CardEvalQuery a → NotebookDSL Unit
peekEvalCard cardId (NotifyRunCard _) = runCard cardId
peekEvalCard _ _ = pure unit

peekAnyCard ∷ ∀ a. CardId → AnyCardQuery a → NotebookDSL Unit
peekAnyCard cardId q = do
  for_ (q ^? _NextQuery ∘ _Right ∘ Next._AddCardType) createCard
  when (queryShouldRun q) $ runCard cardId
  when (queryShouldSave q) triggerSave
  pure unit

queryShouldRun ∷ ∀ a. AnyCardQuery a → Boolean
queryShouldRun (SaveQuery q) = false
queryShouldRun _ = true

queryShouldSave  ∷ ∀ a. AnyCardQuery a → Boolean
queryShouldSave (AceQuery q) =
  coproduct evalQueryShouldSave aceQueryShouldSave q
queryShouldSave _ = true

evalQueryShouldSave ∷ ∀ a. CardEvalQuery a → Boolean
evalQueryShouldSave _ = true

aceQueryShouldSave
  ∷ ∀ p a. H.ChildF p Ace.AceQuery a → Boolean
aceQueryShouldSave (H.ChildF _ q) =
  case q of
    Ace.TextChanged _ → true
    _ → false


-- | Runs all card that are present in the set of pending cards.
runPendingCards ∷ NotebookDSL Unit
runPendingCards = do
  cards ← H.gets _.pendingCards
  traverse_ runCard' cards
  updateNextActionCard
  where
  runCard' ∷ CardId → NotebookDSL Unit
  runCard' cardId = do
    mbParentId ← H.gets $ DCS.findParent cardId
    case mbParentId of
      -- if there's no parent there's no input port value to pass through
      Nothing → updateCard Nothing cardId
      Just parentId → do
        value ←
          map join $ H.query' cpCard (CardSlot parentId) $ left (H.request GetOutput)
        case value of
          -- if there's a parent but no output the parent card hasn't been evaluated
          -- yet, so we can't run this card either
          Nothing → pure unit
          -- if there's a parent and an output, pass it on as this card's input
          Just p → updateCard (Just p) cardId
    H.modify $ DCS._pendingCards %~ S.delete cardId
    triggerSave

-- | Enqueues the card with the specified ID in the set of cards that are
-- | pending to run and enqueues a debounced H.query to trigger the cards to
-- | actually run.
runCard ∷ CardId → NotebookDSL Unit
runCard cardId = do
  H.modify (DCS.addPendingCard cardId)
  fireDebouncedQuery' (Milliseconds 500.0) DCS._runTrigger RunPendingCards

-- | Updates the evaluated value for a card by running it with the specified
-- | input and then runs any cards that depend on the card's output with the
-- | new result.
updateCard ∷ Maybe Port → CardId → NotebookDSL Unit
updateCard inputPort cardId = do
  path ← H.gets DCS.deckPath
  globalVarMap ← H.gets _.globalVarMap
  let input = { notebookPath: path, inputPort, cardId, globalVarMap }
  result ←
    map join
      $ H.query' cpCard (CardSlot cardId)
      $ left
      $ H.request (UpdateCard input)

  H.modify ∘ Lens.over DCS._failingCards $
    case result of
      Just (CardError msg) → S.insert cardId
      _ → S.delete cardId
  forceRerender'

  runCardDescendants cardId (fromMaybe Blocked result)
  where
  runCardDescendants ∷ CardId → Port → NotebookDSL Unit
  runCardDescendants parentId value = do
    -- Crucially, we run the card descendents according to the virtual graph;
    -- this enables the correct behavior of virtual cards, including the Error Card.
    children ← H.gets $ DCS.findChildren parentId ∘ DCS.virtualState
    traverse_ (updateCard (Just value)) children

-- | Triggers the H.query for autosave. This does not immediate perform the save
-- | H.action, but instead enqueues a debounced H.query to trigger the actual save.
triggerSave ∷ NotebookDSL Unit
triggerSave =
  fireDebouncedQuery' (Milliseconds 500.0) DCS._saveTrigger SaveNotebook

-- | Saves the notebook as JSON, using the current values present in the state.
saveNotebook ∷ NotebookDSL Unit
saveNotebook = H.get >>= \st → do
  if isUnsaved st ∧ isNewExploreNotebook st
    -- If its an unsaved Explore notebook, it is safe to go ahead and run it.
    then runPendingCards
    else do
      cards ← catMaybes <$> for (List.fromList st.cards) \card →
        H.query' cpCard (CardSlot card.id)
          $ left
          $ H.request (SaveCard card.id card.ty)

      let json = Model.encode { name: st.name, cards, dependencies: st.dependencies }

      for_ st.path \path → do
        deckId ← runExceptT do
          i ← ExceptT $ genId path st.id
          ExceptT $ save path i json
          pure i

        case deckId of
          Left err → do
            -- TODO: do something to notify the user saving failed
            pure unit
          Right deckId' → do
            H.modify $ DCS._id .~ Just deckId'

            -- runPendingCards would be deffered if there had previously been
            -- no `deckPath`. We need to flush the queue.
            when (isNothing $ DCS.deckPath st) runPendingCards

            -- We need to get the modified version of the notebook state.
            H.gets DCS.deckPath >>= traverse_ \path' →
              let notebookHash =
                    case st.viewingCard of
                      Nothing →
                        mkNotebookHash path' (NA.Load st.accessType) st.globalVarMap
                      Just cid →
                        mkNotebookCardHash path' cid st.accessType st.globalVarMap
              in H.fromEff $ locationObject >>= Location.setHash notebookHash

  where

  isUnsaved ∷ DCS.State → Boolean
  isUnsaved = isNothing ∘ DCS.deckPath

  isNewExploreNotebook ∷ DCS.State → Boolean
  isNewExploreNotebook { cards } =
    let
      cardArrays = List.toUnfoldable (map _.ty cards)
    in
      cardArrays ≡ [ OpenResource ] ∨ cardArrays ≡ [ OpenResource, JTable ]

  -- Finds a new name for a notebook in the specified parent directory, using
  -- a name value as a basis to start with.
  getNewName' ∷ DirPath → String → NotebookDSL (Either Exn.Error Pathy.DirName)
  getNewName' dir name =
    let baseName = name ⊕ "." ⊕ Config.notebookExtension
    in map Pathy.DirName <$> Quasar.getNewName dir baseName

  genId ∷ DirPath → Maybe DeckId → NotebookDSL (Either Exn.Error DeckId)
  genId path deckId = case deckId of
    Just id' → pure $ Right id'
    Nothing → map DeckId <$> NB.fresh (path </> Pathy.file "index")

  -- Saves a notebook and returns the name it was saved as.
  save ∷ DirPath → DeckId → Json → NotebookDSL (Either Exn.Error Unit)
  save dir deckId json = Quasar.save (deckIndex dir deckId) json

  -- Renames a notebook and returns the new name it was changed to.
  rename
    ∷ DirPath
    → Pathy.DirName
    → String
    → NotebookDSL (Either Exn.Error Pathy.DirName)
  rename dir oldName newName = runExceptT do
    newName' ← ExceptT $ getNewName' dir newName
    let oldPath = dir </> Pathy.dir' oldName
        newPath = dir </> Pathy.dir' newName'
    ExceptT $ Quasar.move (R.Directory oldPath) (Left newPath)
    pure newName'

-- | Takes a `DirName` for a saved notebook and returns the name part without
-- | the `.slam` extension.
nameFromDirName ∷ Pathy.DirName → String
nameFromDirName dirName =
  let name = Pathy.runDirName dirName
  in Str.take (Str.length name - Str.length Config.notebookExtension - 1) name

deckIndex ∷ DirPath → DeckId → FilePath
deckIndex path deckId = path </> Pathy.dir (deckIdToString deckId) </> Pathy.file "index"
