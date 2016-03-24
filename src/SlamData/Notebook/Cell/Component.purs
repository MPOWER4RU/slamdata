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

module SlamData.Notebook.Cell.Component
  ( CellComponent
  , makeEditorCellComponent
  , makeResultsCellComponent
  , makeSingularCellComponent
  , module SlamData.Notebook.Cell.Component.Def
  , module SlamData.Notebook.Cell.Component.Query
  , module SlamData.Notebook.Cell.Component.State
  ) where

import SlamData.Prelude

import Control.Coroutine.Aff (produce)
import Control.Coroutine.Stalling (producerToStallingProducer)
import Control.Monad.Eff.Ref (newRef, readRef, writeRef)
import Control.Monad.Free (liftF)
import Control.Monad.Aff (cancel)
import Control.Monad.Eff.Exception as Exn

import Data.Argonaut (jsonNull)
import Data.Date as Date
import Data.Function (on)
import Data.Lens (PrismP, review, preview, clonePrism, (.~), (%~))
import Data.Path.Pathy as Path
import Data.Visibility (Visibility(..), toggleVisibility)

import DOM.Timer (interval, clearInterval)

import Halogen as H
import Halogen.HTML.Indexed as HH
import Halogen.HTML.Properties.Indexed as HP
import Halogen.HTML.Properties.Indexed.ARIA as ARIA
import Halogen.Query.EventSource (EventSource(..))
import Halogen.Query.HalogenF (HalogenFP(..))
import Halogen.Themes.Bootstrap3 as B

