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

module FileSystem.Dialog.Download.Query where

import FileSystem.Dialog.Download.State
import Model.Resource (Resource())

data Query a
  = SourceTyped String a
  | ToggleList a
  | SourceClicked Resource a
  | TargetTyped String a
  | ToggleCompress a
  | SetOutput OutputType a
  | Dismiss a
  | NewTab String a
  | ModifyCSVOpts (CSVOptions -> CSVOptions) a
  | ModifyJSONOpts (JSONOptions -> JSONOptions) a
  | AddSources (Array Resource) a
  | SetSources (Array Resource) a
