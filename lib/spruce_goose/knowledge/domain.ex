defmodule SpruceGoose.Knowledge.Domain do
  use Ash.Domain

  resources do
    resource(SpruceGoose.Knowledge.Generation)
    resource(SpruceGoose.Knowledge.Node)
    resource(SpruceGoose.Knowledge.Relation)
  end
end
