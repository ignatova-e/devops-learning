# Лабораторная работа: свой exporter для Prometheus на Bash

В этой лабораторной мы напишем небольшой аналог `node_exporter`. Скрипт читает
системные файлы Linux, формирует метрики в формате Prometheus, Nginx публикует
их по HTTP, а Prometheus регулярно забирает результат.

## Задание

Соберите информацию о базовых метриках системы: загрузке CPU, оперативной
памяти и объёме/свободном месте корневой файловой системы. Отдайте результат
через Nginx в [формате экспозиции Prometheus](https://prometheus.io/docs/instrumenting/exposition_formats/).
Настройте Prometheus на сбор этой страницы. Обновление метрик должно происходить
не чаще одного раза в 3 секунды.

Сначала попробуйте выполнить задание самостоятельно. Если пока не хватает
навыков или опыта — просто повторяйте шаги ниже: это учебный проект, а не
экзамен. Все команды рассчитаны на Ubuntu/Debian и выполняются в виртуальной
машине или другом Linux-хосте с правами `sudo`.

> В условии иногда говорится об HTML-странице. Prometheus ожидает не HTML, а
> обычный текст со строками `имя_метрики значение`; Nginx всё равно отдаёт этот
> файл как веб-страницу по URL. Поэтому `Content-Type: text/plain` здесь верен.

## Что получится

```text
/proc, df ──> Bash ──> /var/www/custom-metrics/metrics
                              │
                           Nginx :8080/metrics
                              │
                           Prometheus :9090
```

Файлы готового учебного проекта лежат рядом с этой инструкцией:

| Файл | Назначение |
| --- | --- |
| `metrics.sh` | считывает CPU, память и диск, формирует текст метрик |
| `main.sh` | точка входа: загружает функции и записывает файл |
| `nginx-metrics.conf` | публикует один файл по адресу `/metrics` |
| `custom-node-metrics.service` | разово запускает сборщик от root |
| `custom-node-metrics.timer` | запускает сервис раз в 3 секунды |
| `prometheus-custom.yml` | фрагмент конфигурации Prometheus |

## 1. Установите Nginx и Prometheus

```bash
sudo apt update
sudo apt install -y nginx prometheus curl
```

Проверьте, что службы доступны:

```bash
systemctl is-active nginx
systemctl is-active prometheus
```

Ожидаемый вывод для обеих команд — `active`.

## 2. Посмотрите, откуда берутся данные

Linux уже предоставляет нужную информацию:

```bash
head -n 1 /proc/stat
grep -E 'MemTotal|MemAvailable' /proc/meminfo
df -B1 /
```

В первой строке `/proc/stat` содержатся счётчики времени CPU. Скрипт берёт два
замера с интервалом в секунду и вычисляет долю занятого CPU за этот интервал.
Из `/proc/meminfo` берутся общий и доступный объём RAM в байтах. `df -B1 /`
показывает размер и свободное место файловой системы, в которой расположен
корень `/`.

## 3. Установите сборщик

Скопируйте проект на сервер или перейдите в этот каталог в репозитории:

```bash
cd labs/bash/custom-node-exporter
sudo install -d -m 0755 /usr/local/lib/custom-node-exporter
sudo install -m 0755 main.sh metrics.sh /usr/local/lib/custom-node-exporter/
sudo install -d -m 0755 /var/www/custom-metrics
sudo /usr/local/lib/custom-node-exporter/main.sh
```

В результате появится файл `/var/www/custom-metrics/metrics`. Откройте его:

```bash
cat /var/www/custom-metrics/metrics
```

Пример результата (числа зависят от машины):

```text
# HELP custom_cpu_usage_ratio CPU busy fraction measured over one second.
# TYPE custom_cpu_usage_ratio gauge
custom_cpu_usage_ratio 0.124587
custom_memory_total_bytes 8343537664
custom_memory_available_bytes 5123456789
custom_disk_size_bytes{mountpoint="/"} 42949672960
custom_disk_available_bytes{mountpoint="/"} 219902325555
```

Строки `HELP` и `TYPE` документируют метрику. `gauge` — значение, которое может
как расти, так и уменьшаться. Метка `mountpoint="/"` уточняет, к какой
файловой системе относится размер диска.

Запись идёт во временный файл, затем он атомарно переименовывается. Поэтому
Nginx и Prometheus никогда не прочитают файл наполовину записанным.

## 4. Отдайте метрики через Nginx

Установите конфигурацию и проверьте её до перезагрузки:

```bash
sudo install -m 0644 nginx-metrics.conf /etc/nginx/sites-available/custom-metrics
sudo ln -sfn /etc/nginx/sites-available/custom-metrics /etc/nginx/sites-enabled/custom-metrics
sudo nginx -t
sudo systemctl reload nginx
curl http://localhost:8080/metrics
```

Последняя команда должна вывести те же метрики. В конфигурации выбран порт
`8080`, чтобы не конфликтовать со стандартным сайтом Nginx на порту `80`.

Если ответ `403 Forbidden`, проверьте права: файл должен быть читаемым для
пользователя Nginx. Скрипт уже устанавливает режим `0644`.

## 5. Включите обновление раз в 3 секунды

`cron` не умеет запускать задачи чаще раза в минуту, поэтому используем
`systemd timer`. Сервис однократно собирает данные, а таймер запускает его с
интервалом 3 секунды — чаще условие задания не допускает.

```bash
sudo install -m 0644 custom-node-metrics.service /etc/systemd/system/
sudo install -m 0644 custom-node-metrics.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now custom-node-metrics.timer
systemctl list-timers custom-node-metrics.timer
```

В таблице таймеров появится `custom-node-metrics.timer`, а в поле `LEFT` будет
порядка трёх секунд. Проверить последние запуски можно так:

```bash
sudo journalctl -u custom-node-metrics.service -n 10 --no-pager
stat /var/www/custom-metrics/metrics
```

## 6. Подключите Prometheus

Откройте `/etc/prometheus/prometheus.yml` и добавьте содержимое
`prometheus-custom.yml` в существующий раздел `scrape_configs:`. В итоговом
файле фрагмент должен быть вложен на том же уровне, что и другие `job_name`:

```yaml
scrape_configs:
  # другие задания могут быть выше
  - job_name: custom-node
    metrics_path: /metrics
    static_configs:
      - targets: ['localhost:8080']
```

Проверьте YAML и перезапустите Prometheus:

```bash
sudo promtool check config /etc/prometheus/prometheus.yml
sudo systemctl restart prometheus
```

Откройте `http://localhost:9090/targets`. Цель `custom-node` должна получить
состояние **UP**. На вкладке **Graph** выполните запросы:

```promql
up{job="custom-node"}
custom_cpu_usage_ratio
custom_memory_available_bytes
custom_disk_available_bytes{mountpoint="/"}
```

Первый запрос возвращает `1`, когда Prometheus может забрать метрики. Остальные
возвращают текущие значения. В настройке используется интервал сбора 15 секунд,
который обычно задан в `/etc/prometheus/prometheus.yml`; этого достаточно, так
как файл обновляется раз в 3 секунды. При необходимости можно поставить
`scrape_interval: 3s` у задания, но это не обязательно.

## Проверка изменений

В одном терминале выполните нагрузку на CPU на 20 секунд:

```bash
timeout 20s sh -c 'while :; do :; done'
```

В другом несколько раз запустите:

```bash
curl -s http://localhost:8080/metrics | grep custom_cpu_usage_ratio
```

Во время нагрузки значение будет заметно выше обычного. После её завершения оно
вернётся к низкому уровню. Конкретное число зависит от количества ядер и других
процессов на машине.

## Очистка (по желанию)

```bash
sudo systemctl disable --now custom-node-metrics.timer
sudo rm /etc/systemd/system/custom-node-metrics.service /etc/systemd/system/custom-node-metrics.timer
sudo rm /etc/nginx/sites-enabled/custom-metrics /etc/nginx/sites-available/custom-metrics
sudo rm -rf /usr/local/lib/custom-node-exporter /var/www/custom-metrics
sudo systemctl daemon-reload
sudo systemctl reload nginx
```

Перед удалением строки из `/etc/prometheus/prometheus.yml` сделайте резервную
копию конфигурации и затем перезапустите Prometheus.
