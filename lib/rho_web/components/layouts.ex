defmodule RhoWeb.Layouts do
  use Phoenix.Component

  import Plug.CSRFProtection, only: [get_csrf_token: 0]
  import RhoWeb.CoreComponents

  embed_templates "layouts/*"
end
