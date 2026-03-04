# Публикация на GitHub (пошагово, RU)

Ниже безопасный и быстрый сценарий публикации проекта в публичный GitHub-репозиторий.

## 1) Подготовка локальной папки

Открой терминал в проекте:

```bash
cd /Users/vp/Documents/NotesTransfer
```

Проверь, инициализирован ли git:

```bash
git rev-parse --is-inside-work-tree
```

Если получаешь `not a git repository`, выполни:

```bash
git init
```

## 2) Проверка перед первым `git add .`

Важно: в проекте могут быть локальные файлы, которые не стоит публиковать.

Проверь потенциальные секреты:

```bash
rg -n "(api[_-]?key|token|secret|password|BEGIN (RSA|OPENSSH|EC|PGP) PRIVATE KEY|sk-|ctx7sk-)" -S .
```

Проверь служебные/локальные файлы:

```bash
ls -la
```

Рекомендуется не публиковать:

- `chrome-tabs.md` (может содержать приватные URL/токены в query-параметрах)
- `.build/`
- `.DS_Store`
- любые экспортированные заметки и архивы (`notes-export`, `*.zip`)

Если нужно, добавь в `.gitignore` и удали из индекса:

```bash
echo "chrome-tabs.md" >> .gitignore
git rm --cached chrome-tabs.md 2>/dev/null || true
```

## 3) Первый коммит

```bash
git add .
git commit -m "chore: prepare project for public release"
```

## 4) Создание репозитория на GitHub

Создай пустой репозиторий, например `notes-matrix`:

- Visibility: `Public`
- Без авто-добавления README/.gitignore/LICENSE

## 5) Привязка remote и push

```bash
git branch -M main
git remote add origin git@github.com:<your-username>/notes-matrix.git
git push -u origin main
```

Если `origin` уже есть:

```bash
git remote set-url origin git@github.com:<your-username>/notes-matrix.git
git push -u origin main
```

## 6) Запретить push другим пользователям

GitHub -> `Settings` -> `Collaborators and teams`

- убедись, что write/admin доступ только у тебя.

GitHub -> `Settings` -> `Branches` -> `Add branch protection rule` для `main`:

1. Включи `Restrict who can push to matching branches`
2. Добавь только свой аккаунт
3. (Рекомендуется) `Require status checks to pass before merging`

## 7) Обновление README-бейджей

Замени плейсхолдеры:

```bash
GITHUB_USER="<your-username>"
REPO_NAME="notes-matrix"
sed -i '' "s|<your-username>|${GITHUB_USER}|g; s|<repo>|${REPO_NAME}|g" README.md
git add README.md
git commit -m "docs: configure README badges"
git push
```

## 8) Регулярный рабочий цикл

```bash
git status -sb
git add -A
git commit -m "feat: <short summary>"
git push
```

## 9) Быстрый pre-push чек

```bash
git status
git branch --show-current
git remote -v
git ls-files | rg -n "\\.DS_Store|\\.build/|chrome-tabs\\.md" || true
rg -n "(api[_-]?key|token|secret|password|BEGIN (RSA|OPENSSH|EC|PGP) PRIVATE KEY|sk-|ctx7sk-)" -S . || true
```

Ожидаемый результат:

- ветка `main`
- нет приватных токенов/ключей в tracked файлах
- нет `chrome-tabs.md`, `.build/`, `.DS_Store` в tracked-файлах
