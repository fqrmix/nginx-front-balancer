# nginx-balancer

Reverse-proxy + TLS termination перед `sm_bot_golang` (admin API) и
`sm_bot_admin` (веб-админка). Сертификаты — wildcard Let's Encrypt через
DNS-01 (HOSTKEY), автопродление через `acme.sh`.

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

## HOSTKEY: API-токен и кастомный dnsapi-хук

**`hostkey.ru`, не `hostkey.com`** — это разные бэкенды с разными API-хостами
(`invapi.hostkey.ru` vs `invapi.hostkey.com`) и разными NS
(`ns1/ns2.hostkey.ru`). Токен от одного не работает на другом. Скрипт
ниже настроен на `.ru`.

У HOSTKEY нет официального плагина ни для `acme.sh`, ни для `certbot`, но
есть собственный DNS API (`https://invapi.hostkey.ru/pdns.php`,
[документация](https://hostkey.ru/documentation/apidocs/pdns/)) с
точечными `add_dns`/`delete_dns` по одной записи — в отличие от Beget, где
`changeRecords` перезаписывает всю зону целиком и сторонние скрипты
регулярно стирали существующие A/MX-записи, здесь такого риска нет.

`acme/dns_hostkey.sh` — самописный dnsapi-хук под конвенцию `acme.sh`
(`dns_hostkey_add`/`dns_hostkey_rm`), примонтирован в оба контейнера
(`acme_issue`, `acme_renew`) по пути `/acme.sh/dnsapi/dns_hostkey.sh`.
Он не универсальный: вместо общего алгоритма поиска зоны (обычно
dnsapi-скрипты поднимаются по лейблам домена и спрашивают провайдера, где
граница зоны) просто отрезает захардкоженный суффикс `fqrmix.ru`
(`HOSTKEY_ZONE` в `.env`, если когда-нибудь понадобится другой). Для
единственной используемой здесь зоны этого достаточно.

Токен — в личном кабинете `hostkey.ru`, раздел API-ключей
([документация](https://hostkey.ru/documentation/apidocs/api/)), положить
в `HOSTKEY_TOKEN` в `.env`. Заодно проверь, что NS у `fqrmix.ru` в
регистраторе действительно указывают на `ns1.hostkey.ru`/`ns2.hostkey.ru`
— иначе DNS-хостинг и, соответственно, этот API вообще не про твою зону.

Хук монтируется в `/acmebin/dnsapi/dns_hostkey.sh` — **не** в
`/acme.sh/dnsapi/`, хотя `acme_state`-volume смонтирован именно на
`/acme.sh`. Разница: `/acme.sh` — это `LE_CONFIG_HOME` (там только
аккаунт/сертификаты), а dnsapi-хуки грузятся из `LE_WORKING_DIR`, который
в образе `neilpang/acme.sh` — `/acmebin` (проверено запуском образа и
`env | grep LE_`). Первая версия монтировала не туда и `acme.sh` тихо не
находил хук (`Cannot find DNS API hook for: dns_hostkey`, просился
добавить TXT вручную) — если увидишь такую ошибку в логах, значит опять
не тот путь.

Проверено (реальным прогоном `neilpang/acme.sh --issue --dns dns_hostkey`
с тестовым доменом): хук находится (`Found domain API file:
/acmebin/dnsapi/dns_hostkey.sh`) и вызывается (падает на `HOSTKEY_TOKEN is
not set`, как и должен без токена). **Не проверено** — реальный вызов
`pdns.php` с настоящим токеном: своего аккаунта HOSTKEY для этого нет,
проверка ответа на `"result":"OK"` собрана из документации, а не из
живого ответа API. Первый прогон `acme_issue` с реальным `HOSTKEY_TOKEN`
стоит запустить руками и посмотреть на фактический ответ, прежде чем
полагаться на автопродление:

```bash
docker compose run --rm acme_issue
docker compose logs acme_issue
```

## DNS-записи, которые нужно создать в HOSTKEY заранее

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
cp .env.example .env    # HOSTKEY_TOKEN
docker compose up --build -d
```

Порядок внутри compose: `acme_issue` (одноразовый выпуск сертификата) →
`nginx` (ждёт его успешного завершения) и `acme_renew` (демон
автопродления). `nginx` перечитывает сертификат раз в 12 часов сам —
никакой синхронизации между контейнерами не требуется (см.
`nginx/docker-entrypoint-reload.sh`).

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
