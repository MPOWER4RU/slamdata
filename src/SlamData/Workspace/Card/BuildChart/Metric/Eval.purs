module SlamData.Workspace.Card.BuildChart.Metric.Eval
  ( eval
  , module SlamData.Workspace.Card.BuildChart.Metric.Model
  ) where

import SlamData.Prelude

import Data.Argonaut (JArray, Json)
import Data.Array as A
import Data.Formatter.Number as FN
import Data.String as Str
import Data.String.Regex as Rgx
import Data.Lens ((^?))

import Quasar.Types (FilePath)

import SlamData.Quasar.Class (class QuasarDSL)
import SlamData.Quasar.Error as QE
import SlamData.Workspace.Card.BuildChart.Common.Eval as BCE
import SlamData.Workspace.Card.Eval.CardEvalT as CET
import SlamData.Workspace.Card.Port as Port
import SlamData.Workspace.Card.BuildChart.Metric.Model (Model, MetricR)
import SlamData.Workspace.Card.BuildChart.Semantics (getValues)
import SlamData.Workspace.Card.BuildChart.Aggregation as Ag

eval
  ∷ ∀ m
  . (Monad m, QuasarDSL m)
  ⇒ Model
  → FilePath
  → CET.CardEvalT m Port.Port
eval Nothing _  =
  QE.throw "Please select axis to aggregate"
eval (Just conf) resource = do
  records ← BCE.records resource
  pure $ Port.Metric $ buildMetric conf records


buildMetric ∷ MetricR → JArray → Port.MetricPort
buildMetric r records =
  { value, label: r.label }
  where
  formatterRegex ∷ Rgx.Regex
  formatterRegex =
    unsafePartial fromRight $ Rgx.regex "{{[^}]+}}" Rgx.noFlags

  value ∷ String
  value = fromMaybe (show metricValue) do
    input ← r.formatter
    matches ← Rgx.match formatterRegex input
    firstMatch ← join $ A.head matches
    woPrefix ← Str.stripPrefix "{{" firstMatch
    formatString ← Str.stripSuffix "}}" woPrefix
    formatter ← either (const Nothing) Just $ FN.parseFormatString formatString
    let
      formattedNumber = FN.format formatter metricValue

    pure $ Rgx.replace formatterRegex formattedNumber input

  metricValue ∷ Number
  metricValue =
    Ag.runAggregation r.valueAggregation $ foldMap foldFn records

  foldFn ∷ Json → Array Number
  foldFn js =
    getValues js $ pure r.value
