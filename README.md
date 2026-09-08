# nginx-balancer

Reverse-proxy + TLS termination перед `sm_bot_golang` (admin API) и
`sm_bot_admin` (веб-админка). Сертификаты — wildcard Let's Encrypt через
DNS-01 (Beget), автопродление через `acme.sh`.

## Домены

| Домен | Что отдаёт |
|---|---|
| `fqrmix.ru`, `www.fqrmix.ru` | статическая HTML-заглушка (`www/fqrmix-placeholder`) |
| `sm-bot.yoomoney-services.fqrmix.ru` | проксирует на контейнер `sm_bot_admin:80` |
| `api.yoomoney-services.fqrmix.ru/smbot/*` | проксирует на `sm_bot_golang:7772/*` (префикс `/smbot` срезается) |

**Важный нюанс сертификата.** `*.fqrmix.ru` покрывает только один уровень
поддоменов — `sm-bot.yoomoney-services.fqrmix.ru` и
`api.yoomoney-services.fqrmix.ru` на два уровня глубже и под этот wildcard
не попадают. Поэтому запрашивается один сертификат с тремя SAN:
`fqrmix.ru`, `*.fqrmix.ru` и `*.yoomoney-services.fqrmix.ru` (см.
`acme_issue` в `docker-compose.yaml`). Если подтверждённые домены
поменяются — поправить список там же.

## Beget: API-логин/пароль

Использует официальный, встроенный в образ `neilpang/acme.sh` плагин
`dns_beget` ([wiki](https://github.com/acmesh-official/acme.sh/wiki/dnsapi2#dns_beget))
— никакого кастомного скрипта не нужно, он уже лежит в образе на
`/acmebin/dnsapi/dns_beget.sh`. Проверил прямым запуском образа
(`--issue --dns dns_beget ...`): хук находится (`Found domain API file:
/acmebin/dnsapi/dns_beget.sh`) и запрашивает `Beget_Username`/
`Beget_Password`, как и ожидается.

Учётные данные — обычные логин/пароль от аккаунта Beget (не отдельный
API-токен), включить доступ по API нужно в личном кабинете Beget:
«Настройки аккаунта» → «Доступ по API». Положить в `Beget_Username` /
`Beget_Password` в `.env`.

**Важно про `changeRecords` у Beget** — этот метод перезаписывает всю
зону целиком, а не отдельную запись; сторонние самописные интеграции
(например, у `lego`, ACME-клиента Traefik/Caddy) из-за этого стирали
существующие A/MX-записи домена ([issue](https://github.com/go-acme/lego/issues/2774)).
Официальный `dns_beget.sh` от этой проблемы застрахован: перед
изменением он делает `dns/getData` и добавляет TXT-запись поверх уже
существующих A/AAAA/CAA/MX/SRV/TXT — я прочитал исходник плагина в
образе и убедился в этом лично, а не поверил на слово документации. Но
собственного аккаунта Beget для полного end-to-end теста (реальный
`changeRecords`/`getData` вызов) у меня нет — первый прогон `acme_issue`
стоит один раз проверить руками:

```bash
docker compose run --rm acme_issue
docker compose logs acme_issue
```

## DNS-записи, которые нужно создать в Beget заранее

Выпуск сертификата (DNS-01) не требует ничего, кроме доступа к API — но
чтобы трафик реально доходил до сервера, в зоне `fqrmix.ru` должны быть:

- `fqrmix.ru` → A/AAAA на публичный IP этого хоста
- `*.yoomoney-services.fqrmix.ru` → A/AAAA на тот же IP (покрывает и
  `sm-bot.`, и `api.` одной записью; либо явно каждую отдельно)

## Конфликт порта 443 с proxy-balancer

**На этом хосте уже есть `proxy-balancer-app`, который держит хостовый
`443:443` под VLESS Reality** (камуфляж под `www.microsoft.com`). Этот
compose-проект тоже публикует `443:443` — оба одновременно на одном хосте
не запустятся (`bind: address already in use`).

Договорились сделать `nginx-balancer` отдельным, самостоятельным сервисом
сейчас, а не сразу мультиплексировать порт с `proxy-balancer` — то есть
эта раскатка **не запускается на проде, пока не решён конфликт порта**.
Когда будете готовы:

1. **Быстрый путь** — на сервере, где живёт `proxy-balancer`, не публиковать
   его `443` на хост (переиспользовать доступ к Reality как-то иначе,
   например только по IP:port без домена), и отдать 443 полностью
   `nginx-balancer`.
2. **Путь без изменений в proxy-balancer** — задействовать
   `extensions/stream-sni.conf.example`: `stream{}` + `ssl_preread`
   разбирает SNI из ClientHello *не расшифровывая TLS* и раздаёт по
   имени хоста — `fqrmix.ru`/`*.fqrmix.ru` сюда, всё остальное (SNI
   `www.microsoft.com` от Reality) транзитом в `proxy-balancer-app` по
   общей docker-сети. Файл — референс с комментариями, не подключён по
   умолчанию: чтобы включить, нужно завести кастомный `nginx.conf` (сейчас
   используется штатный из образа) и завести общую сеть с
   `proxy-balancer`.

## Запуск

```bash
cp .env.example .env    # Beget_Username / Beget_Password
docker compose up --build -d
```

Порядок внутри compose: `acme_issue` (одноразовый выпуск сертификата) →
`nginx` (ждёт его успешного завершения) и `acme_renew` (демон
автопродления). `nginx` перечитывает сертификат раз в 12 часов сам —
никакой синхронизации между контейнерами не требуется (см.
`nginx/docker-entrypoint-reload.sh`).

`acme.sh --issue` возвращает **exit code 2** (не 0), когда сертификат уже
валиден и обновлять рано («Domains not changed. Skipping.») — это не
ошибка, а штатный «пропуск». `acme_issue`'ный `set -e` изначально
принимал такой exit code за сбой и падал ещё до `--install-cert`, из-за
чего `nginx`/`acme_renew` вечно висели в `Created`
(`depends_on: condition: service_completed_successfully` не срабатывал).
Команда в `docker-compose.yaml` это учитывает: код 2 — пропускается,
любой другой — падает как обычно.

## Порядок раскатки в связке с остальными репозиториями

Сеть `sm_bot_net` создаётся `sm_bot_golang/deploy/docker-compose.yaml` —
поднимай его первым (или хотя бы `docker network create sm_bot_net`
заранее), иначе `sm_bot_admin` и этот compose не смогут подключиться
(`external: true`).

1. `sm_bot_golang`: `docker compose -f deploy/docker-compose.yaml up -d`
   (сеть `sm_bot_net` создаётся здесь; admin API порт `7772` **уже не
   публикуется на хост** — снаружи он был доступен по нему до этого
   изменения, поэтому это самый разрушительный шаг: до момента, пока
   `nginx-balancer` не поднимется и не начнёт проксировать
   `api.yoomoney-services.fqrmix.ru/smbot/*`, у админки не будет доступа
   к API вообще).
2. `sm_bot_admin`: `docker compose -f deploy/docker-compose.yaml up --build -d`
3. `nginx-balancer` (этот репозиторий, после решения конфликта порта 443
   выше): `docker compose up --build -d`

## Структура

```
nginx/            Dockerfile, conf.d/*.conf (виртуальные хосты)
www/              статика для fqrmix.ru
extensions/        stream+SNI референс на будущее (см. выше)
docker-compose.yaml  acme_issue, acme_renew, nginx
```
