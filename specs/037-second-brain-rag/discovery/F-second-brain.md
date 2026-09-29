# Informe F — El método Second Brain (Tiago Forte) con precisión suficiente para diseñar 037

Fecha: 25-09-2026. Autor: subagente de discovery (solo lectura del repo; ninguna edición).
Insumos: `second-brain-digest.md` (resumen Bookey del libro, entregado por el operador) + fuentes web
primarias de Forte (fortelabs.com, cuenta @fortelabs) + fuentes de practicantes y críticos. Los
informes A-E de este directorio se usan como contexto ya resuelto; no se repiten aquí.

Leyenda de verificación (regla 01 del operador):

- **[HV]** hecho verificado: leído en la URL citada (vía WebFetch) o en el digest del operador.
- **[SEC]** fuente secundaria: resumen de terceros del libro (el libro no es fetchable); se cita
  el resumen, no el libro.
- **[INF]** inferencia propia, marcada como tal.
- **[NV]** no verificado: no pude localizar la fuente primaria; se declara el hueco.

Fechas en prosa `DD-MM-YYYY`; el año de publicación de cada fuente sale de la propia página.

---

## 0. Resumen ejecutivo

- **PARA se define por dos tests operables, no por temas** [HV]: un *proyecto* tiene "1) a desired
  outcome that will enable you to mark it 'complete,' and 2) a deadline or timeframe"; un *área*
  tiene "1) a standard to be maintained that 2) is continuous over time"; un *recurso* es un tema de
  interés "where you don't have the responsibility to maintain a standard" [SEC]; *archivo* es
  "anything from the previous three categories that is no longer active". El filing es una cascada
  proyecto → área → recurso → archivo/no guardar, y la regla dura es **nunca duplicar**: mover,
  enlazar o etiquetar [SEC, libro 2023].
