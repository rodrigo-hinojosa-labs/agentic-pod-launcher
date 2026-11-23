// Provenance: telegram@claude-plugins-official 0.0.7, server.ts lines 80-87,
// copied verbatim on 2026-11-23 (feature 049, tasks T004). These are the
// vendor handlers that, together with the stderr-capture v1 hook, form the
// EPIPE loop of issue #139. Do not edit: the loop test needs the vendor shape.
// Last-resort safety net — without these the process dies silently on any
// unhandled promise rejection. With them it logs and keeps serving tools.
process.on('unhandledRejection', err => {
  process.stderr.write(`telegram channel: unhandled rejection: ${err}\n`)
})
process.on('uncaughtException', err => {
  process.stderr.write(`telegram channel: uncaught exception: ${err}\n`)
})
