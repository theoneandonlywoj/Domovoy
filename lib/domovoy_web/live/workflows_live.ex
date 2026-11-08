defmodule DomovoyWeb.WorkflowsLive do
  @moduledoc """
  Lists the saved drafts, creates one and deletes one. With runs on, each row's New run
  opens that draft with its launcher, and Runs leads to every run.
  """

  use DomovoyWeb, :live_view

  import DomovoyWeb.ComposerComponents, only: [plugin_status: 1]

  alias Domovoy.Catalog
  alias Domovoy.Composer

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Composer")
     |> assign(:plugins, Catalog.plugins())
     |> assign(:runs_enabled?, Composer.runs_enabled?())
     |> assign(:form, draft_form(""))
     |> stream(:drafts, Composer.list_drafts())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-8">
        <header class="flex flex-wrap items-end justify-between gap-4">
          <div class="space-y-1">
            <h1 class="text-2xl font-semibold tracking-tight">Workflow drafts</h1>
            <p class="text-sm text-muted">
              Compose definitions for Core 0.3.4.
            </p>
          </div>
          <.link
            :if={@runs_enabled?}
            id="runs-link"
            navigate={~p"/composer/runs"}
            class="soft-btn px-3 py-1.5 text-sm"
          >
            <.icon name="hero-queue-list" class="size-4" /> Runs
          </.link>
        </header>

        <.form for={@form} id="draft-form" phx-submit="create" class="flex items-start gap-2">
          <div class="flex-1">
            <.input field={@form[:title]} type="text" label="New draft title" required />
          </div>
          <button
            id="create-draft"
            type="submit"
            phx-disable-with="Creating…"
            class="soft-btn soft-btn-primary mt-7 px-3 py-2 text-sm"
          >
            Create
          </button>
        </.form>

        <ul id="drafts" phx-update="stream" class="space-y-3">
          <li id="drafts-empty" class="hidden py-6 text-sm text-muted only:block">
            No drafts yet.
          </li>
          <li
            :for={{id, draft} <- @streams.drafts}
            id={id}
            class="soft-row flex items-center justify-between gap-4 px-4 py-3"
          >
            <.link
              id={"open-#{draft.id}"}
              navigate={~p"/composer/#{draft.id}"}
              class="soft-link min-w-0 truncate font-medium"
            >
              {draft.title}
            </.link>
            <div class="flex shrink-0 items-center gap-2">
              <.link
                :if={@runs_enabled?}
                id={"new-run-#{draft.id}"}
                navigate={~p"/composer/#{draft.id}?#{[launch: 1]}"}
                class="soft-btn px-3 py-1.5 text-sm"
              >
                New run
              </.link>
              <button
                id={"delete-#{draft.id}"}
                type="button"
                phx-click="delete"
                phx-value-id={draft.id}
                data-confirm="Delete this draft?"
                aria-label={"Delete #{draft.title}"}
                class="soft-btn soft-btn-quiet p-1 hover:text-error"
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
            </div>
          </li>
        </ul>

        <section id="plugins" aria-label="Plugin status" class="space-y-2">
          <h2 class="text-sm font-semibold">Plugins</h2>
          <ul class="flex flex-wrap gap-2">
            <li :for={plugin <- @plugins}><.plugin_status plugin={plugin} /></li>
          </ul>
        </section>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("create", %{"draft" => %{"title" => title}}, socket) when is_binary(title) do
    case Composer.create_draft(%{title: title}) do
      {:ok, draft} ->
        {:noreply, push_navigate(socket, to: ~p"/composer/#{draft.id}")}

      {:error, changeset} ->
        shown = if Composer.text_safe?(title), do: title, else: ""
        {:noreply, assign(socket, :form, draft_form(shown, changeset.errors))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with {:ok, draft} <- Composer.get_draft(id),
         {:ok, deleted} <- Composer.delete_draft(draft) do
      {:noreply, stream_delete(socket, :drafts, deleted)}
    else
      {:error, :runs_unfinished} ->
        {:noreply,
         put_flash(socket, :error, "That draft has a run that isn't finished. Cancel it first.")}

      _gone ->
        {:noreply, stream(socket, :drafts, Composer.list_drafts(), reset: true)}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @spec draft_form(title :: String.t(), errors :: keyword()) :: Phoenix.HTML.Form.t()
  defp draft_form(title, errors \\ []) do
    to_form(%{"title" => title}, as: :draft, id: "draft", errors: errors)
  end
end
