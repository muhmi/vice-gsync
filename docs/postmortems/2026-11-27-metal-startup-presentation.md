# GPU completion did not establish startup presentation

A native window's first submission completed GPU work but returned a zero
`presentedTime`. Retaining the renderer did not turn that submission into a
positive presentation. Subsequent submissions after AppKit startup did obtain
positive timestamps. This ruled out renderer destruction as the sole cause;
the precise compositor startup condition was not isolated.

The visible lifetime test establishes a successful presentation, then submits
again and destroys the renderer before consuming that submission's callback.
It requires a positive timestamp joined to the immutable frame identity.
Submission records report zero/unresolved timestamps explicitly.

Ref: [native test](../../vice/src/arch/gtk3/tests/metal_pixels.m),
[callback ownership](../../vice/src/arch/gtk3/metal_renderer_macos.m).
