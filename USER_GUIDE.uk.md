# StreamLens Go — Посібник користувача

**Мова:** [English](USER_GUIDE.md) | **Українська (ця сторінка)**

> Це повний український переклад [англійського user guide](USER_GUIDE.md).
> Якщо формулювання відрізняються, джерелом істини для поведінки й оцінювання є
> `PRD.md`.

Використовуйте цю сторінку перед вибором команди або відкриттям pull request.
Вона відокремлює публічний процес кандидата від приватного процесу оцінювання,
щоб кожна людина використовувала лише потрібний репозиторій і права доступу.

Публічний репозиторій завдання:
[`streamlens-performance-challenge`](https://github.com/YaroTanko/streamlens-performance-challenge).
Приватний репозиторій evaluator належить інтерв'юеру; кандидатам не потрібен
доступ до нього і вони не повинні запускати його самостійно. Це окрема вправа
Go: не поєднуйте її з Python-завданням і не подавайте одне рішення в обидва
репозиторії.

## Оберіть свій сценарій

| Ви… | З чого почати | Не використовуйте |
| --- | --- | --- |
| Кандидат, який виконує вправу | Розділ «Шлях кандидата» в цьому публічному репозиторії | Приватний репозиторій evaluator або команди лише для maintainers |
| Інтерв'юер, який перевіряє submission | Розділ «Шлях інтерв'юера» в цьому публічному репозиторії | Файли кандидата поза зафіксованою ревізією pull request |
| Maintainer, який підтримує assessment | Розділ «Шлях maintainer» у цьому репозиторії, потім приватний посібник evaluator | Candidate workflows, тести, скрипти або локальні незакомічені зміни як вхід assessment |
| Оператор evaluator | Приватний [`USER_GUIDE.md`](https://github.com/YaroTanko/streamlens-performance-evaluator/blob/main/USER_GUIDE.md) репозиторію evaluator | Ручну оцінку незаписаної або вгаданої ревізії |

## Шлях кандидата

### 1. Підготуйте чисту гілку

До сесії інтерв'юер передає повний 40-символьний `STARTER_SHA` — зазвичай commit
upstream `main` на початок сесії. `baseline-v3` не є стартом для кандидата:
це незмінна baseline для evaluator. Переданий SHA гарантує однаковий старт усіх
кандидатів, навіть якщо `main` зміниться пізніше.

Зробіть fork, клонування свого fork і створіть гілку submission від цього commit:

```sh
git clone https://github.com/<your-user>/streamlens-performance-challenge.git
cd streamlens-performance-challenge
git remote add upstream https://github.com/YaroTanko/streamlens-performance-challenge.git
git fetch upstream
STARTER_SHA=<full-sha-sent-by-the-interviewer>
git switch -c optimize-analyzer "$STARTER_SHA"
go version
```

Використовуйте Go 1.26.5, який вибирає `go.mod`. Необов'язковий pre-push hook
ловить прості локальні помилки, але не замінює CI:

```sh
git config core.hooksPath .githooks
```

Якщо `go version` не показує Go 1.26.5, зупиніться **до** запуску таймера й
попросіть інтерв'юера підготувати toolchain. Не змінюйте `go.mod` або директиву
toolchain як обхідний шлях.

30-хвилинний таймер запускається лише після готовності чистого checkout і
потрібного Go toolchain. Він закінчується на 30:00 або після запису SHA фінального
локального commit — залежно від того, що настане раніше. Push, створення PR, час
у черзі CI та читання результату не входять у час вправи.

### 2. Прочитайте контракт і виміряйте baseline

Читайте файли в такому порядку:

1. [`TASK.md`](TASK.md) — scope, час, правила та scoring.
2. [`PRD.md`](PRD.md) — спостережувана поведінка та джерело істини.
3. [`DESIGN.md`](DESIGN.md) — інваріанти, які потрібно зберегти.
4. [`AGENTS.md`](AGENTS.md) — інструкції для AI coding assistant.
5. [`PROFILING.md`](PROFILING.md) — локальні команди профілювання.

До вибору оптимізації виконайте стартові перевірки:

```sh
make check
make benchmark
make profile-cpu
make profile-alloc
```

Профіль допомагає сформувати гіпотезу: benchmark показує, чи стала зміна швидшою,
а профіль — чому це могло статися. Можна використовувати інший profiler, але
в notes потрібно чесно записати фактичне спостереження.

### 3. Зробіть submission

Змініть рівно два файли:

```text
internal/analyzer/engine.go
OPTIMIZATION.md
```

Для assessment v3 файл `engine.go` також має лишатися в безпечній підмножині
стандартної бібліотеки з `TASK.md`. Не додавайте до analyzer доступ до файлової
системи, процесів, `unsafe`, розпізнавання benchmark, прямий вивід або глобальні
керування runtime. Інструменти профілювання поза цим файлом дозволені.

Замініть шаблон optimization notes на 5–10 стислих bullets. Додайте правдивий
непорожній bullet `Profile evidence:` з назвою команди або інструмента та
виявленим hotspot.

Перед commit повторіть перевірки й перегляньте точний diff submission:

```sh
make check
make benchmark
make profile-cpu
git diff --check
git diff --name-only "$STARTER_SHA"...HEAD
```

Остання команда має показати лише два дозволені шляхи. Потім закомітьте зміни,
запишіть повний SHA до завершення таймера і виконайте push:

```sh
git add internal/analyzer/engine.go OPTIMIZATION.md
git commit -m "Optimize event analysis"
git rev-parse HEAD
git push -u origin optimize-analyzer
```

Відкрийте pull request з цієї гілки до `main` цього репозиторію. Тримайте PR
чернеткою під час підготовки; позначте **Ready for review** лише після push
записаного commit. Заповніть pull-request template.

### 4. Правильно прочитайте результат

Для PR у стані ready публічний workflow автоматично перевіряє scope і source
policy за закоміченими даними, запускає correctness checks і порівняльні
benchmarks, збирає діагностичні profiles та запускає private evaluator. Кандидат
не запускає private evaluator самостійно.

| Що ви бачите | Що це означає | Наступна дія |
| --- | --- | --- |
| Помилка protected scope або source policy | Commit змінив заборонений шлях або використовує заборонену v3-конструкцію | Виправте лише два дозволені файли, створіть нову ревізію та виконайте push до завершення таймера, якщо це ще можливо |
| Не пройдено functional tests | Змінено спостережуваний контракт | Виправте implementation і перевірте його локально |
| Валідний scored result нижче target | Assessment відпрацював правильно, але performance gate не досягнуто | Обговоріть результат з інтерв'юером; це не infrastructure error |
| Помилка canary, image, evidence або private dispatch | Assessment infrastructure не завершилася | Повідомте інтерв'юера; не змінюйте код лише для повтору infrastructure |
| Для першого fork потрібне approval | GitHub очікує дію maintainer | Повідомте інтерв'юера; час approval не входить у таймер |

CI є авторитетним: він порівнює незмінну `baseline-v3` з вашою точною
закоміченою ревізією. Локальні вимірювання мають лише орієнтовний характер.

## Шлях інтерв'юера

### Підготуйте сесію

До запуску таймера отримайте актуальний публічний `main`, запишіть його SHA як
`STARTER_SHA` і надішліть той самий SHA усім кандидатам:

```sh
git fetch origin main
git rev-parse origin/main
```

Переконайтеся, що доступний Go 1.26.5 і checkout кандидата чистий. Таймер
починається лише після цих перевірок; наступний commit у `main` не повинен
змінити стартову точку кандидата.

### Одноразове налаштування

Налаштуйте secret `PRIVATE_EVALUATOR_DISPATCH_TOKEN`. Це fine-grained token,
обмежений `YaroTanko/streamlens-performance-evaluator`, з **Actions: Read and
write**. Contents write permission не потрібен.

```sh
gh secret set PRIVATE_EVALUATOR_DISPATCH_TOKEN \
  --repo YaroTanko/streamlens-performance-challenge
```

Не передавайте token кандидатам і не розміщуйте його у файлах, якими керує
кандидат.

### Для кожного candidate PR

1. Переконайтеся, що кандидат використовує fork і змінює лише
   `internal/analyzer/engine.go` та `OPTIMIZATION.md`.
2. Попросіть кандидата позначити PR як ready. Чернетка навмисно не запускає
   assessment.
3. Якщо GitHub просить approval для first-time contributor, схваліть публічний
   workflow. Це дія інтерв'юера, а не робота кандидата.
4. Прочитайте public job summary та artifact. До читання performance tier
   підтвердьте scope/source preflight, functional checks, isolation canary і
   profile capture.
5. Відкривайте автоматично запущений private evaluator лише коли потрібні його
   додаткові докази. Не просіть кандидата доступ до private repository.
6. Перегляньте точний diff, `OPTIMIZATION.md`, benchmark report і profiles. Tier
   є доказом, але не самостійним hiring decision.

Якщо метрика перебуває в межах двох відсоткових пунктів від межі tier, один раз
повторіть запуск для того самого SHA і використайте нижчий неузгоджений результат,
як визначено в `PRD.md`. Не просіть кандидата змінювати код або notes для такого
повторного запуску.

## Шлях maintainer

Використовуйте цей шлях лише для підтримки assessment, а не для candidate
submission.

- Активна версія assessment — 3. `baseline-v3` незмінна; workflow фіксує її
  повний SHA та Go container, зафіксований digest.
- Зміна workload, source policy, tests, benchmark tooling або runtime contract
  потребує нової assessment version і нової незмінної baseline. Не редагуйте ці
  файли у candidate PR.
- Для локального end-to-end assessment використовуйте `make assess` з двома
  чистими точними Git checkout і потрібними SHA input. Див. **Maintainer
  assessment entry point** у [`README.md`](README.md); потрібні Docker і pinned
  image.
- Перед активацією нової версії виконайте calibration і real-runtime canary з
  [`CALIBRATION.md`](CALIBRATION.md).
- Для ручної переоцінки та роботи з private evidence використовуйте приватний
  [`USER_GUIDE.md`](https://github.com/YaroTanko/streamlens-performance-evaluator/blob/main/USER_GUIDE.md)
  evaluator.

## Правила для всіх

- Вважайте `PRD.md` джерелом істини для продукту та assessment.
- Не запускайте на trusted host workflows, tests, scripts або generated files,
  якими керує кандидат.
- Працюйте з точними закоміченими SHA, а не з незакоміченим working tree.
- Тримайте доступ кандидата публічним і мінімальним, а evidence та tokens
  evaluator — приватними.
