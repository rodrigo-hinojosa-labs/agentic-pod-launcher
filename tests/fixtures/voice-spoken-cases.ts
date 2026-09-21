// 034 — normalization cases for _voiceSpokenNormalize (research R4, contract spoken-text-pipeline.md C8).
// Plain TS data, NO export: DOCKER_E2E E9 concatenates this file after the extracted helpers and
// runs the table under the container's bun. Entries without `lang` run with TELEGRAM_VOICE_STT_LANG
// empty (Spanish word table); `lang: 'en'` entries run with TELEGRAM_VOICE_STT_LANG=en.
// Generated once from the Phase 0 prototype (38 Spanish cases + 1 English) — 38/38 + 1/1 measured
// under bun 1.3.12 on 2026-09-18. Real emoji/accent glyphs are DATA here (not patcher constants).

const VOICE_SPOKEN_CASES: { in: string; want: string; lang?: string }[] = [
  { in: '**Total:** $1.234.567 (12% más que ayer)', want: 'Total: 1.234.567 pesos chilenos (12 por ciento más que ayer).' },
  { in: '# Resumen\nTodo bien.', want: 'Resumen. Todo bien.' },
  { in: '1. Uno\n2. Dos\n3. Tres', want: 'Uno. Dos. Tres.' },
  { in: '- alfa\n- beta', want: 'alfa. beta.' },
  { in: 'Mira [el reporte](https://example.com/x?a=1) hoy.', want: 'Mira el reporte hoy.' },
  { in: 'Ver https://example.com/abc ahora', want: 'Ver ahora.' },
  { in: 'Listo ✅ y 🚀 vamos', want: 'Listo y vamos.' },
  { in: 'US$ 500 y USD 300', want: '500 dólares y 300 dólares.' },
  { in: 'UF 30 más 12 UF', want: '30 unidades de fomento más 12 unidades de fomento.' },
  { in: 'Cuesta CLP 4.500 o $4.500', want: 'Cuesta 4.500 pesos chilenos o 4.500 pesos chilenos.' },
  { in: 'Subió 12,5% este mes', want: 'Subió 12,5 por ciento este mes.' },
  { in: 'Ya está en texto plano.', want: 'Ya está en texto plano.' },
  { in: '```\ncode here\n```\nDespués.', want: 'Después.' },
  { in: 'Usa `git push` ahora', want: 'Usa git push ahora.' },
  { in: '_cursiva_ y *otra* y ~~tachado~~', want: 'cursiva y otra y tachado.' },
  { in: 'un millón de pesos ya escrito', want: 'un millón de pesos ya escrito.' },
  { in: 'la variable $HOME no es plata', want: 'la variable HOME no es plata.' },
  { in: '$1.234,50 con decimales', want: '1.234,50 pesos chilenos con decimales.' },
  { in: '> cita\n| a | b |', want: 'cita. a b.' },
  { in: 'Dos montos: $100 y $200.', want: 'Dos montos: 100 pesos chilenos y 200 pesos chilenos.' },
  // review additions (runtime/F1)
  { in: '$1500', want: '1500 pesos chilenos.' },
  { in: 'multa de $25000', want: 'multa de 25000 pesos chilenos.' },
  { in: 'US$ 1500', want: '1500 dólares.' },
  { in: 'USD 2500', want: '2500 dólares.' },
  { in: 'UF 1000', want: '1000 unidades de fomento.' },
  { in: 'CLP 4500', want: '4500 pesos chilenos.' },
  { in: 'vale $2024', want: 'vale 2024 pesos chilenos.' },
  { in: '1500 USD', want: '1500 dólares.' },
  // review additions (runtime/F2)
  { in: 'Resumen\n---\nFin', want: 'Resumen. Fin.' },
  { in: '***', want: '' },
  { in: '* * *', want: '' },
  { in: 'a\n-\nb', want: 'a. b.' },
  { in: '| Item | Monto |\n|---|---|\n| Pan | $500 |', want: 'Item Monto. Pan 500 pesos chilenos.' },
  { in: '|:---:|:---|\nx', want: 'x.' },
  { in: 'Título\n=====\nTexto', want: 'Título. Texto.' },
  { in: 'Listo ✅ 🇨🇱 👍🏽 vamos', want: 'Listo vamos.' },
  { in: '1️⃣ primero', want: '1 primero.' },
  { in: 'Reunión 10:30 y 3.5% de IVA', want: 'Reunión 10:30 y 3.5 por ciento de IVA.' },
  { in: 'Total: $1.234.567 (12% up)', want: 'Total: 1.234.567 Chilean pesos (12 percent up).', lang: 'en' },
]
