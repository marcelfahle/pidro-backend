defmodule PidroServerWeb.Dev.EmailMigrationLive do
  @moduledoc """
  Admin email studio for creating and editing Pidro emails.
  """

  use PidroServerWeb, :live_view

  import PidroServerWeb.Dev.AdminComponents

  alias PidroServer.Emails

  @impl true
  def mount(_params, _session, socket) do
    kind = :transactional
    selected = Emails.first_template(kind)

    {:ok,
     socket
     |> assign(:page_title, "Email Studio")
     |> assign(:kind_filter, kind)
     |> assign(:show_delete_modal, false)
     |> assign(:template_to_delete, nil)
     |> assign_selected(selected)
     |> load_email_ops()}
  end

  @impl true
  def handle_event("filter_kind", %{"kind" => kind}, socket) do
    kind = Emails.normalize_kind(kind)
    selected = Emails.first_template(kind)

    {:noreply,
     socket
     |> assign(:kind_filter, kind)
     |> assign_selected(selected)
     |> load_email_ops()}
  end

  @impl true
  def handle_event("new_template", %{"kind" => kind}, socket) do
    case Emails.create_template(kind) do
      {:ok, template} ->
        {:noreply,
         socket
         |> assign(:kind_filter, template.kind)
         |> assign_selected(template)
         |> load_email_ops()
         |> put_flash(:info, "Created #{kind_label(template.kind)} draft.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not create a new email draft.")}
    end
  end

  @impl true
  def handle_event("select_template", %{"id" => id}, socket) do
    case Emails.get_template(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "That email no longer exists.")}

      template ->
        {:noreply,
         socket
         |> assign(:kind_filter, template.kind)
         |> assign_selected(template)
         |> load_email_ops()}
    end
  end

  @impl true
  def handle_event("request_delete", %{"id" => id}, socket) do
    case Emails.get_template(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "That email draft no longer exists.")}

      template ->
        {:noreply,
         socket
         |> assign(:show_delete_modal, true)
         |> assign(:template_to_delete, template)}
    end
  end

  @impl true
  def handle_event("cancel_delete", _params, socket) do
    {:noreply, close_delete_modal(socket)}
  end

  @impl true
  def handle_event("confirm_delete", _params, socket) do
    case socket.assigns.template_to_delete do
      nil ->
        {:noreply, close_delete_modal(socket)}

      template ->
        case Emails.delete_template(template) do
          {:ok, deleted_template} ->
            selected = Emails.first_template(deleted_template.kind)

            {:noreply,
             socket
             |> close_delete_modal()
             |> assign(:kind_filter, deleted_template.kind)
             |> assign_selected(selected)
             |> load_email_ops()
             |> put_flash(:info, "Deleted #{deleted_template.name}.")}

          {:error, _changeset} ->
            {:noreply,
             socket
             |> close_delete_modal()
             |> put_flash(:error, "Could not delete #{template.name}. Try again.")}
        end
    end
  end

  @impl true
  def handle_event("save_template", %{"template" => params}, socket) do
    case socket.assigns.selected_template do
      nil ->
        {:noreply, put_flash(socket, :error, "Create an email before saving.")}

      template ->
        case Emails.update_template(template, params) do
          {:ok, template} ->
            {:noreply,
             socket
             |> assign_selected(template)
             |> load_email_ops()
             |> put_flash(:info, "Saved #{template.name}.")}

          {:error, changeset} ->
            {:noreply,
             socket
             |> assign(:form, to_form(changeset, as: :template))
             |> put_flash(:error, "Fix the highlighted fields and save again.")}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_shell
      active="emails"
      title="Email Studio"
      subtitle="Draft transactional emails and campaigns. Transactional templates expose stable keys for server-side sends."
      flash={@flash}
    >
      <:actions>
        <button
          type="button"
          phx-click="new_template"
          phx-value-kind="transactional"
          class={primary_button_class()}
        >
          <.icon name="hero-bolt" class="size-4" /> New transactional
        </button>
        <button
          type="button"
          phx-click="new_template"
          phx-value-kind="campaign"
          class={secondary_button_class()}
        >
          <.icon name="hero-megaphone" class="size-4" /> New campaign
        </button>
        <.link
          href={~p"/admin/emails/export.csv"}
          class={secondary_button_class()}
        >
          <.icon name="hero-arrow-down-tray" class="size-4" /> Export contacts
        </.link>
      </:actions>

      <section class="rounded-lg border border-stone-200 bg-white px-4 py-3">
        <div class="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
          <div class="flex flex-wrap items-center gap-x-4 gap-y-1 text-sm text-stone-600">
            <span>
              <strong class="font-medium text-stone-950">{@template_summary.total}</strong> emails
            </span>
            <span>
              <strong class="font-medium text-stone-950">{@template_summary.transactional}</strong>
              transactional
            </span>
            <span>
              <strong class="font-medium text-stone-950">{@template_summary.campaigns}</strong>
              campaigns
            </span>
          </div>
          <p class="text-sm text-stone-500">
            {format_number(@subscriber_summary.contacts_with_email)} exportable contacts · {format_number(
              @subscriber_summary.missing_email
            )} players missing email
          </p>
        </div>
      </section>

      <section class="grid gap-4 xl:grid-cols-[18rem_minmax(0,1fr)]">
        <aside class={panel_class(["xl:self-start"])}>
          <div class="border-b border-stone-200 p-3">
            <div class="grid grid-cols-2 gap-1 rounded-md bg-stone-100/80 p-1">
              <button
                type="button"
                phx-click="filter_kind"
                phx-value-kind="transactional"
                class={kind_tab_class(@kind_filter == :transactional)}
              >
                Transactional
              </button>
              <button
                type="button"
                phx-click="filter_kind"
                phx-value-kind="campaign"
                class={kind_tab_class(@kind_filter == :campaign)}
              >
                Campaigns
              </button>
            </div>
          </div>

          <div class="border-b border-stone-200 px-3 py-3">
            <button
              type="button"
              phx-click="new_template"
              phx-value-kind={Atom.to_string(@kind_filter)}
              class={primary_button_class(["w-full", "justify-center"])}
            >
              <.icon name="hero-plus" class="size-4" /> New {kind_label(@kind_filter)}
            </button>
          </div>

          <%= if Enum.empty?(@templates) do %>
            <div class="p-4">
              <.empty_state
                icon="hero-envelope"
                title={"No #{kind_label(@kind_filter)} emails yet"}
                body="Create a draft to start writing."
              />
            </div>
          <% else %>
            <div class="divide-y divide-stone-100">
              <button
                :for={template <- @templates}
                type="button"
                phx-click="select_template"
                phx-value-id={template.id}
                class={template_button_class(template, @selected_template)}
              >
                <span class="flex min-w-0 items-center gap-2">
                  <span class={kind_dot_class(template.kind)}></span>
                  <span class="truncate">{template.name}</span>
                </span>
                <span class="mt-1 block truncate pl-4 text-xs font-normal text-stone-500">
                  {template.subject}
                </span>
                <span class="mt-1 block truncate pl-4 font-mono text-[11px] font-normal text-stone-400">
                  :{template.key}
                </span>
              </button>
            </div>
          <% end %>
        </aside>

        <%= if @selected_template do %>
          <.form
            for={@form}
            id={"email-editor-#{@selected_template.id}"}
            phx-submit="save_template"
            phx-hook="EmailEditor"
            data-template-id={@selected_template.id}
            class="grid min-w-0 gap-4 2xl:grid-cols-[minmax(0,1fr)_24rem]"
          >
            <div class={panel_class(["min-w-0"])}>
              <div class="flex flex-col gap-3 border-b border-stone-200 px-4 py-3 lg:flex-row lg:items-start lg:justify-between">
                <div>
                  <div class="flex flex-wrap items-center gap-2">
                    <span class={kind_badge_class(@selected_template.kind)}>
                      {kind_label(@selected_template.kind)}
                    </span>
                    <span class={subtle_badge_class()}>
                      Saved in database
                    </span>
                    <span class="rounded-md border border-stone-200 bg-white px-2 py-1 font-mono text-xs font-medium text-stone-600">
                      :{@selected_template.key}
                    </span>
                    <span
                      data-editor-dirty
                      class="hidden rounded-md border border-amber-200 bg-amber-50 px-2 py-1 text-xs font-medium text-amber-800"
                    >
                      Unsaved changes
                    </span>
                  </div>
                  <h2 class="mt-2 text-lg font-semibold text-stone-950">
                    {@selected_template.name}
                  </h2>
                </div>
                <div class="flex flex-wrap gap-2">
                  <button
                    type="submit"
                    class={primary_button_class()}
                  >
                    <.icon name="hero-check" class="size-4" /> Save email
                  </button>
                  <button
                    type="button"
                    data-editor-action="copy-html"
                    class={secondary_button_class()}
                  >
                    <.icon name="hero-clipboard-document" class="size-4" /> Copy HTML
                  </button>
                  <button
                    type="button"
                    data-editor-action="download-html"
                    class={secondary_button_class()}
                  >
                    <.icon name="hero-arrow-down-tray" class="size-4" /> Download
                  </button>
                  <button
                    type="button"
                    phx-click="request_delete"
                    phx-value-id={@selected_template.id}
                    class={danger_button_class()}
                  >
                    <.icon name="hero-trash" class="size-4" /> Delete
                  </button>
                </div>
              </div>

              <div class="grid gap-px bg-stone-100 lg:grid-cols-2">
                <label class="block bg-white px-4 py-3">
                  <span class={field_label_class()}>
                    Internal name
                  </span>
                  <input
                    name={@form[:name].name}
                    data-email-field="name"
                    value={field_value(@form, :name)}
                    class={text_input_class(["font-medium"])}
                  />
                </label>
                <label class="block bg-white px-4 py-3">
                  <span class={field_label_class()}>
                    Code key
                  </span>
                  <input
                    name={@form[:key].name}
                    data-email-field="key"
                    value={field_value(@form, :key)}
                    class={text_input_class(["font-mono"])}
                  />
                  <p class="mt-1 truncate text-xs text-stone-500">
                    Use
                    <code class="font-mono">
                      Emails.deliver_transactional(:{field_value(
                        @form,
                        :key
                      )}, ...)
                    </code>
                  </p>
                </label>
                <label class="block bg-white px-4 py-3">
                  <span class={field_label_class()}>
                    Subject
                  </span>
                  <input
                    name={@form[:subject].name}
                    data-email-field="subject"
                    value={field_value(@form, :subject)}
                    class={text_input_class(["font-medium"])}
                  />
                </label>
                <label class="block bg-white px-4 py-3">
                  <span class={field_label_class()}>
                    Preview text
                  </span>
                  <input
                    name={@form[:preview_text].name}
                    data-email-field="preview"
                    value={field_value(@form, :preview_text)}
                    class={text_input_class()}
                  />
                </label>
                <div class="grid gap-px bg-stone-100 sm:grid-cols-3 lg:col-span-2">
                  <label class="block bg-white px-4 py-3">
                    <span class={field_label_class()}>
                      From name
                    </span>
                    <input
                      name={@form[:from_name].name}
                      data-email-field="fromName"
                      value={field_value(@form, :from_name)}
                      class={text_input_class()}
                    />
                  </label>
                  <label class="block bg-white px-4 py-3">
                    <span class={field_label_class()}>
                      From email
                    </span>
                    <input
                      name={@form[:from_email].name}
                      data-email-field="fromEmail"
                      value={field_value(@form, :from_email)}
                      class={text_input_class()}
                    />
                  </label>
                  <label class="block bg-white px-4 py-3">
                    <span class={field_label_class()}>
                      Reply-to
                    </span>
                    <input
                      name={@form[:reply_to].name}
                      data-email-field="replyTo"
                      value={field_value(@form, :reply_to)}
                      class={text_input_class()}
                    />
                  </label>
                </div>
              </div>

              <textarea
                name={@form[:html_body].name}
                data-email-hidden-html
                class="hidden"
              >{field_value(@form, :html_body)}</textarea>

              <div class="border-t border-stone-200">
                <div class="flex flex-wrap items-center gap-1 border-b border-stone-200 bg-stone-50 px-3 py-2">
                  <button
                    type="button"
                    data-editor-command="bold"
                    class="editor-tool-button"
                    title="Bold"
                  >
                    B
                  </button>
                  <button
                    type="button"
                    data-editor-command="italic"
                    class="editor-tool-button italic"
                    title="Italic"
                  >
                    I
                  </button>
                  <button
                    type="button"
                    data-editor-command="formatBlock"
                    data-editor-value="h2"
                    class="editor-tool-button"
                    title="Heading"
                  >
                    H2
                  </button>
                  <button
                    type="button"
                    data-editor-command="insertUnorderedList"
                    class="editor-tool-button"
                    title="Bulleted list"
                  >
                    <.icon name="hero-list-bullet" class="size-4" />
                  </button>
                  <button
                    type="button"
                    data-editor-command="insertOrderedList"
                    class="editor-tool-button"
                    title="Numbered list"
                  >
                    1.
                  </button>
                  <button
                    type="button"
                    data-editor-action="create-link"
                    class="editor-tool-button"
                    title="Insert link"
                  >
                    <.icon name="hero-link" class="size-4" />
                  </button>
                  <button
                    type="button"
                    data-editor-command="removeFormat"
                    class="editor-tool-button"
                    title="Clear formatting"
                  >
                    <.icon name="hero-eraser" class="size-4" />
                  </button>
                  <div class="mx-2 hidden h-6 w-px bg-stone-300 sm:block"></div>
                  <span class="px-2 text-xs font-medium text-stone-500">
                    Variables
                  </span>
                  <button
                    :for={variable <- @selected_template.variables}
                    type="button"
                    data-editor-variable={variable}
                    class="rounded-md border border-stone-200 bg-white px-2 py-1 font-mono text-xs font-medium text-stone-600 hover:border-stone-300 hover:text-stone-950"
                  >
                    {variable}
                  </button>
                </div>

                <div class="bg-stone-50 p-4">
                  <div
                    data-email-body
                    contenteditable="true"
                    class="email-editor-body mx-auto min-h-[28rem] w-full max-w-[42rem] rounded-lg border border-stone-200 bg-white px-8 py-7 text-base leading-7 text-stone-950 focus:border-stone-400 focus:outline-none focus:ring-2 focus:ring-stone-200"
                  ><%= raw(field_value(@form, :html_body)) %></div>
                </div>
              </div>
            </div>

            <aside class="grid min-w-0 gap-4">
              <div class={panel_class()}>
                <div class="flex items-center justify-between border-b border-stone-200 px-4 py-3">
                  <div>
                    <h2 class={section_heading_class()}>
                      Preview
                    </h2>
                    <p class="mt-1 text-xs text-stone-500">Email body with a 640px frame.</p>
                  </div>
                  <span class={subtle_badge_class()}>
                    Live
                  </span>
                </div>
                <iframe
                  title="Email preview"
                  data-email-preview
                  sandbox=""
                  class="h-[30rem] w-full bg-white"
                ></iframe>
              </div>

              <div class={panel_class()}>
                <div class="border-b border-stone-200 px-4 py-3">
                  <h2 class={section_heading_class()}>
                    Variables for this email
                  </h2>
                </div>
                <label class="block p-4">
                  <span class={field_label_class()}>
                    One per line
                  </span>
                  <textarea
                    name={@form[:variables_text].name}
                    data-email-field="variablesText"
                    class={textarea_input_class(["h-28", "font-mono", "text-xs"])}
                  >{field_value(@form, :variables_text)}</textarea>
                </label>
              </div>

              <div class={panel_class()}>
                <div class="border-b border-stone-200 px-4 py-3">
                  <h2 class={section_heading_class()}>
                    HTML source
                  </h2>
                </div>
                <textarea
                  data-email-source
                  readonly
                  spellcheck="false"
                  class="h-60 w-full resize-y border-0 bg-stone-950 p-4 font-mono text-xs leading-5 text-stone-100 focus:ring-0"
                ></textarea>
              </div>

              <div class={panel_class()}>
                <div class="border-b border-stone-200 px-4 py-3">
                  <h2 class={section_heading_class()}>
                    Variable library
                  </h2>
                </div>
                <div class="divide-y divide-stone-100">
                  <div :for={group <- @variable_groups} class="px-4 py-3">
                    <p class="text-xs font-medium text-stone-500">
                      {group.name}
                    </p>
                    <div class="mt-2 flex flex-wrap gap-2">
                      <button
                        :for={variable <- group.variables}
                        type="button"
                        data-editor-variable={variable.key}
                        class="rounded-md border border-stone-200 bg-stone-50 px-2 py-1 font-mono text-xs font-medium text-stone-600 hover:bg-white hover:text-stone-950"
                        title={variable.label}
                      >
                        {variable.key}
                      </button>
                    </div>
                  </div>
                </div>
              </div>
            </aside>
          </.form>
        <% else %>
          <div class="rounded-lg border border-dashed border-stone-200 bg-white p-8">
            <.empty_state
              icon="hero-envelope"
              title="No email selected"
              body="Create a transactional email or campaign to open the editor."
            />
          </div>
        <% end %>
      </section>

      <%= if @show_delete_modal and @template_to_delete do %>
        <div class="fixed inset-0 z-50 flex items-end justify-center bg-stone-950/45 p-4 sm:items-center">
          <div class="w-full max-w-lg rounded-lg border border-stone-200 bg-white p-6 shadow-xl animate-deal-in">
            <div class="flex gap-4">
              <div class="flex size-11 shrink-0 items-center justify-center rounded-md bg-rose-50 text-rose-700">
                <.icon name="hero-exclamation-triangle" class="size-6" />
              </div>
              <div>
                <h2 class="text-lg font-semibold text-stone-950">
                  Delete {@template_to_delete.name}?
                </h2>
                <p class="mt-2 text-sm leading-6 text-stone-600">
                  This removes the draft from the email studio database. Exported HTML files,
                  contact exports, and any already-sent emails are not affected.
                </p>
              </div>
            </div>
            <div class="mt-6 flex flex-col-reverse gap-3 sm:flex-row sm:justify-end">
              <button
                type="button"
                phx-click="cancel_delete"
                class="rounded-md border border-stone-200 bg-white px-4 py-2 text-sm font-medium text-stone-700 hover:bg-stone-50"
              >
                Keep email
              </button>
              <button
                type="button"
                phx-click="confirm_delete"
                class="rounded-md bg-rose-600 px-4 py-2 text-sm font-semibold text-white shadow-sm transition hover:bg-rose-700 active:translate-y-px"
              >
                Delete email
              </button>
            </div>
          </div>
        </div>
      <% end %>
    </.admin_shell>
    """
  end

  defp assign_selected(socket, nil) do
    socket
    |> assign(:selected_template, nil)
    |> assign(:form, nil)
  end

  defp assign_selected(socket, template) do
    socket
    |> assign(:selected_template, template)
    |> assign(:form, to_form(Emails.change_template(template), as: :template))
  end

  defp load_email_ops(socket) do
    kind = socket.assigns.kind_filter

    socket
    |> assign(:subscriber_summary, Emails.subscriber_summary())
    |> assign(:template_summary, Emails.template_summary())
    |> assign(:templates, Emails.list_templates(kind))
    |> assign(:variable_groups, Emails.variable_groups())
    |> assign(:delivery_setup, Emails.delivery_setup())
  end

  defp close_delete_modal(socket) do
    socket
    |> assign(:show_delete_modal, false)
    |> assign(:template_to_delete, nil)
  end

  defp panel_class(extra \\ []) do
    [
      "overflow-hidden rounded-lg border border-stone-200 bg-white",
      extra
    ]
  end

  defp primary_button_class(extra \\ []) do
    [
      "inline-flex items-center gap-2 rounded-md bg-stone-950 px-3 py-2 text-sm font-medium text-white transition hover:bg-stone-800 active:translate-y-px",
      extra
    ]
  end

  defp secondary_button_class(extra \\ []) do
    [
      "inline-flex items-center gap-2 rounded-md border border-stone-200 bg-white px-3 py-2 text-sm font-medium text-stone-700 transition hover:bg-stone-50 hover:text-stone-950 active:translate-y-px",
      extra
    ]
  end

  defp danger_button_class(extra \\ []) do
    [
      "inline-flex items-center gap-2 rounded-md border border-rose-200 bg-white px-3 py-2 text-sm font-medium text-rose-700 transition hover:bg-rose-50 hover:text-rose-900 active:translate-y-px",
      extra
    ]
  end

  defp section_heading_class do
    "text-sm font-semibold text-stone-800"
  end

  defp field_label_class do
    "text-xs font-medium text-stone-500"
  end

  defp subtle_badge_class do
    "rounded-md border border-stone-200 bg-stone-50 px-2 py-1 text-xs font-medium text-stone-600"
  end

  defp text_input_class(extra \\ []) do
    [
      "mt-1 w-full rounded-md border-stone-200 bg-white px-3 py-2 text-sm text-stone-950 focus:border-stone-400 focus:ring-stone-200",
      extra
    ]
  end

  defp textarea_input_class(extra) do
    [
      "mt-1 w-full rounded-md border-stone-200 bg-white px-3 py-2 text-sm text-stone-950 focus:border-stone-400 focus:ring-stone-200",
      extra
    ]
  end

  defp template_button_class(template, %{id: selected_id}) when template.id == selected_id do
    "block w-full px-4 py-3 text-left text-sm font-medium text-stone-950 bg-stone-100 transition hover:bg-stone-100"
  end

  defp template_button_class(_template, _selected_template) do
    "block w-full px-4 py-3 text-left text-sm font-medium text-stone-700 transition hover:bg-stone-50 hover:text-stone-950"
  end

  defp kind_tab_class(true) do
    "rounded-md bg-white px-2 py-2 text-xs font-medium text-stone-950 shadow-sm"
  end

  defp kind_tab_class(false) do
    "rounded-md px-2 py-2 text-xs font-medium text-stone-500 transition hover:text-stone-950"
  end

  defp kind_dot_class(:transactional), do: "size-2 rounded-full bg-amber-500"
  defp kind_dot_class(:campaign), do: "size-2 rounded-full bg-sky-500"

  defp kind_badge_class(:campaign),
    do: "rounded-md border border-sky-200 bg-sky-50 px-2 py-1 text-xs font-medium text-sky-700"

  defp kind_badge_class(:transactional),
    do:
      "rounded-md border border-amber-200 bg-amber-50 px-2 py-1 text-xs font-medium text-amber-800"

  defp kind_label(:campaign), do: "Campaign"
  defp kind_label(:transactional), do: "Transactional"

  defp field_value(form, field), do: Phoenix.HTML.Form.input_value(form, field) || ""

  defp format_number(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reverse()
    |> Enum.map_join(",", &Enum.join/1)
  end

  defp format_number(value), do: to_string(value)
end
