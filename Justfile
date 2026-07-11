set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

server_ip := "95.217.3.224"

default:
    @just --list

bootstrap:
    bundle exec kamal server bootstrap
    ssh root@{{server_ip}} 'ufw allow OpenSSH && ufw allow 80/tcp && ufw allow 443/tcp && ufw --force enable'

setup:
    bundle exec kamal setup

deploy:
    bundle exec kamal deploy

migrate:
    bundle exec kamal app exec --primary "bin/pidro_server eval \"PidroServer.Release.migrate()\""

backup:
    ops/backup-production

install-backup-timer:
    ops/install-backup-timer

smoke:
    ops/smoke-production

quality:
    mix precommit

rollback version:
    bundle exec kamal rollback {{version}}

logs:
    bundle exec kamal app logs -f

console:
    bundle exec kamal app exec --primary --interactive "bin/pidro_server remote"

boot-postgres:
    bundle exec kamal accessory boot postgres

postgres-logs:
    bundle exec kamal accessory logs postgres

health:
    curl -fsS https://app.pidro.online/up
