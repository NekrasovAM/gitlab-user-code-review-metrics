# GitLab User Code Review Metrics
### Подсчёт количества уникальных MR, в которых был оставлены комментарии, как метрика "Количество проведённых ревью" за указанный период для выбранных пользователей.


Стек: Bash<br>
Среда запуска: Linux / MacOS / WSL<br>
Утилиты: git, curl<br>

*Ubuntu / Debian*

```bash
sudo apt install -y git
```
```bash
sudo apt install -y curl
```

## Установка и запуск

```bash
git clone https://github.com/NekrasovAM/gitlab-user-code-review-metrics.git
```

```bash
cd users-gitlab-metrics
```

```bash
chmod +x ./count_mrs_reviews.sh
```

1. Cоздать персональный токен (https://mygitlabdomain.domain-com/-/user_settings/personal_access_tokens,) с правами доступа `read_api`, `read_user` и `read_repository` и скопировать его.
2. Переименовать (копировать) файл `config.env.dist` в `config.env`.
3. Отредактировать файл `config.env`: в значении `API_TOKEN` вставить скопированный токен и сохранить файл конфигурации.
4. [Опционально] В файле `users.txt` указать список пользователей GitLab, по которым нужна выгрузка.
5. [Опционально] В файле `config.env` укзать значения ключей `DATE_FROM` и `DATE_TO`, если планируется запуск без аргументов.

#### Запуск по одному пользователю с аргументами
```bash
./count_mrs_reviews.sh 2025-01-01 2025-09-09 UserName1
```

#### Запуск по нескольким пользователям с аргументами
```bash
./count_mrs_reviews.sh 2025-01-01 2025-09-09 UserName1 UserName2 UserName3
```

#### Запуск по нескольким пользователям без аргументов с указанием даты

Добавить UserName пользователей GitLab, по которым нужна выгрузка, в файл `users.txt` с разделенем в виде переноса строки.

*users.txt*
```
UserName1
UserName2
UserName3
```

```bash
./count_mrs_reviews.sh 2025-01-01 2025-09-09
```


#### Запуск без аргументов

1. Необходимо, чтобы в файле `config.env` были заданы ключи `DATE_FROM` и `DATE_TO`.
2. Необходимо, чтобы в файле `users.txt` было не менее 1 UserName пользователя GitLab.

*config.env*
```
DATE_FROM="2025-01-01"
DATE_TO="2025-09-09"
```

```bash
./count_mrs_reviews.sh
```

#### Результаты

Полученный результаты будут сохранены в директории со скриптом в папке `results` отдельно по каждому пользователю в формате `UserName-DATE_FROM-DATE_TO.txt` .<br>
В случае повторного запуска с теми же параметрами, старый файл с результатами будет перезаписан.

#### Условия подсчёта ревью уникальных Merge Requests

По-умолчанию подсчёт уникальных Merge Requests выполняется по комментариям пользователя.<br>
Включить (в дополнение) в подсчёт по `Approved merge request` в MR, где нет комментариев через флаг в `config.env`:

```
COUNT_APPROVE_WITHOUT_COMMENTS="TRUE"
```