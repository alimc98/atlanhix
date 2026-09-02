# NEXUS UX Rules

1. **Never block** — every async action shows immediate feedback (<100 ms) and
   remains cancellable (connect, test, update subscription).
2. **States are explicit** — every screen implements empty / loading / error /
   partial-error states. Node list: skeletons while testing batch; per-node
   health dot always reflects *last known* state with a relative timestamp.
3. **Errors are sentences** — [message] + [likely cause] + [next action].
   Raw errors live one tap away ("View technical details").
4. **Confirmation only where destructive** — delete node/profile/subscription;
   nothing else. Connect/disconnect are always instant, never confirmed.
5. **Keyboard first (desktop)** — `Ctrl+K` command palette: connect/disconnect,
   switch node, run test, open screens. Full tab order; focus rings visible.
6. **Screen readers** — all state communicated via semantics labels
   ("Connected to London 01, 32 ms, healthy", not just color).
7. **Contrast** — text ≥ 4.5:1, large text ≥ 3:1, status colors paired with
   icons/shapes (never color-only).
8. **RTL** — layout mirrors via directional padding/edges; numbers stay
   Latin-digit mono in metrics; Persian strings never mid-word break.
9. **Touch targets ≥ 44 px**; desktop lists support hover previews.
10. **Optimistic UI, honest results** — UI shows the intended action
    immediately; failures roll back with explanation.
