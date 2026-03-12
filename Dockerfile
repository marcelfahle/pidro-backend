ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=28
ARG ELIXIR_IMAGE=elixir:${ELIXIR_VERSION}-otp-${OTP_VERSION}

FROM ${ELIXIR_IMAGE} AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends build-essential git ca-certificates curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config ./config
COPY apps/pidro_engine/mix.exs ./apps/pidro_engine/mix.exs
COPY apps/pidro_server/mix.exs ./apps/pidro_server/mix.exs

RUN mix deps.get --only ${MIX_ENV}
RUN mix deps.compile

COPY apps ./apps

RUN mix compile
RUN cd apps/pidro_server && mix assets.deploy
RUN cd apps/pidro_server && mix release pidro_server

FROM ${ELIXIR_IMAGE} AS runner

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends ca-certificates locales openssl && \
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && \
    locale-gen && \
    rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8
ENV MIX_ENV=prod
ENV PHX_SERVER=true

WORKDIR /app

RUN useradd --create-home --shell /bin/bash app

COPY --from=builder --chown=app:app /app/_build/prod/rel/pidro_server ./

USER app

EXPOSE 4000

CMD ["bin/pidro_server", "start"]
