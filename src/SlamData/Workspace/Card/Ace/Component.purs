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

module SlamData.Workspace.Card.Ace.Component
  ( aceComponent
  , DSL
  , HTML
  , AceEval
  , module SlamData.Workspace.Card.Ace.Component.Query
  , module SlamData.Workspace.Card.Ace.Component.State
  ) where

import SlamData.Prelude

import Ace.Editor as Editor
import Ace.EditSession as Session
import Ace.Halogen.Component as AC
import Ace.Types (Editor)

import Control.Monad.Aff.AVar (makeVar, takeVar)
import Control.Monad.Aff.EventLoop as EventLoop

import Data.Lens ((.~))

import Halogen as H
import Halogen.HTML.Indexed as HH
import Halogen.HTML.Events.Indexed as HE
import Halogen.HTML.Properties.Indexed as HP
import Halogen.HTML.Properties.Indexed.ARIA as ARIA
import Halogen.Themes.Bootstrap3 as B
import Halogen.Component.Utils (subscribeToASource')

import SlamData.Monad (Slam)
import SlamData.Notification as N
import SlamData.Render.Common (glyph)
import SlamData.Render.CSS as CSS
import SlamData.Workspace.Card.Ace.Component.Query (Query(..), QueryP)
import SlamData.Workspace.Card.Ace.Component.State (State, StateP, Status(..), initialState, _levelOfDetails, _status, isNew, isLoading, isReady)
import SlamData.Workspace.Card.CardType as CT
import SlamData.Workspace.Card.Common.Render (renderLowLOD)
import SlamData.Workspace.Card.Component as CC
import SlamData.Workspace.Card.Model as Card
import SlamData.Workspace.LevelOfDetails (LevelOfDetails(..))

import Utils.Ace (getRangeRecs, readOnly)

type DSL = H.ParentDSL State AC.AceState (CC.CardEvalQuery ⨁ Query) AC.AceQuery Slam Unit
type HTML = H.ParentHTML AC.AceState (CC.CardEvalQuery ⨁ Query) AC.AceQuery Slam Unit
type AceEval = CC.CardEvalInput → DSL Unit

type AceConfig =
  { mode ∷ CT.AceMode
  , eval ∷ AceEval
  }

aceComponent ∷ AceConfig → H.Component CC.CardStateP CC.CardQueryP Slam
aceComponent cfg = CC.makeCardComponent
  { cardType: CT.Ace cfg.mode
  , component: H.lifecycleParentComponent
      { render: render cfg
      , eval: eval cfg
      , peek: Just (peek ∘ H.runChildF)
      , initializer: Just $ right $ H.action Init
      , finalizer: Just $ right $ H.action Finalize
      }
  , initialState: H.parentState initialState
  , _State: CC._AceState
  , _Query: CC.makeQueryPrism' CC._AceQuery
  }

eval ∷ AceConfig → (CC.CardEvalQuery ⨁ Query) ~> DSL
eval cfg = cardEval cfg ⨁ evalComponent

evalComponent :: Query ~> DSL
evalComponent = case _ of
  Init next → do
    trigger ← H.fromAff $ makeVar
    breaker ← subscribeToASource'
      (const $ right $ H.action RunFromNotification)
      (takeVar trigger)
    H.modify (_ { trigger = Just trigger, breaker = Just breaker })
    pure next
  RunFromNotification next → do
    CC.raiseUpdatedP' CC.EvalModelUpdate
    pure next
  Finalize next → do
    breaker ← H.gets _.breaker
    H.fromAff $ for_ breaker EventLoop.break'
    pure next

cardEval ∷ AceConfig → CC.CardEvalQuery ~> DSL
cardEval cfg = case _ of
  CC.EvalCard info output next → do
    cfg.eval info
    pure next
  CC.Activate next → do
    mbEditor ← H.query unit $ H.request AC.GetEditor
    for_ (join mbEditor) $ H.fromEff ∘ Editor.focus
    pure next
  CC.Deactivate next → do
    st ← H.get
    for_ st.trigger \trigger →
      when st.dirty do
        N.info "Don't forget to run your query to see the latest result."
          Nothing
          Nothing
          (Just $ N.ActionOptions
            { messagePrefix: ""
            , actionMessage: "Run query now"
            , messageSuffix: ""
            , action: N.Fulfill trigger
            })
    pure next
  CC.Save k → do
    status ← H.gets _.status
    content ← fromMaybe "" <$> H.query unit (H.request AC.GetText)
    mbEditor ← H.query unit (H.request AC.GetEditor)
    rrs ← H.fromEff $ maybe (pure []) getRangeRecs $ join mbEditor
    pure ∘ k
      $ Card.Ace cfg.mode
      $ if isNew status
        then Nothing
        else Just { text: content, ranges: rrs }
  CC.Load card next → do
    case card of
      Card.Ace _ (Just { text, ranges }) → do
        -- We don't want the Ace component to trigger a TextChanged event when we
        -- initially set the text, so we use this nasty state to filter it out.
        H.modify $ _status .~ Loading
        H.query unit $ H.action $ AC.SetText text
        H.modify $ _status .~ Ready
        mbEditor ← H.query unit $ H.request AC.GetEditor
        H.fromEff $ for_ (join mbEditor) \editor → do
          traverse_ (readOnly editor) ranges
          Editor.navigateFileEnd editor
      Card.Ace CT.MarkdownMode Nothing →
        H.modify $ _status .~ Ready
      _ → pure unit
    H.modify _ { dirty = false }
    pure next
  CC.SetDimensions dims next → do
    H.modify
      $ _levelOfDetails
      .~ if dims.width < 240.0 then Low else High
    mbEditor ← H.query unit $ H.request AC.GetEditor
    for_ (join mbEditor) $ H.fromEff ∘ Editor.resize Nothing
    pure next
  CC.ModelUpdated _ next → do
    H.modify _ { dirty = false }
    pure next
  CC.ZoomIn next →
    pure next

peek ∷ ∀ x. AC.AceQuery x → DSL Unit
peek = case _ of
  AC.TextChanged _ → H.modify _ { dirty = true }
  _ → pure unit

aceSetup ∷ AceConfig → Editor → Slam Unit
aceSetup cfg editor = H.fromEff do
  Editor.setTheme "ace/theme/chrome" editor
  Editor.setEnableLiveAutocompletion true editor
  Editor.setEnableBasicAutocompletion true editor
  Session.setMode (CT.aceMode cfg.mode) =<< Editor.getSession editor

render ∷ AceConfig → State → HTML
render cfg state =
  HH.div_
    [ renderHighLOD cfg state
    , renderLowLOD (CT.lightCardGlyph $ CT.Ace cfg.mode) left state.levelOfDetails
    ]

renderHighLOD ∷ AceConfig → State → HTML
renderHighLOD cfg state =
  HH.div
    [ HP.classes
        $ [ CSS.cardInput, CSS.aceContainer ]
        ⊕ (guard (state.levelOfDetails ≠ High) $> B.hidden)
    ]
    [ HH.div [ HP.class_ (HH.className "sd-ace-inset-shadow") ] []
    , HH.div
        [ HP.class_ (HH.className "sd-ace-toolbar") ]
        [ HH.button
            [ HP.class_ (HH.className "sd-ace-run")
            , HP.disabled (not state.dirty)
            , HP.title "Run Query"
            , ARIA.label "Run query"
            , HE.onClick (HE.input_ (left <<< CC.ModelUpdated CC.EvalModelUpdate))
            ]
            [ glyph B.glyphiconPlay
            , HH.text "Run Query"
            ]
        ]
    , HH.slot unit \_ →
        { component: AC.aceComponent (aceSetup cfg) (Just AC.Live)
        , initialState: AC.initialAceState
        }
    ]