- **CODE tiene tres reglas mecanizables y una que no lo es**: capturar sólo una fracción y **no
  organizar al capturar** (bandeja); destilar en capas oportunistas con un presupuesto decreciente
  (50 % → 25 % → 20 % → 5 % → <1 % del original, [HV] PS III); expresar en paquetes intermedios
  reutilizables. La que no se mecaniza es el criterio de captura: **resonancia** ("that resonates
  with me"), que Forte define explícitamente como intuición afectiva previa al análisis [HV].
- **Cadencias verificadas** [HV]: weekly review de 5 pasos (email, calendario, escritorio/descargas,
  notas, tareas; 30 min; "one-touch": decidir, no hacer); monthly review (metas, lista de proyectos,
  áreas, someday/maybe, reprioritizar; ~17 min). Los checklists de kickoff/cierre de proyecto existen
  en el libro (cap. 9) y en resúmenes [SEC]; **no encontré** un post primario en fortelabs.com que los
  enumere [NV].
- **Qué puede hacer un agente solo**: aplicar los tests PARA y la cascada; mantener la lista de
  proyectos; archivar por estado; computar la cola de revisión por horizonte; ejecutar kickoff/cierre
  como operaciones; contar capas y presupuestos de destilación; producir paquetes al final de cada
  sesión. **Qué queda en el humano**: la resonancia, la autoría de los favorite problems, la zona
  gris proyecto/área, la decisión de cerrar o pausar un proyecto, y "noticing" (Forte, 13-04-2026:
  lo que la IA aún no hace es "reminding you of what's important and what actions need to be taken").
- **Tensión PARA (acción) vs wiki por tipo (Karpathy)**: es real y está documentada por ambos lados
  (Sascha, zettelkasten.de: "hierarchy of urgency" vs "hierarchy-free network"; Milo: "over half the
  time I don't know what exactly I'm thinking about"). La resolución que usan los practicantes es
  consistente: **una sola casa por nota (por tipo o por PARA), el otro eje en metadatos
  (status/tags/propiedades) y vistas derivadas** (MOC, Dataview, PARA-Tree). Forte mismo lo avala:
  tags "tunnel through the walls of our siloed folders" y se etiqueta **por acción/estado, no por
  concepto** [HV].
- **Críticas a evitar por diseño**: collector's fallacy (guardar ≠ saber); progressive summarization
  "is merely preparing resources so that they are easier to skim" (procesar es otra cosa); Resources
  como cajón de sastre; churn de mover archivos al cambiar prioridades; sobre-anidamiento; y el
  reconocimiento honesto de que "PARA organizes, it does not capture or use".

---

## 1. Fuentes leídas y qué verificó cada una

| # | Fuente | Fecha pub. (según la página) | Qué aporta |
|---|---|---|---|
| F1 | https://fortelabs.com/blog/para/ | 24-02-2023, act. 15-04-2026 | Definiciones de las 4 categorías; "organize by actionability"; sección "Can AI Organize Your Files According to PARA?" |
| F2 | https://fortelabs.com/blog/project-people-vs-area-people-are-you-running-a-sprint-or-a-marathon/ | 11-07-2022 | Test proyecto vs área (verbatim), pares de ejemplo, dos modos de falla |
| F3 | https://fortelabs.com/blog/basboverview/ | 01-05-2023 | CODE, "save anything that resonates", pregunta de filing "what project would this be useful for?" |
| F4 | https://fortelabs.com/blog/progressive-summarization-a-practical-technique-for-designing-discoverable-notes/ | 27-12-2017, act. 16-05-2023 | Capas 0-5 verbatim; "opportunistically"; discoverability vs understanding |
| F5 | https://fortelabs.com/blog/progressive-summarization-iii-guidelines-and-principles/ | 28-12-2017, act. 10-06-2022 | Porcentajes por capa; 4 guías; "More summarization is not better" |
| F6 | https://fortelabs.com/blog/progressive-summarization-vi-core-principles-of-knowledge-capture/ | 03-07-2018, act. 10-06-2022 | 7 principios de captura ("opportunistic compression", "intuition over analysis") |
| F7 | https://fortelabs.com/blog/just-in-time-pm-4-intermediate-packets/ | 20-05-2018, act. 10-06-2022 | Definición de IP, 5 beneficios, "Lego pieces" |
| F8 | https://fortelabs.com/blog/intermediate-packets-in-the-wild/ | 26-09-2021 | Ejemplos por dominio; **no** hay tipología formal |
| F9 | https://fortelabs.com/blog/12-favorite-problems-how-to-spark-genius-with-the-power-of-open-questions/ | 26-09-2022 | Cita de Feynman; uso como filtro |
| F10 | https://fortelabs.com/blog/how-to-generate-your-own-favorite-problems-a-4-step-guide/ | 04-10-2022 | 4 pasos; criterios de una buena pregunta |
| F11 | https://fortelabs.com/blog/the-one-touch-guide-to-doing-a-weekly-review/ | 19-05-2020, act. 03-05-2022 | Weekly review de 5 pasos; 30 min; "one-touch"; qué no hacer |
| F12 | https://api.fxtwitter.com/fortelabs/status/1705598082509906157 (tweet @fortelabs) | 23-09-2023 | "My 5-point Weekly Review checklist" verbatim |
| F13 | https://fortelabs.com/blog/the-weekly-review-is-an-operating-system/ | 26-05-2017, act. 06-05-2021 | Versión antigua de 7 pasos (evidencia de que el checklist evolucionó) |
| F14 | https://fortelabs.com/blog/the-design-of-a-weekly-review/ | 17-09-2018, act. 06-05-2021 | Principios de diseño de una revisión (frecuencia por tasa de cambio, "resistance as feedback") |
| F15 | https://fortelabs.com/blog/the-monthly-review-is-a-systems-check/ | 30-11-2017, act. 06-05-2021 | Pasos de la monthly review; ~17 min |
| F16 | https://fortelabs.com/blog/a-complete-guide-to-tagging-for-personal-knowledge-management/ | 09-01-2019, act. 31-01-2020 | Folders primero; tags por acción/estado; fallas del tagging |
| F17 | https://fortelabs.com/blog/how-to-implement-para-in-your-favorite-notetaking-app/ | 23-10-2023, act. 18-12-2024 | Índice de videos (Obsidian: John Mavrick; Notion: Marie Poulin); sin reglas propias |
| F18 | https://fortelabs.com/blog/the-10-principles-of-building-a-second-brain/ | 24-07-2019, act. 23-04-2021 | 10 principios ("Projects Over Categories", "Make it Easier for Your Future Self") |
| F19 | https://fortelabs.com/blog/12-steps-to-build-a-second-brain/ | 05-05-2022, act. 14-09-2022 | Orden de adopción; "Schedule a Weekly Review" |
| F20 | https://fortelabs.com/blog/mise-en-place-for-knowledge-workers/ | 28-06-2021, act. 17-08-2021 | 6 prácticas de "working clean" (placeholders, finishing mindset) |
| F21 | https://fortelabs.com/blog/why-para-is-the-key-to-the-ai-era/ | 13-04-2026 | PARA como "minimum viable context" para LLMs; qué queda humano |
| F22 | https://api.fxtwitter.com/fortelabs/status/2022679961845313968 (tweet @fortelabs) | 14-02-2026 | Claude Code sobre su carpeta PARA → "Master Prompt" de 10 secciones |
| F23 | https://fortelabs.com/blog/introducing-the-ai-second-brain/ | 13-03-2026 | Postura de Forte sobre IA: "think more clearly and make better decisions", no autonomía |
| F24 | https://fortelabs.com/blog/para-for-teams/ (Nat Eliason) y https://fortelabs.com/blog/team-knowledge-management-how-to-use-para-in-your-organization/ | 12-11-2018 / 13-03-2023 | Consultadas para localizar citas; **no** contienen las frases buscadas (ver §7) |
| S1 | https://briansunter.com/building-a-second-brain | s/f | [SEC] checklists kickoff/cierre, reviews, 4 preguntas de captura, cascada PARA |
| S2 | https://walterteng.com/building-a-second-brain | s/f | [SEC] IP: "distilled notes, outtakes, work-in-progress or even final deliverables from older projects" |
| S3 | https://thomasjfrank.com/productivity/books/the-para-method-by-tiago-forte-summary-and-book-notes/ | s/f | [SEC] libro *The PARA Method* (2023): setup en 60 s, 3 hábitos, weekly maintenance, "never duplicate", consistencia entre plataformas |
| S4 | digest del operador (`second-brain-digest.md`) | 22-09-2026 | [SEC] Bookey del libro BASB: cap. 5-9 (PARA, PS 4 capas, 5 tipos de IP, hábitos) |
| P1 | https://zettelkasten.de/posts/collectors-fallacy/ (Christian Tietze) | 20-01-2014 | Collector's fallacy: definición y remedios |
| P2 | https://zettelkasten.de/posts/building-a-second-brain-and-zettelkasten/ (Sascha) | 26-06-2023 | Crítica ZK a BASB/PARA/PS y combinación propuesta |
| P3 | https://forum.obsidian.md/t/the-ultimate-folder-system-a-quixotic-journey-to-ace/63483 (Nick Milo) | 20-07-2023 | Crítica a PARA; ACE (Atlas/Calendar/Efforts) |
| P4 | https://blog.linkingyourthinking.com/notes/the-four-intensities-of-efforts (Milo) | (c) 2025 | Efforts: On / Ongoing / Simmering / Sleeping |
| P5 | https://forum.obsidian.md/t/taking-advantage-of-orderly-para-and-chaotic-zettelkasten-methodologies-simultaneously/47786 | 11-2022 a 07-2023 | Prácticas híbridas (ZK dentro de Resources, #inbox + Dataview, MOC-as-category) |
| P6 | https://osgav.run/blog/para-zettelkasten-conclusion.html | 21-04-2021 | "Can the R of my P.A.R.A. be my Zettelkasten? Yes." |
| P7 | https://mattgiaro.com/para-method-and-zettelkasten/ y https://mattgiaro.com/para-method-alternatives/ | s/f | Debilidades de PARA (mover archivos, templates, fronteras difusas) |
| P8 | https://evakeiffenheim.substack.com/p/the-fatal-flaw-in-most-personal-knowledge | 30-06-2025 | Collector's fallacy aplicada a Second Brain; "digital graveyard" |
| P9 | https://www.obsibrain.com/blog/obsidian-para-method-setup | 05-06-2026 | Folders = casa; tags = status/type; "0 Inbox"; anti-anidamiento |
| P10 | https://github.com/byarbrough/obsidian-para | s/f | Plantilla Obsidian: un solo nivel bajo cada carpeta PARA; archivo por carpeta fechada |
| P11 | https://community.obsidian.md/plugins/para-tree | s/f | PARA por frontmatter: `type`, `area`, `status`, `cadence`, `goal`, `next-action`, `project` |
| P12 | https://www.iwoszapar.com/p/para-method | 03-07-2026 | "Finish line test", "weekly move-down pass", "lazy population", 4 puntos de quiebre |
| P13 | https://zainrizvi.io/blog/remembering-what-you-read-zettelkasten-vs-para/ | 09-05-2020, act. 01-2022 | Contra-ejemplo: prefiere PARA+PS a ZK ("80 % con 20 % del esfuerzo") |

Bloqueadas: los cuatro `medium-*.html` de este directorio son páginas "Attention Required | Cloudflare"
(verificado con `grep '<title>'`), no contenido. No se usaron.

---

## 2. Definiciones canónicas (con cita y URL)

### 2.1 Las cuatro categorías de PARA

| Categoría | Definición verbatim | Fuente |
|---|---|---|
| Projects | "short-term efforts (in your work or personal life) that you take on with a certain goal in mind" | F1 [HV] |
| Areas | "important parts of your work and life that require ongoing attention" | F1 [HV] |
| Resources | "topics you're interested in and learning about" (F1); "Topics and interests you have, where you don't have the responsibility to maintain a standard" (libro 2023 vía S3) | F1 [HV], S3 [SEC] |
| Archives | "anything from the previous three categories that is no longer active, but you might want to save" | F1 [HV] |

Principio rector [HV, F1]: "Instead of organizing information according to broad subjects like in
school, I advise you to organize it according to the projects and goals you are committed to right
now. This is what it means to 'organize by actionability'". Gradiente de accionabilidad [SEC, S3]:
proyectos los más accionables, áreas menos, recursos apenas, archivo nada "until reactivated".

### 2.2 El test proyecto vs área (la pieza más mecanizable del método)

Verbatim [HV, F2, 11-07-2022]:

> "A project is any endeavor that has 1) a desired outcome that will enable you to mark it
> 'complete,' and 2) a deadline or timeframe by which you'd like it done."
>
> "An area of responsibility has 1) a standard to be maintained that 2) is continuous over time."

Pares de ejemplo [HV, F2]: marathon / Health; publishing a book / Writing; saving 3 months' expenses /
Finances; vacation to Thailand / Travel; anniversary dinner / Spouse.

Dos modos de falla [HV, F2]: tratar un proyecto como área ("writing a book in 30 minutes a day" →
"it will feel like it's taking forever with no discernible progress"); tratar un área como proyecto
("lose 10 pounds as a one-time goal" → "revert right back… because you didn't put in place any
mechanism for maintaining that new standard").

Reformulación de practicante, útil como predicado [HV, P12]: "if you can imagine crossing it off and
feeling done, it is a Project. If crossing it off feels wrong because the work simply continues, it
is an Area." (**finish line test**).

### 2.3 La pregunta de filing (cascada)

- Primaria [HV, F3]: la pregunta principal de filing es "what project would this be useful for?".
- Cascada completa, atribuida al libro [SEC, S1]: "In which project will this be most useful? If
  none: In which area? If none: Which resource? If none: Place in archives." Un resumen de búsqueda
  la reprodujo con la coda "or not save it at all"; **no localicé la URL primaria** de esa coda [NV].
- Fundamento de por qué las notas de proyecto se revisan más [SEC/NV]: la frase "designed to
  facilitate forwarding knowledge through time" (proyecto = horizonte corto; área = revisión menos
  frecuente; recurso = "if and when"; archivo = "cold storage") aparece atribuida a Forte en un
  resumen de búsqueda y coincide con el libro BASB cap. 5 según mi recuerdo, pero **no la encontré
  en F1, F24 ni en otra página de fortelabs.com** [NV]. Se usa aquí como inferencia razonable, no
  como cita.

### 2.4 Movimiento entre categorías

- Verificado [HV, F1]: el archivo recibe "Projects you've completed or put on hold" y "Areas that are
  no longer active". F1 **no** describe un flujo sistemático.
- Libro 2023 [SEC, S3]: cuatro formas de mover, "move items to different folders, move entire
  folders, link items together, or use tags" y la regla "never duplicating items".
- Practicante [HV, P9]: "notes shift from Resources into Projects when work begins, and completed
  projects move into Archives"; la weekly review lo formaliza: "Drag any finished project folder into
  `4 Archives`".
- Practicante [HV, P12] (**weekly move-down pass**): "Once a week, glance at Projects. Anything
  finished slides to Archives. Anything that turned out to be ongoing becomes an Area."

### 2.5 CODE y los criterios de captura

- CODE [HV, F3]: Capture (save resonant ideas), Organize (by actionability), Distill (progressive
  summarization), Express (tangible output / intermediate packets).
- Criterio de captura primario [HV, F3 y F6]: "save anything that resonates with you on an intuitive
  level"; F6 lo eleva a principio: "Intuition over analysis". Una búsqueda en fortelabs.com devolvió
  la formulación "The best rule of thumb is not to set out explicit decision criteria for what you
  keep. Instead, use resonance as your criteria" [HV vía snippet de búsqueda; página no abierta].
- Las cuatro preguntas del libro [SEC, S1 y S4]: "Does it inspire me? Is it useful? Is it personal?
  Is it surprising?"
- Fracción a capturar: el digest dice "capturar una FRACCIÓN del original (excerpts)" [SEC, S4]; F6
  no da porcentaje [HV]. El "10 %" que a veces se atribuye a Forte **no lo encontré** en fuente
  primaria [NV].
- Separar captura de organización [SEC, S4; HV, S3 "Create an inbox as default capture destination";
  HV, P9 "0 Inbox"].

### 2.6 Progressive Summarization: capas y porcentajes

Capas verbatim [HV, F4]:

| Capa | Qué es (Forte) |
|---|---|
| 0 | Fuente original completa |
| 1 | "I just capture anything that feels insightful, interesting, or useful." |
| 2 | "I bold only the best parts of the passages I've imported" |
| 3 | "I switch to highlighting… for 'the best of the best'" |
| 4 | "I summarize layers 2 and 3 in an informal executive summary at the top of the note, restating the key points in my own words." |
| 5 | "I remix them" — algo nuevo (post, sketch, video) |

Cuándo [HV, F4]: "opportunistically"; "I do this bolding layer at a later time, when I'm already
reviewing this note anyway" — cada capa se agrega "only when I'm already reviewing the note anyway".
F6 lo nombra "Opportunistic compression": "add value to our notes every time we touch them".

Presupuesto por capa [HV, F5]: 50 % de lo consumido llega a capa 1; 25 % del original a capa 2;
20 % del original a capa 3; 5 % a capa 4; <1 % a capa 5. (**La regla "10-20 %" que menciona el
encargo no aparece así**; lo que Forte publica es esta escalera 50/25/20/5/<1 [NV para "10-20 %"].)

Cuatro guías [HV, F5]: (1) "Don't apply all layers to all notes"; (2) "Use resonance as your
criteria"; (3) "Design a system for the laziest version of yourself"; (4) "Keep your notes
glanceable". Frase rectora: "More summarization is not better. Instead, you want to calibrate the
amount of attention… to correspond with how valuable that note is." Tensión declarada [HV, F4]:
"The two priorities we are trying to balance are discoverability and understanding… you cannot
compress something without losing some of its context."

### 2.7 Intermediate Packets

- Definición [HV, F7]: "Instead of delivering one big lump of value at the very end, you stage your
  progress in a series of short, intense sprints, ending each one with a tangible, intermediate
  deliverable, like a set of notes, a brainstorm, a series of examples, an outline, a prototype, or a
  draft."
- Cinco beneficios [HV, F7]: interruption-proof; more frequent feedback; create value in any time
  span; less intimidating projects; reuse ("snapping together existing packets, like Lego pieces").
- Tipología de 5 tipos (distilled notes, outtakes, work-in-process, final deliverables, documents
  created by others): está en el **libro** cap. 7 [SEC, S4; S2 confirma cuatro de los cinco]. **Los
  posts primarios F7 y F8 no la enumeran** [HV]; F8 da ejemplos por dominio (module, prototype,
  demo, storyboard, wireframe).
- Reglas de nombre/almacenamiento: **ninguna** en F7/F8 [HV]. Sólo "keep all packets in your Second
  Brain" y la reutilización como ensamblaje.

### 2.8 12 Favorite Problems

- Cita de Feynman [HV, F9]: "You have to keep a dozen of your favorite problems constantly present in
  your mind, although by and large they will lay in a dormant state. Every time you hear or read a new
  trick or a new result, test it against each of your twelve problems to see whether it helps."
- Definición de Forte [HV, F10]: "an open-ended question you use to prime your subconscious to notice
  potential answers in the information you're consuming".
- Los 4 pasos [HV, F10]: (1) prompts de arranque (obsesiones de infancia, hobbies largos, patrones
  recurrentes, historias que conmueven, hacia dónde divaga la mente); (2) formular preguntas
  "How/What" ("can't be answered with a simple yes or no"); (3) hacerlas **specific,
  counter-intuitive, or cross-disciplinary** ("The best open questions have an element of surprise");
  (4) "Start capturing information relevant to your favorite problems" — usarlas como filtro.
- Uso y mantención [HV, F9/F10, F19]: guardar la lista como una nota; "revisit it any time you need
  ideas for what to capture"; deben evolucionar con los intereses; no hay cadencia fija de revisión
  [HV: F10 no la da]. F19 paso 5: "Use these open-ended questions as a filter to decide which content
  is worth keeping."

### 2.9 Weekly y monthly review

Weekly, versión vigente [HV, F12 tweet 23-09-2023, idéntica a F11]:

1. "Email: Clear inbox & capture new tasks or notes"
2. "Calendar: Review upcoming week for new tasks or notes" (F11 precisa: -2 semanas atrás / +4 adelante)
3. "Desktop/Downloads: Clear these folders"
4. "Notes: Clear notes inbox" (F11: "about 15-30 notes per week… no more than 5 minutes to move them into notebooks")
5. "Tasks: Clear task manager inbox & plan the week's tasks"

Reglas [HV, F11]: 30 minutos; "Touch each item only once"; "I'm not doing anything, just deciding what
needs to be done" (F13); no revisar todas las metas cada semana ("creates overwhelming lists that
kill motivation"). La versión de 2017 (F13) tenía 7 pasos con "Waiting For" y "Choose Today tasks";
el checklist se simplificó a 5 [HV].

Weekly maintenance del libro *The PARA Method* [SEC, S3]: (1) retitular ítems de la bandeja con
nombres descriptivos; (2) clasificarlos en las carpetas PARA; (3) actualizar proyectos activos
(renombrar, revisar tareas, archivar los irrelevantes).

Monthly [HV, F15, ~17 min]:

1. Metas: "Cross out and move completed goals to 'Completed' heading", "Update timelines", "Update wording/definition", "Add new goals".
2. Lista de proyectos: "Archive any completed or inactive projects", "Update outcome/goal for each project", "Order projects by global priority", "Replicate updated Project List across Evernote, Finder/Dropbox, Google Drive".
3. Áreas: "Evaluate areas and capture any new tasks, projects, habits, routines, or decisions needed", "Replicate list of areas across…".
4. Narrativa personal / visión.
5-8. Someday/Maybe, reprioritizar tareas, extraer highlights de ebooks, vaciar papelera.

Principios de diseño de revisiones [HV, F14]: frecuencia proporcional a la tasa de cambio del ítem;
"It is only through experience that it can be personalized. And it is only through personalization
that it becomes sustainable"; **resistance as feedback**: si revisar algo se siente innecesario, bajar
su frecuencia; tres escalas (weekly, monthly, annual) como capas.

### 2.10 Checklists de proyecto

No hay post primario en fortelabs.com que los enumere (búsquedas F-dominio sin resultado) [NV].
Están en el libro BASB cap. 9 [SEC, S4] y S1 los reproduce ítem por ítem:

- Kickoff [SEC, S1]: "Capture your current thinking on the project"; "Review notes from folders and
  tags"; "Search for related terms across all folders"; "Tag relevant notes to the project"; "Create
  an outline of collected notes and plan".
- Completion [SEC, S1]: "Mark project as complete"; "Cross out the associated project goal and move
  to 'Completed'"; "Review and organize parts that could be reused"; "Move project to archives across
  all platforms"; "If canceled or paused, record current status".

Consistente con el digest [SEC, S4]: kickoff = "qué notas existen ya, qué IPs reutilizar, objetivo,
plan"; completion = "marcar completo, recolectar aprendizajes, mover a Archives, extraer IPs".

### 2.11 Principios transversales (los que un diseño debería honrar)

- "Projects Over Categories: Organize your ideas according to the projects where they will be most
  useful and actionable." [HV, F18]
- "Make it Easier for Your Future Self: Do it a little bit at a time, whenever it's convenient" [HV, F18]
- "Idea Recycling: Ideas are not single-use only. They can outlive the projects they were originally
  a part of." [HV, F18]
- Tres hábitos del libro 2023 [SEC, S3]: organizar según resultados, no por organizar; organizar
  **just-in-time**: "as little as possible, as late as possible, and only as much as is needed";
  mantener todo informal **excepto los proyectos**, que "require precise goal and timeframe
  definitions".
- Setup en 60 segundos [SEC, S3]: (1) archivar todo lo existente en carpetas fechadas; (2) crear
  Projects con subcarpetas por esfuerzo activo; (3) crear Areas/Resources **sólo cuando se
  necesiten** ("never pre-create empty folders"). Coincide con P10 (archivo por carpeta fechada;
  "gradually migrate active items") y P12 ("lazy population… populated by use, not by a heroic
  weekend of sorting").
- Misma estructura en todas las herramientas [HV, F1 "across any platform"; SEC, S3 "Keep the
  system architecture consistent… not all PARA folders need exist on every platform"]. F17 (la
  guía de apps) es un índice de videos y **no** fija convenciones de numeración ni de profundidad
  [HV]; la numeración `1 Projects…4 Archives` y "un solo nivel bajo cada carpeta PARA" vienen de
  practicantes (P9, P10) [HV].
- Tags [HV, F16]: "it is only necessary to use tags when your collection becomes formidable";
  etiquetar "by action/deliverable, not concept" (`[reviewed]`, `[added]`, `[active]`,
  `[completed]`); "The best time to do this is when starting a project"; fallas del tagging que él
  mismo reconoce: "difficult to remember, hard to decide upon, abstract rather than concrete,
  enabling mere cataloguing instead of productive output".
- Working clean [HV, F20]: "Placeholders — Every incoming input… should trigger an immediate 'first
  move'"; "Finishing Mindset — a dish that is 99% finished has zero value".

---

## 3. Reglas operativas mecanizables (no la filosofía)

Cada fila: regla → fuente → forma mecanizable (predicado, campo o cadencia) → quién decide.
"Agente" = ejecutable sin humano; "Propone" = el agente calcula y el humano confirma; "Humano" = no
se mecaniza.

| # | Regla | Fuente | Forma mecanizable | Decide |
|---|---|---|---|---|
| R1 | Test de proyecto: outcome marcable + deadline/timeframe | F2 | `is_project := has(outcome) && has(due)`; si falta uno → no es proyecto (o está mal definido) | Agente (predicado); Humano (zona gris) |
| R2 | Test de área: estándar + continuo | F2, P12 | `is_area := has(standard) && !has(due)`; "finish line test" como pregunta al humano cuando ambos fallan | Propone |
| R3 | Recurso = interés sin estándar ni fecha | S3 | default cuando R1 y R2 fallan y hay al menos un interés/tema declarado | Agente |
| R4 | Cascada de filing proyecto → área → recurso → archivo/no guardar | F3, S1 | ejecutar R1-R3 en orden sobre la lista viva de proyectos/áreas; sin match → recurso o descartar | Agente |
| R5 | Nunca duplicar: mover, enlazar o etiquetar | S3 | invariante verificable: un ítem tiene **una** casa; las demás son referencias | Agente (lint) |
| R6 | Archivo = estado, no borrado; reactivable | F1, S3, P11 | `status: archived` + `archived: YYYY-MM-DD`; reactivar = cambio de estado, sin mover contenido | Agente |
| R7 | Horizonte de revisión por categoría | [INF sobre §2.3]; F14 | proyecto: por proyecto; área: mensual; recurso: bajo demanda; archivo: nunca. Campo `cadence`/`next_review` (P11 usa `cadence:` con valores tipo `14d`, `weekly`, `monthly`) | Agente (cola); Humano (ajuste por "resistance as feedback") |
| R8 | Weekly move-down pass | P12, P9 | semanal: proyectos con `status: done` → archivo; proyectos que resultaron continuos → área | Propone |
| R9 | Weekly review = vaciar bandejas + decidir, no hacer | F11, F12 | 5 pasos; para un agente aplican 4 y 5 (bandeja de notas: retitular, clasificar, archivar irrelevantes; tareas: capturar loops abiertos) | Agente (bandeja); Propone (prioridades) |
| R10 | Monthly review = lista de proyectos + áreas | F15 | archivar completados/inactivos; actualizar outcome de cada proyecto; ordenar por prioridad; replicar la lista en todas las superficies; por área capturar tareas/proyectos/hábitos/decisiones | Agente (archivar, replicar); Propone (prioridad, outcome) |
| R11 | Kickoff checklist | S1, S4 | al crear un proyecto: (a) registrar el pensamiento actual; (b) buscar notas relacionadas (por nombre, tags, texto); (c) enlazarlas al proyecto; (d) producir un outline/plan | Agente |
| R12 | Completion checklist | S1, S4 | al cerrar: (a) marcar completo; (b) mover el objetivo a "Completed"; (c) extraer partes reutilizables (paquetes); (d) archivar en todas las superficies; (e) si pausado/cancelado, registrar estado | Agente (a-d); Humano (decidir el cierre) |
| R13 | Capturar una fracción, no el documento | S4, F6 | excerpt ≤ una fracción de la fuente; la fuente completa vive aparte (inmutable) | Agente |
| R14 | No organizar al capturar; bandeja | S3, S4, P9 | `inbox` como estado computado o carpeta; procesamiento diferido a R9 | Agente |
| R15 | Filtro de favorite problems en captura | F9, F10, F19 | `problems: [id…]` en la nota; match contra la lista viva; sin match → candidato a no guardar | Agente (match); Humano (autoría de la lista) |
| R16 | Cada capa de PS es subconjunto de la anterior y opportunistic | F4, F6 | contador `layer: 1..5`; sólo se sube de capa cuando la nota se toca por otra razón; nunca en batch | Agente |
| R17 | Presupuesto decreciente por capa | F5 | métrica: %L2 ≈ 25 % del original, %L3 ≈ 20 %, %L4 ≈ 5 %; alerta si una nota concentra más de lo esperado ("Don't apply all layers to all notes") | Agente (medir); Propone (podar) |
| R18 | Resumen ejecutivo arriba, en palabras propias (L4) | F4 | sección fija al inicio de la nota; distinguible de los excerpts (L1) | Agente |
| R19 | Cada sesión termina con un paquete intermedio | F7, S4 ("Hemingway Bridge") | al cierre de sesión: estado + próximos pasos + artefacto reutilizable | Agente |
| R20 | Paquetes tipados | S4 (libro cap. 7) | `packet: distilled-note \| outtake \| wip \| deliverable \| external` | Agente |
| R21 | Favorite problems: ~12, How/What, específicas/contraintuitivas/interdisciplinarias, en UNA nota, revisables | F9, F10 | lint: cada problema empieza con How/What; conteo ≤ 12; fecha de última revisión | Agente (lint); Humano (contenido) |
| R22 | Setup: archivar todo lo previo con fecha, empezar por proyectos, crear áreas/recursos bajo demanda | S3, P10, P12 | migración: `archived: <fecha>` masivo + lista de proyectos; **no** pre-crear contenedores vacíos | Agente |
| R23 | Misma estructura en todas las superficies; no todas las carpetas en todas | F1, S3, F15 | la lista de proyectos/áreas es única y se replica como puntero (no copia) | Agente |
| R24 | Tags por acción/estado, no por concepto; añadir estructura al iniciar un proyecto | F16 | vocabulario cerrado de estados; prohibir tags que repliquen carpetas (P9: "recreating your folder tree as tags… is redundant") | Agente (lint) |
| R25 | Just-in-time: lo mínimo, lo más tarde posible | S3, F18 | ningún paso obligatorio de clasificación fina en captura; la estructura crece por uso | Diseño |
| R26 | Placeholders: todo input dispara un "first move" | F20 | captura → una línea en bandeja o log, siempre | Agente |
| R27 | Resistance as feedback | F14 | si una revisión se salta N veces sin consecuencias, bajar su cadencia | Propone |

---

## 4. Qué es inherentemente humano y qué puede ejecutar un agente LLM

### 4.1 Postura del propio Forte sobre la IA (2026)

- [HV, F21, 13-04-2026]: la razón de PARA en la era de la IA es el contexto acotado: "You need to
  be able to find and provide access to only the minimum viable context needed for the task at
  hand"; "When you ask an AI to help you with a project, you can point it at a Project folder". Lo
  que la IA no hace todavía: "reminding you of what's important and what actions need to be taken"
  (notar un archivo y reconocer la acción asociada). Forte organizó a mano 222 archivos en 36 minutos
  y lo considera inversión que vale.
- [HV, F22, 14-02-2026]: apuntó Claude Code a "my entire PARA folder structure" para que escribiera
  un "Master Prompt" de 10 secciones (incluye "8. Your 12 Favorite Problems" y "6. Current life
  context (… active projects …)"). Prefiere ese documento compilado a conectar el LLM a las fuentes:
  "More secure… More compressed and token efficient… More portable… Allows me to edit and choose
  what context I'm providing". [INF] Es exactamente la idea de "wiki compilada" de Karpathy aplicada
  a PARA: el agente lee la estructura y produce un artefacto destilado; el humano lo edita.
- [HV, F23, 13-03-2026]: "a better use for AI is to think more clearly and make better decisions",
  en oposición explícita a "emphasis on execution and autonomy"; advierte que la "memoria" de la IA
  se degrada y que "bigger context windows actually make this worse".

### 4.2 Matriz por paso y hábito

| Pieza del método | Inherentemente humano | Agente autónomo | Semi-autónomo (agente propone, humano confirma) |
|---|---|---|---|
| Capture: resonancia | Sí. Forte la define como intuición afectiva ("System 1… before… System 2") [HV, F6/F3]. Un LLM no "resuena"; si dice que sí, miente. | Captura por señal explícita del operador ("guarda esto"), captura pasiva de sesiones (ya existe: claude-mem, informe C §3.2) | Proxy de resonancia: match con favorite problems + proyectos activos + "surprising" (contradice una página existente) → **candidato**, nunca "resonó" |
| Capture: fracción, no documento | — | Sí: extraer excerpts; guardar la fuente aparte | — |
| Capture: no organizar al capturar | — | Sí: bandeja | — |
| 12 Favorite Problems | Autoría y revisión del contenido (F10: nacen de obsesiones, hobbies, "what your mind wanders toward") | Lint de forma (How/What, ≤12, específicas); match de cada captura contra la lista; reporte de "problemas sin aportes en N días" | Proponer reformulaciones o problemas emergentes a partir de patrones de captura |
| Organize: tests PARA | Zona gris proyecto/área (P12: "Some items genuinely sit on the boundary") | Aplicar R1-R4 cuando los campos existen; mantener la lista de proyectos; archivar por estado | Clasificación cuando faltan campos: preguntar outcome/deadline/estándar |
| Organize: mover entre categorías | Decidir que un proyecto terminó, se pausa o se cancela (R12 e) | Move-down pass sobre estados ya declarados; reactivación al citar un archivado desde un proyecto activo | Detectar "esto parece continuo, ¿es un área?" |
| Distill: capas 1-3 (excerpt, bold, highlight) | Forte: "Use resonance as your criteria" [F5]; el humano subraya lo que le importa | Capa 1 (extraer lo relevante a proyectos/problemas) y capa 4 (resumen ejecutivo en palabras propias) son tareas de lenguaje puras | Capas 2-3: el agente puede proponer negritas/resaltados como "lo más citado / lo que responde a un problema"; el humano valida |
| Distill: oportunismo y presupuesto | Nada | Medir capas y presupuestos (R16-R17); subir de capa sólo al tocar la nota | Podar notas sobre-destiladas |
| Express: paquetes intermedios | Juicio de qué vale reutilizar (R12 c) en parte | Producir el paquete al cierre de sesión; tipar; indexar; reutilizar en kickoff (R11 b-c) | Marcar `deliverable` vs `wip` |
| Weekly review | Prioridades de la semana | Pasos 4-5 sobre la bandeja de notas y loops abiertos; reporte de cambios | Propuesta de prioridades |
| Monthly review | Metas, orden de prioridad global, cierre de proyectos | Archivar completados; replicar listas; evaluar áreas contra sus indicadores si están declarados | Sugerir outcome actualizado por proyecto |
| Kickoff / completion checklists | Decidir abrir/cerrar | Ejecutar los ítems mecánicos (R11, R12 a-d) | Outline inicial |
| Noticing habits | Forte lo define como hábito humano al tocar una nota [S4] | Equivalente máquina: lint de títulos, enlaces rotos, huérfanos, `updated` viejo (ya existe en el repo: `wiki_graph.sh`, informe A) | Sugerir retitulado/enlaces |
| "Reminding you of what's important" | Forte lo reserva al humano [F21] | Sólo si el humano declaró `next-action`/`due`/`cadence` (P11): entonces es una cola computable | Recordatorios derivados de fechas declaradas, nunca de importancia inferida |

Regla de oro que sale de esta matriz [INF]: **el agente puede mecanizar todo lo que se apoya en
campos declarados (outcome, due, standard, status, cadence, problems) y nada de lo que se apoya en
afecto (resonancia, importancia)**. El diseño debe forzar que esos campos existan (kickoff) para que
el resto sea automático, y debe etiquetar como "candidato" toda inferencia de importancia.

---

## 5. Tensiones entre PARA (por acción) y una wiki por tipo (Karpathy), y cómo las resuelven los practicantes

### 5.1 La tensión, dicha por sus protagonistas

- Sascha (zettelkasten.de, 26-06-2023) [HV, P2]: "BASB speaks the language of action. ZKM speaks the
  language of knowledge"; PARA es "a hierarchy of urgency", el Zettelkasten "a hierarchy-free
  network"; "The processing of knowledge, knowledge work, is explicitly *not* part of BASB".
- Nick Milo (foro Obsidian, 20-07-2023) [HV, P3]: "Over half the time I don't know what exactly I'm
  thinking about" — PARA exige decidir proyecto/área al capturar; su respuesta es ACE: "Atlas is for
  the SPACE of knowledge and ideas; Calendar is for moments in TIME; Efforts are for projects of
  IMPORTANCE". Efforts funde Projects+Areas en intensidades [HV, P4]: On ("the most active efforts &
  projects"), Ongoing ("broader, ongoing efforts"), Simmering ("back of mind efforts"), Sleeping
  ("everything else (random, done, cold storage, etc)"); "Too much going on? Move an effort from On
  to Simmering."
- Matt Giaro [HV, P7]: usar PARA para las notas "limits the effectiveness of the Zettelkasten"
  porque en ZK "the structure is meant to emerge by itself".
- Forte mismo, en el otro sentido [HV, F1 sección "Can AI Organize Your Files According to PARA?",
  F21]: PARA existe para entregar "minimum viable context" por proyecto; una wiki por tipo no
  responde "qué necesito ahora" sin una capa adicional.
- Karpathy (informe E §6) [HV allí]: cero menciones a PARA; su "append-and-review note" es el
  anti-PARA (sin carpetas ni tags); el gist organiza por ontología (entities/concepts/comparisons).

### 5.2 Las resoluciones observadas (todas verificadas en la fuente indicada)

| Patrón | Quién | Cómo | Consecuencia para un diseño |
|---|---|---|---|
| **Una casa por tipo, PARA en metadatos** | PARA-Tree [HV, P11] | Frontmatter: `type: project \| area \| resource`, `area:` (wikilink al tronco), `status: active \| in-progress \| idea \| done \| ready-to-publish \| archived`, `cadence:` (`14d`, `weekly`, `monthly`), `goal:`, `next-action:`, `project:` (en recursos), `promoted-to:` (proyecto que se vuelve área). "nodes are matched by note name… give projects/resources unique basenames." | PARA no necesita carpetas: basta un eje en frontmatter + vistas derivadas. Los campos `goal`/`next-action`/`cadence` son exactamente los que hacen mecanizables R1, R7 y R10 |
| **Carpetas = casa por accionabilidad; tags = estado y tipo** | obsibrain [HV, P9]; Forte [HV, F16] | "Use PARA for where notes live and tags for status and type — they're complementary, not competing"; Forte: tags "tunnel through the walls of our siloed folders"; "The classic mistake is recreating your folder tree as tags" | Simétrico al anterior: elegir UN eje para la ubicación y el otro para metadatos. Nunca ambos en carpetas |
| **La wiki vive dentro de Resources** | osgav [HV, P6]: "Can the R of my P.A.R.A. be my Zettelkasten? Yes."; webinspect [HV, P5]: "all of my atomic notes are in Resources"; Forte [HV, F22]: "my Obsidian vault (under Resources)" | El conocimiento por tipo es un recurso; proyectos y áreas son punteros/MOCs hacia él | Encaja con el repo: el vault entero es "R"; falta la capa P/A encima, no dentro |
| **MOC-as-category** | dennes [HV, P5]: "a document can have as many parents as you like" | Una página-mapa por proyecto/área que enlaza páginas del wiki sin moverlas | Proyecto = página índice (MOC) con `goal`/`due`; el wiki no se toca |
| **Bandeja como consulta** | bulletninja [HV, P5]: "a dataview query to list… notes with the #inbox tag"; notas "sometimes upgraded as part of an existing or a new Project, Area, Resource or Archive" | La bandeja es un **estado computado**, no una carpeta | Coincide con "pending ingest como estado computado" de E §5.2 |
| **Archivo como carpeta fechada, sin reclasificar** | byarbrough [HV, P10]; libro 2023 [SEC, S3] | Al migrar: mover todo intacto a `4. Archive/<fecha>` y sacar hacia P/A/R sólo lo que se use | Estrategia de adopción sin big-bang; equivalente por estado: `archived: <fecha>` masivo |
| **Profundidad acotada** | byarbrough [HV, P10]: "only one folder below each of these four PARA folders"; obsibrain [HV, P9]: "most notes should sit one or two levels deep, never five" | Límite duro de anidamiento | Lint de profundidad si se usan carpetas |
| **Intensidades en vez de P/A** | Milo [HV, P4] | On/Ongoing/Simmering/Sleeping como estados de un "effort" | Alternativa: `status` con cuatro valores en vez de dos categorías; resuelve la zona gris P/A convirtiéndola en un dial |
| **Vistas derivadas** | Dataview (P5, P9), PARA-Tree (P11), Periodic Notes (P9) | Listas de proyectos activos, cola de revisión, bandeja, todo consultado desde frontmatter | En un vault sin Obsidian abierto (agente headless), la vista derivada la produce un script determinista (el repo ya tiene `.graph/*.json`, informe A) |

### 5.3 Lectura para 037 [INF, no re-litiga C/D]

Las tres resoluciones compatibles con "the only six" (informe C §5, D §2.1) son las de la tabla: (a)
PARA como **eje de frontmatter** (`para:`/`status`/`cadence`/`goal`/`next_action`) sobre los tipos
existentes; (b) proyectos y áreas como **páginas-mapa** (MOC) que apuntan al wiki, no como
directorios que lo fragmentan; (c) bandeja y cola de revisión como **estados computados** por el
grafo derivado. Lo que la evidencia desaconseja: PARA como carpetas paralelas a `wiki/` (fragmenta,
rompe wikilinks — C §5.4) y PARA como tags que repliquen carpetas (P9, F16).

---

## 6. Críticas documentadas al método (qué evitar por diseño)

| Crítica | Fuente | Evidencia verbatim | Mitigación de diseño [INF] |
|---|---|---|---|
| **Collector's fallacy**: guardar ≠ saber | Tietze, 20-01-2014 [HV, P1]; Keiffenheim, 30-06-2025 [HV, P8] | "to know about something isn't the same as knowing something"; remedios: "read and highlight… shortly after obtaining", "reading without taking notes is just a waste of time in the long run", ciclos cortos, límites de tiempo. Keiffenheim: "a beautiful, well-organized, time-consuming digital graveyard"; "the bottleneck of retrieving the right thing at the right moment so it can lead to action-oriented insight" | Medir **uso**, no volumen: tasa de páginas citadas en respuestas/paquetes; bandeja con vencimiento; captura que no llega a capa 1 en N días se descarta o archiva. Karpathy ya empuja lo mismo (E: "file good answers back") |
| **PS prepara, no procesa** | Sascha, 26-06-2023 [HV, P2] | highlighting "is merely preparing resources so that they are easier to skim"; "The processing of knowledge, knowledge work, is explicitly *not* part of BASB" | En una wiki compilada el "procesar" ya existe (summary → concept/synthesis en palabras propias). No importar las capas 2-3 (bold/highlight) como fin; importar la capa 4 (resumen propio) y el presupuesto decreciente |
| **Sobre-organización / anidamiento** | obsibrain [HV, P9]; byarbrough [HV, P10]; Forte [HV, F18 "Make it Easier for Your Future Self… a little bit at a time"] | "Building deep nested subfolders before you have notes to fill them" es error común; "never pre-create empty folders" [S3] | Just-in-time (R25): sin contenedores vacíos; profundidad ≤ 2; lint |
| **Churn de mover archivos** | Giaro [HV, P7] | "When things change, folders, notes, and assets start moving around"; "PARA doesn't handle Templates or 'recycling files'" | PARA por estado/metadato, nunca por ruta: cambiar de categoría es editar un campo. Paquetes tipados (R20) resuelven "recycling" |
| **Fronteras difusas P/A y A/R** | Giaro [HV, P7]; iwoszapar [HV, P12 "Projects-Areas Gray Zone"]; Milo [HV, P3] | "Some items genuinely sit on the boundary"; Milo: no se sabe qué se está pensando al capturar | Capturar sin clasificar (bandeja); el agente clasifica **sólo** con campos declarados; en zona gris pregunta (finish line test) o usa intensidades (Milo) |
| **Resources como cajón de sastre** | iwoszapar [HV, P12 "Resources Bucket Bloat… a junk drawer"] | sin poda activa, Resources crece sin uso | `stale` ya existe en el repo (A/C); añadir "sin citas en N días → candidato a archivo" |
| **PARA no captura ni usa** | iwoszapar [HV, P12] | "PARA organizes, it does not capture or use" | No vender PARA como el RAG; es el eje de prioridad sobre el RAG existente |
| **Impuesto de mantención** | iwoszapar [HV, P12 "Manual Maintenance Tax"]; Forte [HV, F14] | "The weekly audit is small but essential; skipping it causes system decay" | Que la mantención mecánica la haga el agente (R8-R10) y que el humano sólo decida |
| **Tagging que falla** | Forte contra sí mismo [HV, F16] | tags "difficult to remember, hard to decide upon, abstract… enabling mere cataloguing" | Vocabulario cerrado de estados/acciones, validado por lint; cero tags temáticos libres |
| **PARA vs ZK: la estructura debe emerger** | Giaro [HV, P7]; Sascha [HV, P2] | "the structure is meant to emerge by itself" | El wiki por tipo (Karpathy) ya es la parte emergente; PARA sólo prioriza. No reordenar el wiki por proyecto |
| **La IA no sabe qué es importante** | Forte [HV, F21] | "reminding you of what's important and what actions need to be taken" queda humano | Importancia sólo desde campos declarados; recordatorios derivados de `due`/`cadence`, nunca de inferencia |
| **Contra-crítica**: ZK es más caro que PARA+PS | zainrizvi [HV, P13] | ZK "HUGE barrier to entry"; PARA+PS "80% of the way there with 20% of the effort"; "Just in Time linking" | No exigir enlazado exhaustivo en captura; enlazar en kickoff (R11) y al destilar |

---

## 7. Lo que no encontré o no pude verificar

1. **"forwarding knowledge through time" / "cold storage" / "scheduled for review"**: atribuido a
   Forte por un resumen de búsqueda; no está en F1, F24 ni en otra página de fortelabs.com que haya
   abierto. Muy probablemente es el libro BASB cap. 5. Tratado como [NV]; el diseño no debe citarlo
   como fuente primaria.
2. **La coda "or not save it at all"** de la cascada de filing: misma situación [NV]. La cascada sin
   coda está en S1 [SEC]; la pregunta base está en F3 [HV].
3. **Checklists de kickoff/cierre**: sin post primario; sólo libro (cap. 9) vía S1/S4 [SEC].
4. **Cinco tipos de paquetes intermedios**: sólo libro (cap. 7) vía S4 (y S2 parcial); F7/F8 no los
   enumeran [HV].
5. **Regla "10-20 %" de Progressive Summarization** que menciona el encargo: no existe como tal en
   F4/F5/F6. Lo publicado es 50/25/20/5/<1 % del original por capa [HV, F5]. Ninguna página da un
   "10 %" de captura.
6. **Reglas de Forte para PARA en Obsidian/Notion**: F17 es un índice de videos; no fija numeración,
   profundidad ni frontmatter [HV]. Las convenciones concretas son de practicantes (P9-P11).
7. **"10 reglas" o "60 segundos" del libro *The PARA Method* (2023)**: el "60-Second PARA Setup" de
   tres pasos y los "Three Core Habits" existen según S3 [SEC]; no hay "10 rules" verificables.
8. **Cadencia de revisión de los favorite problems**: F10 dice que deben evolucionar; no fija
   frecuencia [HV].
9. Cuatro artículos de Medium del directorio: bloqueados por Cloudflare; no aportan.

---

## 8. Implicaciones para la spec 037 (síntesis, todo [INF] salvo lo citado)

1. **Declarar la extensión como propia**: Karpathy no menciona PARA (E §6); Forte no menciona wiki
   compilada pero sí usa Claude Code para compilar su PARA en un "Master Prompt" (F22). La spec puede
   presentar 037 como "Karpathy define el qué; Forte aporta el para-qué y la cadencia", como ya
   sugiere E §6.
2. **PARA como eje, no como tipo**: los campos de PARA-Tree (P11) son un molde probado en Obsidian:
   `para`/`status`/`cadence`/`goal`/`next_action`/`area`. Encaja en C §5.1 (frontmatter, costo cero
   en el linter) y evita las críticas de churn y fragmentación (§6).
3. **Los tests, no la filosofía, van al `CLAUDE.md` del vault**: R1-R4 (outcome+due → proyecto;
   estándar+continuo → área; cascada) y R5-R6 (una casa; archivo por estado). Son predicados, no
   prosa.
4. **Kickoff y completion como operaciones del vault** (R11, R12): son exactamente las dos ocasiones
   en que Forte exige "precisión" (S3: los proyectos requieren "precise goal and timeframe"); el
   resto del método es informal por diseño.
5. **Weekly/monthly review**: separar lo mecánico (bandeja, move-down, archivar, replicar lista,
   cola por `cadence`) —que puede ser un finding determinista del grafo (C §5.7 opción B) o una
   operación del agente— de lo decisional (prioridades, cierres), que es humano. F14 da además una
   regla de auto-ajuste ("resistance as feedback") que se puede medir.
6. **Favorite problems**: una sola página, lint de forma (How/What, ≤12), campo `problems:` en las
   páginas capturadas, y un reporte "problemas sin aportes"; la autoría es humana.
7. **Progressive Summarization**: no intentar capas 2-3 (bold/highlight) sobre `raw_sources/`
   inmutable (C §4); tomar de PS el presupuesto decreciente y el oportunismo, y mapear L4 al resumen
   ejecutivo de `summary`. La crítica de Sascha (§6) indica que el valor está en L4-L5, que es lo que
   el wiki ya hace.
8. **Paquetes**: el tipo `synthesis` con `packet:` tipado (C §5.2) cubre R19-R20 sin séptimo tipo;
   la regla "cada sesión deja un paquete" es el Hemingway Bridge y se puede exigir en el protocolo
   de cierre.
9. **Anti collector's fallacy como criterio de éxito**: medir uso (páginas citadas, paquetes
   reutilizados en kickoff) en vez de volumen; bandeja con vencimiento. Es la única forma de que el
   sistema no se convierta en el "digital graveyard" de P8.
10. **Lo que no se automatiza y hay que decir en la spec**: resonancia, importancia, cierre de
    proyectos, zona gris P/A. El agente clasifica con campos declarados y marca el resto como
    candidato; Forte (F21, F23) fija esa frontera él mismo.
