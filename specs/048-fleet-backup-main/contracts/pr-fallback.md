# Contract P: camino de pull request cuando `main` está protegida

Se activa solo cuando el empuje del paso 8 de M2 es rechazado con un mensaje de protección (M2 de research: `GH006`, `protected branch hook declined` o el rechazo por regla). Un rechazo por no fast-forward nunca lo activa.

## P1. Pasos

1. Empujar el mismo commit a `refs/heads/agent-backup-pr/<u>-<epoch>`.
2. `POST /repos/{owner}/{repo}/pulls` con `head=agent-backup-pr/<u>-<epoch>`, `base=main`, título igual al asunto del commit y cuerpo fijo: `Automated backup of <agente>/<u> by agentic-pod-launcher. It changes only .agent-backup/<u>/.`
3. `PUT /repos/{owner}/{repo}/pulls/{n}/merge` con `merge_method=merge`.
4. Merge 200: borrar la rama temporal; resultado `ok`, `pr_fallback: {number, result: merged, at}`; continuar con el paso 9 de M2.
5. Cualquier otro resultado en 2 o 3 (405, 403, 409, 422, red): si hay pull request, `PATCH .../pulls/{n}` con `state=closed`; borrar la rama temporal; resultado `main-protected`, `pr_fallback: {number, result: <código>, at}`.

## P2. Reglas

- Base de la API: `https://api.github.com`, sobreescribible solo por la costura de pruebas `BACKUP_GH_API_BASE`, que acepta únicamente `https://api.github.com` o `http://127.0.0.1:<puerto>` (patrón de `TELEGRAM_API_BASE` de 040).
- El token va en un archivo de configuración de `curl` (`-K`) con modo 0600, creado y borrado dentro de la llamada; nunca en `argv`, en el entorno de otro hijo, en logs ni en el estado.
- Cada llamada tiene `--max-time 20`; el camino completo, un presupuesto de 90 s.
- La rama temporal empieza con `agent-backup-pr/`, nunca con `backup/`, para que el refspec negativo del clon de trabajo y la regla de propiedad no la confundan.

## P3. Invariantes que prueban los tests

- P-I1: con el servidor de prueba en modo "protegido, merge permitido", el commit de respaldo llega a `main` y no queda rama temporal.
- P-I2: en modo "protegido, merge prohibido", `main` no cambia, el pull request queda cerrado y no queda rama temporal.
- P-I3: el token no aparece en `argv` de ningún proceso hijo (espía de `curl`) y el archivo de configuración tiene modo 0600 al momento de la llamada.
