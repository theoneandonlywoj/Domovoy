defmodule Domovoy.ComposerFixtures.UnloadedProbe do
  @moduledoc """
  A module nothing references. The hostile tests purge it, name it in an edit, and
  check that it was refused without being loaded.
  """
end