import SlamData.Effects (Slam)
import SlamData.FileSystem.Resource (_filePath)
import SlamData.Notebook.AccessType (AccessType(..))
import SlamData.Notebook.Cell.CellType (CellType(..), AceMode(..), cellGlyph, cellName)
import SlamData.Notebook.Cell.Common.EvalQuery (prepareCellEvalInput)
import SlamData.Notebook.Cell.Component.Def (CellDefProps, EditorCellDef, ResultsCellDef, makeQueryPrism, makeQueryPrism')
import SlamData.Notebook.Cell.Component.Query (CellEvalInputPre, CellQueryP, InnerCellQuery, AnyCellQuery(..), CellEvalQuery(..), CellQuery(..), _APIQuery, _APIResultsQuery, _AceQuery, _AnyCellQuery, _CellEvalQuery, _ChartQuery, _DownloadQuery, _ExploreQuery, _JTableQuery, _MarkdownQuery, _SearchQuery, _VizQuery, _NextQuery)
import SlamData.Notebook.Cell.Component.Render (CellHTML, header, statusBar)
import SlamData.Notebook.Cell.Component.State (AnyCellState, CellState, CellStateP, _APIResultsState, _APIState, _AceState, _ChartState, _DownloadState, _ExploreState, _JTableState, _MarkdownState, _SearchState, _VizState, _NextState, _accessType, _cachingEnabled, _canceler, _hasResults, _input, _isCollapsed, _messageVisibility, _messages, _output, _runState, _tickStopper, _visibility, initEditorCellState, initResultsCellState)
import SlamData.Notebook.Cell.Port (Port(..), _Resource)
import SlamData.Notebook.Cell.RunState (RunState(..))
import SlamData.Render.Common (row', fadeWhen, glyph)
import SlamData.Render.CSS as CSS

-- | Type synonym for the full type of a cell component.
type CellComponent = H.Component CellStateP CellQueryP Slam
type CellDSL = H.ParentDSL CellState AnyCellState CellQuery InnerCellQuery Slam Unit

-- | Constructs a cell component for an editor-style cell.
makeEditorCellComponent
  :: forall s f
   . EditorCellDef s f
  -> CellComponent
makeEditorCellComponent def = makeCellComponentPart def render
  where
  render
    :: H.Component AnyCellState InnerCellQuery Slam
    -> AnyCellState
    -> CellState
    -> CellHTML
  render =
    cellSourceRender
      def
      (\x -> x.accessType == ReadOnly)
      (\x -> [statusBar x.hasResults x])

-- | Sometimes we don't need editor or results and whole cell can be expressed
-- | as one cell part
makeSingularCellComponent
  :: forall s f
   . EditorCellDef s f
  -> CellComponent
makeSingularCellComponent def = makeCellComponentPart def render
  where
  render
    :: H.Component AnyCellState InnerCellQuery Slam
    -> AnyCellState
    -> CellState
    -> CellHTML
  render =
    cellSourceRender
      def
      (const false)
      (const [])

cellSourceRender
  :: forall s f
   . EditorCellDef s f
  -> (CellState -> Boolean)
  -> (CellState -> Array CellHTML)
  -> H.Component AnyCellState InnerCellQuery Slam
  -> AnyCellState
  -> CellState
  -> CellHTML
cellSourceRender def collapseWhen afterContent component initialState cs =
  if cs.visibility == Invisible
    then HH.text ""
    else shown
  where
  shouldCollapse =
    cs.isCollapsed || collapseWhen cs
  collapsedClass =
    guard shouldCollapse $> CSS.collapsed

  hideIfCollapsed =
    ARIA.hidden $ show shouldCollapse

  shown :: CellHTML
  shown =
    HH.div [ HP.classes $ join [ containerClasses, collapsedClass ] ]
    $ fold
        [
          guard cs.controllable $> header def cs
        , [ HH.div [ HP.classes ([B.row] ⊕ (fadeWhen shouldCollapse))
                   , hideIfCollapsed
                   ]
              [ HH.slot unit \_ -> {component, initialState} ]
          ]
        , afterContent cs
        ]

-- | Constructs a cell component for an results-style cell.
makeResultsCellComponent
  :: forall s f
   . ResultsCellDef s f
  -> CellComponent
makeResultsCellComponent def = makeCellComponentPart def render
  where
  render
    :: H.Component AnyCellState InnerCellQuery Slam
    -> AnyCellState
    -> CellState
    -> CellHTML
  render component initialState cs =
    if cs.visibility == Invisible
    then HH.text ""
    else
      HH.div
        [ HP.classes containerClasses ]
        [ row' [CSS.cellOutput]

            [ HH.div
                [ HP.class_ CSS.cellOutputLabel ]
                [ HH.text (resLabel cs.input)
                ]
            , HH.div
                [ HP.class_ CSS.cellOutputResult ]
                [ HH.slot unit \_ -> { component: component
                                    , initialState: initialState
                                    }
                ]
            ]
        ]

  resLabel :: Maybe Port -> String
  resLabel p =
    maybe "" (\p -> Path.runFileName (Path.fileName p) ++ " :=")
    $ preview (_Resource <<< _filePath) =<< p

containerClasses :: Array (HH.ClassName)
containerClasses = [B.containerFluid, CSS.notebookCell, B.clearfix]

-- | Constructs a cell component from a record with the necessary properties and
-- | a render function.
makeCellComponentPart
  :: forall s f r
   . Object (CellDefProps s f r)
  -> (  H.Component AnyCellState InnerCellQuery Slam
     -> AnyCellState
     -> CellState
     -> CellHTML
     )
  -> CellComponent
makeCellComponentPart def render =
  H.parentComponent
    { render: render component initialState
    , eval
    , peek: Just (peek <<< H.runChildF)
    }
  where

  _State :: PrismP AnyCellState s
  _State = clonePrism def._State

  _Query :: forall a. PrismP (InnerCellQuery a) (f a)
  _Query = clonePrism def._Query

  component :: H.Component AnyCellState InnerCellQuery Slam
  component =
    H.transform
      (review _State) (preview _State)
      (review _Query) (preview _Query)
      def.component

  initialState :: AnyCellState
  initialState = review _State def.initialState

  eval :: Natural CellQuery CellDSL
  eval (RunCell next) = pure next
  eval (StopCell next) = stopRun $> next
  eval (UpdateCell input k) = do
    H.fromAff =<< H.gets _.tickStopper
    tickStopper <- startInterval
    H.modify (_tickStopper .~ tickStopper)
    cachingEnabled <- H.gets _.cachingEnabled
    let input' = prepareCellEvalInput cachingEnabled input
    H.modify (_input .~ input'.inputPort)
    result <- H.query unit (left (H.request (EvalCell input')))
    for_ result \{ output } -> H.modify (_hasResults .~ isJust output)
    H.fromAff tickStopper
    H.modify
      $ (_runState %~ finishRun)
      <<< (_output .~ (_.output =<< result))
      <<< (_messages .~ (maybe [] _.messages result))
    maybe (liftF HaltHF) (pure <<< k <<< _.output) result
  eval (RefreshCell next) = pure next
  eval (TrashCell next) = pure next
  eval (ToggleCollapsed next) =
    H.modify (_isCollapsed %~ not) $> next
  eval (ToggleMessages next) =
    H.modify (_messageVisibility %~ toggleVisibility) $> next
  eval (ToggleCaching next) =
    H.modify (_cachingEnabled %~ not) $> next
  eval (ShareCell next) = pure next
  eval (Tick elapsed next) =
    H.modify (_runState .~ RunElapsed elapsed) $> next
  eval (GetOutput k) = k <$> H.gets (_.output)
  eval (SaveCell cellId cellType k) = do
    { hasResults, cachingEnabled } <- H.get
    json <- H.query unit (left (H.request Save))
    pure <<< k $
      { cellId
      , cellType
      , cachingEnabled
      , hasRun: hasResults
      , state: fromMaybe jsonNull json
      }
  eval (LoadCell model next) = do
    for_ model.cachingEnabled \b ->
      H.modify (_cachingEnabled .~ b)
    H.query unit (left (H.action (Load model.state)))
    pure next
  eval (SetCellAccessType at next) =
    H.modify (_accessType .~ at) $> next

  peek :: forall a. InnerCellQuery a -> CellDSL Unit
  peek = coproduct cellEvalPeek (const $ pure unit)

  cellEvalPeek :: forall a. CellEvalQuery a -> CellDSL Unit
  cellEvalPeek (SetCanceler canceler _) = H.modify $ _canceler .~ canceler
  cellEvalPeek (SetupCell _ _) = H.modify $ _canceler .~ mempty
  cellEvalPeek (EvalCell _ _) = H.modify $ _canceler .~ mempty
  cellEvalPeek _ = pure unit

  stopRun :: CellDSL Unit
  stopRun = do
    cs <- H.gets _.canceler
    ts <- H.gets _.tickStopper
    H.fromAff ts
    H.fromAff $ cancel cs (Exn.error "Canceled")
    H.modify $ _runState .~ RunInitial

-- | Starts a timer running on an interval that passes Tick queries back to the
-- | component, allowing the runState to be updated with a timer.
-- |
-- | The returned value is an action that will stop the timer running when
-- | processed.
startInterval :: CellDSL (Slam Unit)
startInterval = do
  ref <- H.fromEff (newRef Nothing)
  start <- H.fromEff Date.now
  H.modify (_runState .~ RunElapsed zero)

  H.subscribe' $ EventSource $ producerToStallingProducer $ produce \emit -> do
    i <- interval 1000 $ emit <<< Left <<< H.action <<< Tick =<< do
      now <- Date.now
      pure $ on (-) Date.toEpochMilliseconds now start
    writeRef ref (Just i)

  pure $ maybe (pure unit) (H.fromEff <<< clearInterval) =<< H.fromEff (readRef ref)

-- | Update the `RunState` from its current value to `RunFinished`.
finishRun :: RunState -> RunState
finishRun RunInitial = RunElapsed zero
finishRun (RunElapsed ms) = RunFinished ms
finishRun (RunFinished ms) = RunFinished ms
