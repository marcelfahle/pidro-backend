set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

server_ip := "95.217.3.224"

default:
    @just --list

bootstrap:
    kamal server bootstrap
    ssh root@{{server_ip}} 'ufw allow OpenSSH && ufw allow 80/tcp && ufw allow 443/tcp && ufw --force enable'

setup:
    kamal setup

deploy:
    kamal deploy

migrate:
    kamal app exec --primary "bin/pidro_server eval \"PidroServer.Release.migrate()\""

rollback version:
    kamal rollback {{version}}

logs:
    kamal app logs -f

console:
    kamal app exec --primary --interactive "bin/pidro_server remote"

boot-postgres:
    kamal accessory boot postgres

postgres-logs:
    kamal accessory logs postgres

health:
    curl -fsS http://{{server_ip}}/up

health-domain:
    curl -fsS https://play.pidro.online/up
