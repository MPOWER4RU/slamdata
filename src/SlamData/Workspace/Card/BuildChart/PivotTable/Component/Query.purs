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

module SlamData.Workspace.Card.BuildChart.PivotTable.Component.Query
  ( Query(..)
  , QueryC
  , QueryP
  ) where

import SlamData.Prelude

import Halogen as H
import Halogen.Component.Utils.Drag (DragEvent)
import Halogen.HTML.Events.Types as HET

import SlamData.Workspace.Card.BuildChart.Aggregation as Ag
import SlamData.Workspace.Card.BuildChart.PivotTable.Component.ChildSlot (ChildQuery, ChildSlot)
import SlamData.Workspace.Card.Common.EvalQuery (CardEvalQuery)

data Query a
  = AddDimension a
  | RemoveDimension Int a
  | AddColumn a
  | RemoveColumn Int a
  | OrderDimensionStart Int (HET.Event HET.MouseEvent) a
  | OrderingDimension Int DragEvent a
  | OrderOverDimension Int a
  | OrderOutDimension Int a
  | OrderColumnStart Int (HET.Event HET.MouseEvent) a
  | OrderingColumn Int DragEvent a
  | OrderOverColumn Int a
  | OrderOutColumn Int a
  | ChooseAggregation Int (Maybe Ag.Aggregation) a

type QueryC = CardEvalQuery ⨁ Query

type QueryP = QueryC ⨁ H.ChildF ChildSlot ChildQuery
