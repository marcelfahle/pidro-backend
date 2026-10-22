defmodule PidroServerWeb.Dev.GameSettingsLive do
  @moduledoc "Runtime game pacing controls for the ops panel."

  use PidroServerWeb, :live_view
  import PidroServerWeb.Dev.AdminComponents

  alias PidroServer.Games.PacingSettings

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, "Game Settings") |> assign_pacing_settings()}
  end

  @impl true
  def handle_event("update_pacing_form", %{"pacing" => params}, socket) do
    {:noreply, assign_pacing_settings(socket, PacingSettings.normalize_form(params))}
  end

  @impl true
  def handle_event("save_pacing", %{"pacing" => params}, socket) do
    case PacingSettings.validate(params) do
      {:ok, values} ->
        PacingSettings.save(values)

        {:noreply,
         socket
         |> assign_pacing_settings(PacingSettings.current_form())
         |> put_flash(:info, "Game pacing updated")}

      {:error, form, errors} ->
        {:noreply,
         socket
         |> assign_pacing_settings(form, errors)
         |> put_flash(:error, "Fix the pacing values and try again")}
    end
  end

  @impl true
  def handle_event("reset_pacing", _params, socket) do
    PacingSettings.reset()

    {:noreply,
     socket
     |> assign_pacing_settings(PacingSettings.current_form())
     |> put_flash(:info, "Game pacing reset to defaults")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_shell
      active="game-settings"
      title="Game Settings"
      subtitle="Tune runtime game pacing."
      flash={@flash}
    >
      <section class="rounded-md border border-stone-300 bg-white p-4 shadow-sm">
        <h2 class="font-mono text-xs font-black uppercase tracking-[0.16em] text-stone-700">
          Game Pacing
        </h2>
        <p class="mt-2 text-sm text-stone-500">
          Runtime controls for bot delays and trick/hand pauses. These values are saved with
          <code>Application.put_env</code>
          so they take effect immediately without a restart.
        </p>
        <div class="mt-4 rounded-sm border border-stone-200 bg-stone-50 p-4 text-sm">
          <p class="font-bold">
            Bots will act between {@pacing_preview.bot_delay_min_ms}ms and {@pacing_preview.bot_delay_max_ms}ms
          </p>
          <p class="mt-1 text-stone-500">
            Trick pause: {@pacing_form["trick_transition_delay_ms"]}ms
            · Hand pause: {@pacing_form["hand_transition_delay_ms"]}ms
            · Deal pause: {@pacing_form["deal_transition_delay_ms"]}ms
          </p>
        </div>
        <form
          id="pacing-form"
          phx-submit="save_pacing"
          phx-change="update_pacing_form"
          class="mt-6 space-y-6"
        >
          <div class="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3">
            <div
              :for={field <- @pacing_fields}
              class="rounded-md border border-stone-200 bg-stone-50/60 p-4"
            >
              <label for={pacing_input_id(field)} class="block text-sm font-medium">{field.label}</label>
              <p class="mt-1 text-xs leading-5 text-stone-500">{field.description}</p>
              <input
                type="number"
                min={field.min}
                max={field.max}
                step={field.step}
                id={pacing_input_id(field)}
                name={"pacing[#{field_key(field)}]"}
                value={@pacing_form[field_key(field)]}
                class="mt-3 block w-full rounded-md border-stone-300 bg-white shadow-sm"
              />
              <div class="mt-2 flex justify-between text-xs text-stone-500">
                <span>Range: {field.min}ms to {field.max}ms</span>
                <span>Step: {field.step}ms</span>
              </div>
              <p :if={@pacing_errors[field_key(field)]} class="mt-2 text-xs font-medium text-red-600">
                {@pacing_errors[field_key(field)]}
              </p>
            </div>
          </div>
          <div class="flex flex-wrap gap-3">
            <button
              type="submit"
              class="rounded-md bg-indigo-600 px-4 py-2 text-sm font-medium text-white hover:bg-indigo-700"
            >Save Pacing</button>
            <button
              type="button"
              phx-click="reset_pacing"
              class="rounded-md border border-stone-300 bg-white px-4 py-2 text-sm font-medium hover:bg-stone-50"
            >Reset to Defaults</button>
          </div>
        </form>
      </section>
    </.admin_shell>
    """
  end

  defp assign_pacing_settings(socket, form \\ nil, errors \\ %{}) do
    form = form || PacingSettings.current_form()

    socket
    |> assign(:pacing_fields, PacingSettings.field_specs())
    |> assign(:pacing_form, form)
    |> assign(:pacing_errors, errors)
    |> assign(:pacing_preview, PacingSettings.preview(form))
  end

  defp pacing_input_id(field), do: "pacing_#{field_key(field)}"
  defp field_key(field), do: Atom.to_string(field.key)
end
