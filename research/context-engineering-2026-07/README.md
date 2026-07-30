# Контекст-инжиниринг для моделей Claude 5 — подборка (июль 2026)

**Собрано:** 2026-07-25.
**Повод:** 24 июля 2026 вышел Claude Opus 5, и в тот же день Anthropic опубликовал разбор
«новые правила контекст-инжиниринга». Ключевой факт: **из системного промпта Claude Code
убрали больше 80% текста — без потери качества**. Это меняет то, как надо писать мозг агента.

**Что такое контекст-инжиниринг (одной фразой).** Модель видит не только твоё сообщение.
Она видит системный промпт, CLAUDE.md, описания скиллов, память, вывод инструментов.
Контекст-инжиниринг — искусство собрать этот набор так, чтобы нужное было под рукой,
а ненужное не мешало. Аналогия: это не «написать инструкцию сотруднику», а «разложить
рабочий стол» — что лежит всегда на виду, что в ящике, что в архиве на полке.

## Источники

Отсортировано по свежести. «Свежесть» — насколько источник учитывает поколение Claude 5.

| # | Источник | Дата | Свежесть | Конспект |
|---|---|---|---|---|
| 1 | [The new rules of context engineering for Claude 5 generation models](https://claude.com/blog/the-new-rules-of-context-engineering-for-claude-5-generation-models) | 2026-07-24 | 🟢 опорный | [01](01-new-rules-context-engineering.md) |
| 2 | [How to write effective AI agent skills: 6 data-backed practices](https://arize.com/blog/how-to-write-effective-ai-agent-skills/) (Arize, не Anthropic) | 2026-07-24 | 🟢 цифры | [02](02-skills-empirics-skillsbench.md) |
| 3 | [Building verification loops in Claude Code with skills](https://claude.com/blog/building-verification-loops-in-claude-code-with-skills) | 2026-07-22 | 🟢 | [03](03-verification-loops.md) |
| 4 | [A field guide to Claude Fable 5: Finding your unknowns](https://claude.com/blog/a-field-guide-to-claude-fable-finding-your-unknowns) | 2026-07-06 | 🟢 | [06](06-secondary-sources.md) |
| 5 | [Claude Code docs — Best practices](https://code.claude.com/docs/en/best-practices) | живой документ | 🟢 | [04](04-docs-best-practices.md) |
| 6 | [Claude Code docs — Memory (CLAUDE.md + auto memory)](https://code.claude.com/docs/en/memory) | живой документ | 🟢 | [04](04-docs-best-practices.md) |
| 7 | [Claude Code docs — Skills](https://code.claude.com/docs/en/skills) | живой документ | 🟢 | [05](05-docs-skills.md) |
| 8 | [Steering Claude Code: when to use CLAUDE.md, skills, hooks, and subagents](https://claude.com/blog/steering-claude-code-skills-hooks-rules-subagents-and-more) | 2026-06-18 | 🟡 до Opus 5, но таблица выбора актуальна | [06](06-secondary-sources.md) |
| 9 | [A harness for every task: dynamic workflows in Claude Code](https://claude.com/blog/a-harness-for-every-task-dynamic-workflows-in-claude-code) | 2026-06-02 | 🟡 | [06](06-secondary-sources.md) |

**Сознательно НЕ взято как опора** (старше поколения Claude 5, читать с поправкой):

- [Effective context engineering for AI agents](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) — 2025-09-29. Фундамент понятия, но написан под старые модели.
- [Prompt engineering best practices](https://claude.com/blog/best-practices-for-prompt-engineering) — 2025-11-10. Советует «давай примеры» — статья №1 это прямо отменяет для новых моделей.
- [Equipping agents for the real world with Agent Skills](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills) — 2025-10-16.

Раздел «Engineering» на anthropic.com за последние 3 месяца по нашей теме публикаций
не давал — свежее живёт в блоге `claude.com/blog` и в документации.

## Выводы

- **[PRINCIPLES.md](PRINCIPLES.md)** — 12 принципов описания мозга агента, выведенных
  из этих источников. Каждый принцип: формулировка → откуда → как проверить.
- **[GAP-ANALYSIS.md](GAP-ANALYSIS.md)** — честный разбор нашего мозга по этим принципам:
  где совпало, где мы впереди, где дыры.

## Перенос в другой проект

Подборка переносимая: скопировать папку `research/` в другой проект и запустить там
[`ЗАПУСК-ДИАГНОСТИКИ.md`](ЗАПУСК-ДИАГНОСТИКИ.md) — шесть фаз от чтения первоисточников
до решения, что прорабатывать. Принципы там оцениваются **заново, с правом их оспорить**:
они выведены под агента с контрактом безопасности и другому проекту могут не подойти.

## Дисциплина применения

Ни один принцип отсюда не правит персону автоматически. Порядок: принцип → разбор
(`GAP-ANALYSIS.md`) → **ADR в `decisions/`** → правка ядра/references через `/dev`.
Чужая статья — вход, не истина.
</content>
